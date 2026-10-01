-- Winch Up :: who is in the member directory, and what a row is allowed to say
--
-- Run with:  supabase test db
--
-- REWRITTEN for the owner's "make all member profiles visible" spec. The previous version of this
-- file asserted the opposite rule -- that a member appears only after opting in twice -- and it was
-- right to, at the time. Those assertions are not deleted and replaced with nothing: each one
-- existed to protect something, and the protection has to survive the policy reversing.
--
-- So the shape is the same. Almost every assertion here is about ABSENCE: who is still not listed,
-- what a row still does not carry, and what a reader still cannot work out from it. The difference
-- is that "has not opted in" has stopped being a reason to be absent, and four other reasons --
-- suspended, deleted, blocked, yourself -- have to carry the whole weight instead.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- ---------------------------------------------------------------------------
-- A browsing member, and everybody they might or might not see
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
)
select '00000000-0000-0000-0000-000000000000', v.id, 'authenticated', 'authenticated',
       v.email, 'x', now(), '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
from (values
  ('d1000000-0000-4000-8000-00000000000d'::uuid, 'dir-browser@example.invalid'),
  ('d2000000-0000-4000-8000-00000000000d'::uuid, 'dir-willing@example.invalid'),
  ('d3000000-0000-4000-8000-00000000000d'::uuid, 'dir-quiet@example.invalid'),
  ('d4000000-0000-4000-8000-00000000000d'::uuid, 'dir-paused@example.invalid'),
  ('d5000000-0000-4000-8000-00000000000d'::uuid, 'dir-neither@example.invalid'),
  ('d6000000-0000-4000-8000-00000000000d'::uuid, 'dir-deleted@example.invalid'),
  -- The four this rewrite adds.
  ('d7000000-0000-4000-8000-00000000000d'::uuid, 'dir-norig@example.invalid'),
  ('d8000000-0000-4000-8000-00000000000d'::uuid, 'dir-suspended@example.invalid'),
  ('d9000000-0000-4000-8000-00000000000d'::uuid, 'dir-iblocked@example.invalid'),
  ('da000000-0000-4000-8000-00000000000d'::uuid, 'dir-blockedme@example.invalid'),
  -- Two names that exist only to prove the search box is not a wildcard.
  ('db000000-0000-4000-8000-00000000000d'::uuid, 'dir-underscore@example.invalid'),
  ('dc000000-0000-4000-8000-00000000000d'::uuid, 'dir-literal@example.invalid')
) as v(id, email)
on conflict (id) do nothing;

-- Houston, and points at measured distances from it.
insert into public.responders (
  id, user_id, phone, first_name, home_location, radius_miles, equipment, approval,
  availability, vehicle_desc, recoveries_count, redacted_at
) values
  ('d1000000-1111-4111-8111-00000000000d', 'd1000000-0000-4000-8000-00000000000d',
   '+15125558001', 'Browser',
   extensions.st_setsrid(extensions.st_point(-95.3698, 29.7604), 4326)::extensions.geography,
   60, '{winch}', 'approved', 'active', 'Browsing Rig', 0, null),
  -- About 2 miles north. Willing to be called out, and not paused.
  ('d2000000-1111-4111-8111-00000000000d', 'd2000000-0000-4000-8000-00000000000d',
   '+15125558002', 'Willing',
   extensions.st_setsrid(extensions.st_point(-95.3698, 29.7894), 4326)::extensions.geography,
   60, '{winch,kinetic_rope}', 'approved', 'active', 'Lifted F-250', 7, null),
  -- Never turned availability on. Under the old rule, invisible. Under the new one, a member.
  ('d3000000-1111-4111-8111-00000000000d', 'd3000000-0000-4000-8000-00000000000d',
   '+15125558003', 'Quiet',
   extensions.st_setsrid(extensions.st_point(-95.3698, 29.7704), 4326)::extensions.geography,
   60, '{winch}', 'approved', 'active', 'Tacoma', 0, null),
  -- Says yes on the profile switch but is PAUSED, which is what replying STOP sets.
  ('d4000000-1111-4111-8111-00000000000d', 'd4000000-0000-4000-8000-00000000000d',
   '+15125558004', 'Paused',
   extensions.st_setsrid(extensions.st_point(-95.3698, 29.7804), 4326)::extensions.geography,
   60, '{tractor}', 'approved', 'paused', 'Kubota', 0, null),
  ('d5000000-1111-4111-8111-00000000000d', 'd5000000-0000-4000-8000-00000000000d',
   '+15125558005', 'Neither',
   extensions.st_setsrid(extensions.st_point(-95.3698, 29.7654), 4326)::extensions.geography,
   60, '{winch}', 'approved', 'active', 'Bronco', 0, null),
  -- Deleted their account.
  ('d6000000-1111-4111-8111-00000000000d', 'd6000000-0000-4000-8000-00000000000d',
   '+15125558006', 'Removed',
   extensions.st_setsrid(extensions.st_point(-95.3698, 29.7624), 4326)::extensions.geography,
   60, '{winch}', 'approved', 'active', 'Gone', 0, now()),
  ('d8000000-1111-4111-8111-00000000000d', 'd8000000-0000-4000-8000-00000000000d',
   '+15125558008', 'Suspended',
   extensions.st_setsrid(extensions.st_point(-95.3698, 29.7614), 4326)::extensions.geography,
   60, '{winch}', 'approved', 'active', 'Suspended Rig', 0, null),
  ('d9000000-1111-4111-8111-00000000000d', 'd9000000-0000-4000-8000-00000000000d',
   '+15125558009', 'IBlocked',
   extensions.st_setsrid(extensions.st_point(-95.3698, 29.7634), 4326)::extensions.geography,
   60, '{winch}', 'approved', 'active', 'Blocked Rig', 0, null),
  ('da000000-1111-4111-8111-00000000000d', 'da000000-0000-4000-8000-00000000000d',
   '+15125558010', 'BlockedMe',
   extensions.st_setsrid(extensions.st_point(-95.3698, 29.7644), 4326)::extensions.geography,
   60, '{winch}', 'approved', 'active', 'Blocker Rig', 0, null)
on conflict (id) do nothing;

-- d7 gets NO responders row at all, deliberately. This is the member the old inner join lost.
-- app.ensure_recovery_profile() runs only when somebody turns availability on, so every member who
-- never did looks exactly like this -- which is most of them.

update public.profiles set available_to_help = true,  display_name = 'Willing'
 where user_id = 'd2000000-0000-4000-8000-00000000000d';
update public.profiles set available_to_help = false, display_name = 'Quiet'
 where user_id = 'd3000000-0000-4000-8000-00000000000d';
update public.profiles set available_to_help = true,  display_name = 'Paused'
 where user_id = 'd4000000-0000-4000-8000-00000000000d';
update public.profiles set available_to_help = false, display_name = 'Neither'
 where user_id = 'd5000000-0000-4000-8000-00000000000d';
update public.profiles set available_to_help = true,  display_name = 'Removed'
 where user_id = 'd6000000-0000-4000-8000-00000000000d';
update public.profiles set available_to_help = false, display_name = 'NoRig'
 where user_id = 'd7000000-0000-4000-8000-00000000000d';
update public.profiles set available_to_help = true,  display_name = 'Suspended',
       suspended_at = now(), suspended_reason = 'test'
 where user_id = 'd8000000-0000-4000-8000-00000000000d';
update public.profiles set available_to_help = true,  display_name = 'IBlocked'
 where user_id = 'd9000000-0000-4000-8000-00000000000d';
update public.profiles set available_to_help = true,  display_name = 'BlockedMe'
 where user_id = 'da000000-0000-4000-8000-00000000000d';

-- The search pair. One name contains a literal underscore; the other is what that underscore
-- would match if it were treated as a wildcard.
update public.profiles set display_name = 'Rust_Bucket'
 where user_id = 'db000000-0000-4000-8000-00000000000d';
update public.profiles set display_name = 'RustyBucket'
 where user_id = 'dc000000-0000-4000-8000-00000000000d';

-- Blocked in both directions: one the browser blocked, one who blocked the browser.
insert into public.user_blocks (blocker_user_id, blocked_user_id) values
  ('d1000000-0000-4000-8000-00000000000d', 'd9000000-0000-4000-8000-00000000000d'),
  ('da000000-0000-4000-8000-00000000000d', 'd1000000-0000-4000-8000-00000000000d')
on conflict do nothing;

-- A recovery in Houston, so section 4 can ask the dispatcher who it would ring. Created here
-- rather than relying on a seeded one: supabase test db runs against seed.sql, which has no
-- requests, and an assertion that passes because there was nothing to dispatch is worse than
-- no assertion -- it reads green forever.
insert into public.requests (
  id, public_token, requester_name, requester_phone,
  location, location_source, vehicle_class, stuck_type, stuck_depth,
  needs_tractor, land_type, emergency_ack_at, rules_accepted,
  waiver_id, waiver_accepted_at, next_action_at, is_test
) values (
  'dd000000-0000-4000-8000-00000000000d', 'dir-test-token-0000000000000001', 'Directory Test', '+17130000099',
  extensions.st_setsrid(extensions.st_point(-95.3698, 29.7604), 4326)::extensions.geography,
  'gps', 'truck', 'mud', 'frame',
  false, 'public', now(), true,
  (select id from public.waivers where slug = 'requester_waiver' and is_current),
  now(), now(), true
);

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"d1000000-0000-4000-8000-00000000000d","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 1. Everybody active is in the list, whatever they have or have not switched on
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int
     from jsonb_array_elements(public.nearby_members() -> 'members') m
    where m ->> 'display_name' = 'Willing'),
  1,
  'a member who is willing to be called out is listed'
);

-- The two that were absent under the old rule and are the point of the new one.
select is(
  (select count(*)::int
     from jsonb_array_elements(public.nearby_members() -> 'members') m
    where m ->> 'display_name' = 'Quiet'),
  1,
  'and so is a member who never turned availability on: being listed is not being on call'
);

select is(
  (select count(*)::int
     from jsonb_array_elements(public.nearby_members() -> 'members') m
    where m ->> 'display_name' = 'Neither'),
  1,
  'a member who switched nothing on at all is still a member of the community'
);

-- THE LEFT JOIN. Removing the two gates would not have listed this member, because they have no
-- responders row to join to, and nothing on screen would have said so.
select is(
  (select count(*)::int
     from jsonb_array_elements(public.nearby_members() -> 'members') m
    where m ->> 'display_name' = 'NoRig'),
  1,
  'a member who never volunteered -- and so has no responders row -- is listed'
);

select is(
  (select m ->> 'vehicle_desc'
     from jsonb_array_elements(public.nearby_members() -> 'members') m
    where m ->> 'display_name' = 'NoRig'),
  null,
  'with no rig and no distance rather than a fabricated one'
);

-- ---------------------------------------------------------------------------
-- 2. The four reasons somebody is still absent
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int
     from jsonb_array_elements(public.nearby_members() -> 'members') m
    where m ->> 'display_name' = 'Removed'),
  0,
  'a deleted account is excluded outright, not shown as a tombstone'
);

select is(
  (select count(*)::int
     from jsonb_array_elements(public.nearby_members() -> 'members') m
    where m ->> 'display_name' = 'Suspended'),
  0,
  'a suspended account is not an active community member'
);

select is(
  (select count(*)::int
     from jsonb_array_elements(public.nearby_members() -> 'members') m
    where m ->> 'display_name' = 'IBlocked'),
  0,
  'somebody you blocked is not in your directory'
);

-- The direction that is easy to miss. A one-way block that still shows the blocker to the person
-- they blocked is how blocking fails the person who needed it.
select is(
  (select count(*)::int
     from jsonb_array_elements(public.nearby_members() -> 'members') m
    where m ->> 'display_name' = 'BlockedMe'),
  0,
  'and neither is somebody who blocked you'
);

select is(
  (select count(*)::int
     from jsonb_array_elements(public.nearby_members() -> 'members') m
    where (m ->> 'user_id')::uuid = 'd1000000-0000-4000-8000-00000000000d'),
  0,
  'you are not in your own directory'
);

-- ---------------------------------------------------------------------------
-- 3. Availability is reported, not required
-- ---------------------------------------------------------------------------

select is(
  (select m ->> 'available'
     from jsonb_array_elements(public.nearby_members() -> 'members') m
    where m ->> 'display_name' = 'Willing'),
  'true',
  'availability is shown for a member who enabled it'
);

select is(
  (select m ->> 'available'
     from jsonb_array_elements(public.nearby_members() -> 'members') m
    where m ->> 'display_name' = 'Quiet'),
  'false',
  'and reported false rather than omitted for one who did not'
);

-- Both halves are required. availability='paused' is what replying STOP sets, and a member who
-- stopped texts and never un-paused is not available however their profile switch reads.
select is(
  (select m ->> 'available'
     from jsonb_array_elements(public.nearby_members() -> 'members') m
    where m ->> 'display_name' = 'Paused'),
  'false',
  'a paused member is not advertised as available even with the profile switch on'
);

-- ---------------------------------------------------------------------------
-- 4. Being in the directory is not being on call  (spec section 4)
-- ---------------------------------------------------------------------------
--
-- The single most important assertion in this file. The whole change is that the directory stopped
-- reading available_to_help; if the DISPATCHER had stopped reading it too, then making profiles
-- visible would have quietly signed every member up to be rung at 3am, and nothing on any screen
-- would have said so.

-- The CONTROL first. Without it this section passes when app.candidates() returns nothing at all
-- -- no request, no responders, a typo in the radius -- and a test that cannot fail is not a
-- test. Willing is two miles away, approved, active and available, so if anybody is dispatched
-- to, it is them.
select is(
  (select count(*)::int
     from app.candidates(
            'dd000000-0000-4000-8000-00000000000d', 60, 50) c
    -- responders.id, NOT the user id. candidates() returns the responder row, and comparing it
    -- against a user id is how this control failed against a dispatcher that was working.
    where c.responder_id = 'd2000000-1111-4111-8111-00000000000d'),
  1,
  'the dispatcher does ring a member who enabled availability'
);

select is(
  (select count(*)::int
     from app.candidates(
            'dd000000-0000-4000-8000-00000000000d', 60, 50) c
    where c.responder_id = 'd3000000-1111-4111-8111-00000000000d'),
  0,
  'and does not ring a listed member who never enabled it, two miles closer or not'
);

-- Suspension reaches the dispatcher too, or a suspended account stays on call while being
-- invisible -- the worst of both.
select is(
  (select count(*)::int
     from app.candidates(
            'dd000000-0000-4000-8000-00000000000d', 60, 50) c
    where c.responder_id = 'd8000000-1111-4111-8111-00000000000d'),
  0,
  'a suspended member is not dispatched to either'
);

select is(
  (select count(*)::int
     from app.candidates('dd000000-0000-4000-8000-00000000000d', 60, 50) c
    where c.responder_id = 'd6000000-1111-4111-8111-00000000000d'),
  0,
  'and neither is a deleted one, without relying on the scrub having nulled their location'
);

-- The conditions added for suspension, deletion and blocking are three more ways to return
-- nothing. If one of them is wrong the ring empties, every exclusion above passes, and the
-- dispatcher quietly stops reaching anybody.
select ok(
  (select count(*)::int
     from app.candidates('dd000000-0000-4000-8000-00000000000d', 60, 50) c) > 1,
  'and the ring still reaches more than one person, so none of this emptied it'
);

-- ---------------------------------------------------------------------------
-- 5. What a row carries
-- ---------------------------------------------------------------------------

select ok(
  not ((select m from jsonb_array_elements(public.nearby_members() -> 'members') m
         where m ->> 'display_name' = 'Willing')
       ?| array['phone', 'email', 'lat', 'lng', 'home_location', 'last_location']),
  'no phone, no email and no coordinates leave this function'
);

select is(
  (select m ->> 'miles' from jsonb_array_elements(public.nearby_members() -> 'members') m
    where m ->> 'display_name' = 'Willing'),
  '2',
  'distance comes back in whole miles, computed server-side from a point the caller never sees'
);

-- The rounding is the protection, so it is asserted directly rather than trusted. An exact
-- distance from a known origin is a circle; three of them is an address.
select is(app.coarse_miles(1609.344 * 2.4), 2, 'under five miles rounds to whole miles');
select is(app.coarse_miles(1609.344 * 12.3), 10, 'and beyond five, to the nearest five');
select is(app.coarse_miles(1609.344 * 43.0), 45, 'a long way out is rounded a long way');
select is(app.coarse_miles(80), 1, 'and nothing is ever reported as zero miles away');

-- ---------------------------------------------------------------------------
-- 6. Search by name, and the box is not a wildcard
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int
     from jsonb_array_elements(public.nearby_members(p_query => 'willing') -> 'members') m),
  1,
  'search matches on name, case-insensitively'
);

select is(
  (select count(*)::int
     from jsonb_array_elements(public.nearby_members(p_query => 'RUST') -> 'members') m),
  2,
  'a partial name matches anywhere in it, in upper case, for everybody it fits'
);

-- THE ESCAPE. Without it, a member typing an underscore gets every name of the same shape back,
-- and the search box quietly becomes a way to enumerate the membership one pattern at a time.
select is(
  (select count(*)::int
     from jsonb_array_elements(public.nearby_members(p_query => 'Rust_Bucket') -> 'members') m),
  1,
  'an underscore in a search is a character, not a single-character wildcard'
);

select is(
  (select count(*)::int
     from jsonb_array_elements(public.nearby_members(p_query => '%') -> 'members') m),
  0,
  'and a percent sign matches the names that contain one: none'
);

select ok(
  (select count(*)::int
     from jsonb_array_elements(public.nearby_members(p_query => '  ') -> 'members') m) > 1,
  'a blank search is not a filter at all'
);

-- ---------------------------------------------------------------------------
-- 7. The profile obeys the same rule as the list
-- ---------------------------------------------------------------------------

select is(
  public.member_profile('d3000000-0000-4000-8000-00000000000d') ->> 'ok',
  'true',
  'a member who opted into nothing has a readable profile, same as the list says'
);

select is(
  public.member_profile('d7000000-0000-4000-8000-00000000000d') ->> 'ok',
  'true',
  'and so does one with no responders row'
);

select is(
  public.member_profile('d8000000-0000-4000-8000-00000000000d') ->> 'error',
  'not_found',
  'a suspended member has no readable profile'
);

select is(
  public.member_profile('d9000000-0000-4000-8000-00000000000d') ->> 'error',
  'not_found',
  'nor does somebody you blocked'
);

select is(
  public.member_profile('da000000-0000-4000-8000-00000000000d') ->> 'error',
  'not_found',
  'nor somebody who blocked you'
);

select is(
  public.member_profile('d6000000-0000-4000-8000-00000000000d') ->> 'error',
  'not_found',
  'nor a deleted one'
);

-- Same answer for every refusal, so the profile route cannot be used to tell a suspended account
-- from a block from an id that was never a member.
select is(
  public.member_profile('00000000-0000-4000-8000-0000000000ff') ->> 'error',
  'not_found',
  'an id that was never a member gets the same answer as a suspended one'
);

select ok(
  not (public.member_profile('d2000000-0000-4000-8000-00000000000d') -> 'member'
        ?| array['phone', 'email', 'lat', 'lng', 'home_location', 'last_location']),
  'and a profile carries no way to contact somebody outside a recovery'
);

-- The reference shows a rating and years of experience. Neither exists in this product, and
-- inventing them would be inventing a reputation for a volunteer.
select ok(
  not (public.member_profile('d2000000-0000-4000-8000-00000000000d') -> 'member'
        ?| array['rating', 'reviews', 'years', 'stars']),
  'no rating, no review count, no years of experience -- none of those are real here'
);

select is(
  (public.member_profile('d2000000-0000-4000-8000-00000000000d') -> 'member' ->> 'recoveries')::int,
  7,
  'recoveries_count is the one metric shown, because it is the one the dispatch path maintains'
);

select is(
  (public.member_profile('d7000000-0000-4000-8000-00000000000d') -> 'member' ->> 'recoveries')::int,
  0,
  'a member with no responders row has done none, not null'
);

-- ---------------------------------------------------------------------------
-- 8. Signed out is not a reader
-- ---------------------------------------------------------------------------

reset role;
set local role anon;

select throws_ok(
  'select public.nearby_members()',
  '42501',
  null,
  'anon cannot call the directory at all'
);

select throws_ok(
  $$select public.member_profile('d2000000-0000-4000-8000-00000000000d')$$,
  '42501',
  null,
  'nor read a profile'
);

reset role;

select * from finish();
rollback;
