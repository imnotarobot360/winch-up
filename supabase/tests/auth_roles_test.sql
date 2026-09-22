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

-- ---------------------------------------------------------------------------
-- 6. An account can actually be deleted
--
-- Seven columns referenced auth.users with no ON DELETE clause. The delete raised a foreign key
-- violation for any admin who had ever acted, and for any volunteer who had ever accepted a job
-- -- exactly the accounts most likely to ask for deletion.
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int
     from pg_constraint c
    where c.contype = 'f'
      and c.confrelid = 'auth.users'::regclass
      and c.confdeltype = 'a'),
  0,
  'no foreign key to auth.users blocks account deletion'
);

select is(
  (select confdeltype::text from pg_constraint
    where conname = 'audit_log_actor_user_id_fkey'),
  'n',
  'audit rows survive deletion with a null actor rather than being erased'
);

select is(
  (select confdeltype::text from pg_constraint
    where conname = 'profiles_user_id_fkey'),
  'c',
  'the profile itself is removed with the account'
);

-- ---------------------------------------------------------------------------
-- 7. A recovery request belongs to an account
-- ---------------------------------------------------------------------------

select is(
  public.create_request(
    jsonb_build_object('name','Test','phone','+15125550901','lat',30.2,'lng',-97.7,
      'vehicle_class','truck','stuck_type','mud','land_type','public','locale','en'),
    'https://example.com') ->> 'error',
  'account_required',
  'create_request refuses a request with no account behind it'
);

select is(
  public.create_request(
    jsonb_build_object('name','Test','phone','+15125550902','lat',30.2,'lng',-97.7,
      'vehicle_class','truck','stuck_type','mud','land_type','public','locale','en',
      'requester_user_id','00000000-0000-4000-8000-000000000002'),
    'https://example.com') ->> 'ok',
  'true',
  'create_request accepts one that carries an account'
);

select is(
  (select (requester_user_id is not null) from requests
    where requester_phone = '+15125550902'),
  true,
  'the account is stored on the row, not just checked'
);

-- ---------------------------------------------------------------------------
-- 8. One open recovery per account
--
-- Its own account and its own requests: this must not depend on what the assertions above left
-- behind.
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
) values (
  '00000000-0000-0000-0000-000000000000', 'bbbbbbbb-0000-4000-8000-00000000000b',
  'authenticated', 'authenticated', 'one-open-test@example.invalid', 'x', now(),
  '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
);

select is(
  public.create_request(jsonb_build_object(
    'name','Dupe','phone','+15125557001','lat',30.2,'lng',-97.7,
    'vehicle_class','truck','stuck_type','mud','land_type','public','locale','en',
    'requester_user_id','bbbbbbbb-0000-4000-8000-00000000000b'),
    'https://example.com') ->> 'ok',
  'true',
  'the first request is created'
);

select is(
  public.create_request(jsonb_build_object(
    'name','Dupe','phone','+15125557001','lat',30.9,'lng',-97.1,
    'vehicle_class','jeep','stuck_type','sand','land_type','public','locale','en',
    'requester_user_id','bbbbbbbb-0000-4000-8000-00000000000b'),
    'https://example.com') ->> 'existing_open',
  'true',
  'a second submission while one is open hands back the one they already have'
);

select is(
  (select count(*)::int from requests
    where requester_user_id = 'bbbbbbbb-0000-4000-8000-00000000000b'),
  1,
  'and no second request is created, so volunteers are not sent to the same truck twice'
);

update requests set status = 'recovered'
 where requester_user_id = 'bbbbbbbb-0000-4000-8000-00000000000b';

select is(
  public.create_request(jsonb_build_object(
    'name','Dupe','phone','+15125557001','lat',30.9,'lng',-97.1,
    'vehicle_class','jeep','stuck_type','sand','land_type','public','locale','en',
    'requester_user_id','bbbbbbbb-0000-4000-8000-00000000000b'),
    'https://example.com') ->> 'existing_open',
  null,
  'once the first is closed they can ask for help again'
);

select * from finish();
rollback;
