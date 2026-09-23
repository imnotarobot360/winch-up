-- Winch Up :: web push
--
-- Spec section 7: when a request is submitted, tell nearby members who are available and have
-- asked to hear about it. The notification system has carried 'push' in its channel enum since
-- Phase 13 and has been writing "push delivery is not built yet" into last_error ever since.
-- This builds it.
--
-- WHY PUSH AND NOT SMS
--
-- Twilio A2P 10DLC is still not approved, so the SMS ring cannot actually reach anybody in
-- production. Web push needs no carrier, no registration and no per-message cost, and this app
-- is already an installable PWA with a service worker. It is the only channel that works today.
--
-- WHERE THE SENDING HAPPENS
--
-- Not here. Push needs an HTTPS request to a browser vendor's endpoint and an aes128gcm payload
-- encrypted to a per-subscription key; neither belongs in, or is possible from, a Postgres
-- function. So this mirrors how SMS already works in this codebase -- the database decides who
-- should be told and records what happened, and a Node drain does the sending. The copy lives in
-- TypeScript with the SMS templates, for the same reason it does there.
--
-- `drain_notifications` therefore stops touching push rows entirely rather than marking them
-- suppressed. They stay queued until the Node side claims them.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- Subscriptions
-- ---------------------------------------------------------------------------
--
-- One row per browser, not per person: somebody with a phone and a laptop has two, and both
-- should buzz. The endpoint is the identity -- it is what the push service routes on -- and it is
-- unique, so re-subscribing the same browser updates rather than duplicating.
--
-- p256dh and auth are the subscription's public key and shared secret. They are not credentials
-- for anything of ours; they are what a payload is encrypted TO, so only that browser can read
-- it. Stored because there is no way to send without them, and useless to anybody else.

create table if not exists public.push_subscriptions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  endpoint      text not null unique,
  p256dh        text not null,
  auth          text not null,
  user_agent    text,
  created_at    timestamptz not null default now(),
  last_used_at  timestamptz,
  -- A browser that has been uninstalled or had permission revoked answers 404/410 forever.
  -- Counted so the sender can drop it rather than retrying into nothing every minute.
  failure_count integer not null default 0
);

create index if not exists push_subscriptions_user_idx
  on public.push_subscriptions (user_id);

alter table public.push_subscriptions enable row level security;

revoke all on public.push_subscriptions from public, anon, authenticated;

-- Deny by default, then one narrow grant: a member may see and delete their own registrations,
-- which is what "manage your devices" means. Writes go through the RPC below so the user_id is
-- taken from the session rather than the request body.
grant select, delete on public.push_subscriptions to authenticated;

drop policy if exists push_subscriptions_own_select on public.push_subscriptions;
create policy push_subscriptions_own_select on public.push_subscriptions
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists push_subscriptions_own_delete on public.push_subscriptions;
create policy push_subscriptions_own_delete on public.push_subscriptions
  for delete to authenticated
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Registering a browser
-- ---------------------------------------------------------------------------

create or replace function public.save_push_subscription(
  p_endpoint   text,
  p_p256dh     text,
  p_auth       text,
  p_user_agent text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  if p_endpoint is null or length(btrim(p_endpoint)) < 20
     or p_p256dh is null or p_auth is null then
    return jsonb_build_object('ok', false, 'error', 'incomplete_subscription');
  end if;

  -- The endpoint is the identity. A browser that re-subscribes -- which it does whenever the
  -- push service rotates it -- must land on its own row, and must be able to change hands if the
  -- same device is later used by a different account.
  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth, user_agent)
  values (v_uid, btrim(p_endpoint), p_p256dh, p_auth, left(coalesce(p_user_agent, ''), 300))
  on conflict (endpoint) do update
     set user_id       = excluded.user_id,
         p256dh        = excluded.p256dh,
         auth          = excluded.auth,
         user_agent    = excluded.user_agent,
         failure_count = 0;

  return jsonb_build_object('ok', true);
end;
$fn$;

revoke all on function public.save_push_subscription(text, text, text, text) from public, anon;
grant execute on function public.save_push_subscription(text, text, text, text)
  to authenticated, service_role;

create or replace function public.delete_push_subscription(p_endpoint text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  delete from public.push_subscriptions
   where endpoint = p_endpoint and user_id = v_uid;

  return jsonb_build_object('ok', true);
end;
$fn$;

revoke all on function public.delete_push_subscription(text) from public, anon;
grant execute on function public.delete_push_subscription(text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- What the sender claims
-- ---------------------------------------------------------------------------
--
-- Returns one row per (delivery, browser): a person with two devices gets two sends for one
-- notification, and each can fail independently.
--
-- `attempts` is incremented here, at claim time, not after the send. If the sender crashes
-- mid-flight the row has still burned an attempt, which is the safe direction -- the alternative
-- is a delivery that retries forever because nothing ever recorded that it was tried.

-- In `public`, not `app`, and this is the exception that proves the rule rather than a slip.
-- Internal helpers live in `app` precisely so PostgREST cannot reach them -- but the caller here
-- IS PostgREST, holding the service-role key, exactly as it is for drain_notifications. A
-- function in `app` would be invisible to it. The protection is the grant: service_role only,
-- revoked from anon and authenticated, so the fact that it is reachable is not the same as it
-- being callable.
create or replace function public.claim_push_deliveries(p_limit integer default 100)
returns table (
  delivery_id     uuid,
  subscription_id uuid,
  endpoint        text,
  p256dh          text,
  auth            text,
  kind            notification_kind,
  title_key       text,
  params          jsonb,
  -- Which language to send in. There is no locale on profiles -- the language is a URL segment,
  -- not a stored preference -- so the only recorded answer is the one the volunteer gave when
  -- they set up their recovery profile. English when there is nothing.
  locale          text
)
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
begin
  return query
  with due as (
    select d.id
      from public.notification_deliveries d
     where d.channel = 'push'
       and d.state in ('queued', 'failed')
       and d.attempts < 3
       and d.next_attempt_at <= now()
     order by d.created_at
     limit greatest(1, least(coalesce(p_limit, 100), 500))
     for update of d skip locked
  ),
  bumped as (
    update public.notification_deliveries d
       set attempts = d.attempts + 1, updated_at = now()
      from due
     where d.id = due.id
     returning d.id, d.notification_id
  )
  select
    b.id, s.id, s.endpoint, s.p256dh, s.auth,
    n.kind, n.title_key, n.params,
    coalesce((select r.locale from public.responders r where r.user_id = n.user_id), 'en')
  from bumped b
  join public.notifications n on n.id = b.notification_id
  join public.push_subscriptions s on s.user_id = n.user_id;
end;
$fn$;

revoke all on function public.claim_push_deliveries(integer) from public, anon, authenticated;
grant execute on function public.claim_push_deliveries(integer) to service_role;

-- ---------------------------------------------------------------------------
-- Recording the outcome
-- ---------------------------------------------------------------------------

create or replace function public.record_push_result(
  p_delivery_id uuid,
  p_ok          boolean,
  p_error       text default null,
  p_gone        boolean default false,
  p_subscription_id uuid default null
)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
begin
  if p_ok then
    update public.notification_deliveries
       set state = 'delivered', last_error = null, updated_at = now()
     where id = p_delivery_id;

    update public.push_subscriptions
       set last_used_at = now(), failure_count = 0
     where id = p_subscription_id;
    return;
  end if;

  -- 404 or 410 from the push service means this browser is gone for good -- uninstalled, or
  -- permission revoked. Retrying is pointless and the row is dropped rather than left to fail
  -- three times a minute forever.
  if p_gone and p_subscription_id is not null then
    delete from public.push_subscriptions where id = p_subscription_id;
  end if;

  update public.notification_deliveries
     -- The cast, again. A CASE over string literals is `text` and Postgres will not assign it to
     -- an enum column. This is the second time in this phase; the first was standing down losing
     -- offers in app.assign_responder. Worth remembering that pgSQL will happily compile it and
     -- only fail when the line actually runs.
     set state = (case when attempts >= 3 then 'failed' else 'queued' end)::delivery_state,
         last_error = left(coalesce(p_error, 'push failed'), 300),
         -- Backing off the same way the rest of this system does.
         next_attempt_at = now() + make_interval(mins => case attempts
                                                           when 1 then 1
                                                           when 2 then 5
                                                           else 25
                                                         end),
         updated_at = now()
   where id = p_delivery_id;
end;
$fn$;

revoke all on function public.record_push_result(uuid, boolean, text, boolean, uuid)
  from public, anon, authenticated;
grant execute on function public.record_push_result(uuid, boolean, text, boolean, uuid)
  to service_role;

-- ---------------------------------------------------------------------------
-- Hand push rows to the sender
-- ---------------------------------------------------------------------------
--
-- Copied from 20260922003000_notifications.sql with two changes, both marked inline: push is
-- excluded from the selection, and the fall-through comment no longer claims push is unbuilt.
-- Everything else is byte for byte the original.
--
-- It was extracted by a script rather than retyped, deliberately. The last long pgSQL function
-- rewritten by hand in this phase lost its trailing UPDATE and silently stopped every request
-- escalating; twenty assertions caught it, and the cheaper lesson is to not retype.

create or replace function public.drain_notifications(p_limit integer default 100)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_row       record;
  v_delivered integer := 0;
  v_queued    integer := 0;
  v_failed    integer := 0;
  v_skipped   integer := 0;
  v_phone     text;
  v_template  text;
  v_reminders integer;
begin
  v_reminders := app.send_event_reminders();

  for v_row in
    select d.id, d.channel, d.attempts, n.user_id, n.kind, n.title_key, n.params
      from notification_deliveries d
      join notifications n on n.id = d.notification_id
     where d.state in ('queued', 'failed')
       and d.attempts < 3
       and d.next_attempt_at <= now()
       -- Push is claimed by the Node sender (public.claim_push_deliveries), because it needs an
       -- HTTPS request and an encrypted payload that a Postgres function cannot produce. If this
       -- filter is ever removed, the two will race and every push notification will be marked
       -- suppressed a fraction of a second before it would have been sent.
       and d.channel <> 'push'
     order by
       -- The priority the spec asks for, expressed where it actually matters: what gets sent
       -- first when there is a backlog. Somebody stuck outranks somebody's reply.
       case n.kind
         when 'recovery_request'  then 0
         when 'recovery_offer'    then 0
         when 'recovery_accepted' then 0
         when 'recovery_status'   then 1
         when 'safety'            then 1
         when 'message'           then 2
         when 'event_reminder'    then 3
         when 'community'         then 4
         else 5
       end,
       d.created_at
     limit greatest(1, least(coalesce(p_limit, 100), 500))
    for update of d skip locked
  loop
    if v_row.channel = 'in_app' then
      -- Already visible the moment the notification row was written. Nothing to send.
      update notification_deliveries
         set state = 'delivered', attempts = attempts + 1, updated_at = now()
       where id = v_row.id;
      v_delivered := v_delivered + 1;

    elsif v_row.channel = 'sms' then
      v_template := v_row.params ->> 'sms_template';
      select phone into v_phone from auth.users where id = v_row.user_id;

      if v_template is null then
        -- Deliberate, and recorded. Recovery texts go through the dispatch outbox; a second
        -- path would text somebody twice about the same thing.
        update notification_deliveries
           set state = 'suppressed', attempts = attempts + 1,
               last_error = 'no sms template on this notification', updated_at = now()
         where id = v_row.id;
        v_skipped := v_skipped + 1;

      elsif v_phone is null then
        update notification_deliveries
           set state = 'suppressed', attempts = attempts + 1,
               last_error = 'no phone number on the account', updated_at = now()
         where id = v_row.id;
        v_skipped := v_skipped + 1;

      else
        perform app.queue_sms(v_phone, v_template, v_row.params, 'en');
        update notification_deliveries
           set state = 'sent', attempts = attempts + 1, updated_at = now()
         where id = v_row.id;
        v_queued := v_queued + 1;
      end if;

    else
      -- Email only, now that push is built. The enum still carries it so the log can say we
      -- did not send, and why, rather than the request vanishing.
      update notification_deliveries
         set state = 'suppressed', attempts = attempts + 1,
             last_error = v_row.channel::text || ' delivery is not built yet',
             updated_at = now()
       where id = v_row.id;
      v_skipped := v_skipped + 1;
    end if;
  end loop;

  -- Anything that has burned its three attempts stops being retried. The in_app notification is
  -- still there, which is the fallback.
  update notification_deliveries
     set state = 'failed', updated_at = now()
   where state = 'queued' and attempts >= 3;

  get diagnostics v_failed = row_count;

  return jsonb_build_object(
    'ok', true,
    'delivered', v_delivered,
    'queued_sms', v_queued,
    'suppressed', v_skipped,
    'gave_up', v_failed,
    'event_reminders', v_reminders
  );
end;
$$;
