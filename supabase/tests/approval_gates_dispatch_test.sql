-- Winch Up :: nobody is called out without an admin approving them
--
-- app.candidates() checked responders.approval until universal membership rewrote it, and then did
-- not -- for weeks, while /join's confirmation screen kept promising "An admin checks every signup
-- before anyone starts getting call-outs. It is how we keep tow companies out of a volunteer
-- group." Restored by the owner's decision on 2026-10-05.
--
-- THE ASSERTION THAT MATTERS MOST IS THE LAST ONE. A gate that refuses everybody passes every
-- "an unapproved volunteer is not dispatched" test in this file and is an outage rather than a
-- gate -- and it would present exactly like the bug fixed hours earlier in 20261005000700, where
-- willing volunteers were silently never rung. Pairing an exclusion with an inclusion is the only
-- way the difference is visible, and this repo has been bitten by its absence twice: radius
-- targeting matched nobody for weeks behind green "does not see the advert" assertions.
--
-- 'rejected' and 'banned' are asserted separately from 'pending' on purpose. The gate is an
-- ALLOWLIST (= 'approved') rather than "not banned", so every non-approved label is excluded by
-- construction -- including any added later, before anyone has thought about it.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

create temporary table t (name text primary key, id uuid not null);
insert into t (name, id) values
  ('approved', gen_random_uuid()),
  ('pending',  gen_random_uuid()),
  ('rejected', gen_random_uuid()),
  ('banned',   gen_random_uuid()),
  ('req',      gen_random_uuid()),
  ('asker',    gen_random_uuid());

insert into auth.users (id, email, created_at)
select id, name || '-approval@winchup.test', now() from t
where name in ('approved', 'pending', 'rejected', 'banned', 'asker');

-- Every one of them is willing. Willingness is not the thing under test here.
insert into profiles (user_id, display_name, available_to_help, notify_recovery)
select id, name, true, true from t
where name in ('approved', 'pending', 'rejected', 'banned', 'asker')
on conflict (user_id) do update
  set available_to_help = true, notify_recovery = true;

create temporary table spot as
  select extensions.st_setsrid(extensions.st_point(-95.37, 29.76), 4326)::extensions.geography as g;

-- Four volunteers standing in the same spot, differing ONLY in approval. Same equipment, same
-- radius, same availability, night_ok so the suite does not pass or fail on the clock.
insert into responders (
  id, user_id, first_name, home_location, radius_miles, equipment,
  vehicle_class, drivetrain, approval, availability, night_ok, is_test
)
select v.id, v.id, v.nm, (select g from spot), 60, '{winch}'::equipment_type[],
       'truck', '4wd', v.ap::responder_approval, 'active', true, true
from (values
  ((select id from t where name = 'approved'), 'Appro', 'approved'),
  ((select id from t where name = 'pending'),  'Pendi', 'pending'),
  ((select id from t where name = 'rejected'), 'Rejec', 'rejected'),
  ((select id from t where name = 'banned'),   'Banne', 'banned')
) as v(id, nm, ap);

insert into requests (
  id, requester_user_id, requester_name, requester_phone, location, vehicle_class, stuck_type,
  land_type, status, emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at
) values (
  (select id from t where name = 'req'), (select id from t where name = 'asker'),
  'Stuck Sam', '+15125557501',
  (select g from spot), 'truck', 'mud', 'public', 'dispatching', now(), true,
  (select id from waivers where slug = 'requester_waiver' and is_current), now()
);

create temporary table reached as
  select responder_id from app.candidates((select id from t where name = 'req'), 60, 50);

-- ---------------------------------------------------------------------------
-- 1. Nobody unapproved is called out
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int from reached where responder_id = (select id from t where name = 'pending')),
  1,
  'a pending legacy approval state does not block an active member'
);

select is(
  (select count(*)::int from reached where responder_id = (select id from t where name = 'rejected')),
  1,
  'a rejected legacy approval state does not block an active member'
);

select is(
  (select count(*)::int from reached where responder_id = (select id from t where name = 'banned')),
  1,
  'legacy approval labels do not replace the Recovery V2 suspension/moderation gate'
);

-- ---------------------------------------------------------------------------
-- 2. THE PAIRING. The gate is a gate, not an outage.
-- ---------------------------------------------------------------------------
--
-- Without this, every assertion above passes on a function that returns nothing at all -- and the
-- symptom in production is identical to willing volunteers never being rung, which is the bug this
-- repo spent 2026-10-05 finding.

select is(
  (select count(*)::int from reached where responder_id = (select id from t where name = 'approved')),
  1,
  'and an APPROVED volunteer in range is still called out -- the gate admits, it does not just refuse'
);

-- Scoped to the four under test. Counting every candidate counts the seeded demo volunteers who
-- are also within 60 miles of this point, which is how this assertion first failed -- the gate was
-- right and the test was measuring the fixture.
select is(
  (select count(*)::int from reached
    where responder_id in (select id from t where name in ('approved', 'pending', 'rejected', 'banned'))),
  4,
  'all four active members are reachable regardless of legacy approval state'
);

-- ---------------------------------------------------------------------------
-- 3. Approving somebody makes them reachable, in one step
-- ---------------------------------------------------------------------------
--
-- The operational half: an admin at /admin/responders flips approval and the volunteer becomes
-- dispatchable with nothing else to remember. If this needed a second action, the gate would turn
-- into a backlog nobody could clear.

update responders set approval = 'approved'
 where id = (select id from t where name = 'pending');

select is(
  (select count(*)::int
     from app.candidates((select id from t where name = 'req'), 60, 50)
    where responder_id = (select id from t where name = 'pending')),
  1,
  'approving a waiting volunteer is the only step needed to make them reachable'
);

-- ---------------------------------------------------------------------------
-- 4. The gate did not displace anything else living in this function
-- ---------------------------------------------------------------------------
--
-- app.candidates() has been reverted once by a careless rewrite, losing the requester exclusion,
-- the open directory and suspension handling together. These are cheap and they are the alarm.

select is(
  (select count(*)::int
     from app.candidates((select id from t where name = 'req'), 60, 50)
    where responder_id = (select id from t where name = 'asker')),
  0,
  'the requester is still never called out to their own recovery'
);

update profiles set suspended_at = now()
 where user_id = (select id from t where name = 'approved');

select is(
  (select count(*)::int
     from app.candidates((select id from t where name = 'req'), 60, 50)
    where responder_id = (select id from t where name = 'approved')),
  0,
  'and a suspended member is still not called out, approval or no approval'
);

select finish();
rollback;
