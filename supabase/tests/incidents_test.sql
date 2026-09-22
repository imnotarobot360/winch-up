-- Winch Up :: proof that a report cannot reach the person it is about
--
-- Run with:  supabase test db
--
-- The rule these tests defend: THE SUBJECT OF A REPORT NEVER SEES IT. A volunteer who learns
-- that the person they just winched out reported them knows where that person was, what they
-- drive, and usually their phone number. This is not a data leak, it is a safety problem, and
-- it is why safety_incidents has no table grants at all.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- ---------------------------------------------------------------------------
-- 1. Nobody has table access. Not read, not write, not anyone.
-- ---------------------------------------------------------------------------

select ok(not has_table_privilege('anon', 'safety_incidents', 'SELECT'),
  'anon cannot read safety_incidents');
select ok(not has_table_privilege('authenticated', 'safety_incidents', 'SELECT'),
  'a signed-in user cannot read safety_incidents, including their own reports');
select ok(not has_table_privilege('authenticated', 'safety_incidents', 'INSERT'),
  'reports are written through a function, never by direct insert');
select ok(not has_table_privilege('authenticated', 'safety_incidents', 'UPDATE'),
  'nobody can edit a report after filing it');

select is(
  (select relrowsecurity from pg_class where relname = 'safety_incidents'),
  true,
  'row level security is on as well, so a stray grant still fails closed'
);

-- ---------------------------------------------------------------------------
-- 2. The subject, signed in, trying to read reports about themselves
-- ---------------------------------------------------------------------------

insert into safety_incidents (
  reporter_kind, reporter_user_id, subject_responder_id, category, description
) values (
  'requester', '00000000-0000-4000-8000-000000000003',
  '11111111-1111-4111-8111-000000000001', 'asked_for_money',
  'He asked for forty dollars in cash before hooking up the strap.'
);

set local role authenticated;
-- This is Mike's account, and Mike is the responder named above.
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated"}';

select throws_ok(
  'select count(*) from safety_incidents',
  '42501',
  null,
  'the subject of a report cannot read it'
);

-- ---------------------------------------------------------------------------
-- 3. The reporting function, as an ordinary signed-in user
-- ---------------------------------------------------------------------------

select is(
  public.report_incident(jsonb_build_object(
    'category', 'unsafe_behavior',
    'description', 'Driver was swinging a chain with people standing close by.')) ->> 'ok',
  'true',
  'a signed-in user can file a report'
);

select is(
  public.report_incident(jsonb_build_object(
    'category', 'unsafe_behavior', 'description', 'too short')) ->> 'error',
  'description_too_short',
  'a report needs enough detail to act on'
);

select is(
  public.report_incident(jsonb_build_object(
    'category', 'not_a_real_category',
    'description', 'Something happened that was genuinely concerning.')) ->> 'error',
  'invalid_category',
  'an unknown category is refused rather than stored as something else'
);

-- The token function is for the server to call on a requester's behalf. A browser session
-- reaching it would let any signed-in user file reports against any request whose token they
-- guessed or were forwarded.
select throws_ok(
  $$select public.report_incident_by_token('anything', '{}'::jsonb)$$,
  '42501',
  null,
  'the token reporting function is not callable from a browser session'
);

reset role;

-- ---------------------------------------------------------------------------
-- 4. A token report names the volunteer who actually took the job
--
-- The subject is read from the request, not from the payload. Otherwise whoever holds a status
-- link could file a report against a volunteer who was never sent to them.
-- ---------------------------------------------------------------------------

select is(
  public.report_incident_by_token(
    (select public_token from requests where id = '22222222-2222-4222-8222-000000000003'),
    jsonb_build_object(
      'category', 'asked_for_money',
      'subject_responder_id', '11111111-1111-4111-8111-000000000005',
      'description', 'Asked me for cash once the truck was out of the mud.')
  ) ->> 'ok',
  'true',
  'a requester holding their link can report what happened'
);

select is(
  (select subject_responder_id from safety_incidents
    where category = 'asked_for_money'
      and description like 'Asked me for cash%'),
  (select accepted_responder_id from requests where id = '22222222-2222-4222-8222-000000000003'),
  'and the report names the volunteer who took the job, not whoever the payload claimed'
);

select isnt(
  (select subject_responder_id from safety_incidents
    where description like 'Asked me for cash%'),
  '11111111-1111-4111-8111-000000000005',
  'the subject_responder_id in the payload is ignored'
);

-- ---------------------------------------------------------------------------
-- 5. The description is deliberately allowed to contain contact details
--
-- Everywhere else contains_contact_info() stops a phone number reaching a public surface. Here
-- "he called me from 512-555-0134 afterwards" is the most useful sentence in the report, and
-- only an admin ever reads it.
-- ---------------------------------------------------------------------------

select lives_ok(
  $$insert into safety_incidents (reporter_kind, category, description)
    values ('requester', 'harassment',
            'He kept calling me from 512-555-0134 after I marked it recovered.')$$,
  'a report may quote a phone number, because an admin needs it to act'
);

select * from finish();
rollback;
