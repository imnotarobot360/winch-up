-- What the recovery alerts actually did: section 13's numbers, derived rather than stored.
--
-- The spec asks the admin screen to show SMS sent, delivered, failed, helpers notified, offers
-- received, helpers accepted and average response time. NOT ONE OF THESE NEEDS A NEW TABLE.
-- `dispatches` already records one row per helper per recovery with a state, a queued time and a
-- responded time, and `sms_messages` records the texts. A counters table would need a writer on
-- every path that touches either, and the morning that writer is missed the screen reads
-- confidently wrong -- which is worse than reading nothing, because nobody checks a number that
-- has always looked fine.
--
-- The window is a parameter rather than all time. "How is dispatch doing" is a question about the
-- last few days; a lifetime average hides a week of failures behind a year of successes.
--
-- SUPPRESSED IS NOT FAILED, and the screen must not conflate them. With sms.outbound_enabled off,
-- app.queue_sms writes a row in a terminal state with a reason -- deliberately, so "why did nobody
-- get told" has an answer. Counting those as failures would show a wall of red for a system that
-- is working exactly as configured. They are their own number, so the admin can see at a glance
-- that the master switch is the reason nothing is going out.

set search_path = public, extensions;

create or replace function public.admin_recovery_alert_stats(p_days integer default 7)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_since timestamptz;
  v_days  integer := least(greatest(coalesce(p_days, 7), 1), 90);
begin
  -- Returns VOID, so it is performed rather than assigned. Assigning it compiles and then fails on
  -- the first call, because plpgsql does not check a body until it runs.
  perform app.require_admin();

  v_since := now() - make_interval(days => v_days);

  return jsonb_build_object(
    'ok', true,
    'window_days', v_days,
    'since', v_since,

    -- ALERTS: one dispatch row per helper per recovery, which is what "helpers notified" means.
    'alerts', (
      select jsonb_build_object(
        'helpers_notified', count(*),
        'recoveries',       count(distinct request_id),
        'offers_received',  count(*) filter (where state = 'accepted'),
        'declined',         count(*) filter (where state = 'declined'),
        'no_reply',         count(*) filter (where responded_at is null),
        -- Seconds, not a pretty string: formatting is the screen's job and a number can be
        -- compared across windows.
        --
        -- A REPLY CANNOT PRECEDE ITS OWN ALERT, so rows where it appears to are excluded rather
        -- than averaged. The demo seed contains several, and the first time this screen rendered
        -- it told the admin the average reply time was MINUS 58 minutes. Impossible data should
        -- not be quietly folded into a statistic -- it drags the figure toward nonsense while
        -- still looking like a measurement. Caught by opening the page; no assertion had thought
        -- to ask whether the number could be negative.
        'avg_response_seconds',
          round(avg(extract(epoch from (responded_at - queued_at)))
                filter (where responded_at is not null and responded_at >= queued_at))::integer,
        'median_response_seconds',
          round(percentile_cont(0.5) within group (
            order by extract(epoch from (responded_at - queued_at))
          ) filter (where responded_at is not null and responded_at >= queued_at))::integer,
        -- Counted, not hidden. If this is ever non-zero in production something is writing
        -- timestamps that cannot be true, and silently dropping the rows would bury that.
        'impossible_timings',
          count(*) filter (where responded_at is not null and responded_at < queued_at)
      )
      from public.dispatches where queued_at >= v_since
    ),

    -- PER WAVE. The whole point of per-wave tuning is being able to see whether wave 1 is doing
    -- the work; one blended number cannot answer that.
    'by_wave', (
      select coalesce(jsonb_agg(w order by w ->> 'wave'), '[]'::jsonb)
      from (
        select jsonb_build_object(
                 'wave', ring,
                 'radius_miles', app.ring_radius_miles(ring),
                 'notified', count(*),
                 'offers', count(*) filter (where state = 'accepted'),
                 'avg_distance_miles', round(avg(distance_miles), 1)
               ) as w
          from public.dispatches
         where queued_at >= v_since
         group by ring
      ) waves
    ),

    -- TEXTS. Only the call-out template: counting every message the system sends would mix
    -- requester status updates into a figure the admin reads as "how many volunteers did we text".
    'sms', (
      select jsonb_build_object(
        'sent',      count(*) filter (where state = 'sent'),
        'delivered', count(*) filter (where state = 'delivered'),
        'failed',    count(*) filter (where state = 'failed'),
        'queued',    count(*) filter (where state = 'queued'),
        -- Its own STATE, never folded into failed. app.queue_sms writes state 'suppressed' with
        -- the reason in error_message; there is no suppressed_reason column, which I assumed
        -- there was and which a plpgsql body would not have complained about until somebody
        -- opened the screen.
        'suppressed', count(*) filter (where state = 'suppressed')
      )
      from public.sms_messages
      where created_at >= v_since
        and template_key = 'responder.offer'
    ),

    -- TEAMS: did the crew sizes get filled?
    'teams', (
      select jsonb_build_object(
        'recoveries_wanting_more_than_one', count(*) filter (where helpers_needed > 1),
        'accepted',                         count(*) filter (where status in ('accepted', 'on_site')),
        'unmatched',                        count(*) filter (where status = 'unmatched')
      )
      from public.requests where created_at >= v_since
    ),

    -- The settings the numbers above are a consequence of, so the screen can show cause beside
    -- effect instead of making somebody open two pages to compare them.
    'settings', jsonb_build_object(
      'radii_miles',  jsonb_build_array(app.ring_radius_miles(1), app.ring_radius_miles(2), app.ring_radius_miles(3)),
      'helpers',      jsonb_build_array(app.ring_max_helpers(1), app.ring_max_helpers(2), app.ring_max_helpers(3)),
      'waits_minutes', jsonb_build_array(app.ring_wait_minutes(1), app.ring_wait_minutes(2), app.ring_wait_minutes(3)),
      'unmatched_after_minutes', app.setting_int('dispatch.unmatched_after_minutes', 25),
      'location_freshness_minutes', app.setting_int('dispatch.location_freshness_minutes', 120),
      -- The one that explains a screen full of zeroes.
      'sms_outbound_enabled', app.setting_bool('sms.outbound_enabled', false)
    )
  );
end;
$fn$;

revoke all on function public.admin_recovery_alert_stats(integer) from public, anon;
grant execute on function public.admin_recovery_alert_stats(integer) to authenticated, service_role;

-- TELL POSTGREST THE SCHEMA CHANGED, or this function does not exist as far as the app is
-- concerned. Without it the admin screen answers "Could not find the function
-- public.admin_recovery_alert_stats(p_days) in the schema cache" -- a PGRST202, which reads like
-- an unapplied migration and is nothing of the kind. Caught by opening the page: pgTAP calls the
-- function directly and never goes through PostgREST, so every database assertion passed while
-- the screen was broken.
notify pgrst, 'reload schema';

-- Does it exist, and is it gated? Calling it here would run as the migration's superuser role and
-- prove nothing about the gate, so the grant list is read instead.
select
  has_function_privilege('authenticated', 'public.admin_recovery_alert_stats(integer)', 'execute')
    as authenticated_may_call,
  has_function_privilege('anon', 'public.admin_recovery_alert_stats(integer)', 'execute')
    as anon_may_call_should_be_false;
