-- Winch Up :: proof that nobody can promote themselves
--
-- Run with:  supabase test db
--
-- The rule these tests defend: role membership is granted by the database or by an admin, never
-- by the user it applies to. Phase 3 states it as "users must not be able to assign themselves
-- administrator or moderator permissions"; this is what makes that a property rather than a
-- promise. If any of these fail, do not deploy.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- ---------------------------------------------------------------------------
-- 1. There is no write path to user_roles for an ordinary user
-- ---------------------------------------------------------------------------

select ok(not has_table_privilege('authenticated', 'user_roles', 'INSERT'),
  'authenticated has no INSERT on user_roles');
select ok(not has_table_privilege('authenticated', 'user_roles', 'UPDATE'),
  'authenticated has no UPDATE on user_roles');
select ok(not has_table_privilege('authenticated', 'user_roles', 'DELETE'),
  'authenticated has no DELETE on user_roles');
select ok(not has_table_privilege('anon', 'user_roles', 'SELECT'),
  'anon cannot read user_roles at all');

-- ---------------------------------------------------------------------------
-- 2. The attack, run for real
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated"}';

select throws_ok(
  $$insert into user_roles (user_id, role)
    values ('00000000-0000-4000-8000-000000000002', 'admin')$$,
  '42501',
  null,
  'a signed-in user cannot grant themselves admin'
);

select throws_ok(
  $$insert into user_roles (user_id, role)
    values ('00000000-0000-4000-8000-000000000002', 'moderator')$$,
  '42501',
  null,
  'a signed-in user cannot grant themselves moderator'
);

select throws_ok(
  $$update user_roles set role = 'admin' where user_id = '00000000-0000-4000-8000-000000000002'$$,
  '42501',
  null,
  'a signed-in user cannot upgrade a role they already hold'
);

-- A user sees their own roles and nobody else's.
select is(
  (select count(*)::int from user_roles
    where user_id <> '00000000-0000-4000-8000-000000000002'),
  0,
  'a signed-in user cannot enumerate other people''s roles'
);

reset role;

-- ---------------------------------------------------------------------------
-- 3. Profiles are private by default
-- ---------------------------------------------------------------------------

select ok(not has_table_privilege('anon', 'profiles', 'SELECT'),
  'anon has no SELECT on profiles');
select ok(not has_table_privilege('authenticated', 'profiles', 'INSERT'),
  'authenticated cannot insert a profile: the signup trigger owns that');
select ok(not has_table_privilege('authenticated', 'profiles', 'DELETE'),
  'authenticated cannot delete a profile: deletion cascades from auth.users');

-- The owner cannot re-point their row at another account, because user_id is not in the
-- UPDATE column grant.
select ok(not has_column_privilege('authenticated', 'profiles', 'user_id', 'UPDATE'),
  'user_id is not updatable, so a profile cannot be moved to another account');

select ok(has_column_privilege('authenticated', 'profiles', 'display_name', 'UPDATE'),
  'a user can edit their own display name');

-- ---------------------------------------------------------------------------
-- 4. Marketing consent is opt-in
-- ---------------------------------------------------------------------------

select is(
  (select column_default from information_schema.columns
    where table_name = 'profiles' and column_name = 'notify_marketing'),
  'false',
  'marketing notifications default to off: a default-on box is not consent'
);

select is(
  (select column_default from information_schema.columns
    where table_name = 'profiles' and column_name = 'profile_public'),
  'false',
  'profiles are private until someone chooses otherwise'
);

-- ---------------------------------------------------------------------------
-- 5. Display names cannot smuggle contact details
-- ---------------------------------------------------------------------------

select ok(
  not public.contains_contact_info('Mike R') is true,
  'an ordinary display name passes'
);
select ok(
  public.contains_contact_info('Mike 512-555-0134'),
  'a phone number in a display name is caught by the same check public text uses'
);

select * from finish();
rollback;
