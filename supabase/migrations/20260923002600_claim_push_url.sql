-- Winch Up :: 20260923001700 contains one statement that can never succeed
--
-- create or replace function refuses to change a function's return type, and 001700 adds a `url`
-- column to claim_push_deliveries' RETURNS TABLE. Against any database that already has the
-- 20260923000400 version -- which is every database except a brand new one -- that statement is:
--
--     ERROR:  cannot change return type of existing function
--
-- It went unnoticed because the local database had already been through 001700 at some earlier
-- point, so the signature already matched and the file re-applied cleanly. Production had not,
-- and because this is the LAST object in a 465-line file, everything above it landed and the
-- verification query reported "1 of 6 missing" -- which reads like a truncated paste rather than
-- a statement that cannot ever work.
--
-- Fixed forward rather than by editing 001700, which is the rule in CLAUDE.md and the right one:
-- a migration that has been applied anywhere is a historical record, and quietly changing it
-- means two databases can have run "the same" file and disagree. Re-running 001700 after this
-- will still fail on that one statement; that is harmless, because this file has already put the
-- function in its intended shape and 001700's version is identical to it.
--
-- The drop is what makes it work. Nothing depends on this function's signature except
-- src/lib/push/send.ts, which is deployed separately and reads columns by name, so dropping and
-- recreating costs nothing -- but the grant has to be re-issued, because a drop takes the
-- privileges with it.
--
-- WHAT THE url COLUMN IS FOR
--
-- src/lib/push/send.ts reads it to decide where a notification opens. It used to read
-- claim.params?.url, and app.notify has never put the url in params -- it has its own column --
-- so that key has never existed and every push notification would have opened /me. Push has
-- never run in production (no VAPID keys, the drain reports skipped), which is why nobody saw it.

set search_path = public, extensions;

drop function if exists public.claim_push_deliveries(integer);

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
  locale          text,
  url             text
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
    coalesce((select r.locale from public.responders r where r.user_id = n.user_id), 'en'),
    n.url
  from bumped b
  join public.notifications n on n.id = b.notification_id
  join public.push_subscriptions s on s.user_id = n.user_id;
end;
$fn$;

revoke all on function public.claim_push_deliveries(integer) from public, anon, authenticated;
grant execute on function public.claim_push_deliveries(integer) to service_role;
