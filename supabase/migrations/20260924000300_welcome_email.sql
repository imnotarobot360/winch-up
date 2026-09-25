-- Winch Up :: the welcome email, fired by the one event that actually means "verified"
--
-- §5 says send it after successful email verification, once. The hard part is "after": Supabase
-- Auth owns verification and does not emit a server-side event this app can subscribe to. The
-- obvious workarounds are both wrong. Sending it from the /auth/callback route means a member who
-- opens the link on a phone with no signal, or closes the tab during the redirect, never gets it.
-- Sending it on first authenticated page load means the email arrives when they next visit, which
-- for somebody who verified and walked away is never.
--
-- The event does exist, though, in the only place that cannot be skipped: auth.users.
-- email_confirmed_at goes from null to a timestamp exactly once, written by Supabase itself
-- inside the transaction that verifies the link. A trigger on that transition fires whether or
-- not the browser survived the redirect.
--
-- This follows the rule in CLAUDE.md -- notification producers are triggers, never calls added to
-- existing functions -- for the same reason it was written: a producer bolted onto a code path
-- only fires when that code path runs, and the whole problem here is that it might not.
--
-- ONCE, AND WHY IT IS NOT A CHECK
--
-- The trigger does not ask whether a welcome email was already sent. It inserts with
-- idempotency_key = 'welcome:<user id>' and lets the unique index refuse the second one. A check
-- would be a read-then-write, and the case it has to survive -- two things confirming the same
-- account at once -- is exactly the one a read-then-write loses.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- app.queue_welcome_email
--
-- LOCALE. There is no locale column on profiles; the language is a URL segment, and a member who
-- has not been to /join yet has no responders row either. So the only answer available at signup
-- is the one the browser put in raw_user_meta_data when it called signUp, which auth-form.tsx now
-- sends. English when there is nothing, which is the same fallback push uses.
-- ---------------------------------------------------------------------------

create or replace function app.queue_welcome_email()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_locale text;
begin
  -- Phone-OTP accounts have no address. Nothing to send, and no row worth writing.
  if new.email is null or new.email = '' then
    return new;
  end if;

  v_locale := coalesce(nullif(new.raw_user_meta_data ->> 'locale', ''), 'en');
  if v_locale not in ('en', 'es') then
    v_locale := 'en';
  end if;

  insert into public.email_deliveries (user_id, template_key, locale, status, idempotency_key)
  values (new.id, 'auth.welcome', v_locale, 'queued', 'welcome:' || new.id)
  on conflict (idempotency_key) where idempotency_key is not null do nothing;

  return new;
end;
$$;

-- Two triggers rather than one with a compound condition, because the conditions are genuinely
-- different events and a single WHEN clause covering both reads as though somebody was being
-- clever.

-- The normal path: Supabase writes email_confirmed_at when the link is opened.
drop trigger if exists on_email_confirmed on auth.users;

create trigger on_email_confirmed
  after update of email_confirmed_at on auth.users
  for each row
  when (old.email_confirmed_at is null and new.email_confirmed_at is not null)
  execute function app.queue_welcome_email();

-- Already confirmed at creation: a project with confirmations switched off, an admin-created
-- account, or a seeded one. Without this they are silently never welcomed, and that is the
-- configuration a self-hosted or a local stack runs in -- so the gap would be invisible in
-- development and appear only in production, or the reverse.
drop trigger if exists on_user_created_confirmed on auth.users;

create trigger on_user_created_confirmed
  after insert on auth.users
  for each row
  when (new.email_confirmed_at is not null)
  execute function app.queue_welcome_email();

-- ---------------------------------------------------------------------------
-- public.claim_email_deliveries
--
-- Hands the drain a batch to send, and marks them so a second drain cannot take the same rows.
--
-- The recipient address is JOINED here and never stored -- that is the whole reason
-- email_deliveries has no address column. It is read at the moment of sending, from the one
-- place that is authoritative, which also means an account deleted between queueing and sending
-- simply drops out of the join instead of being mailed.
--
-- `for update skip locked` rather than a plain update: two overlapping drains must take
-- different rows, not the same rows twice. Matches claim_push_deliveries.
-- ---------------------------------------------------------------------------

create or replace function public.claim_email_deliveries(p_limit integer default 50)
returns table (
  id          uuid,
  user_id     uuid,
  to_email    text,
  template_key text,
  locale      text
)
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  return query
  with claimed as (
    select d.id
    from public.email_deliveries d
    where d.status = 'queued'
    order by d.created_at
    limit greatest(1, least(coalesce(p_limit, 50), 200))
    for update skip locked
  ),
  marked as (
    update public.email_deliveries d
       set status = 'sending', attempts = d.attempts + 1
      from claimed c
     where d.id = c.id
    returning d.id, d.user_id, d.template_key, d.locale
  )
  select m.id, m.user_id, u.email::text, m.template_key, m.locale
  from marked m
  join auth.users u on u.id = m.user_id
  where u.email is not null;
end;
$$;

-- ---------------------------------------------------------------------------
-- public.record_email_result
--
-- Separate from the claim so a crash between the two leaves a row in `sending` rather than one
-- that looks queued and gets sent twice. A stuck `sending` row is visible and re-runnable; a
-- duplicate email is neither.
-- ---------------------------------------------------------------------------

create or replace function public.record_email_result(
  p_id uuid,
  p_status text,
  p_provider text default null,
  p_message_id text default null,
  p_error text default null
)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if p_status not in ('sent', 'failed', 'skipped', 'queued') then
    raise exception 'record_email_result: bad status %', p_status;
  end if;

  update public.email_deliveries
     set status              = p_status,
         provider            = coalesce(p_provider, provider),
         provider_message_id = coalesce(p_message_id, provider_message_id),
         failure_reason      = left(p_error, 500),
         -- A row put back to `queued` for a later retry has not completed, and saying it did
         -- would make the retry look like a second send.
         completed_at        = case when p_status = 'queued' then null else now() end
   where id = p_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
--
-- The claim and record pair live in 'public', not 'app', for one reason: the drain calls them
-- through supabase-js, which goes over PostgREST, and PostgREST can only see the exposed schema.
-- An 'app' function is invisible to it -- the call would 404 forever and the queue would fill up
-- silently. This mirrors public.claim_push_deliveries / public.record_push_result exactly.
--
-- Revoked from everyone and granted only to service_role, so the only caller is the drain. The
-- trigger function stays in 'app' because nothing outside Postgres ever calls it.
-- ---------------------------------------------------------------------------

revoke all on function app.queue_welcome_email() from public, anon, authenticated;

revoke all on function public.claim_email_deliveries(integer) from public, anon, authenticated;
grant execute on function public.claim_email_deliveries(integer) to service_role;

revoke all on function public.record_email_result(uuid, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.record_email_result(uuid, text, text, text, text) to service_role;
