-- Winch Up :: a recovery call-out reaches a volunteer's phone
--
-- app.notify_on_request_event sent the volunteer's call-out with array['in_app'] alone, so the one
-- notification this product exists to deliver was the only one that never buzzed a handset. Chat
-- messages, helper status changes and direct messages have all pushed since September: somebody got
-- a phone alert for a chat reply and silence for a rig stuck two miles away. It surfaced on
-- 2026-10-05, when Twilio was refusing the account's token and push was the channel that would
-- have worked -- built, deployed, subscribed, and idle.
--
-- THE PAIRING THAT MATTERS: assertion set 2. Adding push to the whole function would pass every
-- "the call-out pushes" assertion and also push a THANK-YOU. Push is a tap on the shoulder, and
-- spending one on "somebody said thanks" is how a volunteer turns notifications off and takes the
-- call-outs with them. A blunt fix looks identical on the channel that is asserted.
--
-- Set 3 is the consent half. A suppressed row must still EXIST -- "why did nobody get told" needs
-- an answer -- so asserting absence would pin the wrong behaviour as correct.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

create temporary table t (name text primary key, id uuid not null);
insert into t (name, id) values
  ('willing', gen_random_uuid()), ('optedout', gen_random_uuid()), ('req', gen_random_uuid());

insert into auth.users (id, email, created_at) values
  ((select id from t where name = 'willing'),  'push-willing@winchup.test',  now()),
  ((select id from t where name = 'optedout'), 'push-optedout@winchup.test', now());

-- The only difference between them is whether they want to hear about nearby recoveries.
insert into profiles (user_id, display_name, notify_recovery) values
  ((select id from t where name = 'willing'),  'Willing', true),
  ((select id from t where name = 'optedout'), 'Quiet',   false)
on conflict (user_id) do update set notify_recovery = excluded.notify_recovery;

create temporary table spot as
  select extensions.st_setsrid(extensions.st_point(-95.37, 29.76), 4326)::extensions.geography as g;

insert into responders (
  id, user_id, first_name, home_location, radius_miles, equipment,
  vehicle_class, drivetrain, approval, availability, is_test
)
select v.id, v.id, v.nm, (select g from spot), 30, '{winch}'::equipment_type[],
       'truck', '4wd', 'approved', 'active', true
from (values
  ((select id from t where name = 'willing'),  'Willing'),
  ((select id from t where name = 'optedout'), 'Quiet')
) as v(id, nm);

insert into requests (
  id, requester_name, requester_phone, location, vehicle_class, stuck_type, land_type,
  status, emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at
) values (
  (select id from t where name = 'req'), 'Stuck Sam', '+15125557401',
  (select g from spot), 'truck', 'mud', 'public', 'dispatching', now(), true,
  (select id from waivers where slug = 'requester_waiver' and is_current), now()
);

-- ---------------------------------------------------------------------------
-- 1. The call-out pushes
-- ---------------------------------------------------------------------------
--
-- Written the way the ring writes it: notify_ring's last act per candidate is this event row, and
-- the notification is produced by a trigger on it rather than by a call inside the ring.

insert into request_events (request_id, event_type, actor_kind, actor_responder_id, data, is_public)
values ((select id from t where name = 'req'), 'responder_notified', 'system',
        (select id from t where name = 'willing'),
        jsonb_build_object('ring', 1, 'miles', 2.8), false);

select is(
  (select count(*)::int from notification_deliveries d
     join notifications n on n.id = d.notification_id
    where n.user_id = (select id from t where name = 'willing')
      and d.channel = 'push' and d.state = 'queued'),
  1,
  'a call-out queues a PUSH delivery -- the channel it never used'
);

select is(
  (select count(*)::int from notification_deliveries d
     join notifications n on n.id = d.notification_id
    where n.user_id = (select id from t where name = 'willing')
      and d.channel = 'in_app' and d.state = 'queued'),
  1,
  'and still queues the in-app one, which is what it used to do alone'
);

-- The distance has to reach the copy or the push says nothing a volunteer can act on.
select is(
  (select n.params ->> 'miles' from notifications n
    where n.user_id = (select id from t where name = 'willing')),
  '2.8',
  'the distance is carried in the params, as a number rather than text'
);

-- A SEPARATE KEY, so enriching the copy cannot break notifications already in the inbox: the
-- in-app list renders title_key through next-intl with the stored params, and next-intl throws on
-- a missing interpolation value.
select is(
  (select n.title_key from notifications n
    where n.user_id = (select id from t where name = 'willing')),
  'notify.responder.responder_notified_near',
  'and points at its own copy key, leaving historical call-outs rendering as they always did'
);

-- The things that must never be in a payload read off a lock screen by whoever is standing nearby.
select is(
  (select (n.params ? 'requester_phone') or (n.params ? 'lat') or (n.params ? 'lng')
     from notifications n where n.user_id = (select id from t where name = 'willing')),
  false,
  'and carries no phone and no coordinates'
);

-- ---------------------------------------------------------------------------
-- 2. THE PAIRING. A thank-you does not push.
-- ---------------------------------------------------------------------------

insert into request_events (request_id, event_type, actor_kind, actor_responder_id, data, is_public)
values ((select id from t where name = 'req'), 'thanked', 'system',
        (select id from t where name = 'willing'), '{}'::jsonb, false);

select is(
  (select count(*)::int from notification_deliveries d
     join notifications n on n.id = d.notification_id
    where n.user_id = (select id from t where name = 'willing')
      and n.title_key = 'notify.responder.thanked' and d.channel = 'push'),
  0,
  'a thank-you queues NO push -- urgency is what earns a buzz, and spending one here loses the lot'
);

select is(
  (select count(*)::int from notification_deliveries d
     join notifications n on n.id = d.notification_id
    where n.user_id = (select id from t where name = 'willing')
      and n.title_key = 'notify.responder.thanked' and d.channel = 'in_app'),
  1,
  'but it is still delivered in-app, so nothing was taken away'
);

-- ---------------------------------------------------------------------------
-- 3. Consent, and the row that proves it was considered
-- ---------------------------------------------------------------------------

insert into request_events (request_id, event_type, actor_kind, actor_responder_id, data, is_public)
values ((select id from t where name = 'req'), 'responder_notified', 'system',
        (select id from t where name = 'optedout'),
        jsonb_build_object('ring', 1, 'miles', 4.1), false);

select is(
  (select d.state::text from notification_deliveries d
     join notifications n on n.id = d.notification_id
    where n.user_id = (select id from t where name = 'optedout') and d.channel = 'push'),
  'suppressed',
  'somebody who turned nearby alerts off is not pushed at'
);

-- Asserting the row is ABSENT would have been the easy version and would have pinned the wrong
-- behaviour: a suppressed delivery is the only record of why a volunteer heard nothing.
select isnt_empty(
  format('select 1 from notification_deliveries d join notifications n on n.id = d.notification_id where n.user_id = %L and d.channel = ''push''',
         (select id from t where name = 'optedout')),
  'and the refusal is RECORDED rather than dropped, so "why did nobody get told" has an answer'
);

select finish();
rollback;
