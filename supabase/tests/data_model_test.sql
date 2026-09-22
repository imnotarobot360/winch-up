-- Winch Up :: the data model Phase 12 asked for
--
-- Run with:  supabase test db
--
-- Two jobs. First, a checklist: the phase lists the entities the finished product needs, and
-- this asserts each one exists, including the three that are satisfied by something other than
-- a table of that name. Second, the behaviour of the pieces added to close the gaps -- groups,
-- events, notifications, and the constraints that make a Stripe webhook safe to replay.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- ---------------------------------------------------------------------------
-- 1. The checklist
-- ---------------------------------------------------------------------------

select has_table('public', t, format('the data model has %s', t))
  from unnest(array[
    'profiles', 'user_roles', 'vehicles', 'responders',
    'requests', 'dispatches', 'request_events', 'request_messages',
    'community_posts', 'community_comments', 'groups', 'group_members', 'events',
    'trails', 'trail_conditions',
    'businesses', 'ad_campaigns', 'ad_creatives', 'ad_daily_stats',
    'invoices', 'payments', 'stripe_webhook_events',
    'safety_incidents', 'content_reports', 'audit_log',
    'notifications', 'notification_deliveries'
  ]) as t;

-- Three entities on the list are satisfied by something other than a table of that name, and
-- each was a deliberate decision rather than an omission.

-- "Recovery equipment": a shared vocabulary, used by responders, vehicles, trails and matching.
-- A table of equipment types would be a table of enum values with extra joins.
select ok(
  exists (select 1 from pg_type where typname = 'equipment_type'),
  'recovery equipment is the equipment_type enum, shared by volunteers, rigs and trails'
);

-- "Conversations": derived, never stored. You are in the conversation if you are the requester
-- or the accepted responder; reassigning the job moves the conversation with it. A participants
-- table would be a second copy of that fact, free to drift.
select has_function(
  'app', 'is_request_participant', array['uuid'],
  'conversations are derived from the request, not stored as their own rows'
);

-- "Ad impressions" and "ad clicks": counted per creative per surface per day, never per person.
select ok(
  not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'ad_daily_stats'
       and column_name ~* 'user|session|ip'
  ),
  'impressions and clicks are counts, and the table still cannot identify anybody'
);

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
)
select '00000000-0000-0000-0000-000000000000', v.id, 'authenticated', 'authenticated',
       v.email, 'x', now(), '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
from (values
  ('d1111111-0000-4000-8000-0000000000dd'::uuid, 'dm-owner@example.invalid'),
  ('d2222222-0000-4000-8000-0000000000dd'::uuid, 'dm-member@example.invalid'),
  ('d3333333-0000-4000-8000-0000000000dd'::uuid, 'dm-quiet@example.invalid')
) as v(id, email);

insert into profiles (user_id, display_name, notify_marketing)
values
  ('d1111111-0000-4000-8000-0000000000dd', 'Owner', false),
  ('d2222222-0000-4000-8000-0000000000dd', 'Member', true),
  ('d3333333-0000-4000-8000-0000000000dd', 'Quiet', false)
on conflict (user_id) do update
  set display_name = excluded.display_name, notify_marketing = excluded.notify_marketing;

-- ---------------------------------------------------------------------------
-- 2. Notifications
-- ---------------------------------------------------------------------------

select ok(
  app.notify('d1111111-0000-4000-8000-0000000000dd', 'recovery_request',
             'notify.nearbyRequest', '{"miles":4}'::jsonb, '/r/abc',
             array['in_app','sms']::notification_channel[]) is not null,
  'a notification is written, with a delivery per channel'
);

select is(
  (select count(*)::integer from notification_deliveries d
     join notifications n on n.id = d.notification_id
    where n.user_id = 'd1111111-0000-4000-8000-0000000000dd' and d.state = 'queued'),
  2,
  'both channels are queued for a recovery notification'
);

-- Marketing is the one that needs consent, and without it the delivery is recorded as
-- suppressed rather than skipped. A record of a decision not to send is worth keeping.
select ok(
  app.notify('d3333333-0000-4000-8000-0000000000dd', 'marketing',
             'notify.newsletter', '{}'::jsonb, null,
             array['sms']::notification_channel[]) is not null,
  'a marketing notification is still written for somebody who has not consented'
);

select is(
  (select d.state::text from notification_deliveries d
     join notifications n on n.id = d.notification_id
    where n.user_id = 'd3333333-0000-4000-8000-0000000000dd' and n.kind = 'marketing'),
  'suppressed',
  'but its delivery is suppressed, not queued'
);

select is(
  (select d.state::text from notification_deliveries d
     join notifications n on n.id = d.notification_id
    where n.user_id = 'd2222222-0000-4000-8000-0000000000dd' and n.kind = 'marketing'),
  null,
  'and somebody who did consent has nothing yet, because nothing was sent to them'
);

-- Two statements, not one. Calling a volatile function inside the WHERE clause of the same
-- SELECT that reads its rows finds nothing: the snapshot was taken before the insert happened.
select ok(
  app.notify('d2222222-0000-4000-8000-0000000000dd', 'marketing',
             'notify.newsletter', '{}'::jsonb, null,
             array['sms']::notification_channel[]) is not null,
  'the member who did consent is sent one'
);

select is(
  (select d.state::text from notification_deliveries d
     join notifications n on n.id = d.notification_id
    where n.user_id = 'd2222222-0000-4000-8000-0000000000dd' and n.kind = 'marketing'),
  'queued',
  'and theirs is queued rather than suppressed'
);

-- Duplicate prevention: the same dedupe key never sends twice.
select ok(
  app.notify('d1111111-0000-4000-8000-0000000000dd', 'recovery_status',
             'notify.onSite', '{}'::jsonb, null,
             array['sms']::notification_channel[], 'req-123-onsite') is not null,
  'a delivery with an explicit dedupe key is written'
);

select ok(
  app.notify('d1111111-0000-4000-8000-0000000000dd', 'recovery_status',
             'notify.onSite', '{}'::jsonb, null,
             array['sms']::notification_channel[], 'req-123-onsite') is not null,
  'and the retry writes its notification'
);

select is(
  (select count(*)::integer from notification_deliveries where dedupe_key = 'req-123-onsite:sms'),
  1,
  'but only one delivery, so nobody is texted twice at two in the morning'
);

-- The inbox.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"d1111111-0000-4000-8000-0000000000dd","role":"authenticated"}';

select ok(
  (public.my_notifications() ->> 'unread')::integer >= 3,
  'a member sees their own unread count'
);

select is(public.mark_notifications_read() ->> 'ok', 'true', 'and can clear it');

select is(
  (public.my_notifications() ->> 'unread')::integer, 0,
  'which it does'
);

-- ---------------------------------------------------------------------------
-- 3. Groups
-- ---------------------------------------------------------------------------

select is(
  public.create_group(jsonb_build_object(
    'slug', 'bastrop-runs', 'name', 'Bastrop Sunday Runs',
    'region', 'Bastrop County')) ->> 'ok',
  'true',
  'a member creates a group'
);

reset role;

select is(
  (select role::text from group_members m join groups g on g.id = m.group_id
    where g.slug = 'bastrop-runs' and m.user_id = 'd1111111-0000-4000-8000-0000000000dd'),
  'owner',
  'and owns it, because a group with nobody in charge is not a group'
);

create temp table gids as select slug, id from groups;
grant select on gids to public;

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"d2222222-0000-4000-8000-0000000000dd","role":"authenticated"}';

select is(
  public.group_membership((select id from gids where slug = 'bastrop-runs'), true) ->> 'ok',
  'true',
  'somebody else joins an open group'
);

select is(
  (public.groups_list() -> 'groups' -> 0 ->> 'member_count')::integer, 2,
  'and the count follows'
);

-- Invite-only is honest about not being built rather than quietly letting anybody in.
reset role;
insert into groups (slug, name, visibility, created_by)
values ('private-crew', 'Private Crew', 'invite_only', 'd1111111-0000-4000-8000-0000000000dd');
insert into group_members (group_id, user_id, role)
values ((select id from groups where slug = 'private-crew'),
        'd1111111-0000-4000-8000-0000000000dd', 'owner');
drop table gids;
create temp table gids as select slug, id from groups;
grant select on gids to public;

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"d2222222-0000-4000-8000-0000000000dd","role":"authenticated"}';

select is(
  public.group_membership((select id from gids where slug = 'private-crew'), true) ->> 'error',
  'not_open',
  'an invite-only group refuses, rather than pretending there is an invite flow'
);

set local request.jwt.claims =
  '{"sub":"d1111111-0000-4000-8000-0000000000dd","role":"authenticated"}';

select is(
  public.group_membership((select id from gids where slug = 'bastrop-runs'), false) ->> 'error',
  'last_owner',
  'the only owner cannot walk out and leave a group with nobody running it'
);

-- ---------------------------------------------------------------------------
-- 4. Events
-- ---------------------------------------------------------------------------

set local request.jwt.claims =
  '{"sub":"d2222222-0000-4000-8000-0000000000dd","role":"authenticated"}';

select is(
  public.create_event(jsonb_build_object(
    'group_id', (select id from gids where slug = 'bastrop-runs'),
    'title', 'Sunday run', 'starts_at', (now() + interval '3 days')::text)) ->> 'error',
  'not_an_organizer',
  'an ordinary member cannot post an event in a group they only joined'
);

set local request.jwt.claims =
  '{"sub":"d1111111-0000-4000-8000-0000000000dd","role":"authenticated"}';

select is(
  public.create_event(jsonb_build_object(
    'group_id', (select id from gids where slug = 'bastrop-runs'),
    'title', 'Sunday run', 'starts_at', (now() + interval '3 days')::text,
    'capacity', 1, 'status', 'published')) ->> 'ok',
  'true',
  'an organizer can'
);

reset role;
create temp table eids as select title, id from events;
grant select on eids to public;

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"d1111111-0000-4000-8000-0000000000dd","role":"authenticated"}';

select is(
  (public.events_upcoming() -> 'events' -> 0 ->> 'going_count')::integer, 1,
  'whoever is running it is going to it'
);

set local request.jwt.claims =
  '{"sub":"d2222222-0000-4000-8000-0000000000dd","role":"authenticated"}';

select is(
  public.event_rsvp((select id from eids where title = 'Sunday run'), 'going') ->> 'error',
  'full',
  'and a capacity of one means one'
);

select is(
  public.event_rsvp((select id from eids where title = 'Sunday run'), 'maybe') ->> 'ok',
  'true',
  'but a maybe does not take a seat'
);

reset role;
update events set starts_at = now() - interval '1 hour' where title = 'Sunday run';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"d2222222-0000-4000-8000-0000000000dd","role":"authenticated"}';

select is(
  public.event_rsvp((select id from eids where title = 'Sunday run'), 'going') ->> 'error',
  'already_started',
  'nobody signs up for something that has already left'
);

-- ---------------------------------------------------------------------------
-- 5. Money: the constraints that make a Stripe handler safe before it is written
-- ---------------------------------------------------------------------------

reset role;

select ok(not has_table_privilege('authenticated', 'payments', 'SELECT'),
  'nobody reads payments through a grant');
select ok(not has_table_privilege('authenticated', 'stripe_webhook_events', 'SELECT'),
  'nor the webhook log');

insert into stripe_webhook_events (id, type, payload)
values ('evt_test_1', 'invoice.paid', '{}'::jsonb);

select throws_ok(
  $$insert into stripe_webhook_events (id, type, payload)
    values ('evt_test_1', 'invoice.paid', '{}'::jsonb)$$,
  '23505', null,
  'a replayed webhook cannot be processed twice -- the event id is the primary key'
);

insert into businesses (name, slug, category, status, verification_note)
values ('Money Test', 'money-test', 'offroad_shop', 'approved', 'fixture');

insert into payments (business_id, amount_cents, stripe_payment_intent_id)
values ((select id from businesses where slug = 'money-test'), 15000, 'pi_test_1');

select throws_ok(
  $$insert into payments (business_id, amount_cents, stripe_payment_intent_id)
    values ((select id from businesses where slug = 'money-test'), 15000, 'pi_test_1')$$,
  '23505', null,
  'and one payment intent can only ever become one payment'
);

select throws_ok(
  $$insert into invoices (business_id, period_start, period_end, amount_cents, status)
    values ((select id from businesses where slug = 'money-test'),
            current_date, current_date + 30, 15000, 'paid')$$,
  '23514', null,
  'an invoice cannot be marked paid without saying when'
);

select * from finish();
rollback;
