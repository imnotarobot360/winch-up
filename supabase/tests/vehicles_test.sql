-- Winch Up :: proof that a member's rigs are their own
--
-- Run with:  supabase test db
--
-- Vehicles are not public. Phase 8 may publish some of this on a member profile; that has to be
-- a decision with a policy change behind it, not something that leaks because a default was
-- permissive. These tests are what make that true rather than intended.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- ---------------------------------------------------------------------------
-- 1. Privileges
-- ---------------------------------------------------------------------------

select ok(not has_table_privilege('anon', 'vehicles', 'SELECT'),
  'anon cannot read vehicles at all');
select ok(has_table_privilege('authenticated', 'vehicles', 'INSERT'),
  'a signed-in member can register a vehicle');

select is(
  (select relrowsecurity from pg_class where relname = 'vehicles'),
  true,
  'row level security is on for vehicles'
);

-- ---------------------------------------------------------------------------
-- 2. Isolation, run as two different signed-in users
-- ---------------------------------------------------------------------------

-- Known state. The whole file runs in a transaction that rolls back, so this touches nothing
-- beyond the test, and it keeps the counts below from depending on whatever else is in the
-- table.
delete from vehicles;

insert into vehicles (user_id, make, model)
values ('00000000-0000-4000-8000-000000000002', 'Jeep', 'Wrangler');

set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated"}';

select is(
  (select count(*)::int from vehicles), 1,
  'the owner sees their own rig'
);

reset role;
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000000004","role":"authenticated"}';

select is(
  (select count(*)::int from vehicles), 0,
  'another member sees none of it'
);

-- Writing a row that belongs to someone else is refused by the WITH CHECK, not silently
-- accepted and hidden.
select throws_ok(
  $$insert into vehicles (user_id, make)
    values ('00000000-0000-4000-8000-000000000002', 'Stolen')$$,
  '42501',
  null,
  'a member cannot register a vehicle against another account'
);

reset role;

-- ---------------------------------------------------------------------------
-- 3. Constraints that protect the data rather than the user
-- ---------------------------------------------------------------------------

select throws_ok(
  $$insert into vehicles (user_id, notes)
    values ('00000000-0000-4000-8000-000000000002', 'text me 512-555-0134')$$,
  '23514',
  null,
  'a phone number cannot be smuggled into a vehicle note'
);

select throws_ok(
  $$insert into vehicles (user_id, is_primary) values
    ('00000000-0000-4000-8000-000000000002', true),
    ('00000000-0000-4000-8000-000000000002', true)$$,
  '23505',
  null,
  'only one rig can be primary per member'
);

select ok(
  (select count(*)::int from pg_trigger where tgname = 'vehicles_limit') = 1,
  'the per-member vehicle cap is enforced by a trigger, not by the UI'
);

-- ---------------------------------------------------------------------------
-- 4. Nothing here claims to be verified
--
-- Phase 4 says equipment is self-reported unless separately verified. The schema should not
-- carry a column a later query could read as a verification it never performed.
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int from information_schema.columns
    where table_name = 'vehicles' and column_name in ('verified', 'is_verified', 'certified')),
  0,
  'vehicles carries no verification flag that nothing actually sets'
);

-- ---------------------------------------------------------------------------
-- 5. set_primary_vehicle() is scoped to the caller
--
-- It is security definer and takes an id, which is exactly the shape of function that turns
-- into "change any row" when the id is trusted instead of checked.
-- ---------------------------------------------------------------------------

delete from vehicles;

insert into vehicles (id, user_id, make, is_primary) values
  ('11111111-1111-4111-8111-000000000001', '00000000-0000-4000-8000-000000000002', 'Jeep',  true),
  ('11111111-1111-4111-8111-000000000002', '00000000-0000-4000-8000-000000000002', 'Ford',  false),
  ('11111111-1111-4111-8111-000000000003', '00000000-0000-4000-8000-000000000004', 'Other', true);

set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated"}';

select is(
  public.set_primary_vehicle('11111111-1111-4111-8111-000000000003') ->> 'error',
  'not_found',
  'promoting another member''s rig is refused'
);

-- Checked with the role reset: inside that member's own session RLS hides the row, so the
-- query would return null and the test would pass for the wrong reason.
reset role;

select is(
  (select is_primary from vehicles where id = '11111111-1111-4111-8111-000000000003'),
  true,
  'and the other member''s rig is left exactly as it was'
);

set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated"}';

select is(
  public.set_primary_vehicle('11111111-1111-4111-8111-000000000002') ->> 'ok',
  'true',
  'promoting your own rig succeeds'
);

select is(
  (select count(*)::int from vehicles
    where user_id = '00000000-0000-4000-8000-000000000002' and is_primary),
  1,
  'and the previous main rig is demoted in the same transaction, never two at once'
);

reset role;

select * from finish();
rollback;
