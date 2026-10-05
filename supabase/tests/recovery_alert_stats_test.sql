-- Winch Up :: the recovery-alert statistics the admin screen reads
--
-- THIS SUITE EXISTS BECAUSE A PLPGSQL BODY IS NOT CHECKED UNTIL IT RUNS. admin_recovery_alert_stats
-- was created cleanly while referring to a column that has never existed (`suppressed_reason` --
-- suppression is a STATE, with the reason in error_message). CREATE FUNCTION reported success, the
-- grant check passed, and the first person to learn otherwise would have been an admin opening the
-- screen. So every assertion here CALLS the function rather than reading its definition.
--
-- It is also the inclusion half of the gate: "anon cannot call it" is worth nothing unless an
-- admin can.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- COUNT ONLY WHAT THIS FILE CREATED.
--
-- These assertions are exact numbers, and the demo seed shares this database: the first run of
-- this suite reported 14 helpers notified and 4 recoveries, all of it other people's rows. A test
-- that counts whatever happens to be in the database passes or fails on yesterday's clicking
-- about. The community and trails suites clear for the same reason; the rollback at the end puts
-- everything back.
delete from sms_messages;
delete from dispatches;

create temporary table t (name text primary key, id uuid not null);
insert into t (name, id) values
  ('admin', gen_random_uuid()), ('member', gen_random_uuid()),
  ('req', gen_random_uuid()), ('helper', gen_random_uuid());

insert into auth.users (id, email, created_at)
values ((select id from t where name = 'admin'), 'stats-admin@winchup.test', now()),
       ((select id from t where name = 'member'), 'stats-member@winchup.test', now());

-- Admin-ness lives in user_roles, not on profiles. (I assumed a profiles.role column; there
-- isn't one, and app.is_admin() reads user_roles.)
insert into profiles (user_id, display_name)
values ((select id from t where name = 'admin'), 'Stats Admin'),
       ((select id from t where name = 'member'), 'Stats Member')
on conflict (user_id) do nothing;

insert into user_roles (user_id, role)
values ((select id from t where name = 'admin'), 'admin')
on conflict do nothing;

-- One recovery with one alerted helper, so the counters have something to count.
insert into responders (
  id, phone, first_name, home_location, radius_miles, equipment,
  vehicle_class, drivetrain, approval, availability, is_test, sms_opt_in
) values (
  (select id from t where name = 'helper'), '+15125556001', 'Stat',
  extensions.st_setsrid(extensions.st_point(-95.37, 29.76), 4326)::extensions.geography,
  30, '{winch}'::equipment_type[], 'truck', '4wd', 'approved', 'active', true, true
);

insert into requests (
  id, requester_name, requester_phone, location, vehicle_class, stuck_type, land_type,
  status, helpers_needed, emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at
) values (
  (select id from t where name = 'req'), 'Stat Sam', '+15125556999',
  extensions.st_setsrid(extensions.st_point(-95.37, 29.76), 4326)::extensions.geography,
  'truck', 'mud', 'public', 'dispatching', 2, now(), true,
  (select id from waivers where slug = 'requester_waiver' and is_current), now()
);

insert into dispatches (request_id, responder_id, ring, distance_miles, state, queued_at, responded_at)
values (
  (select id from t where name = 'req'), (select id from t where name = 'helper'),
  1, 2.5, 'accepted', now() - interval '90 seconds', now() - interval '30 seconds'
);

-- ---------------------------------------------------------------------------
-- The gate, both ways
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-0000-0000-000000000000","role":"authenticated"}';

select throws_ok(
  'select public.admin_recovery_alert_stats(7)',
  null, null,
  'somebody who is not an admin is refused'
);

reset role;

-- ---------------------------------------------------------------------------
-- An admin gets real numbers -- the half that proves the refusal above means something
-- ---------------------------------------------------------------------------

select lives_ok(
  format(
    'set local request.jwt.claims = %L',
    json_build_object('sub', (select id from t where name = 'admin'), 'role', 'authenticated')::text
  ),
  'claims set for the admin'
);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', (select id from t where name = 'admin'), 'role', 'authenticated')::text,
  true
);

select lives_ok(
  'select public.admin_recovery_alert_stats(7)',
  'an admin can call it -- which is what catches a column that does not exist'
);

select is(
  (public.admin_recovery_alert_stats(7) ->> 'ok')::boolean,
  true,
  'it reports ok'
);

select is(
  (public.admin_recovery_alert_stats(7) -> 'alerts' ->> 'helpers_notified')::int,
  1,
  'one helper notified is counted as one'
);

select is(
  (public.admin_recovery_alert_stats(7) -> 'alerts' ->> 'offers_received')::int,
  1,
  'and their acceptance is counted as an offer received'
);

select is(
  (public.admin_recovery_alert_stats(7) -> 'alerts' ->> 'avg_response_seconds')::int,
  60,
  'the average response time is the real gap between queued and responded, in seconds'
);

-- Every key section 13 asks the screen to show. Named individually rather than counted, so a
-- rename is a failure here instead of a blank tile nobody notices.
select ok(
  public.admin_recovery_alert_stats(7) -> 'sms' ? 'sent'
  and public.admin_recovery_alert_stats(7) -> 'sms' ? 'delivered'
  and public.admin_recovery_alert_stats(7) -> 'sms' ? 'failed'
  and public.admin_recovery_alert_stats(7) -> 'sms' ? 'suppressed',
  'the SMS block carries sent, delivered, failed and suppressed'
);

select is(
  (public.admin_recovery_alert_stats(7) -> 'settings' -> 'radii_miles' ->> 0)::int,
  15,
  'the settings block shows the live wave-1 radius beside the numbers it produced'
);

select is(
  jsonb_array_length(public.admin_recovery_alert_stats(7) -> 'by_wave'),
  1,
  'the per-wave breakdown has a row for the wave that ran'
);

select is(
  (public.admin_recovery_alert_stats(7) -> 'teams' ->> 'recoveries_wanting_more_than_one')::int,
  1,
  'a recovery asking for two helpers is reported as wanting more than one'
);

-- SUPPRESSED IS NOT FAILED. With the master switch off every call-out lands in the suppressed
-- state, and a screen that called those failures would show a wall of red for a system behaving
-- exactly as configured.
insert into sms_messages (direction, state, to_phone, template_key, params, locale, request_id, error_message)
values ('outbound', 'suppressed', '+10000000000', 'responder.offer', '{}'::jsonb, 'en',
        (select id from t where name = 'req'), 'sms.outbound_enabled is off');

select is(
  (public.admin_recovery_alert_stats(7) -> 'sms' ->> 'suppressed')::int,
  1,
  'a suppressed call-out is counted as suppressed'
);

select is(
  (public.admin_recovery_alert_stats(7) -> 'sms' ->> 'failed')::int,
  0,
  'and NOT as a failure, which is the distinction the whole block exists for'
);

-- A REPLY CANNOT PRECEDE ITS OWN ALERT.
--
-- Found by opening the screen, which announced an average reply time of MINUS 58 minutes: the
-- demo seed holds dispatches whose responded_at is before their queued_at, and the average took
-- them at face value. Impossible data dragged toward nonsense while still looking measured. No
-- assertion had thought to ask whether the number could be negative, so here is the one that does.
insert into dispatches (request_id, responder_id, ring, distance_miles, state, queued_at, responded_at)
select (select id from t where name = 'req'), r.id, 1, 3.0, 'accepted',
       now() - interval '1 minute', now() - interval '20 minutes'
  from responders r where r.phone = '+15125556001'
 on conflict (request_id, responder_id) do update
    set queued_at = excluded.queued_at, responded_at = excluded.responded_at;

select is(
  (public.admin_recovery_alert_stats(7) -> 'alerts' ->> 'impossible_timings')::int,
  1,
  'a reply stamped before its own alert is counted as impossible'
);

select is(
  (public.admin_recovery_alert_stats(7) -> 'alerts' ->> 'avg_response_seconds'),
  null,
  'and excluded from the average, which reports nothing rather than a negative duration'
);

-- Put the row back so the window assertions below measure what they were written to measure.
update dispatches
   set queued_at = now() - interval '90 seconds', responded_at = now() - interval '30 seconds'
 where request_id = (select id from t where name = 'req');

select is(
  (public.admin_recovery_alert_stats(7) -> 'alerts' ->> 'avg_response_seconds')::int,
  60,
  'with a possible timing the average comes back -- so the filter excludes the impossible, not everything'
);

-- The window is a window.
select is(
  (public.admin_recovery_alert_stats(7) -> 'alerts' ->> 'helpers_notified')::int,
  1,
  'inside the window the alert counts'
);

update dispatches set queued_at = now() - interval '40 days', responded_at = now() - interval '40 days'
 where request_id = (select id from t where name = 'req');

select is(
  (public.admin_recovery_alert_stats(7) -> 'alerts' ->> 'helpers_notified')::int,
  0,
  'and outside it, it does not -- so the window narrows rather than decorating the heading'
);

select finish();
rollback;
