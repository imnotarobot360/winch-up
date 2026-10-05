-- Winch Up :: pressing Text in the admin queue
--
-- Three faults this covers, all live until 2026-10-05:
--
--   1. It texted people who had DECLINED, including anyone who replied STOP. notify_ring has
--      always gated on phone + sms_opt_in + no opt-out stamp; this path gated on nothing.
--   2. A second press could only fail, so a volunteer whose phone was off could never be nudged.
--   3. It could not say what it did -- 'ok' covered texted, not-texted and nothing alike.
--
-- THE ASSERTION THAT MATTERS MOST is that withholding the text does NOT withhold the alert. The
-- dispatch row is the alert; a volunteer who declined texts still gets it by push and in-app. A
-- fix that refused outright would have looked correct and quietly stopped admins from assigning
-- anybody who had opted out of SMS.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

delete from sms_messages;
delete from dispatches;

create temporary table t (name text primary key, id uuid not null);
insert into t (name, id) values
  ('admin', gen_random_uuid()), ('req', gen_random_uuid()),
  ('willing', gen_random_uuid()), ('declined', gen_random_uuid()), ('stopped', gen_random_uuid());

insert into auth.users (id, email, created_at)
values ((select id from t where name = 'admin'), 'manual-admin@winchup.test', now());
insert into profiles (user_id, display_name)
values ((select id from t where name = 'admin'), 'Manual Admin')
on conflict (user_id) do nothing;
insert into user_roles (user_id, role)
values ((select id from t where name = 'admin'), 'admin')
on conflict do nothing;

create temporary table spot as
  select extensions.st_setsrid(extensions.st_point(-95.37, 29.76), 4326)::extensions.geography as g;

-- Three volunteers who differ only in whether they may be texted.
insert into responders (
  id, phone, first_name, home_location, radius_miles, equipment,
  vehicle_class, drivetrain, approval, availability, is_test, sms_opt_in, sms_opt_out_at
)
select v.id, v.phone, v.nm, (select g from spot), 30, '{winch}'::equipment_type[],
       'truck', '4wd', 'approved', 'active', true, v.opt, v.stopped_at
from (values
  ((select id from t where name = 'willing'),  '+15125559301', 'Willa', true,  null::timestamptz),
  ((select id from t where name = 'declined'), '+15125559302', 'Dec',   false, null::timestamptz),
  -- Replied STOP: opted out AND stamped, which is what the inbound webhook writes.
  ((select id from t where name = 'stopped'),  '+15125559303', 'Stu',   false, now())
) as v(id, phone, nm, opt, stopped_at);

insert into requests (
  id, requester_name, requester_phone, location, vehicle_class, stuck_type, land_type,
  status, emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at
) values (
  (select id from t where name = 'req'), 'Stuck Sam', '+15125557301',
  (select g from spot), 'truck', 'mud', 'public', 'dispatching', now(), true,
  (select id from waivers where slug = 'requester_waiver' and is_current), now()
);

select set_config('request.jwt.claims',
  json_build_object('sub', (select id from t where name = 'admin'), 'role', 'authenticated')::text,
  true);

-- ---------------------------------------------------------------------------
-- 1. Somebody who consented is texted
-- ---------------------------------------------------------------------------

select is(
  (public.admin_manual_dispatch((select id from t where name = 'req'),
                                (select id from t where name = 'willing')) ->> 'texted')::boolean,
  true,
  'a volunteer who consented to texts is texted'
);

select is(
  (select count(*)::int from sms_messages where to_phone = '+15125559301'),
  1,
  'and the message really is queued'
);

-- ---------------------------------------------------------------------------
-- 2. Somebody who declined is NOT texted -- but IS alerted
-- ---------------------------------------------------------------------------

select is(
  (public.admin_manual_dispatch((select id from t where name = 'req'),
                                (select id from t where name = 'declined')) ->> 'texted')::boolean,
  false,
  'a volunteer who declined texts is not texted'
);

select is(
  (select count(*)::int from sms_messages where to_phone = '+15125559302'),
  0,
  'no message is queued for them'
);

-- THE PAIRING. A fix that refused outright would pass the two assertions above and be wrong.
select is(
  (select count(*)::int from dispatches
    where request_id = (select id from t where name = 'req')
      and responder_id = (select id from t where name = 'declined')),
  1,
  'but they ARE dispatched -- the row is the alert, and they get it by push and in-app'
);

select is(
  public.admin_manual_dispatch((select id from t where name = 'req'),
                               (select id from t where name = 'declined')) ->> 'reason',
  'no_sms_consent',
  'and the admin is told why there was no text, rather than assuming one went out'
);

-- ---------------------------------------------------------------------------
-- 3. STOP. The refusal that is not a preference.
-- ---------------------------------------------------------------------------

select is(
  (public.admin_manual_dispatch((select id from t where name = 'req'),
                                (select id from t where name = 'stopped')) ->> 'texted')::boolean,
  false,
  'somebody who replied STOP is not texted by an admin pressing Text'
);

select is(
  (select count(*)::int from sms_messages where to_phone = '+15125559303'),
  0,
  'not one message -- STOP is a carrier requirement, not a preference'
);

select is(
  public.admin_manual_dispatch((select id from t where name = 'req'),
                               (select id from t where name = 'stopped')) ->> 'reason',
  'stopped',
  'and it is reported as STOP specifically, not lumped in with never having opted in'
);

-- ---------------------------------------------------------------------------
-- 4. A second press re-sends instead of dead-ending
-- ---------------------------------------------------------------------------

select is(
  (public.admin_manual_dispatch((select id from t where name = 'req'),
                                (select id from t where name = 'willing')) ->> 'resent')::boolean,
  true,
  'pressing Text again is a re-send, not the old already_offered dead end'
);

select is(
  (select count(*)::int from sms_messages where to_phone = '+15125559301'),
  2,
  'a second message is queued -- which is the whole point of being able to try again'
);

select is(
  (select count(*)::int from dispatches
    where request_id = (select id from t where name = 'req')
      and responder_id = (select id from t where name = 'willing')),
  1,
  'and still exactly ONE dispatch row, because the unique constraint is right and stays'
);

-- A re-send reaches nobody new, so the count the queue prints must not move.
select is(
  (select notified_count from requests where id = (select id from t where name = 'req')),
  3,
  'notified_count counts volunteers reached, not buttons pressed'
);

-- ---------------------------------------------------------------------------
-- 5. Still an admin-only action
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims', '', true);

select throws_ok(
  format('select public.admin_manual_dispatch(%L, %L)',
         (select id from t where name = 'req'), (select id from t where name = 'willing')),
  null, null,
  'a caller with no session cannot text volunteers'
);

select finish();
rollback;
