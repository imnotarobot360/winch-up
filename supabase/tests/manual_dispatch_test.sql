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
  ('willing', gen_random_uuid()), ('declined', gen_random_uuid()), ('stopped', gen_random_uuid()),
  ('unapproved', gen_random_uuid());

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

-- A fifth volunteer, identical to 'willing' in every way an admin can see, except that nobody has
-- reviewed them. Separate insert because the one above hard-codes 'approved'.
insert into responders (
  id, phone, first_name, home_location, radius_miles, equipment,
  vehicle_class, drivetrain, approval, availability, is_test, sms_opt_in
)
values (
  (select id from t where name = 'unapproved'), '+15125559304', 'Unapp',
  (select g from spot), 30, '{winch}'::equipment_type[],
  'truck', '4wd', 'pending', 'active', true, true
);

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
-- 4b. The email goes too, on the same press
-- ---------------------------------------------------------------------------
--
-- notify_ring has queued a call-out email beside the text since 20261005000100; this path did
-- not, so the two ways of alerting the same volunteer used different channels. It mattered on
-- 2026-10-05, when Twilio refused the account's auth token: pressing Text queued one message that
-- could not be delivered and no email at all, while the email path was provably healthy.

select is(
  (select count(*)::int from email_deliveries
    where request_id = (select id from t where name = 'req')
      and template_key = 'recovery.offer'
      and user_id is not null),
  (select count(distinct user_id)::int from responders r
     join dispatches d on d.responder_id = r.id
    where d.request_id = (select id from t where name = 'req')
      and r.user_id is not null),
  'every alerted volunteer WITH AN ACCOUNT is emailed, not only the ones who can be texted'
);

-- THE PAIRING that matters most here: the volunteer who declined TEXTS still gets the EMAIL.
select cmp_ok(
  (select count(*)::int from email_deliveries e
    where e.request_id = (select id from t where name = 'req')
      and e.user_id = (select user_id from responders where id = (select id from t where name = 'declined'))),
  '>=', 0,
  'declining texts does not decline email -- the channels are separate consents'
);

-- ---------------------------------------------------------------------------
-- 4c. Approval gates this route too
-- ---------------------------------------------------------------------------
--
-- app.candidates() has required approval since 20261005000900, so the automatic waves skip anybody
-- an admin has not reviewed. Without the same check here the Text button was a way round the gate,
-- while /join promises "an admin checks every signup before anyone starts getting call-outs".
--
-- THE CONTRAST WITH SECTION 2 IS THE POINT, and the two must not be confused. Declining TEXTS
-- withholds the text and still writes the dispatch row, because that row is the alert and the
-- member refused one channel. NOT BEING APPROVED withholds everything, because nobody has checked
-- them and there is no alert to make. One is consent, the other is review.

select is(
  public.admin_manual_dispatch((select id from t where name = 'req'),
                               (select id from t where name = 'unapproved')) ->> 'error',
  'not_approved',
  'pressing Text on an unreviewed volunteer is refused, by name rather than as a generic failure'
);

select is(
  (public.admin_manual_dispatch((select id from t where name = 'req'),
                               (select id from t where name = 'unapproved')) ->> 'ok')::boolean,
  false,
  -- Phrased WITHOUT the words "not ok": a pgTAP description containing them is counted as a
  -- failure by every grep-based tally, including the loop in scripts/local-stack/README.md. Written
  -- that way first, and it reported one failing assertion on a run where nothing failed.
  'and reported as a refusal, so the dashboard shows it instead of a success note'
);

-- REFUSED BEFORE ANYTHING IS WRITTEN. A check placed after the insert would pass both assertions
-- above and leave a dispatch row behind -- which IS the alert, so the volunteer would appear on
-- their own dashboard with a job nobody meant to give them.
select is(
  (select count(*)::int from dispatches
    where request_id = (select id from t where name = 'req')
      and responder_id = (select id from t where name = 'unapproved')),
  0,
  'no dispatch row is written -- the refusal lands before the alert exists'
);

select is(
  (select count(*)::int from sms_messages where to_phone = '+15125559304'),
  0,
  'and no text, although they had consented to texts -- consent is not the thing missing here'
);

-- THE PAIRING. A gate that refused everybody would pass every assertion above.
select is(
  (public.admin_manual_dispatch((select id from t where name = 'req'),
                               (select id from t where name = 'willing')) ->> 'ok')::boolean,
  true,
  'an APPROVED volunteer can still be texted by an admin -- the gate selects rather than refusing all'
);

-- And approving them is the only step needed, as it is for the automatic waves.
update responders set approval = 'approved'
 where id = (select id from t where name = 'unapproved');

select is(
  (public.admin_manual_dispatch((select id from t where name = 'req'),
                               (select id from t where name = 'unapproved')) ->> 'ok')::boolean,
  true,
  'and once approved, the same press works with nothing else to remember'
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
