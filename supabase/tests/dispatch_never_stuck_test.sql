-- Winch Up :: a recovery cannot fall out of the state machine
--
-- TX-FMHP went unmatched on 2026-10-04 and was still unmatched on the PUBLIC BOARD at 14:30Z the
-- next day, an hour and a quarter past the latest its 24-hour expiry could have been due, with the
-- tick running every sixty seconds the whole time and the scheduler reporting healthy.
--
-- THE CAUSE WAS A NULL DUE TIME, WRITTEN BY US. `advance_one` deferred with
-- `next_action_at = now() + make_interval(mins => wait_min)` while wait_min was never assigned --
-- 20261004000600 moved the assignment after the row lock, 20261004000700 rebuilt the function from
-- the original file and dropped it. null minutes makes a null interval makes a null timestamp, and
-- the batch query only ever collected rows with a non-null due time. The request was then
-- invisible to the scheduler for ever: not the requester's to clear, since they have gone, and
-- until 20261005000200 not an admin's either.
--
-- Two separate things are asserted here, because either alone would leave the hole open:
--   1. the deferral writes a REAL due time (the cause), and
--   2. a row that already has a null one is rescued (the cure, for rows stuck before the fix).

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

create temporary table t (name text primary key, id uuid not null);
insert into t (name, id) values
  ('deferred', gen_random_uuid()), ('stuck', gen_random_uuid()), ('fresh', gen_random_uuid());

create temporary table spot as
  select extensions.st_setsrid(extensions.st_point(-95.37, 29.76), 4326)::extensions.geography as g;

insert into requests (
  id, requester_name, requester_phone, location, vehicle_class, stuck_type, land_type,
  status, emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at
)
select v.id, v.nm, v.phone, (select g from spot), 'truck', 'mud', 'public',
       'dispatching', now(), true,
       (select id from waivers where slug = 'requester_waiver' and is_current), now()
from (values
  ((select id from t where name = 'deferred'), 'Deferred', '+15125557401'),
  ((select id from t where name = 'stuck'),    'Stuck',    '+15125557402'),
  ((select id from t where name = 'fresh'),    'Fresh',    '+15125557403')
) as v(id, nm, phone);

-- ---------------------------------------------------------------------------
-- 1. THE CAUSE. A deferral must write a real due time.
-- ---------------------------------------------------------------------------
--
-- Ring 3 exhausted but the unmatched window not yet up: the branch that falls through to the
-- deferral at the bottom of advance_one.

update requests
   set current_ring = 3,
       dispatch_started_at = now() - interval '2 minutes',
       next_action_at = now() - interval '1 second'
 where id = (select id from t where name = 'deferred');

select lives_ok(
  'select app.advance_one((select id from t where name = ''deferred''))',
  'the tick handles a request that is waiting rather than escalating'
);

select isnt(
  (select next_action_at from requests where id = (select id from t where name = 'deferred')),
  null,
  'and it is given a REAL next due time -- a null here is how a recovery leaves the scheduler for ever'
);

select cmp_ok(
  (select next_action_at from requests where id = (select id from t where name = 'deferred')),
  '>', now(),
  'in the future, so the tick will come back to it'
);

-- ---------------------------------------------------------------------------
-- 2. THE CURE. A row already stuck with a null due time is rescued.
-- ---------------------------------------------------------------------------

update requests
   set status = 'unmatched',
       unmatched_at = now() - interval '30 hours',
       next_action_at = null
 where id = (select id from t where name = 'stuck');

-- The batch driver must COLLECT it. This is the half that was missing: the query asked for
-- `next_action_at is not null` and the row could never be seen again.
select lives_ok(
  'select public.advance_dispatch(50)',
  'the tick runs'
);

select is(
  (select status::text from requests where id = (select id from t where name = 'stuck')),
  'expired',
  'an unmatched recovery past its expiry is expired even with no due time -- it cannot sit on the public board for ever'
);

-- ---------------------------------------------------------------------------
-- 3. THE PAIRING. The rescue must not sweep up anything else.
-- ---------------------------------------------------------------------------
--
-- A fix that expired every null-due-time row would pass the assertion above and quietly close
-- live recoveries. Scoped to unmatched AND past the window, and both halves are checked.

update requests
   set status = 'unmatched',
       unmatched_at = now() - interval '2 hours',
       next_action_at = null
 where id = (select id from t where name = 'fresh');

select lives_ok('select public.advance_dispatch(50)', 'the tick runs again');

select is(
  (select status::text from requests where id = (select id from t where name = 'fresh')),
  'unmatched',
  'an unmatched recovery still INSIDE its expiry window is left alone -- the rescue is for stuck rows, not a reaper'
);

-- And a live recovery with no due time is not touched either.
update requests
   set status = 'dispatching', unmatched_at = null, next_action_at = null
 where id = (select id from t where name = 'fresh');

select lives_ok('select public.advance_dispatch(50)', 'and again');

select is(
  (select status::text from requests where id = (select id from t where name = 'fresh')),
  'dispatching',
  'a dispatching recovery with no due time is not expired by this -- that is a different fault with a different cause'
);

select finish();
rollback;
