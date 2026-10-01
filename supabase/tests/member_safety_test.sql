-- Winch Up :: reporting a member, and suspending one
--
-- Run with:  supabase test db
--
-- Spec §6. These matter more than they would have a week ago: with every profile visible, moderation
-- is the only thing between an abusive member and the whole membership. /rules has been promising
-- suspension to a schema that could not do it.
--
-- The assertions are in two halves. First that the ordinary member can report and cannot do anything
-- else -- cannot suspend, cannot read the queue, cannot reach anybody's suspension state. Then that
-- a suspension actually lands everywhere it is supposed to, which is three separate places that
-- must agree: the directory, the profile and the ring.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- ---------------------------------------------------------------------------
-- An admin, a complainant, and somebody to complain about
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
)
select '00000000-0000-0000-0000-000000000000', v.id, 'authenticated', 'authenticated',
       v.email, 'x', now(), '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
from (values
  ('fa000000-0000-4000-8000-00000000000f'::uuid, 'safety-admin@example.invalid'),
  ('fb000000-0000-4000-8000-00000000000f'::uuid, 'safety-reporter@example.invalid'),
  ('fc000000-0000-4000-8000-00000000000f'::uuid, 'safety-target@example.invalid'),
  ('fd000000-0000-4000-8000-00000000000f'::uuid, 'safety-bystander@example.invalid')
) as v(id, email)
on conflict (id) do nothing;

insert into public.user_roles (user_id, role)
values ('fa000000-0000-4000-8000-00000000000f', 'admin')
on conflict do nothing;

update public.profiles set display_name = 'Reporter'
 where user_id = 'fb000000-0000-4000-8000-00000000000f';
update public.profiles set display_name = 'Target', available_to_help = true
 where user_id = 'fc000000-0000-4000-8000-00000000000f';
update public.profiles set display_name = 'Bystander'
 where user_id = 'fd000000-0000-4000-8000-00000000000f';

-- The target is a volunteer near Houston, so the dispatcher has a reason to reach them and the
-- suspension assertion is not passing because there was never anybody to exclude.
insert into public.responders (
  id, user_id, phone, first_name, home_location, radius_miles, equipment, approval,
  availability, vehicle_desc, recoveries_count
) values (
  'fc000000-1111-4111-8111-00000000000f', 'fc000000-0000-4000-8000-00000000000f',
  '+15125558801', 'Target',
  extensions.st_setsrid(extensions.st_point(-95.3698, 29.7704), 4326)::extensions.geography,
  60, '{winch}', 'approved', 'active', 'Target Rig', 3
) on conflict (id) do nothing;

insert into public.requests (
  id, public_token, requester_name, requester_phone,
  location, location_source, vehicle_class, stuck_type, stuck_depth,
  needs_tractor, land_type, emergency_ack_at, rules_accepted,
  waiver_id, waiver_accepted_at, next_action_at, is_test
) values (
  'fe000000-0000-4000-8000-00000000000f', 'safety-test-token-000000000000001',
  'Safety Test', '+17130000098',
  extensions.st_setsrid(extensions.st_point(-95.3698, 29.7604), 4326)::extensions.geography,
  'gps', 'truck', 'mud', 'frame',
  false, 'public', now(), true,
  (select id from public.waivers where slug = 'requester_waiver' and is_current),
  now(), now(), true
);

-- ---------------------------------------------------------------------------
-- 1. An ordinary member can report, and only report
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"fb000000-0000-4000-8000-00000000000f","role":"authenticated"}';

select is(
  public.report_member('fc000000-0000-4000-8000-00000000000f', 'harassment', 'Shouted at me')
    ->> 'ok',
  'true',
  'a member can report another member'
);

-- Pressing it twice is the normal accident, and it must not put two rows in front of a moderator.
select is(
  public.report_member('fc000000-0000-4000-8000-00000000000f', 'harassment', 'again')
    ->> 'already_open',
  'true',
  'and reporting the same person twice reuses the open report rather than stacking them'
);

reset role;

-- Counted with the role RESET. authenticated has no grant on content_reports or audit_log, which
-- is correct and is itself asserted elsewhere -- so a count run from the member's seat fails with
-- permission denied and says nothing about whether the row was written.
select is(
  (select count(*)::int from public.content_reports
    where target_kind = 'member'
      and target_id = 'fc000000-0000-4000-8000-00000000000f'
      and reporter_user_id = 'fb000000-0000-4000-8000-00000000000f'),
  1,
  'one row, not two'
);

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"fb000000-0000-4000-8000-00000000000f","role":"authenticated"}';

select is(
  public.report_member('fb000000-0000-4000-8000-00000000000f', 'spam', null) ->> 'error',
  'cannot_report_self',
  'nobody reports themselves'
);

-- The same answer a profile read gives, so this cannot be used to find out whether an account
-- exists.
select is(
  public.report_member('00000000-0000-4000-8000-0000000000fe', 'spam', null) ->> 'error',
  'not_found',
  'and an id that was never a member gets the profile route answer, not a different one'
);

-- REPORTING IS NOT BLOCKING. Two different acts: a report asks an admin to look, a block is the
-- member's own decision. Doing the second when asked for the first takes that choice away.
reset role;

-- user_blocks has no grant to authenticated either -- it is reached only through
-- set_user_block() -- so this count runs with the role reset, like the others.
select is(
  (select count(*)::int from public.user_blocks
    where blocker_user_id = 'fb000000-0000-4000-8000-00000000000f'),
  0,
  'reporting somebody does not silently block them'
);

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"fb000000-0000-4000-8000-00000000000f","role":"authenticated"}';

-- app.require_admin() RAISES rather than returning false, so this is throws_ok and not a
-- comparison against the result -- there is no result. Worth being exact about: an assertion
-- written as is(... ->> 'ok', null) passes for a function that refuses AND for one that is
-- missing, and the second is not a thing to be relaxed about in a privilege check.
select throws_ok(
  $$select public.admin_suspend_member('fc000000-0000-4000-8000-00000000000f', 'because')$$,
  null,
  null,
  'an ordinary member cannot suspend anybody'
);

-- This one does NOT throw: it is granted to authenticated and answers not_allowed, because a
-- moderation screen asking the question is a normal thing for the server to decline politely.
select is(
  public.moderation_reported_members() ->> 'error',
  'not_allowed',
  'and cannot read the moderation queue'
);

reset role;

-- ---------------------------------------------------------------------------
-- 2. The target is a normal member right up until the moment they are not
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"fd000000-0000-4000-8000-00000000000f","role":"authenticated"}';

-- The control. Every exclusion below is worthless without it: if the target were absent for some
-- other reason, suspension would look like it worked while doing nothing.
select is(
  public.member_profile('fc000000-0000-4000-8000-00000000000f') ->> 'ok',
  'true',
  'before suspension, a bystander can read the reported member''s profile'
);

select is(
  (select count(*)::int
     from jsonb_array_elements(public.nearby_members() -> 'members') m
    where m ->> 'display_name' = 'Target'),
  1,
  'and sees them in the directory'
);

select is(
  (select count(*)::int
     from app.candidates('fe000000-0000-4000-8000-00000000000f', 60, 50) c
    where c.responder_id = 'fc000000-1111-4111-8111-00000000000f'),
  1,
  'and the dispatcher would ring them'
);

reset role;

-- ---------------------------------------------------------------------------
-- 3. An admin suspends, and it lands in all three places
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"fa000000-0000-4000-8000-00000000000f","role":"authenticated"}';

select is(
  public.admin_suspend_member('fc000000-0000-4000-8000-00000000000f', null) ->> 'error',
  'reason_required',
  'a suspension needs a reason -- somebody reads it in three months when the member asks why'
);

select is(
  public.admin_suspend_member('fa000000-0000-4000-8000-00000000000f', 'oops') ->> 'error',
  'cannot_suspend_self',
  'and an admin cannot suspend themselves into a half-state they can still undo'
);

select is(
  public.admin_suspend_member('fc000000-0000-4000-8000-00000000000f', 'Harassed another member')
    ->> 'ok',
  'true',
  'an admin can suspend a member'
);

reset role;

-- Counted with the role RESET. authenticated has no grant on content_reports or audit_log, which
-- is correct and is itself asserted elsewhere -- so a count run from the member's seat fails with
-- permission denied and says nothing about whether the row was written.
select is(
  (select count(*)::int from public.content_reports
    where target_kind = 'member'
      and target_id = 'fc000000-0000-4000-8000-00000000000f'
      and status in ('new', 'reviewing')),
  0,
  'and the open reports about them stop being a pending question'
);

select is(
  (select count(*)::int from public.audit_log
    where action = 'member.suspend' and entity_id = 'fc000000-0000-4000-8000-00000000000f'),
  1,
  'with an audit row, because this is a thing done to somebody'
);

-- ---------------------------------------------------------------------------
-- 4. What suspension actually does, from a bystander's seat
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"fd000000-0000-4000-8000-00000000000f","role":"authenticated"}';

select is(
  public.member_profile('fc000000-0000-4000-8000-00000000000f') ->> 'error',
  'not_found',
  'a suspended member has no readable profile'
);

select is(
  (select count(*)::int
     from jsonb_array_elements(public.nearby_members() -> 'members') m
    where m ->> 'display_name' = 'Target'),
  0,
  'and is gone from the directory'
);

-- The third place, and the one that would have been missed. Invisible to the community while still
-- being rung at 3am to go and help a stranger is the worst of both.
select is(
  (select count(*)::int
     from app.candidates('fe000000-0000-4000-8000-00000000000f', 60, 50) c
    where c.responder_id = 'fc000000-1111-4111-8111-00000000000f'),
  0,
  'and is not dispatched to'
);

select is(
  public.member_rigs('fc000000-0000-4000-8000-00000000000f') ->> 'error',
  'not_found',
  'nor are their rigs readable by the back door'
);

reset role;

-- ---------------------------------------------------------------------------
-- 5. Nothing was destroyed, and it comes back
-- ---------------------------------------------------------------------------
--
-- Suspension is not deletion. The member's recoveries, waiver and messages stay exactly where they
-- are -- a suspension that destroyed the evidence would be useless to whoever has to decide later
-- whether it was fair.

select is(
  (select recoveries_count from public.responders
    where user_id = 'fc000000-0000-4000-8000-00000000000f'),
  3,
  'their recovery history is untouched'
);

select isnt(
  (select phone from public.responders where user_id = 'fc000000-0000-4000-8000-00000000000f'),
  null,
  'and nothing was scrubbed: this is not an account deletion'
);

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"fa000000-0000-4000-8000-00000000000f","role":"authenticated"}';

select is(
  public.admin_restore_member('fc000000-0000-4000-8000-00000000000f') ->> 'ok',
  'true',
  'and an admin can lift it'
);

reset role;

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"fd000000-0000-4000-8000-00000000000f","role":"authenticated"}';

select is(
  public.member_profile('fc000000-0000-4000-8000-00000000000f') ->> 'ok',
  'true',
  'after which they are a member again, in one step and with everything they had'
);

reset role;

-- ---------------------------------------------------------------------------
-- 6. The queue a moderator reads
-- ---------------------------------------------------------------------------
--
-- Both of these were found by USING the screen, not by reading it, and both would have passed a
-- test written from the migration rather than from the job the screen has to do.

-- A second reporter, so the grouping has something to group.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"fd000000-0000-4000-8000-00000000000f","role":"authenticated"}';

select is(
  public.report_member('fc000000-0000-4000-8000-00000000000f', 'spam', 'me too') ->> 'ok',
  'true',
  'a second member can report the same person'
);

reset role;

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"fa000000-0000-4000-8000-00000000000f","role":"authenticated"}';

-- ONE ROW PER MEMBER. The screen above this one already says 'five people reporting one thing is
-- one decision, not five', and the members list was the one place that did not follow its own
-- heading -- two reports put the same person in front of a moderator twice.
select is(
  (select count(*)::int
     from jsonb_array_elements(public.moderation_reported_members() -> 'reports') r
    where (r ->> 'user_id')::uuid = 'fc000000-0000-4000-8000-00000000000f'),
  1,
  'two reports about one member are one row in the queue'
);

select is(
  (select (r ->> 'reports_total')::int
     from jsonb_array_elements(public.moderation_reported_members() -> 'reports') r
    where (r ->> 'user_id')::uuid = 'fc000000-0000-4000-8000-00000000000f'),
  2,
  'with the count on it, because one report is an evening and four is a pattern'
);

select ok(
  not ((select r from jsonb_array_elements(public.moderation_reported_members() -> 'reports') r
         where (r ->> 'user_id')::uuid = 'fc000000-0000-4000-8000-00000000000f')
       ?| array['phone', 'email']),
  'and no contact details: deciding whether somebody is abusive does not need their phone number'
);

-- THE ONE THAT MADE THE UNDO UNREACHABLE. Suspending closes the open reports, so a queue keyed on
-- open reports loses the member a second after the suspension -- and the 'you can undo it' in the
-- warning text was only true at a SQL prompt.
select is(
  public.admin_suspend_member('fc000000-0000-4000-8000-00000000000f', 'Second look') ->> 'ok',
  'true',
  'suspending again works'
);

select is(
  (select count(*)::int
     from jsonb_array_elements(public.moderation_reported_members() -> 'reports') r
    where (r ->> 'user_id')::uuid = 'fc000000-0000-4000-8000-00000000000f'),
  1,
  'a suspended member is STILL in the queue, which is the only route to lifting it'
);

select is(
  (select r ->> 'suspended_reason'
     from jsonb_array_elements(public.moderation_reported_members() -> 'reports') r
    where (r ->> 'user_id')::uuid = 'fc000000-0000-4000-8000-00000000000f'),
  'Second look',
  'with the reason shown, so a second admin is deciding with what the first one wrote'
);

reset role;
-- ---------------------------------------------------------------------------
-- 7. The same person can be reported again, after a decision
-- ---------------------------------------------------------------------------
--
-- content_reports carried a blanket unique constraint on (target_kind, target_id,
-- reporter_user_id) from the day it was created. For a post that is right: the words do not change,
-- so reporting them twice is the same report twice. For a PERSON it meant somebody who reported
-- harassment in March and was harassed again in September could never say so -- the closed March row
-- refused the insert, report_member() surfaced a raw 23505, and the member was told 'that did not go
-- through'.
--
-- The suspension above closed the reporter's report, so this is exactly that situation.

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"fb000000-0000-4000-8000-00000000000f","role":"authenticated"}';

select is(
  public.report_member('fc000000-0000-4000-8000-00000000000f', 'harassment', 'it happened again')
    ->> 'ok',
  'true',
  'a reporter whose earlier report was actioned can report the same member again'
);

select is(
  public.report_member('fc000000-0000-4000-8000-00000000000f', 'harassment', 'and again')
    ->> 'already_open',
  'true',
  'but still only one OPEN report from them at a time'
);

reset role;

-- The index that makes both of those true, asserted directly -- the function reads the open rows
-- itself, so a missing index would leave every assertion above passing while two concurrent presses
-- put two rows in the queue.
select has_index(
  'public', 'content_reports', 'content_reports_one_open_per_reporter_member',
  'one open member report per reporter is enforced by a partial unique index, not just by the read'
);

select has_index(
  'public', 'content_reports', 'content_reports_one_per_reporter_content',
  'and a post can still only be reported once by the same person, as before'
);
select * from finish();
rollback;
