-- Winch Up :: the health page was counting a gate that no longer exists
--
-- /api/health is what somebody opens when a request went out and nothing happened, and its most
-- important number had quietly stopped meaning anything.
--
-- `approved_active_responders` counted approval = 'approved' and availability = 'active'. That
-- was right while approval decided who could be dispatched to. Since 20260923000100 it decides
-- nothing, and the count was wrong in both directions:
--
--   five hundred members with Available to Help on and nobody verified read as ZERO, and the page
--   warned "a request would reach nobody" while the ring reached everybody;
--
--   five hundred verified members who all had the toggle off read as five hundred, and the page
--   said nothing while a request genuinely reached nobody.
--
-- The second is the dangerous one, and it is the one this deployment would have had.
--
-- The key is renamed rather than redefined in place. security_test.sql pins the exact key set, so
-- a rename makes the next reader notice the meaning changed; a quietly redefined key would not.
--
-- Everything else in this function is byte for byte the original, copied by a script rather than
-- retyped: the hand-written first attempt dropped 'ok' and 'sms_failed_24h', invented a
-- 'checked_at', and read sms_outbox instead of sms_messages.

set search_path = public, extensions;

create or replace function public.system_health_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_beat timestamptz;
begin
  select max(beat_at) into v_beat from system_heartbeats;

  return jsonb_build_object(
    'ok', true,

    -- Seconds since the dispatch tick last wrote a heartbeat. Null means it has never run,
    -- which on a live deployment is worse than a large number.
    'scheduler_age_seconds',
      case when v_beat is null then null
           else round(extract(epoch from (now() - v_beat)))
      end,

    -- Texts waiting to go out. The drain takes fifty a minute, so a few hundred is a queue that
    -- has stopped moving rather than a busy evening.
    'sms_queued', (select count(*) from sms_messages where state = 'queued'),
    'sms_failed_24h', (select count(*) from sms_messages
                        where state = 'failed' and created_at > now() - interval '24 hours'),

    'notifications_queued', (select count(*) from notification_deliveries
                              where state in ('queued', 'failed')),

    -- Recoveries in flight. Not who or where -- just how many, so a zero next to a stopped
    -- scheduler reads differently from a twelve.
    'open_requests', (select count(*) from requests
                       where status in ('submitted', 'dispatching', 'unmatched',
                                        'accepted', 'on_site')),

    -- Whether anybody could be matched at all. Zero here is the quietest possible failure: the
    -- dispatcher works perfectly and reaches nobody.
    --
    -- This counted approval = 'approved' until 20260923000100 stopped approval gating anything,
    -- at which point it was wrong in both directions -- silent when a request would reach nobody,
    -- and alarming when it would reach everybody. It now mirrors the hard filters in
    -- app.candidates that do not depend on a particular request: active, not paused, and willing.
    -- A legacy responder with no account never had a toggle to set, so they count, exactly as
    -- candidates() treats them.
    'reachable_volunteers', (
      select count(*)
        from responders r
       where r.availability = 'active'
         and (r.paused_until is null or r.paused_until <= now())
         and case
               when r.user_id is null then true
               else coalesce(
                      (select p.available_to_help from profiles p where p.user_id = r.user_id),
                      false)
             end
    )
  );
end;
$fn$;

revoke all on function public.system_health_summary() from public, anon, authenticated;
grant execute on function public.system_health_summary() to service_role;

comment on function public.system_health_summary() is
  'Counts and ages only, safe to expose without a session. Adding anything that identifies a '
  'person or a place breaks the reason /api/health can be polled by an uptime checker. '
  'reachable_volunteers replaced approved_active_responders when approval stopped being a gate.';
