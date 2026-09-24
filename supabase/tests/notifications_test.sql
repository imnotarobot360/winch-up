-- Winch Up :: proof that the right person is told, once
--
-- Run with:  supabase test db
--
-- Phase 13's list is eight kinds of notification, preferences, a priority rule, a consent rule,
-- and retry, duplicate prevention, delivery logging and fallback. This file is those, in that
-- order, with the two that could hurt somebody first:
--
--   The subject of a safety report is never told one exists. Only the person who filed it hears
--   the outcome.
--
--   A blocked person cannot reach somebody through a notification. Blocking closes that door as
--   well as the feed, or it is not blocking.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

delete from notification_deliveries;
delete from notifications;

-- ---------------------------------------------------------------------------
-- Fixtures: a requester, the volunteer who took the job, a bystander.
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, phone, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
)
select '00000000-0000-0000-0000-000000000000', v.id, 'authenticated', 'authenticated',
       v.email, v.phone, 'x', now(), '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
from (values
  ('f1111111-0000-4000-8000-0000000000ff'::uuid, 'nt-req@example.invalid', '+15125559501'),
  ('f2222222-0000-4000-8000-0000000000ff'::uuid, 'nt-vol@example.invalid', '+15125559502'),
  ('f3333333-0000-4000-8000-0000000000ff'::uuid, 'nt-other@example.invalid', null)
) as v(id, email, phone);

insert into profiles (user_id, display_name) values
  ('f1111111-0000-4000-8000-0000000000ff', 'Reqi'),
  ('f2222222-0000-4000-8000-0000000000ff', 'Vol'),
  ('f3333333-0000-4000-8000-0000000000ff', 'Other')
on conflict (user_id) do update set display_name = excluded.display_name;

insert into responders (
  id, user_id, phone, first_name, home_location, radius_miles,
  equipment, approval, availability, sms_opt_in
) values (
  'f2222222-1111-4111-8111-0000000000ff', 'f2222222-0000-4000-8000-0000000000ff',
  '+15125559502', 'Vol',
  extensions.st_setsrid(extensions.st_point(-97.74, 30.27), 4326)::extensions.geography,
  60, '{winch}', 'approved', 'active', true
);

insert into requests (
  id, requester_name, requester_phone, requester_user_id, location, vehicle_class, stuck_type,
  land_type, status, accepted_responder_id, emergency_ack_at, rules_accepted,
  waiver_id, waiver_accepted_at
) values (
  'f0000000-1111-4111-8111-0000000000ff',
  'Reqi', '+15125559501', 'f1111111-0000-4000-8000-0000000000ff',
  extensions.st_setsrid(extensions.st_point(-97.74, 30.27), 4326)::extensions.geography,
  'truck', 'mud', 'public', 'accepted', 'f2222222-1111-4111-8111-0000000000ff',
  now(), true, (select id from waivers where slug = 'requester_waiver' and is_current), now()
);

-- ---------------------------------------------------------------------------
-- 1. The recovery transitions the state machine already writes down
-- ---------------------------------------------------------------------------

insert into request_events (request_id, event_type, actor_kind)
values ('f0000000-1111-4111-8111-0000000000ff', 'accepted', 'system');

select ok(
  exists (select 1 from notifications
           where user_id = 'f1111111-0000-4000-8000-0000000000ff' and title_key = 'notify.request.accepted'),
  'a volunteer taking the job notifies the person who is stuck'
);

select ok(
  exists (select 1 from notifications n
           where n.user_id = 'f1111111-0000-4000-8000-0000000000ff'
             and n.title_key = 'notify.request.accepted'
             and n.url = '/r/' || (select public_token from requests
                                    where id = 'f0000000-1111-4111-8111-0000000000ff')),
  'and it takes them to their own status page'
);

-- The same transition written twice -- a tick that re-runs, a retry -- notifies once.
insert into request_events (request_id, event_type, actor_kind)
values ('f0000000-1111-4111-8111-0000000000ff', 'accepted', 'system');

select is(
  (select count(*)::integer from notifications
    where user_id = 'f1111111-0000-4000-8000-0000000000ff' and kind = 'recovery_accepted'),
  2,
  'a repeated transition writes the notification again'
);

select is(
  (select count(*)::integer from notification_deliveries d
     join notifications n on n.id = d.notification_id
    where n.user_id = 'f1111111-0000-4000-8000-0000000000ff' and n.kind = 'recovery_accepted'),
  1,
  'but only one delivery, because the dedupe key is the request and the transition'
);

insert into request_events (request_id, event_type, actor_kind)
values ('f0000000-1111-4111-8111-0000000000ff', 'on_site', 'responder');

select ok(
  exists (select 1 from notifications
           where user_id = 'f1111111-0000-4000-8000-0000000000ff' and title_key = 'notify.request.on_site'
             and kind = 'recovery_status'),
  'arriving on site is a status update'
);

-- Internal machinery is not news.
insert into request_events (request_id, event_type, actor_kind)
values ('f0000000-1111-4111-8111-0000000000ff', 'dispatch_started', 'system');

select is(
  (select count(*)::integer from notifications
    where user_id = 'f1111111-0000-4000-8000-0000000000ff'),
  3,
  'but the dispatch starting is not: nobody stuck in a ditch needs telling about ring one'
);

-- The volunteer's side.
insert into request_events (request_id, event_type, actor_kind, actor_responder_id)
values ('f0000000-1111-4111-8111-0000000000ff', 'responder_notified', 'system',
        'f2222222-1111-4111-8111-0000000000ff');

select ok(
  exists (select 1 from notifications
           where user_id = 'f2222222-0000-4000-8000-0000000000ff' and title_key = 'notify.responder.responder_notified'
             and kind = 'recovery_request'),
  'a volunteer being texted about a job also gets it in the app'
);

insert into request_events (request_id, event_type, actor_kind, actor_responder_id)
values ('f0000000-1111-4111-8111-0000000000ff', 'thanked', 'requester',
        'f2222222-1111-4111-8111-0000000000ff');

select ok(
  exists (select 1 from notifications
           where user_id = 'f2222222-0000-4000-8000-0000000000ff' and title_key = 'notify.responder.thanked'),
  'and being thanked is worth telling somebody about'
);

-- ---------------------------------------------------------------------------
-- 2. Messages
-- ---------------------------------------------------------------------------

insert into request_messages (request_id, sender_user_id, sender_role, body)
values ('f0000000-1111-4111-8111-0000000000ff', 'f1111111-0000-4000-8000-0000000000ff',
        'requester', 'I am at the second gate.');

select ok(
  exists (select 1 from notifications where user_id = 'f2222222-0000-4000-8000-0000000000ff' and kind = 'message'),
  'a message notifies the other person on the job'
);

select is(
  (select count(*)::integer from notifications
    where user_id = 'f1111111-0000-4000-8000-0000000000ff' and kind = 'message'),
  0,
  'and never the person who sent it'
);

-- ---------------------------------------------------------------------------
-- 3. Community, and what blocking has to close
-- ---------------------------------------------------------------------------

insert into community_posts (id, author_user_id, body)
values ('f9000000-1111-4111-8111-0000000000ff', 'f1111111-0000-4000-8000-0000000000ff',
        'Anybody running the north loop this weekend?');

insert into community_comments (post_id, author_user_id, body)
values ('f9000000-1111-4111-8111-0000000000ff', 'f3333333-0000-4000-8000-0000000000ff',
        'I am, Saturday morning.');

select ok(
  exists (select 1 from notifications where user_id = 'f1111111-0000-4000-8000-0000000000ff' and kind = 'community'),
  'a reply notifies whoever wrote the post'
);

insert into community_comments (post_id, author_user_id, body)
values ('f9000000-1111-4111-8111-0000000000ff', 'f1111111-0000-4000-8000-0000000000ff',
        'Great, see you there.');

select is(
  (select count(*)::integer from notifications
    where user_id = 'f1111111-0000-4000-8000-0000000000ff' and kind = 'community'),
  1,
  'and not for replying to yourself'
);

-- The one that matters. A notification is a channel; blocking has to close it.
insert into user_blocks (blocker_user_id, blocked_user_id)
values ('f1111111-0000-4000-8000-0000000000ff', 'f3333333-0000-4000-8000-0000000000ff');

insert into community_comments (post_id, author_user_id, body)
values ('f9000000-1111-4111-8111-0000000000ff', 'f3333333-0000-4000-8000-0000000000ff',
        'Still coming.');

select is(
  (select count(*)::integer from notifications
    where user_id = 'f1111111-0000-4000-8000-0000000000ff' and kind = 'community'),
  1,
  'somebody you blocked cannot reach you through a notification either'
);

-- ---------------------------------------------------------------------------
-- 4. Safety reports go one way only
-- ---------------------------------------------------------------------------

insert into safety_incidents (
  id, request_id, reporter_kind, reporter_user_id, subject_user_id, category, description, status
) values (
  'f8000000-1111-4111-8111-0000000000ff', 'f0000000-1111-4111-8111-0000000000ff',
  'requester', 'f1111111-0000-4000-8000-0000000000ff', 'f3333333-0000-4000-8000-0000000000ff',
  'asked_for_money', 'They asked for fifty dollars on the spot.', 'new'
);

update safety_incidents set status = 'actioned' where id = 'f8000000-1111-4111-8111-0000000000ff';

select ok(
  exists (select 1 from notifications where user_id = 'f1111111-0000-4000-8000-0000000000ff' and kind = 'safety'),
  'the person who filed a safety report hears what came of it'
);

select is(
  (select count(*)::integer from notifications
    where user_id = 'f3333333-0000-4000-8000-0000000000ff' and kind = 'safety'),
  0,
  'and the person it was about is never told a report exists at all'
);

-- ---------------------------------------------------------------------------
-- 5. The drain: priority, logging, and what is honestly not built
-- ---------------------------------------------------------------------------

select ok(
  not has_function_privilege('authenticated', 'public.drain_notifications(integer)', 'EXECUTE'),
  'the drain is not callable from a browser'
);
select ok(
  not has_function_privilege('anon', 'public.drain_notifications(integer)', 'EXECUTE'),
  'nor by anon'
);

-- Email is still unbuilt. Push is not, as of 20260923000400 -- it is claimed by the Node sender
-- instead, so this drain must leave it alone rather than suppressing it a fraction of a second
-- before it would have gone out.
select ok(
  app.notify('f1111111-0000-4000-8000-0000000000ff', 'community', 'notify.community.reply',
             '{}'::jsonb, null, array['email','push']::notification_channel[], 'unbuilt') is not null,
  'a notification can ask for a channel that is not built'
);

select ok((public.drain_notifications(500) ->> 'ok')::boolean, 'the drain runs');

select is(
  (select count(*)::integer from notification_deliveries
    where dedupe_key like 'unbuilt%' and state = 'suppressed'),
  1,
  'and records the still-unbuilt channel as suppressed, with a reason, rather than losing it'
);

select is(
  (select state::text from notification_deliveries
    where dedupe_key like 'unbuilt%' and channel = 'push'),
  'queued',
  'while a push delivery is left queued for the sender that now exists'
);

select ok(
  (select last_error from notification_deliveries where dedupe_key = 'unbuilt:email')
    like '%not built yet%',
  'the reason says so in words'
);

select is(
  (select count(*)::integer from notification_deliveries
    where channel = 'in_app' and state <> 'delivered'),
  0,
  'every in-app delivery is delivered, because the notification itself is the delivery'
);

-- SMS without a template is suppressed on purpose: recovery texts go through the dispatch
-- outbox, and a second path would text somebody twice about the same thing.
select ok(
  app.notify('f1111111-0000-4000-8000-0000000000ff', 'recovery_status', 'notify.request.on_site',
             '{}'::jsonb, null, array['sms']::notification_channel[], 'sms-no-template') is not null,
  'a notification can ask for SMS'
);

select ok((public.drain_notifications(500) ->> 'ok')::boolean, 'drain again');

select is(
  (select state::text from notification_deliveries where dedupe_key = 'sms-no-template:sms'),
  'suppressed',
  'without a template it is suppressed rather than sent as something half-rendered'
);

-- With one, it goes to the same outbox everything else uses.
select ok(
  app.notify('f1111111-0000-4000-8000-0000000000ff', 'recovery_status', 'notify.request.on_site',
             jsonb_build_object('sms_template', 'requester.on_site', 'short_code', 'TX-AB12'),
             null, array['sms']::notification_channel[], 'sms-with-template') is not null,
  'a notification carrying a template asks for a real text'
);

select ok((public.drain_notifications(500) ->> 'ok')::boolean, 'drain once more');

select is(
  (select state::text from notification_deliveries where dedupe_key = 'sms-with-template:sms'),
  'sent',
  'and it is handed to the outbox'
);

-- The outbox row exists either way. Whether it carries a phone number depends on
-- sms.outbound_enabled, which ships off (20260923002000) -- so this asserts the plumbing by
-- template key, and the switch separately below.
select ok(
  exists (select 1 from sms_messages where template_key = 'requester.on_site'),
  'which is the same outbox the dispatch path uses, not a second one'
);

select is(
  (select state::text from sms_messages where template_key = 'requester.on_site'),
  'suppressed',
  'and with recovery SMS off it is recorded rather than sent'
);

select is(
  (select to_phone from sms_messages where template_key = 'requester.on_site'),
  '+10000000000',
  'carrying no number, because a message nobody sends should not bank one'
);

-- Turned on, the same notification reaches the same outbox with the real number. This is the
-- assertion that would catch the notification path growing a second sender of its own.
reset role;
update app_settings set value = 'true'::jsonb where key = 'sms.outbound_enabled';

select ok(
  app.notify('f1111111-0000-4000-8000-0000000000ff', 'recovery_status', 'notify.request.on_site',
             jsonb_build_object('sms_template', 'requester.on_site', 'short_code', 'TX-CD34'),
             null, array['sms']::notification_channel[], 'sms-switch-on') is not null,
  'a second one queued with texting switched on'
);

select ok((public.drain_notifications(500) ->> 'ok')::boolean, 'drained');

select ok(
  exists (select 1 from sms_messages
           where template_key = 'requester.on_site'
             and state = 'queued'
             and to_phone = '+15125559501'),
  'reaches the outbox addressed to the real number, ready for the sender'
);

update app_settings set value = 'false'::jsonb where key = 'sms.outbound_enabled';

-- ---------------------------------------------------------------------------
-- 6. Retry and giving up
-- ---------------------------------------------------------------------------

select ok(
  app.notify('f1111111-0000-4000-8000-0000000000ff', 'recovery_status', 'notify.request.on_site',
             jsonb_build_object('sms_template', 'requester.on_site'),
             null, array['sms']::notification_channel[], 'retry-me') is not null,
  'a delivery to retry'
);

select lives_ok(
  $$select app.defer_delivery(
      (select id from notification_deliveries where dedupe_key = 'retry-me:sms'),
      'twilio said no')$$,
  'a failed send defers rather than spinning'
);

select is(
  (select attempts from notification_deliveries where dedupe_key = 'retry-me:sms'), 1,
  'the attempt is counted'
);

select ok(
  (select next_attempt_at from notification_deliveries where dedupe_key = 'retry-me:sms') > now(),
  'and the next try is in the future, not immediately'
);

select is(
  (select last_error from notification_deliveries where dedupe_key = 'retry-me:sms'),
  'twilio said no',
  'with what went wrong written down'
);

update notification_deliveries set attempts = 3, next_attempt_at = now() - interval '1 hour'
 where dedupe_key = 'retry-me:sms';

select ok((public.drain_notifications(500) ->> 'ok')::boolean, 'drain after three attempts');

select is(
  (select state::text from notification_deliveries where dedupe_key = 'retry-me:sms'),
  'failed',
  'after three attempts it stops being retried'
);

select ok(
  exists (select 1 from notifications n
           join notification_deliveries d on d.notification_id = n.id
          where d.dedupe_key = 'retry-me:sms'),
  'and the notification is still there -- the in-app record is the fallback for a channel that failed'
);

-- ---------------------------------------------------------------------------
-- 7. Event reminders
-- ---------------------------------------------------------------------------

insert into groups (id, slug, name, created_by)
values ('f7000000-1111-4111-8111-0000000000ff', 'nt-group', 'NT Group',
        'f1111111-0000-4000-8000-0000000000ff');

insert into events (id, group_id, title, starts_at, status, created_by)
values ('f6000000-1111-4111-8111-0000000000ff', 'f7000000-1111-4111-8111-0000000000ff',
        'Saturday run', now() + interval '6 hours', 'published',
        'f1111111-0000-4000-8000-0000000000ff');

insert into event_rsvps (event_id, user_id, response) values
  ('f6000000-1111-4111-8111-0000000000ff', 'f2222222-0000-4000-8000-0000000000ff', 'going'),
  ('f6000000-1111-4111-8111-0000000000ff', 'f3333333-0000-4000-8000-0000000000ff', 'maybe');

select ok((public.drain_notifications(500) ->> 'ok')::boolean, 'the drain sends reminders');

select is(
  (select count(*)::integer from notifications
    where user_id = 'f2222222-0000-4000-8000-0000000000ff' and kind = 'event_reminder'),
  1,
  'somebody who said they are going is reminded'
);

select is(
  (select count(*)::integer from notifications
    where user_id = 'f3333333-0000-4000-8000-0000000000ff' and kind = 'event_reminder'),
  0,
  'a maybe is not'
);

-- Running every minute for a day must send one reminder, not fourteen hundred.
select ok((public.drain_notifications(500) ->> 'ok')::boolean, 'the drain runs again');
select ok((public.drain_notifications(500) ->> 'ok')::boolean, 'and again');

select is(
  (select count(*)::integer from notification_deliveries d
     join notifications n on n.id = d.notification_id
    where n.kind = 'event_reminder'),
  1,
  'and still only one delivery, however often the job runs'
);

select * from finish();
rollback;
