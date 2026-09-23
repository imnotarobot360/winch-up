-- Winch Up :: a health check somebody can actually poll
--
-- Phase 16 asks for health checks. There is already admin_system_health(), and it is the right
-- screen for a person: it shows the queue, the heartbeat, recent failures, all behind
-- app.require_admin().
--
-- That gate is exactly why it cannot answer this question. An uptime checker has no session and
-- cannot hold a secret -- a status endpoint that needs credentials is a status endpoint nobody
-- polls, and the first time anyone looks at it is after somebody has already phoned to say
-- nothing happened.
--
-- So: a second function that returns counts and ages and nothing else. No names, no numbers, no
-- locations, no request ids. Everything in it would be equally true if the service were empty,
-- which is what makes it safe to expose through an unauthenticated route.
--
-- The question it answers is not "is the web server up" -- Vercel answers that -- but "is the
-- dispatcher alive". A dead pg_cron job looks exactly like a quiet afternoon: nothing moves, no
-- texts go out, and the site serves perfectly.

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
    -- dispatcher works perfectly and reaches nobody, which is this project's actual state until
    -- volunteers are approved.
    'approved_active_responders', (select count(*) from responders
                                    where approval = 'approved' and availability = 'active')
  );
end;
$fn$;

comment on function public.system_health_summary() is
  'Counts and ages only, safe to expose without a session. Adding anything that identifies a '
  'person or a place breaks the reason /api/health can be polled by an uptime checker.';

-- Service role only, same as the drain. The route holds that key; nobody else needs this.
revoke all on function public.system_health_summary() from public, anon, authenticated;
