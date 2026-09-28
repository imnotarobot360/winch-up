-- Winch Up :: the confirmation a member gets for signing
--
-- Requirement 8. Queued by a trigger on the signature rather than sent from the server action,
-- for the same reason the welcome email is queued by a trigger on auth.users: the row landing
-- is the only signal that cannot be missed. If the member closes the tab, or the action's
-- response never arrives, the signature is still recorded and the confirmation still owed.
--
-- The queue row carries the user and the template key and nothing else -- no address, no legal
-- name, no hash. email_deliveries is a log that identifies nobody, which is what lets it be
-- kept; the drain reads the details back off the signature when it sends.

set search_path = public, extensions;

create or replace function app.queue_membership_signed_email()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_email  text;
  v_locale text;
begin
  select u.email into v_email from auth.users u where u.id = new.user_id;

  -- Phone-OTP accounts have no address. The signature still stands; there is just nothing to
  -- send and no row worth writing.
  if v_email is null or v_email = '' then
    return new;
  end if;

  v_locale := case when new.locale in ('en', 'es') then new.locale else 'en' end;

  insert into public.email_deliveries (user_id, template_key, locale, status, idempotency_key)
  values (new.user_id, 'membership.signed', v_locale, 'queued',
          -- Per signature, not per member: a member who signs v1 and later a material v2 is
          -- owed a confirmation for each. A replayed signature inserts no row and so queues
          -- nothing, which is the behaviour the server action relies on.
          'membership-signed:' || new.user_id || ':' || new.agreement_version)
  on conflict (idempotency_key) where idempotency_key is not null do nothing;

  return new;
end;
$fn$;

drop trigger if exists membership_signed_email on public.membership_signatures;

create trigger membership_signed_email
  after insert on public.membership_signatures
  for each row execute function app.queue_membership_signed_email();

notify pgrst, 'reload schema';
