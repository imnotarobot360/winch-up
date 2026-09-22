-- Winch Up :: proof that a recovery thread reaches nobody else
--
-- Run with:  supabase test db
--
-- The rule: a conversation belongs to exactly two people -- the person who was stuck and the
-- volunteer who took the job. Not admins browsing, not a volunteer who was texted and passed,
-- not whoever was forwarded the status link.
--
-- That last one is why this is the single requester action that requires a signed-in account
-- rather than the token. The status link is meant to be shared with family so they can watch;
-- a thread reachable by it would be readable by all of them, and it contains a phone number and
-- an exact location.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- ---------------------------------------------------------------------------
-- Fixtures: one request, one requester, one accepted volunteer, one bystander
-- who was dispatched to but passed, and one unrelated account.
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
)
select '00000000-0000-0000-0000-000000000000', v.id, 'authenticated', 'authenticated',
       v.email, 'x', now(), '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
from (values
  ('f1111111-0000-4000-8000-00000000000f'::uuid, 'msg-requester@example.invalid'),
  ('f2222222-0000-4000-8000-00000000000f'::uuid, 'msg-winner@example.invalid'),
  ('f3333333-0000-4000-8000-00000000000f'::uuid, 'msg-passer@example.invalid'),
  ('f4444444-0000-4000-8000-00000000000f'::uuid, 'msg-stranger@example.invalid')
) as v(id, email);

insert into responders (
  id, user_id, phone, first_name, home_location, radius_miles,
  equipment, approval, availability, sms_opt_in
) values
  ('f2222222-1111-4111-8111-00000000000f', 'f2222222-0000-4000-8000-00000000000f',
   '+15125559301', 'Winner',
   extensions.st_setsrid(extensions.st_point(-97.74, 30.27), 4326)::extensions.geography,
   60, '{winch}', 'approved', 'active', true),
  ('f3333333-1111-4111-8111-00000000000f', 'f3333333-0000-4000-8000-00000000000f',
   '+15125559302', 'Passer',
   extensions.st_setsrid(extensions.st_point(-97.74, 30.27), 4326)::extensions.geography,
   60, '{winch}', 'approved', 'active', true);

insert into requests (
  id, requester_name, requester_phone, requester_user_id, location, vehicle_class, stuck_type,
  land_type, status, accepted_responder_id, emergency_ack_at, rules_accepted,
  waiver_id, waiver_accepted_at
) values (
  'f0000000-1111-4111-8111-00000000000f',
  'Msg Test', '+15125559300', 'f1111111-0000-4000-8000-00000000000f',
  extensions.st_setsrid(extensions.st_point(-97.74, 30.27), 4326)::extensions.geography,
  'truck', 'mud', 'public', 'accepted', 'f2222222-1111-4111-8111-00000000000f',
  now(), true, (select id from waivers where slug = 'requester_waiver' and is_current), now()
);

-- The passer was dispatched to and declined. Being texted about a job is not membership of the
-- conversation about it.
insert into dispatches (request_id, responder_id, ring, distance_miles, state)
values ('f0000000-1111-4111-8111-00000000000f', 'f3333333-1111-4111-8111-00000000000f', 1, 4.2, 'declined');

-- ---------------------------------------------------------------------------
-- 1. No table access for anyone
-- ---------------------------------------------------------------------------

select ok(not has_table_privilege('anon', 'request_messages', 'SELECT'),
  'anon cannot read request_messages');
select ok(not has_table_privilege('authenticated', 'request_messages', 'SELECT'),
  'a signed-in user cannot read the table directly, only through the function');
select ok(not has_table_privilege('authenticated', 'request_messages', 'INSERT'),
  'and cannot insert directly either');

select ok(not has_function_privilege('anon', 'public.request_thread(uuid)', 'EXECUTE'),
  'anon cannot call request_thread: the status token is not a key to the conversation');
select ok(not has_function_privilege('anon', 'public.send_request_message(jsonb)', 'EXECUTE'),
  'nor send_request_message');

-- ---------------------------------------------------------------------------
-- 2. The two participants
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"f1111111-0000-4000-8000-00000000000f","role":"authenticated"}';

select is(
  public.send_request_message(jsonb_build_object(
    'request_id', 'f0000000-1111-4111-8111-00000000000f',
    'body', 'I am at the second gate, blue Tacoma.')) ->> 'ok',
  'true',
  'the person who is stuck can send'
);

set local request.jwt.claims =
  '{"sub":"f2222222-0000-4000-8000-00000000000f","role":"authenticated"}';

select is(
  jsonb_array_length(
    public.request_thread('f0000000-1111-4111-8111-00000000000f') -> 'messages'),
  1,
  'the volunteer who took the job can read it'
);

select is(
  public.send_request_message(jsonb_build_object(
    'request_id', 'f0000000-1111-4111-8111-00000000000f',
    'body', 'On my way, about twenty minutes.')) ->> 'ok',
  'true',
  'and can reply'
);

-- ---------------------------------------------------------------------------
-- 3. Everybody else
-- ---------------------------------------------------------------------------

set local request.jwt.claims =
  '{"sub":"f3333333-0000-4000-8000-00000000000f","role":"authenticated"}';

select is(
  public.request_thread('f0000000-1111-4111-8111-00000000000f') ->> 'error',
  'not_found',
  'a volunteer who was texted about the job and passed cannot read the thread'
);

set local request.jwt.claims =
  '{"sub":"f4444444-0000-4000-8000-00000000000f","role":"authenticated"}';

select is(
  public.request_thread('f0000000-1111-4111-8111-00000000000f') ->> 'error',
  'not_found',
  'an unrelated signed-in account cannot read it'
);

select is(
  public.send_request_message(jsonb_build_object(
    'request_id', 'f0000000-1111-4111-8111-00000000000f',
    'body', 'let me in')) ->> 'error',
  'not_found',
  'nor write into it'
);

-- Same answer for a request that does not exist at all, so a signed-in user cannot walk ids to
-- discover which are real.
select is(
  public.request_thread('f9999999-9999-4999-8999-00000000000f') ->> 'error',
  'not_found',
  'and a nonexistent request answers identically, so ids cannot be probed'
);

-- ---------------------------------------------------------------------------
-- 4. Membership is derived, so reassignment moves the conversation
-- ---------------------------------------------------------------------------

reset role;

update requests set accepted_responder_id = 'f3333333-1111-4111-8111-00000000000f'
 where id = 'f0000000-1111-4111-8111-00000000000f';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"f3333333-0000-4000-8000-00000000000f","role":"authenticated"}';

select is(
  public.request_thread('f0000000-1111-4111-8111-00000000000f') ->> 'ok',
  'true',
  'reassigning the job hands the conversation to the new volunteer'
);

set local request.jwt.claims =
  '{"sub":"f2222222-0000-4000-8000-00000000000f","role":"authenticated"}';

select is(
  public.request_thread('f0000000-1111-4111-8111-00000000000f') ->> 'error',
  'not_found',
  'and takes it away from the old one, because membership is derived and not stored'
);

-- ---------------------------------------------------------------------------
-- 5. Content rules
-- ---------------------------------------------------------------------------

reset role;
update requests set accepted_responder_id = 'f2222222-1111-4111-8111-00000000000f'
 where id = 'f0000000-1111-4111-8111-00000000000f';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"f1111111-0000-4000-8000-00000000000f","role":"authenticated"}';

select is(
  public.send_request_message(jsonb_build_object(
    'request_id', 'f0000000-1111-4111-8111-00000000000f')) ->> 'error',
  'empty',
  'a message with neither text nor a picture is refused'
);

select is(
  public.send_request_message(jsonb_build_object(
    'request_id', 'f0000000-1111-4111-8111-00000000000f',
    'attachment_path', 'x/y.exe', 'attachment_type', 'application/x-msdownload')) ->> 'error',
  'bad_attachment_type',
  'and so is an attachment that is not an image'
);

-- A thread that stays open forever is a channel between two strangers who met once. The incident
-- report is the route if something needs saying after the job is done.
reset role;
update requests set status = 'recovered'
 where id = 'f0000000-1111-4111-8111-00000000000f';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"f1111111-0000-4000-8000-00000000000f","role":"authenticated"}';

select is(
  public.send_request_message(jsonb_build_object(
    'request_id', 'f0000000-1111-4111-8111-00000000000f',
    'body', 'one more thing')) ->> 'error',
  'closed',
  'a finished recovery stops accepting messages'
);

select is(
  public.request_thread('f0000000-1111-4111-8111-00000000000f') ->> 'ok',
  'true',
  'but both people can still read what was said'
);

reset role;

select * from finish();
rollback;
