-- Winch Up :: the closest helpers get texted first
--
-- Section 14 of the owner's closest-helper spec, as a suite. Five helpers at stated distances from
-- one recovery, and the questions it asks: is the ORDER right, does wave 1 stop at its radius,
-- does the search widen, does it stop when the crew is full, can one helper be texted twice, and
-- does an opted-out member get nothing.
--
-- EVERY EXCLUSION IS PAIRED WITH AN INCLUSION. A matcher that matches nobody passes every "does
-- not get it" assertion in this file on its own -- which is how radius targeting in this codebase
-- sat dead through weeks of green suites. So each "E is too far for wave 1" has "and A, B, C, D
-- are not" beside it, and "opted out gets no SMS" has "and still gets a dispatch row".
--
-- DISTANCES ARE PROJECTED, NOT TYPED. st_project() puts a point an exact number of metres away on
-- a bearing, so "1.2 miles" is 1.2 miles rather than a decimal degree somebody worked out once and
-- nobody can check. Due north, so the numbers stay readable.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

create temporary table t (name text primary key, id uuid not null);

-- The demo seed shares this database and its volunteers would otherwise join these waves.
-- Rolled back at the end with everything else.
update responders set availability = 'paused';

-- The recovery, and the helpers around it.
--
--   A   1.2 mi  -> wave 1
--   B   2.8 mi  -> wave 1
--   C   4.7 mi  -> wave 1
--   D   8.4 mi  -> wave 1   (inside 15 miles)
--   E  18.0 mi  -> wave 2   (outside 15, inside 30)
--
-- Wave 1 is 15 miles since 20261004000500. The spec was written against a 5-mile first wave; the
-- OWNER kept 15, so the boundary asserted here is the live one rather than the one the spec
-- assumed, and E is the helper that proves a boundary exists at all.
insert into t (name, id) values
  ('req', gen_random_uuid()),
  ('a', gen_random_uuid()), ('b', gen_random_uuid()), ('c', gen_random_uuid()),
  ('d', gen_random_uuid()), ('e', gen_random_uuid()), ('optout', gen_random_uuid());

create temporary table origin as
  select extensions.st_setsrid(extensions.st_point(-95.3698, 29.7604), 4326)::extensions.geography as g;

insert into responders (
  id, phone, first_name, home_location, radius_miles, equipment,
  vehicle_class, drivetrain, approval, availability, night_ok, is_test, sms_opt_in
)
select
  v.id, v.phone, v.nm,
  extensions.st_project((select g from origin), v.miles * 1609.344, 0)::extensions.geography,
  60, '{winch}'::equipment_type[], 'truck', '4wd', 'approved', 'active', true, true, v.opt
from (values
  ((select id from t where name = 'a'),      '+15125558001', 'Ann',   1.2, true),
  ((select id from t where name = 'b'),      '+15125558002', 'Ben',   2.8, true),
  ((select id from t where name = 'c'),      '+15125558003', 'Cal',   4.7, true),
  ((select id from t where name = 'd'),      '+15125558004', 'Dee',   8.4, true),
  ((select id from t where name = 'e'),      '+15125558005', 'Eli',  18.0, true),
  -- Same distance band as Ann, and has said no to texts. The control for consent.
  ((select id from t where name = 'optout'), '+15125558006', 'Opt',   1.5, false)
) as v(id, phone, nm, miles, opt);

insert into requests (
  id, requester_name, requester_phone, location, vehicle_class, stuck_type, land_type,
  status, emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at
) values (
  (select id from t where name = 'req'), 'Stuck Sam', '+15125557999',
  (select g from origin),
  'truck', 'mud', 'public', 'submitted', now(), true,
  (select id from waivers where slug = 'requester_waiver' and is_current), now()
);

-- ---------------------------------------------------------------------------
-- 1. Distance and ordering
-- ---------------------------------------------------------------------------

select is(
  (select round(distance_miles, 1) from app.candidates((select id from t where name = 'req'), 60, 50)
    where responder_id = (select id from t where name = 'a')),
  1.2::numeric,
  'the projected distance comes back as the distance that was asked for'
);

select is(
  (select array_agg(r.first_name order by c.distance_miles)
     from app.candidates((select id from t where name = 'req'), 60, 50) c
     join responders r on r.id = c.responder_id
    where r.first_name in ('Ann', 'Ben', 'Cal', 'Dee', 'Eli')),
  array['Ann', 'Ben', 'Cal', 'Dee', 'Eli'],
  'helpers come back sorted closest to farthest, which is the whole matching contract'
);

-- ---------------------------------------------------------------------------
-- 2. Wave 1 reaches inside its radius and stops there
-- ---------------------------------------------------------------------------

select is(app.ring_radius_miles(1), 15, 'wave 1 is fifteen miles, the owner-chosen value');
select is(app.ring_max_helpers(1), 5, 'wave 1 texts five helpers');
select is(app.ring_wait_minutes(1), 2, 'wave 1 waits two minutes');

select lives_ok(
  'select app.notify_ring((select id from t where name = ''req''), 1)',
  'wave 1 opens'
);

select is(
  (select count(*)::int from dispatches d join responders r on r.id = d.responder_id
    where d.request_id = (select id from t where name = 'req') and r.first_name = 'Eli'),
  0,
  'Eli at 18 miles is outside wave 1 and is not reached'
);

-- The inclusion that makes the line above mean something.
select is(
  (select array_agg(r.first_name order by d.distance_miles)
     from dispatches d join responders r on r.id = d.responder_id
    where d.request_id = (select id from t where name = 'req')
      and r.first_name in ('Ann', 'Ben', 'Cal', 'Dee')),
  array['Ann', 'Ben', 'Cal', 'Dee'],
  'and the four inside fifteen miles all are -- so the boundary is a boundary, not a dead matcher'
);

-- ---------------------------------------------------------------------------
-- 3. Consent decides the SMS, never the alert
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int from sms_messages m
    where m.request_id = (select id from t where name = 'req')
      and m.to_phone = '+15125558006'),
  0,
  'the member who opted out of recovery SMS is not texted'
);

select cmp_ok(
  (select count(*)::int from sms_messages
    where request_id = (select id from t where name = 'req')
      and template_key = 'responder.offer'),
  '>', 0,
  'and the ones who consented ARE -- consent is the gate, not a switch that silences everybody'
);

select is(
  (select count(*)::int from dispatches d join responders r on r.id = d.responder_id
    where d.request_id = (select id from t where name = 'req') and r.first_name = 'Opt'),
  1,
  'but they still get a dispatch row: declining SMS is not declining to be asked by push or in-app'
);

-- ---------------------------------------------------------------------------
-- 4. Nobody is alerted twice for one recovery
-- ---------------------------------------------------------------------------

select throws_ok(
  format(
    'insert into dispatches (request_id, responder_id, ring, distance_miles, state) '
    'values (%L, %L, 2, 1.2, ''queued'')',
    (select id from t where name = 'req'), (select id from t where name = 'a')
  ),
  '23505',
  null,
  'a second alert to the same helper for the same recovery is refused by the database'
);

select is(
  (select count(*)::int from dispatches
    where request_id = (select id from t where name = 'req')),
  (select count(distinct responder_id)::int from dispatches
    where request_id = (select id from t where name = 'req')),
  'one row per helper, counted rather than assumed'
);

-- ---------------------------------------------------------------------------
-- 5. The search widens
-- ---------------------------------------------------------------------------

select lives_ok(
  'select app.notify_ring((select id from t where name = ''req''), 2)',
  'wave 2 opens'
);

select is(
  (select count(*)::int from dispatches d join responders r on r.id = d.responder_id
    where d.request_id = (select id from t where name = 'req') and r.first_name = 'Eli'),
  1,
  'Eli is reached by wave 2, so widening actually widens'
);

-- ---------------------------------------------------------------------------
-- 6. Expansion stops when the crew is full, and not before
-- ---------------------------------------------------------------------------

select is(app.active_helper_count((select id from t where name = 'req')), 0,
  'no helpers aboard yet');

update requests
   set helpers_needed = 2,
       status = 'accepted',
       accepted_responder_id = (select id from t where name = 'a'),
       next_action_at = now() - interval '1 minute'
 where id = (select id from t where name = 'req');

insert into recovery_participants (request_id, responder_id, role, status)
values ((select id from t where name = 'req'), (select id from t where name = 'a'), 'helper', 'accepted');

select is(app.active_helper_count((select id from t where name = 'req')), 1,
  'one helper aboard, two wanted');

select isnt(
  (select app.advance_one((select id from t where name = 'req')) ->> 'action'),
  'none',
  'a short-handed recovery keeps searching after the first acceptance'
);

-- The second helper arrives, and the search must stop.
insert into recovery_participants (request_id, responder_id, role, status)
values ((select id from t where name = 'req'), (select id from t where name = 'b'), 'helper', 'accepted');

update requests set next_action_at = now() - interval '1 minute'
 where id = (select id from t where name = 'req');

select is(
  (select app.advance_one((select id from t where name = 'req')) ->> 'action'),
  'none',
  'with the crew full the search stops, which is the half that costs money if it is wrong'
);

-- A helper who withdraws is not aboard, and the recovery is short-handed again.
update recovery_participants
   set left_at = now(), status = 'withdrawn'
 where request_id = (select id from t where name = 'req')
   and responder_id = (select id from t where name = 'b');

select is(app.active_helper_count((select id from t where name = 'req')), 1,
  'a withdrawn helper stops counting towards the crew, which is the left_at rule the whole team '
  'feature rests on');

select finish();
rollback;
