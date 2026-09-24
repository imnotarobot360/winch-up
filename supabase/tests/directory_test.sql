-- Winch Up :: who is in the member directory, and what a row is allowed to say
--
-- Run with:  supabase test db
--
-- Screens 7 and 8 of the design reference are the first surface in this product where one member
-- can browse others. Everything else is need-to-know: a volunteer sees a request they were rung
-- about, a participant sees their own recovery. A directory is different in kind, and the only
-- thing that makes it safe is that being in it is a decision somebody made twice.
--
-- So these assertions are almost entirely about absence. Who is NOT listed, what a row does NOT
-- carry, and what a reader cannot work out from it.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- ---------------------------------------------------------------------------
-- Five members, each opted in differently, and one browsing member
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
  ('d2000000-0000-4000-8000-00000000000d'::uuid, 'dir-both@example.invalid'),
  ('d3000000-0000-4000-8000-00000000000d'::uuid, 'dir-public-only@example.invalid'),
  ('d4000000-0000-4000-8000-00000000000d'::uuid, 'dir-available-only@example.invalid'),
  ('d5000000-0000-4000-8000-00000000000d'::uuid, 'dir-neither@example.invalid'),
  ('d6000000-0000-4000-8000-00000000000d'::uuid, 'dir-deleted@example.invalid')
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
  -- About 2 miles north.
  ('d2000000-1111-4111-8111-00000000000d', 'd2000000-0000-4000-8000-00000000000d',
   '+15125558002', 'Bothsy',
   extensions.st_setsrid(extensions.st_point(-95.3698, 29.7894), 4326)::extensions.geography,
   60, '{winch,kinetic_rope}', 'approved', 'active', 'Lifted F-250', 7, null),
  ('d3000000-1111-4111-8111-00000000000d', 'd3000000-0000-4000-8000-00000000000d',
   '+15125558003', 'Publicity',
   extensions.st_setsrid(extensions.st_point(-95.3698, 29.7704), 4326)::extensions.geography,
   60, '{winch}', 'approved', 'active', 'Tacoma', 0, null),
  ('d4000000-1111-4111-8111-00000000000d', 'd4000000-0000-4000-8000-00000000000d',
   '+15125558004', 'Availa',
   extensions.st_setsrid(extensions.st_point(-95.3698, 29.7804), 4326)::extensions.geography,
   60, '{tractor}', 'approved', 'active', 'Kubota', 0, null),
  ('d5000000-1111-4111-8111-00000000000d', 'd5000000-0000-4000-8000-00000000000d',
   '+15125558005', 'Neither',
   extensions.st_setsrid(extensions.st_point(-95.3698, 29.7654), 4326)::extensions.geography,
   60, '{winch}', 'approved', 'active', 'Bronco', 0, null),
  -- Opted into everything, then deleted their account.
  ('d6000000-1111-4111-8111-00000000000d', 'd6000000-0000-4000-8000-00000000000d',
   '+15125558006', 'Removed',
   extensions.st_setsrid(extensions.st_point(-95.3698, 29.7624), 4326)::extensions.geography,
   60, '{winch}', 'approved', 'active', 'Gone', 0, now())
on conflict (id) do nothing;

-- The two switches, set every way round.
update public.profiles set profile_public = false, available_to_help = false
 where user_id = 'd1000000-0000-4000-8000-00000000000d';
update public.profiles set profile_public = true,  available_to_help = true,  display_name = 'Bothsy'
 where user_id = 'd2000000-0000-4000-8000-00000000000d';
update public.profiles set profile_public = true,  available_to_help = false, display_name = 'Publicity'
 where user_id = 'd3000000-0000-4000-8000-00000000000d';
update public.profiles set profile_public = false, available_to_help = true,  display_name = 'Availa'
 where user_id = 'd4000000-0000-4000-8000-00000000000d';
update public.profiles set profile_public = false, available_to_help = false, display_name = 'Neither'
 where user_id = 'd5000000-0000-4000-8000-00000000000d';
update public.profiles set profile_public = true,  available_to_help = true,  display_name = 'Removed'
 where user_id = 'd6000000-0000-4000-8000-00000000000d';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"d1000000-0000-4000-8000-00000000000d","role":"authenticated"}';

-- ---------------------------------------------------------------------------
-- 1. Both switches, or you are not in the list
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int
     from jsonb_array_elements(public.nearby_members() -> 'members') m
    where m ->> 'display_name' = 'Bothsy'),
  1,
  'a member who made their profile public AND is available to help is listed'
);

select is(
  (select count(*)::int
     from jsonb_array_elements(public.nearby_members() -> 'members') m
    where m ->> 'display_name' = 'Publicity'),
  0,
  'a public profile alone is not consent to be pushed at people'
);

-- The one that would be easiest to get wrong, because "available to help" sounds like it means
-- "list me". It means "ring me when somebody near me is stuck".
select is(
  (select count(*)::int
     from jsonb_array_elements(public.nearby_members() -> 'members') m
    where m ->> 'display_name' = 'Availa'),
  0,
  'and being available to help is not consent to be browsed either'
);

select is(
  (select count(*)::int
     from jsonb_array_elements(public.nearby_members() -> 'members') m
    where m ->> 'display_name' = 'Neither'),
  0,
  'somebody who opted into neither is nowhere near this list'
);

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
    where (m ->> 'user_id')::uuid = 'd1000000-0000-4000-8000-00000000000d'),
  0,
  'and you are not nearby yourself'
);

-- ---------------------------------------------------------------------------
-- 2. What a row carries
-- ---------------------------------------------------------------------------

select ok(
  not ((select m from jsonb_array_elements(public.nearby_members() -> 'members') m
         where m ->> 'display_name' = 'Bothsy')
       ?| array['phone', 'email', 'lat', 'lng', 'home_location', 'last_location']),
  'no phone, no email and no coordinates leave this function'
);

select is(
  (select m ->> 'miles' from jsonb_array_elements(public.nearby_members() -> 'members') m
    where m ->> 'display_name' = 'Bothsy'),
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
-- 3. The profile obeys the same rule as the list
-- ---------------------------------------------------------------------------

select is(
  public.member_profile('d2000000-0000-4000-8000-00000000000d') ->> 'ok',
  'true',
  'a listed member has a readable profile'
);

select is(
  public.member_profile('d3000000-0000-4000-8000-00000000000d') ->> 'error',
  'not_found',
  'and a member who is not listed has no back door via a direct profile link'
);

select is(
  public.member_profile('d6000000-0000-4000-8000-00000000000d') ->> 'error',
  'not_found',
  'nor does a deleted one'
);

-- Same answer for "no such member" as for "not public", so the directory cannot be used to test
-- whether an account exists.
select is(
  public.member_profile('00000000-0000-4000-8000-0000000000ff') ->> 'error',
  'not_found',
  'an id that was never a member gets the same answer as one that opted out'
);

select ok(
  not (public.member_profile('d2000000-0000-4000-8000-00000000000d') -> 'member'
        ?| array['phone', 'email', 'lat', 'lng', 'home_location']),
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

-- ---------------------------------------------------------------------------
-- 4. Signed out is not a reader
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
