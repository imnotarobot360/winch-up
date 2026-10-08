-- Winch Up :: when a recovery ends, everybody who was called out is told, and told the truth
--
-- Two faults, both live until 2026-10-05, both in app.stand_down_open_offers -- the single place an
-- outstanding offer is closed, called by a trigger on recovered, cancelled and expired alike.
--
--   1. SMS ONLY. It queued 'responder.already_covered' and nothing else. sms_opt_in defaults false
--      and is its own consent, so a volunteer who declined texts was called out (by email and push)
--      and then told NOTHING when the recovery ended -- left holding an alert never withdrawn.
--   2. IT ALWAYS SAID "ALREADY COVERED", including when the requester CANCELLED and when the
--      request EXPIRED with nobody able to go. A volunteer who offered and waited 25 minutes for
--      nothing was told somebody else had it in hand. The trigger always knew which of the three
--      happened; the message never used it.
--
-- And a third, in app.cancel_request: the volunteer who had ACCEPTED is excluded from the stand-down
-- loop by design (they were not stood down, they were on the job) and got one text naming
-- 'responder.job_cancelled' -- a template outside sms.enabled_templates, so suppressed. The person
-- most likely to be driving was the one told least.
--
-- Found by PREPARING a file-and-cancel test against three volunteers approved minutes earlier, on
-- my own suggestion that cancelling would explain itself to them. It would not have.
--
-- THE PAIRING IS SET 4. "Tell the volunteers" written as "email everybody" passes every assertion
-- above it, and the next cancellation mails the whole membership.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

create temporary table t (name text primary key, id uuid not null);
insert into t (name, id) values
  ('accepted',   gen_random_uuid()),
  ('offered',    gen_random_uuid()),
  ('texter',     gen_random_uuid()),
  ('uninvolved', gen_random_uuid()),
  ('asker',      gen_random_uuid()),
  ('req',        gen_random_uuid()),
  ('req2',       gen_random_uuid());

insert into auth.users (id, email, created_at)
select id, name || '-sd@winchup.test', now() from t;

insert into profiles (user_id, display_name, notify_recovery, notify_recovery_status)
select id, name, true, true from t
on conflict (user_id) do update set notify_recovery = true, notify_recovery_status = true;

create temporary table spot as
  select extensions.st_setsrid(extensions.st_point(-95.37, 29.76), 4326)::extensions.geography as g;

-- 'texter' is the only one who consented to SMS, so the existing text path can be asserted as still
-- working rather than assumed.
insert into responders (
  id, user_id, first_name, phone, home_location, radius_miles, equipment,
  vehicle_class, drivetrain, approval, availability, is_test, sms_opt_in
)
select v.id, v.id, v.nm, v.ph, (select g from spot), 30, '{winch}'::equipment_type[],
       'truck', '4wd', 'approved', 'active', true, v.opt
from (values
  ((select id from t where name = 'accepted'),   'Acce', null::text,      false),
  ((select id from t where name = 'offered'),    'Offe', null::text,      false),
  ((select id from t where name = 'texter'),     'Text', '+15125559401',  true),
  ((select id from t where name = 'uninvolved'), 'Unin', null::text,      false)
) as v(id, nm, ph, opt);

insert into requests (
  id, requester_user_id, requester_name, requester_phone, location, vehicle_class, stuck_type,
  land_type, status, accepted_responder_id, emergency_ack_at, rules_accepted,
  waiver_id, waiver_accepted_at
) values (
  (select id from t where name = 'req'), (select id from t where name = 'asker'),
  'Stuck Sam', '+15125557601',
  (select g from spot), 'truck', 'mud', 'public', 'accepted',
  (select id from t where name = 'accepted'), now(), true,
  (select id from waivers where slug = 'requester_waiver' and is_current), now()
);

-- One on the way, two still holding unanswered offers.
insert into dispatches (request_id, responder_id, ring, distance_miles, state) values
  ((select id from t where name = 'req'), (select id from t where name = 'accepted'), 1, 2.0, 'accepted'),
  ((select id from t where name = 'req'), (select id from t where name = 'offered'),  1, 4.0, 'sent'),
  ((select id from t where name = 'req'), (select id from t where name = 'texter'),   1, 5.0, 'sent');

delete from email_deliveries;
delete from sms_messages;

-- ---------------------------------------------------------------------------
-- 1. A cancellation reaches the people holding offers
-- ---------------------------------------------------------------------------

select is(
  (app.cancel_request((select id from t where name = 'req'), 'testing') ->> 'ok')::boolean,
  true,
  'the recovery is cancelled'
);

select is(
  (select count(*)::int from email_deliveries
    where template_key = 'recovery.stood_down'
      and user_id = (select id from t where name = 'offered')),
  1,
  'a volunteer holding an offer is EMAILED -- with no text consent they previously heard nothing'
);

select is(
  (select count(*)::int from notification_deliveries d
     join notifications n on n.id = d.notification_id
    where n.user_id = (select id from t where name = 'offered')
      and d.channel = 'push' and d.state = 'queued'
      and n.title_key = 'notify.responder.stood_down.cancelled'),
  1,
  'and PUSHED, because a stand-down is more urgent than the call-out, not less'
);

-- The wording follows the ending. This is the assertion that would have caught fault 2.
select is(
  (select n.title_key from notifications n
    where n.user_id = (select id from t where name = 'offered')
      and n.title_key like 'notify.responder.stood_down%'),
  'notify.responder.stood_down.cancelled',
  'and is told it was CALLED OFF, not that somebody else covered it'
);

-- ---------------------------------------------------------------------------
-- 2. And the one who is already driving
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int from email_deliveries
    where template_key = 'recovery.stood_down'
      and user_id = (select id from t where name = 'accepted')),
  1,
  'the volunteer who ACCEPTED is emailed too -- their only notice was a suppressed text'
);

select is(
  (select count(*)::int from notification_deliveries d
     join notifications n on n.id = d.notification_id
    where n.user_id = (select id from t where name = 'accepted')
      and d.channel = 'push'),
  1,
  'and pushed, being the person most likely to be in the truck'
);

-- ---------------------------------------------------------------------------
-- 3. The text that already worked still works
-- ---------------------------------------------------------------------------
--
-- This adds channels. Removing one while adding two would be invisible to every assertion above.

select is(
  (select count(*)::int from sms_messages
    where to_phone = '+15125559401' and template_key = 'responder.already_covered'),
  1,
  'a volunteer who DID consent to texts still gets the text, exactly as before'
);

-- ---------------------------------------------------------------------------
-- 4. THE PAIRING. It is a stand-down, not a broadcast.
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int from email_deliveries
    where user_id = (select id from t where name = 'uninvolved')),
  0,
  'a member never called out to this recovery hears nothing -- being a member is not being involved'
);

select is(
  (select count(*)::int from email_deliveries
    where template_key = 'recovery.stood_down'
      and user_id = (select id from t where name = 'asker')),
  0,
  'and the person who cancelled it is not told their own recovery was cancelled'
);

-- ---------------------------------------------------------------------------
-- 5. EXPIRY SAYS SOMETHING DIFFERENT
-- ---------------------------------------------------------------------------
--
-- The fault that mattered most: 25 minutes with nobody available, and the volunteer who offered was
-- told "already covered". Same trigger, same function, different ending.

insert into requests (
  id, requester_user_id, requester_name, requester_phone, location, vehicle_class, stuck_type,
  land_type, status, emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at
) values (
  (select id from t where name = 'req2'), (select id from t where name = 'asker'),
  'Stuck Sam', '+15125557602',
  (select g from spot), 'truck', 'mud', 'public', 'dispatching', now(), true,
  (select id from waivers where slug = 'requester_waiver' and is_current), now()
);

insert into dispatches (request_id, responder_id, ring, distance_miles, state)
values ((select id from t where name = 'req2'), (select id from t where name = 'offered'), 1, 4.0, 'sent');

update requests set status = 'expired' where id = (select id from t where name = 'req2');

select is(
  (select count(*)::int from notifications n
    where n.user_id = (select id from t where name = 'offered')
      and n.title_key = 'notify.responder.stood_down.expired'),
  1,
  'an expired request tells them NOBODY COULD GO -- not that somebody else covered it'
);

select is(
  (select count(*)::int from email_deliveries
    where template_key = 'recovery.stood_down'
      and request_id = (select id from t where name = 'req2')),
  1,
  'and emails them, so a request that quietly timed out is no longer quiet'
);

select finish();
rollback;
