-- Winch Up :: who would the dispatcher reach, if somebody got stuck HERE?
--
-- Answers "does the matching really work by location" against REAL production volunteers, without
-- creating a recovery, sending a text, or alerting anybody.
--
-- HOW IT AVOIDS DOING ANYTHING. It opens a transaction, inserts one request at the point you give
-- it, asks `app.candidates()` -- the function the dispatcher itself calls, not a copy of its rules
-- -- what each wave would return, prints that, and ROLLS BACK. Nothing is written, no dispatch row
-- is created, so `notify_ring` is never reached and no message is queued. The request never
-- existed.
--
-- WHY IT CALLS THE REAL MATCHER. A coverage report that reimplemented the eligibility rules would
-- drift from the dispatcher within a month and then confidently lie about who is covered -- which
-- is worse than no report, because somebody would plan around it. Every gate that decides a real
-- call-out decides this one: availability, willingness to help, the member's own radius, night
-- hours, equipment, how many jobs they are already on, and the requester exclusion.
--
-- WHAT IT CANNOT TELL YOU. Whether a text arrives. It shows who is MATCHED and whether each one
-- has agreed to texts -- the two things the dispatcher decides. Delivery after that is Twilio,
-- the carrier, and a handset.
--
-- RUN IT
--
--   cd "C:\Users\jjser\New folder\txrecover"
--   & "C:\Users\jjser\tools\pgsql\bin\psql.exe" "<session-pooler URI, NO PASSWORD>" -f docs/who-covers.sql
--
-- It prompts for a latitude and longitude. Paste them from Google Maps: right-click a spot, and
-- the first item on the menu is "lat, lng" -- note that order, and that this asks for latitude
-- first for the same reason.
--
-- THE PASSWORD GOES IN THE PROMPT, NOT THE COMMAND. Delete it from the URI, colon and all, and
-- psql asks for it without echoing. On 2026-10-05 a full URI was pasted into a PowerShell
-- `Read-Host`, which DOES echo, and the production password ended up in the terminal scrollback.

\set ON_ERROR_STOP on
\timing off

\prompt 'Latitude  (e.g. 29.7604): ' lat
\prompt 'Longitude (e.g. -95.3698): ' lng

begin;

-- A request that will never exist. Status 'submitted' and nothing else: no dispatch rows, so the
-- notification and SMS paths are never entered.
create temporary table probe on commit drop as
select
  extensions.st_setsrid(extensions.st_point(:lng, :lat), 4326)::extensions.geography as g;

insert into public.requests (
  id, requester_name, requester_phone, location, vehicle_class, stuck_type, land_type,
  status, emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at
) values (
  '00000000-dead-4000-8000-00000000c0de', 'Coverage probe', '+15120000000',
  (select g from probe), 'truck', 'mud', 'public', 'submitted', now(), true,
  (select id from public.waivers where slug = 'requester_waiver' and is_current), now()
);

\echo ''
\echo '=== WHO IS REACHABLE AT ALL, and how far away ==='
\echo '(60 miles is wave 3, the widest the dispatcher ever goes)'
\echo ''

select
  r.first_name,
  round(c.distance_miles, 1)                                   as miles,
  case
    when app.ring_radius_miles(1) >= c.distance_miles then 1
    when app.ring_radius_miles(2) >= c.distance_miles then 2
    else 3
  end                                                          as first_wave_that_reaches_them,
  -- The volunteer's OWN radius caps the dispatcher's: somebody set to 15 miles is never reached by
  -- wave 3, however wide it goes. This is the field that most often explains an empty wave.
  r.radius_miles                                               as their_own_limit,
  case
    when r.phone is null                then 'no number -- push and in-app only'
    when r.sms_opt_out_at is not null   then 'replied STOP -- push and in-app only'
    when not coalesce(r.sms_opt_in, false)
                                        then 'has not agreed to texts -- push and in-app only'
    else 'TEXT'
  end                                                          as how_they_are_reached
from app.candidates('00000000-dead-4000-8000-00000000c0de'::uuid, 60, 100) c
join public.responders r on r.id = c.responder_id
order by c.distance_miles;

\echo ''
\echo '=== WHAT EACH WAVE WOULD ACTUALLY DO ==='
\echo '(the cap is how many that wave texts, closest first)'
\echo ''

select
  w.wave,
  app.ring_radius_miles(w.wave)                                as radius_miles,
  app.ring_max_helpers(w.wave)                                 as cap,
  app.ring_wait_minutes(w.wave)                                as waits_minutes,
  (select count(*) from app.candidates('00000000-dead-4000-8000-00000000c0de'::uuid,
                                       app.ring_radius_miles(w.wave), 1000))
                                                               as eligible_in_range,
  least(
    (select count(*) from app.candidates('00000000-dead-4000-8000-00000000c0de'::uuid,
                                         app.ring_radius_miles(w.wave), 1000)),
    app.ring_max_helpers(w.wave)
  )                                                            as would_be_alerted
from (values (1), (2), (3)) as w(wave)
order by w.wave;

\echo ''
\echo '=== AND HOW MANY OF THOSE WOULD GET A TEXT ==='
\echo ''

select
  count(*)                                                                as matched_within_60_mi,
  count(*) filter (where r.phone is not null
                     and coalesce(r.sms_opt_in, false)
                     and r.sms_opt_out_at is null)                        as would_be_texted,
  count(*) filter (where r.phone is null
                      or not coalesce(r.sms_opt_in, false)
                      or r.sms_opt_out_at is not null)                    as push_and_in_app_only
from app.candidates('00000000-dead-4000-8000-00000000c0de'::uuid, 60, 1000) c
join public.responders r on r.id = c.responder_id;

rollback;

\echo ''
\echo '================================================================'
\echo ' ROLLED BACK. No recovery was created and nothing was sent.'
\echo '================================================================'
\echo ''
\echo 'Reading it:'
\echo '  eligible_in_range 0 on every wave -> nobody covers that spot at all.'
\echo '  eligible_in_range > 0 but would_be_texted 0 -> they are matched and'
\echo '    will get a push and an in-app alert, but no text, because they have'
\echo '    not agreed to recovery texts. That is the consent gate, not a fault.'
\echo '  their_own_limit smaller than the wave radius -> that volunteer caps'
\echo '    how far they will travel, and the dispatcher honours it.'
\echo ''
