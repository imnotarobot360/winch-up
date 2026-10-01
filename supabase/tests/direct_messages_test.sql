-- Winch Up :: who may message whom, and what a thread payload says
--
-- Run with:  supabase test db
--
-- Member-to-member messaging is the first surface in this product where a stranger can put text in
-- front of another member unprompted. Everything else is need-to-know: a volunteer sees a recovery they
-- were rung about, a participant sees their own thread, the community feed is members-only and
-- moderated. So the assertions here are mostly about REFUSAL -- and, as throughout this suite, each
-- refusal is paired with the control that proves the refusal was the rule and not an empty database.
--
-- The rule being defended, from 20261001002300:
--
--   STARTING a conversation needs the recipient's allow_direct_messages.
--   CONTINUING one does not -- that is what blocking is for.
--   Blocking and suspension override both, in either direction.
--   READING is always allowed to a participant, whatever has happened since.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- ---------------------------------------------------------------------------
-- Five members: two who talk, one who has messages off, one blocked, one suspended
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
)
select '00000000-0000-0000-0000-000000000000', v.id, 'authenticated', 'authenticated',
       v.email, 'x', now(), '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
from (values
  ('11000000-0000-4000-8000-00000000000b'::uuid, 'dm-ana@example.invalid'),
  ('12000000-0000-4000-8000-00000000000b'::uuid, 'dm-ben@example.invalid'),
  ('13000000-0000-4000-8000-00000000000b'::uuid, 'dm-closed@example.invalid'),
  ('14000000-0000-4000-8000-00000000000b'::uuid, 'dm-blocked@example.invalid'),
  ('15000000-0000-4000-8000-00000000000b'::uuid, 'dm-suspended@example.invalid')
) as v(id, email)
on conflict (id) do nothing;

update public.profiles set display_name = 'Ana'
 where user_id = '11000000-0000-4000-8000-00000000000b';
update public.profiles set display_name = 'Ben'
 where user_id = '12000000-0000-4000-8000-00000000000b';
update public.profiles set display_name = 'Closed', allow_direct_messages = false
 where user_id = '13000000-0000-4000-8000-00000000000b';
update public.profiles set display_name = 'Blocked'
 where user_id = '14000000-0000-4000-8000-00000000000b';
update public.profiles set display_name = 'Suspended', suspended_at = now(),
       suspended_reason = 'test'
 where user_id = '15000000-0000-4000-8000-00000000000b';

-- Ana blocked them, so neither direction works.
insert into public.user_blocks (blocker_user_id, blocked_user_id)
values ('11000000-0000-4000-8000-00000000000b', '14000000-0000-4000-8000-00000000000b')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 1. The default is ON, which is a decision and is asserted as one
-- ---------------------------------------------------------------------------

select is(
  (select column_default from information_schema.columns
    where table_name = 'profiles' and column_name = 'allow_direct_messages'),
  'true',
  'members can be messaged by default -- the owner''s call, and the opposite of a directory that '
    || 'shipped empty behind two default-off switches'
);

select is(
  (select column_default from information_schema.columns
    where table_name = 'profiles' and column_name = 'notify_direct_messages'),
  'true',
  'and a direct message buzzes the phone by default'
);

-- ---------------------------------------------------------------------------
-- 2. No table reaches anybody
-- ---------------------------------------------------------------------------
--
-- The whole design rests on this: participation is derived inside the functions, never granted.

select ok(not has_table_privilege('authenticated', 'dm_threads', 'SELECT'),
  'a member cannot select dm_threads directly');
select ok(not has_table_privilege('authenticated', 'dm_messages', 'SELECT'),
  'nor dm_messages');
select ok(not has_table_privilege('authenticated', 'dm_messages', 'INSERT'),
  'and cannot insert a message past the send RPC');
select ok(not has_table_privilege('anon', 'dm_messages', 'SELECT'),
  'anon certainly cannot');

select ok(
  (select relrowsecurity from pg_class where relname = 'dm_threads'),
  'dm_threads has RLS on, so a future grant cannot quietly open it');
select ok(
  (select relrowsecurity from pg_class where relname = 'dm_messages'),
  'and so does dm_messages');

-- ---------------------------------------------------------------------------
-- 3. Ana messages Ben: the control for everything below
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"11000000-0000-4000-8000-00000000000b","role":"authenticated"}';

select is(
  (public.dm_can_message('12000000-0000-4000-8000-00000000000b') ->> 'can_message'),
  'true',
  'a member who allows messages can be messaged'
);

select is(
  public.dm_send('12000000-0000-4000-8000-00000000000b', 'Spare strap on Sunday?', 'client-ana-001')
    ->> 'ok',
  'true',
  'and the message sends'
);

select is(
  public.dm_send('12000000-0000-4000-8000-00000000000b', 'Spare strap on Sunday?', 'client-ana-001')
    ->> 'duplicate',
  'true',
  'a retry with the same client id is the same message, not a second one'
);

-- The idempotency key is the only thing standing between a flaky connection and the recipient seeing
-- everything twice, so it is asserted on the row count rather than on the answer.
reset role;
select is(
  (select count(*)::int from public.dm_messages where client_id = 'client-ana-001'),
  1,
  'one row, not two'
);
select is(
  (select count(*)::int from public.dm_threads
    where member_a = least('11000000-0000-4000-8000-00000000000b'::uuid,
                           '12000000-0000-4000-8000-00000000000b'::uuid)
      and member_b = greatest('11000000-0000-4000-8000-00000000000b'::uuid,
                              '12000000-0000-4000-8000-00000000000b'::uuid)),
  1,
  'and one thread for the pair'
);

-- THE THREAD ID, STASHED WHERE A MEMBER CAN READ IT.
--
-- The rest of this file needs the id while acting as a member, and `select id from dm_threads` is
-- exactly what no member may do -- which is the property section 2 asserts. Reading it from the
-- table mid-test fails with permission denied, and that failure is the design working, not a bug in
-- it. So the id is captured here, with the role reset, into a temp table the test grants itself.
create temp table dm_ids as
  select id as thread from public.dm_threads
   where member_a = least('11000000-0000-4000-8000-00000000000b'::uuid,
                          '12000000-0000-4000-8000-00000000000b'::uuid)
     and member_b = greatest('11000000-0000-4000-8000-00000000000b'::uuid,
                             '12000000-0000-4000-8000-00000000000b'::uuid);
grant select on dm_ids to authenticated;

-- ---------------------------------------------------------------------------
-- 4. The three refusals
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"11000000-0000-4000-8000-00000000000b","role":"authenticated"}';

select is(
  public.dm_send('13000000-0000-4000-8000-00000000000b', 'hello', 'client-ana-002') ->> 'error',
  'messages_off',
  'a member who turned messages off cannot be messaged'
);

select is(
  (public.dm_can_message('13000000-0000-4000-8000-00000000000b') ->> 'reason'),
  'messages_off',
  'and the UI is told so before it draws a button'
);

-- Blocking gives not_found rather than "blocked", so the block is not announced to the person who was
-- blocked. Telling them is how blocking becomes an invitation to make another account.
select is(
  public.dm_send('14000000-0000-4000-8000-00000000000b', 'hello', 'client-ana-003') ->> 'error',
  'not_found',
  'somebody you blocked cannot be messaged, and is not told they were blocked'
);

select is(
  public.dm_send('15000000-0000-4000-8000-00000000000b', 'hello', 'client-ana-004') ->> 'error',
  'not_found',
  'a suspended member cannot be messaged'
);

select is(
  public.dm_send('11000000-0000-4000-8000-00000000000b', 'hello', 'client-ana-005') ->> 'error',
  'not_found',
  'and nobody messages themselves'
);

select is(
  public.dm_send('12000000-0000-4000-8000-00000000000b', '   ', 'client-ana-006') ->> 'error',
  'bad_body',
  'whitespace is not a message'
);

select is(
  public.dm_send('12000000-0000-4000-8000-00000000000b', 'hi', 'short') ->> 'error',
  'bad_client_id',
  'and a client id too short to be unique is refused rather than trusted'
);

reset role;

-- ---------------------------------------------------------------------------
-- 5. The distinction the switch actually makes
-- ---------------------------------------------------------------------------
--
-- THE MOST IMPORTANT PAIR IN THIS FILE. Turning messages off must stop NEW conversations without
-- stranding the ones you already have -- otherwise flipping the switch silently kills every thread a
-- member is in, and they would never know why their replies stopped arriving.

update public.profiles set allow_direct_messages = false
 where user_id = '12000000-0000-4000-8000-00000000000b';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"11000000-0000-4000-8000-00000000000b","role":"authenticated"}';

select is(
  public.dm_send('12000000-0000-4000-8000-00000000000b', 'still here?', 'client-ana-007') ->> 'ok',
  'true',
  'a conversation that already exists survives the other member turning messages off'
);

select is(
  (public.dm_can_message('12000000-0000-4000-8000-00000000000b') ->> 'can_message'),
  'true',
  'and the UI still offers it, because the thread is half theirs'
);

reset role;
update public.profiles set allow_direct_messages = true
 where user_id = '12000000-0000-4000-8000-00000000000b';

-- Blocking, by contrast, stops it dead -- which is why the UI points at blocking and not at the switch
-- when somebody wants a particular person to stop.
insert into public.user_blocks (blocker_user_id, blocked_user_id)
values ('12000000-0000-4000-8000-00000000000b', '11000000-0000-4000-8000-00000000000b')
on conflict do nothing;

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"11000000-0000-4000-8000-00000000000b","role":"authenticated"}';

select is(
  public.dm_send('12000000-0000-4000-8000-00000000000b', 'and now?', 'client-ana-008') ->> 'error',
  'not_found',
  'being blocked DOES stop an existing conversation, which is the control the switch is not'
);

-- ---------------------------------------------------------------------------
-- 6. But the history stays readable
-- ---------------------------------------------------------------------------
--
-- Somebody who blocks a harasser keeps the evidence, and somebody who was blocked keeps their own side
-- of what was said. Blocking stops new messages; it does not rewrite the past.

select is(
  public.dm_thread(
    (select thread from dm_ids)
  ) ->> 'ok',
  'true',
  'a blocked conversation is still readable by both sides'
);

reset role;
delete from public.user_blocks
 where blocker_user_id = '12000000-0000-4000-8000-00000000000b'
   and blocked_user_id = '11000000-0000-4000-8000-00000000000b';

-- ---------------------------------------------------------------------------
-- 7. A thread id is not a key
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"13000000-0000-4000-8000-00000000000b","role":"authenticated"}';

select is(
  public.dm_thread(
    (select thread from dm_ids)
  ) ->> 'error',
  'not_found',
  'a member handed somebody else''s thread id gets nothing'
);

select is(
  public.dm_mark_read((select thread from dm_ids)) ->> 'error',
  'not_found',
  'and cannot mark it read either'
);

select is(
  public.dm_thread('00000000-0000-4000-8000-0000000000ff') ->> 'error',
  'not_found',
  'an invented id gets the same answer, so this is not a way to learn who is talking to whom'
);

select is(
  (select count(*)::int
     from jsonb_array_elements(public.dm_inbox() -> 'threads') t),
  0,
  'and an uninvolved member has an empty inbox'
);

reset role;

-- ---------------------------------------------------------------------------
-- 8. What the payload carries, and what it must not
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"12000000-0000-4000-8000-00000000000b","role":"authenticated"}';

select is(
  (select count(*)::int
     from jsonb_array_elements(public.dm_inbox() -> 'threads') t),
  1,
  'Ben sees the one conversation he is in'
);

select is(
  (select t ->> 'other_name'
     from jsonb_array_elements(public.dm_inbox() -> 'threads') t),
  'Ana',
  'named by display name, from the same place the directory takes it'
);

select is(
  (select (t ->> 'unread')::int
     from jsonb_array_elements(public.dm_inbox() -> 'threads') t),
  2,
  'with the unread count: both of Ana''s messages, and not his own'
);

-- A message payload says whether it is yours, not who sent it. request_thread() returns a first name
-- rather than a user id for the same reason: a thread is not a directory of account ids.
select ok(
  not ((select m from jsonb_array_elements(
          public.dm_thread((select thread from dm_ids)) -> 'messages') m limit 1)
       ?| array['sender_user_id', 'sender', 'user_id', 'email', 'phone']),
  'a message carries `mine`, never a sender id, an email or a phone number'
);

select is(
  (select m ->> 'mine'
     from jsonb_array_elements(
            public.dm_thread((select thread from dm_ids)) -> 'messages') m
    limit 1),
  'false',
  'and Ana''s messages are not Ben''s'
);

-- ---------------------------------------------------------------------------
-- 9. Read receipts mean "they saw it", or they mean nothing
-- ---------------------------------------------------------------------------

select is(
  public.dm_mark_read((select thread from dm_ids)) ->> 'marked',
  '2',
  'marking read stamps the other person''s messages'
);

select is(
  (select (t ->> 'unread')::int
     from jsonb_array_elements(public.dm_inbox() -> 'threads') t),
  0,
  'and the inbox badge clears'
);

reset role;

-- Only the other person's. Stamping your own would make read_at meaningless as the one thing it is for.
select is(
  (select count(*)::int from public.dm_messages
    where sender_user_id = '12000000-0000-4000-8000-00000000000b' and read_at is not null),
  0,
  'Ben marking the thread read did not mark his OWN messages as seen by Ana'
);

-- ---------------------------------------------------------------------------
-- 10. Signed out is not a reader
-- ---------------------------------------------------------------------------

set local role anon;

select throws_ok(
  'select public.dm_inbox()',
  '42501',
  null,
  'anon cannot read an inbox'
);

select throws_ok(
  $$select public.dm_send('12000000-0000-4000-8000-00000000000b', 'hi', 'client-anon-001')$$,
  '42501',
  null,
  'nor send a message'
);

reset role;

-- ---------------------------------------------------------------------------
-- 11. Every preference column is actually reachable by its owner
-- ---------------------------------------------------------------------------
--
-- A PROPERTY, not two assertions about two columns, because the failure this guards against is one
-- somebody repeats rather than one they make twice.
--
-- public.profiles has no blanket grant to authenticated -- it has an enumerated column list, and a
-- column added later is in none of it. When allow_direct_messages and notify_direct_messages were
-- added without grants, the notification screen's select was refused in full, the component fell
-- back to DEFAULTS, and every switch showed its default instead of the member's real preference.
-- Nothing errored. A read failure presenting as a confident wrong answer, on the one screen whose
-- entire job is to tell somebody what they chose.
--
-- So: anything on profiles named like a member-facing preference must be selectable AND updatable
-- by its owner. If a future column is neither of those on purpose, it does not belong to this
-- naming pattern -- suspended_at is the example, and it is excluded by being named for a thing done
-- TO a member rather than chosen BY one.

select is(
  (select coalesce(string_agg(c.column_name, ', ' order by c.column_name), '(none)')
     from information_schema.columns c
    where c.table_schema = 'public' and c.table_name = 'profiles'
      and (c.column_name like 'notify\_%' or c.column_name like 'allow\_%')
      and not exists (
        select 1 from information_schema.column_privileges g
         where g.table_name = 'profiles' and g.grantee = 'authenticated'
           and g.column_name = c.column_name and g.privilege_type = 'SELECT')),
  '(none)',
  'every notify_* and allow_* column on profiles can be READ by the member it belongs to'
);

select is(
  (select coalesce(string_agg(c.column_name, ', ' order by c.column_name), '(none)')
     from information_schema.columns c
    where c.table_schema = 'public' and c.table_name = 'profiles'
      and (c.column_name like 'notify\_%' or c.column_name like 'allow\_%')
      and not exists (
        select 1 from information_schema.column_privileges g
         where g.table_name = 'profiles' and g.grantee = 'authenticated'
           and g.column_name = c.column_name and g.privilege_type = 'UPDATE')),
  '(none)',
  'and CHANGED by them, which is what a preference is'
);

-- The other direction, so the assertion above cannot be satisfied by granting everything: a member
-- must not be able to read or lift their own suspension.
select is(
  (select count(*)::int from information_schema.column_privileges
    where table_name = 'profiles' and grantee = 'authenticated'
      and column_name in ('suspended_at', 'suspended_reason', 'suspended_by')),
  0,
  'while suspension is granted neither way, because it is done TO a member, not chosen by one'
);
select * from finish();
rollback;
