-- Winch Up :: who can read a recovery conversation
--
-- Run with:  supabase test db
--
-- The chat went from two people to a team, and the access rule went with it. request_messages has
-- no grants and no policies, so exactly one function decides who can read a private recovery
-- conversation: app.is_request_participant(). This suite exists because getting that wrong does
-- not break anything visibly -- it just quietly makes other people's recoveries readable.
--
-- Fixtures are built here rather than taken from the demo seed, for the usual reason: a test that
-- fails because somebody edited seed data is a test nobody trusts.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- ---------------------------------------------------------------------------
-- Four people, one recovery. A requests, B and C help, D is a bystander.
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
)
select '00000000-0000-0000-0000-000000000000', v.id, 'authenticated', 'authenticated',
       v.email, 'x', now(), '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
from (values
  ('aaaa1111-0000-4000-8000-00000000000a'::uuid, 'team-a@example.invalid'),
  ('bbbb1111-0000-4000-8000-00000000000b'::uuid, 'team-b@example.invalid'),
  ('cccc1111-0000-4000-8000-00000000000c'::uuid, 'team-c@example.invalid'),
  ('dddd1111-0000-4000-8000-00000000000d'::uuid, 'team-d@example.invalid')
) as v(id, email)
on conflict (id) do nothing;

insert into public.responders (id, user_id, phone, first_name, home_location, radius_miles,
                               equipment, approval, availability)
values
  ('bbbb2222-0000-4000-8000-00000000000b', 'bbbb1111-0000-4000-8000-00000000000b',
   '+15125557001', 'Bea',
   extensions.st_setsrid(extensions.st_point(-95.37, 29.76), 4326)::extensions.geography, 60,
   '{winch}', 'approved', 'active'),
  ('cccc2222-0000-4000-8000-00000000000c', 'cccc1111-0000-4000-8000-00000000000c',
   '+15125557002', 'Cal',
   extensions.st_setsrid(extensions.st_point(-95.38, 29.77), 4326)::extensions.geography, 60,
   '{traction_boards}', 'approved', 'active'),
  ('dddd2222-0000-4000-8000-00000000000d', 'dddd1111-0000-4000-8000-00000000000d',
   '+15125557003', 'Dee',
   extensions.st_setsrid(extensions.st_point(-95.39, 29.78), 4326)::extensions.geography, 60,
   '{winch}', 'approved', 'active')
on conflict (id) do nothing;

insert into public.requests (
  id, public_token, short_code, status, locale, requester_user_id,
  requester_name, requester_phone, location, vehicle_class, stuck_type, land_type,
  emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at
) values (
  'eeee3333-0000-4000-8000-00000000000e', 'team-test-token-aaaaaaaaaa', 'TX-TEAM',
  'unmatched', 'en', 'aaaa1111-0000-4000-8000-00000000000a',
  'Ada', '+15125557000',
  extensions.st_setsrid(extensions.st_point(-95.37, 29.76), 4326)::extensions.geography,
  'truck', 'mud', 'public',
  now(), true, (select id from public.waivers where slug = 'requester_waiver' and is_current), now()
) on conflict (id) do nothing;

-- The insert trigger should have made the requester a participant without being asked.
select is(
  (select count(*)::int from public.recovery_participants
    where request_id = 'eeee3333-0000-4000-8000-00000000000e' and role = 'requester'),
  1,
  'filing a request makes you a participant in your own conversation'
);

-- B and C join the team; D never does.
insert into public.recovery_participants (request_id, user_id, responder_id, role, status)
values
  ('eeee3333-0000-4000-8000-00000000000e', 'bbbb1111-0000-4000-8000-00000000000b',
   'bbbb2222-0000-4000-8000-00000000000b', 'helper', 'accepted'),
  ('eeee3333-0000-4000-8000-00000000000e', 'cccc1111-0000-4000-8000-00000000000c',
   'cccc2222-0000-4000-8000-00000000000c', 'helper', 'accepted')
on conflict do nothing;

insert into public.request_messages (request_id, sender_user_id, sender_role, body)
values
  ('eeee3333-0000-4000-8000-00000000000e', 'aaaa1111-0000-4000-8000-00000000000a', 'requester',
   'Stuck past the second gate'),
  ('eeee3333-0000-4000-8000-00000000000e', 'bbbb1111-0000-4000-8000-00000000000b', 'responder',
   'Twenty minutes out with the winch');

-- ---------------------------------------------------------------------------
-- 1. The team can read it
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaa1111-0000-4000-8000-00000000000a","role":"authenticated"}';

select is(
  (public.request_thread('eeee3333-0000-4000-8000-00000000000e') ->> 'ok'),
  'true',
  'the requester can read the conversation'
);

select is(
  jsonb_array_length(public.request_thread('eeee3333-0000-4000-8000-00000000000e') -> 'team'),
  3,
  'and sees all three people on the recovery, not just one helper'
);

set local request.jwt.claims = '{"sub":"cccc1111-0000-4000-8000-00000000000c","role":"authenticated"}';

select is(
  (public.request_thread('eeee3333-0000-4000-8000-00000000000e') ->> 'ok'),
  'true',
  'the SECOND helper can read it too -- the thing that was impossible before'
);

-- ---------------------------------------------------------------------------
-- 2. A bystander cannot, and cannot tell the difference
-- ---------------------------------------------------------------------------

set local request.jwt.claims = '{"sub":"dddd1111-0000-4000-8000-00000000000d","role":"authenticated"}';

select is(
  (public.request_thread('eeee3333-0000-4000-8000-00000000000e') ->> 'error'),
  'not_found',
  'a member who is not on the recovery is refused'
);

select is(
  (public.request_thread('eeee3333-0000-4000-8000-00000000000e') ->> 'error'),
  (public.request_thread('00000000-1111-4111-8111-000000000fff') ->> 'error'),
  'and gets the same answer as for a request that does not exist, so ids cannot be walked'
);

-- `-> 'messages'` on a payload without that key is SQL NULL, and comparing it to the string
-- 'null' compares NULL to text and is never equal. Ask whether the key exists instead.
select ok(
  not (public.request_thread('eeee3333-0000-4000-8000-00000000000e') ? 'messages'),
  'the refusal payload carries no messages key at all'
);

-- ---------------------------------------------------------------------------
-- 3. Withdrawing keeps the history and stops the future
-- ---------------------------------------------------------------------------

reset role;

update public.recovery_participants
   set left_at = now(), status = 'withdrawn'
 where request_id = 'eeee3333-0000-4000-8000-00000000000e'
   and user_id = 'cccc1111-0000-4000-8000-00000000000c';

set local role authenticated;
set local request.jwt.claims = '{"sub":"cccc1111-0000-4000-8000-00000000000c","role":"authenticated"}';

select is(
  (public.request_thread('eeee3333-0000-4000-8000-00000000000e') ->> 'error'),
  'not_found',
  'a helper who withdrew stops receiving what is said next'
);

reset role;

select isnt_empty(
  $q$select 1 from public.recovery_participants
      where request_id = 'eeee3333-0000-4000-8000-00000000000e'
        and user_id = 'cccc1111-0000-4000-8000-00000000000c'$q$,
  'but their row survives, because the record of who was there is the history'
);

-- ---------------------------------------------------------------------------
-- 4. The lead follows the team
-- ---------------------------------------------------------------------------

select app.sync_recovery_lead('eeee3333-0000-4000-8000-00000000000e');

select is(
  (select accepted_responder_id from public.requests
    where id = 'eeee3333-0000-4000-8000-00000000000e'),
  'bbbb2222-0000-4000-8000-00000000000b'::uuid,
  'the lead is the first helper who has not left'
);

-- Everybody goes home.
update public.recovery_participants
   set left_at = now(), status = 'withdrawn'
 where request_id = 'eeee3333-0000-4000-8000-00000000000e' and role = 'helper';

select app.sync_recovery_lead('eeee3333-0000-4000-8000-00000000000e');

select is(
  (select status::text from public.requests where id = 'eeee3333-0000-4000-8000-00000000000e'),
  'unmatched',
  'when the last helper leaves the request says nobody is coming, rather than lying'
);

select is(
  (select accepted_responder_id from public.requests
    where id = 'eeee3333-0000-4000-8000-00000000000e'),
  null,
  'and no lead is left pointing at somebody who went home'
);

-- ---------------------------------------------------------------------------
-- 5. Unread is per person
-- ---------------------------------------------------------------------------
--
-- The old code marked every message not sent by the reader as read. With two people that was
-- fine. With three it meant one person opening the thread cleared another person's badge.

reset role;

insert into public.recovery_participants (request_id, user_id, responder_id, role, status)
values ('eeee3333-0000-4000-8000-00000000000e', 'bbbb1111-0000-4000-8000-00000000000b',
        'bbbb2222-0000-4000-8000-00000000000b', 'helper', 'accepted')
-- The unique index is partial (`where user_id is not null`), so ON CONFLICT has to carry the same
-- predicate or Postgres cannot match it to an index and refuses the statement outright.
on conflict (request_id, user_id) where user_id is not null
  do update set left_at = null, status = 'accepted';

set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaa1111-0000-4000-8000-00000000000a","role":"authenticated"}';
select public.request_thread('eeee3333-0000-4000-8000-00000000000e');

select is(
  (select unread from public.my_unread_counts()
    where request_id = 'eeee3333-0000-4000-8000-00000000000e'),
  0,
  'the requester has read everything after opening the thread'
);

set local request.jwt.claims = '{"sub":"bbbb1111-0000-4000-8000-00000000000b","role":"authenticated"}';

select cmp_ok(
  (select unread from public.my_unread_counts()
    where request_id = 'eeee3333-0000-4000-8000-00000000000e'),
  '>', 0,
  'and the helper still has an unread message, because somebody else read it, not them'
);

-- ---------------------------------------------------------------------------
-- 6. A helper says where they have got to
-- ---------------------------------------------------------------------------
--
-- Status lives on the participant, not the request: a winch truck can be on site while a tractor
-- is still loading, and neither fact is "the recovery is on_site". The request moves when the
-- FIRST helper arrives.

reset role;
-- Through sync_recovery_lead, not a hand-written UPDATE. `requests_assigned_states_have_responder`
-- refuses an accepted request with nobody assigned, which is the constraint doing exactly its job:
-- the only honest way into that state is to have a helper.
select app.sync_recovery_lead('eeee3333-0000-4000-8000-00000000000e');

select is(
  (select status::text from public.requests where id = 'eeee3333-0000-4000-8000-00000000000e'),
  'accepted',
  'a helper rejoining puts the recovery back to accepted'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"bbbb1111-0000-4000-8000-00000000000b","role":"authenticated"}';

select is(
  public.set_my_participant_status('eeee3333-0000-4000-8000-00000000000e', 'en_route') ->> 'ok',
  'true',
  'a helper can say they are on the way'
);

select is(
  (select status::text from public.recovery_participants
    where request_id = 'eeee3333-0000-4000-8000-00000000000e'
      and user_id = 'bbbb1111-0000-4000-8000-00000000000b'),
  'en_route',
  'and it is recorded against them, not against the recovery'
);

-- Asserting on `requests` and `request_messages` needs the owner role back: requests is behind
-- RLS and request_messages has no grants at all, so as `authenticated` the first returns no row
-- (NULL, not a wrong answer) and the second is refused outright. Act as the member, check as the
-- owner.
reset role;
select is(
  (select status::text from public.requests where id = 'eeee3333-0000-4000-8000-00000000000e'),
  'accepted',
  'one helper setting off does not move the recovery -- nobody has arrived'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"bbbb1111-0000-4000-8000-00000000000b","role":"authenticated"}';

select is(
  public.set_my_participant_status('eeee3333-0000-4000-8000-00000000000e', 'on_site') ->> 'ok',
  'true',
  'and then that they have arrived'
);

reset role;
select is(
  (select status::text from public.requests where id = 'eeee3333-0000-4000-8000-00000000000e'),
  'on_site',
  'the FIRST arrival does move the recovery, which is what somebody waiting needs to see'
);

select isnt_empty(
  $q$select 1 from public.request_messages
      where request_id = 'eeee3333-0000-4000-8000-00000000000e'
        and sender_role = 'system' and body like '%on site%'$q$,
  'and the chat says so, so the team is not guessing'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"bbbb1111-0000-4000-8000-00000000000b","role":"authenticated"}';

-- The refusals, each one a thing the UI must not be the only guard against.
select is(
  public.set_my_participant_status('eeee3333-0000-4000-8000-00000000000e', 'withdrawn') ->> 'error',
  'use_withdraw',
  'leaving is not a status change: it revokes access and may hand over the lead'
);

select is(
  public.set_my_participant_status('eeee3333-0000-4000-8000-00000000000e', 'teleported') ->> 'error',
  'bad_status',
  'an unknown status from a stale client is a refusal, not a 500'
);

set local request.jwt.claims = '{"sub":"dddd1111-0000-4000-8000-00000000000d","role":"authenticated"}';
select is(
  public.set_my_participant_status('eeee3333-0000-4000-8000-00000000000e', 'en_route') ->> 'error',
  'not_found',
  'somebody who is not on the recovery cannot set a status on it'
);

set local request.jwt.claims = '{"sub":"aaaa1111-0000-4000-8000-00000000000a","role":"authenticated"}';
select is(
  public.set_my_participant_status('eeee3333-0000-4000-8000-00000000000e', 'en_route') ->> 'error',
  'not_a_helper',
  'and the person who is stuck is not travelling anywhere'
);

-- ---------------------------------------------------------------------------
-- 7. Leaving
-- ---------------------------------------------------------------------------

select is(
  public.withdraw_from_recovery('eeee3333-0000-4000-8000-00000000000e') ->> 'error',
  'requester_cannot_withdraw',
  'the requester cannot withdraw from their own recovery -- they cancel it'
);

set local request.jwt.claims = '{"sub":"bbbb1111-0000-4000-8000-00000000000b","role":"authenticated"}';

select is(
  public.withdraw_from_recovery('eeee3333-0000-4000-8000-00000000000e') ->> 'ok',
  'true',
  'a helper who cannot make it can say so'
);

select is(
  (public.request_thread('eeee3333-0000-4000-8000-00000000000e') ->> 'error'),
  'not_found',
  'and immediately stops seeing the conversation'
);

reset role;

select is(
  (select status::text from public.requests where id = 'eeee3333-0000-4000-8000-00000000000e'),
  'unmatched',
  'with nobody left coming, the recovery says so instead of leaving somebody waiting'
);

select isnt_empty(
  $q$select 1 from public.request_messages
      where request_id = 'eeee3333-0000-4000-8000-00000000000e'
        and sender_role = 'system' and body like '%no longer make it%'$q$,
  'and the chat records why, for whoever is still reading it'
);

-- ---------------------------------------------------------------------------
-- 8. A message tells the rest of the team, and only the rest
-- ---------------------------------------------------------------------------

reset role;

-- Put the team back: requester A, helpers B and C.
update public.recovery_participants set left_at = null, status = 'accepted'
 where request_id = 'eeee3333-0000-4000-8000-00000000000e';

-- C wants the recovery but not the chatter.
update public.recovery_participants set muted = true
 where request_id = 'eeee3333-0000-4000-8000-00000000000e'
   and user_id = 'cccc1111-0000-4000-8000-00000000000c';

insert into public.request_messages (request_id, sender_user_id, sender_role, body)
values ('eeee3333-0000-4000-8000-00000000000e', 'aaaa1111-0000-4000-8000-00000000000a',
        'requester', 'Gate code is 4412');

select is(
  (select count(*)::int from public.notifications n
    where n.kind = 'message'
      and n.params ->> 'preview' like 'Gate code%'
      and n.user_id = 'bbbb1111-0000-4000-8000-00000000000b'),
  1,
  'a message notifies the other people on the recovery'
);

select is(
  (select count(*)::int from public.notifications n
    where n.kind = 'message'
      and n.params ->> 'preview' like 'Gate code%'
      and n.user_id = 'aaaa1111-0000-4000-8000-00000000000a'),
  0,
  'and never the person who sent it'
);

select is(
  (select count(*)::int from public.notifications n
    where n.kind = 'message'
      and n.params ->> 'preview' like 'Gate code%'
      and n.user_id = 'cccc1111-0000-4000-8000-00000000000c'),
  0,
  'somebody who muted this recovery is not told about chatter'
);

-- Scoped to the kinds this phase added, deliberately.
--
-- The first version asserted that NO notification anywhere carries the token, and it failed with
-- five. Those five are Phase 13's, and they are fine: a notification about your own recovery, in
-- your own authenticated list, carrying your own link. Asserting otherwise would have been me
-- inventing a rule the codebase never held and then "fixing" working code to match it.
--
-- What is worth holding is narrower: the team notifications carry an id, because an id resolves
-- server-side through recovery_link and a token does not need to travel to say "Mike is on site".
select is(
  (select count(*)::int from public.notifications n
    where n.kind in ('message', 'helper_joined', 'helper_status')
      and n.url like '%' || (select public_token from public.requests
                              where id = 'eeee3333-0000-4000-8000-00000000000e') || '%'),
  0,
  'the team notifications carry no recovery token'
);

select isnt_empty(
  $q$select 1 from public.notifications
      where kind = 'message' and url like '/recovery/%'$q$,
  'they carry the request id instead, which resolves server-side for a participant'
);

-- ---------------------------------------------------------------------------
-- 9. Resolving a deep link
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims = '{"sub":"bbbb1111-0000-4000-8000-00000000000b","role":"authenticated"}';

select is(
  public.recovery_link('eeee3333-0000-4000-8000-00000000000e') ->> 'token',
  'team-test-token-aaaaaaaaaa',
  'a participant following a deep link gets their own status token'
);

set local request.jwt.claims = '{"sub":"dddd1111-0000-4000-8000-00000000000d","role":"authenticated"}';

select is(
  public.recovery_link('eeee3333-0000-4000-8000-00000000000e') ->> 'error',
  'not_found',
  'and anybody else gets nothing, so a guessed id opens nothing'
);

select * from finish();
rollback;
