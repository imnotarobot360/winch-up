-- Winch Up :: the schema audit, kept
--
-- Run with:  supabase test db
--
-- Phase 12 asked for the database to be inspected. Inspecting it once is worth very little --
-- the next migration undoes it. So the properties the audit checked are asserted here, over the
-- whole catalogue rather than table by table, and a new table or function that breaks one of
-- them fails this file rather than being found a year later.
--
-- Every assertion below names what it would have caught. Four of them did catch something on
-- 2026-09-22: three functions without a pinned search_path, thirty-four unindexed foreign keys,
-- three geography columns with no GiST index, and one open-request rule that two concurrent
-- submits could both walk past.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- ---------------------------------------------------------------------------
-- 1. Row level security, everywhere, without exception
-- ---------------------------------------------------------------------------

select is(
  (select coalesce(string_agg(c.relname, ', ' order by c.relname), 'none')
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  'none',
  'every table in public has row level security enabled'
);

-- The deny-by-default half: a table with grants but no policies would be readable by anyone
-- holding that grant, which is the opposite of what the grant was for.
select is(
  (select coalesce(string_agg(t.table_name, ', '), 'none') from (
     select distinct g.table_name
       from information_schema.role_table_grants g
       join pg_class c on c.relname = g.table_name
       join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
      where g.table_schema = 'public'
        and g.grantee in ('anon', 'authenticated')
        and not exists (select 1 from pg_policy p where p.polrelid = c.oid)
   ) t),
  'none',
  'no table hands out a grant without a policy to shape it'
);

-- ---------------------------------------------------------------------------
-- 2. Every foreign key has an index
--
-- Without one, deleting the referenced row sequentially scans the child table. This app deletes
-- accounts, so that is not hypothetical: it was thirty-four tables scanned per deletion.
-- ---------------------------------------------------------------------------

select is(
  (select coalesce(string_agg(x.what, ', ' order by x.what), 'none') from (
     select c.relname || '.' || a.attname as what
       from pg_constraint con
       join pg_class c on c.oid = con.conrelid
       join pg_namespace n on n.oid = c.relnamespace
       join unnest(con.conkey) k(attnum) on true
       join pg_attribute a on a.attrelid = c.oid and a.attnum = k.attnum
      where con.contype = 'f' and n.nspname = 'public'
        and not exists (
          select 1 from pg_index i where i.indrelid = c.oid and a.attnum = i.indkey[0]
        )
   ) x),
  'none',
  'every foreign key column in public is the leading column of some index'
);

-- ---------------------------------------------------------------------------
-- 3. Every geography column has a GiST index
--
-- A distance query against an unindexed geography column works perfectly and scans the table.
-- It is the kind of thing that is fine until the day it is not.
-- ---------------------------------------------------------------------------

select is(
  (select coalesce(string_agg(x.what, ', ' order by x.what), 'none') from (
     select c.relname || '.' || a.attname as what
       from pg_attribute a
       join pg_class c on c.oid = a.attrelid
       join pg_namespace n on n.oid = c.relnamespace
       join pg_type t on t.oid = a.atttypid
      where n.nspname = 'public' and c.relkind = 'r'
        and a.attnum > 0 and not a.attisdropped
        and t.typname in ('geography', 'geometry')
        and not exists (
          select 1 from pg_index i join pg_class ic on ic.oid = i.indexrelid
           where i.indrelid = c.oid and a.attnum = any(i.indkey)
             and ic.relam = (select oid from pg_am where amname = 'gist')
        )
   ) x),
  'none',
  'every geography column in public has a GiST index'
);

-- ---------------------------------------------------------------------------
-- 4. Every function pins its search_path
--
-- The project convention since the first migration. Three functions had drifted off it, one of
-- them called from CHECK constraints on a dozen columns.
-- ---------------------------------------------------------------------------

select is(
  (select coalesce(string_agg(n.nspname || '.' || p.proname, ', ' order by p.proname), 'none')
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'app') and p.prokind = 'f'
      and not exists (
        select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%'
      )),
  'none',
  'every function in public and app pins its search_path'
);

-- ---------------------------------------------------------------------------
-- 5. Every reference to auth.users says what happens when the account goes
--
-- This was a real outage-shaped bug in Phase 3: seven constraints defaulted to NO ACTION and
-- auth.admin.deleteUser() threw for anybody who had ever been an admin or a volunteer.
-- ---------------------------------------------------------------------------

select is(
  (select coalesce(string_agg(x.what, ', ' order by x.what), 'none') from (
     select c.relname || '.' || a.attname as what
       from pg_constraint con
       join pg_class c on c.oid = con.conrelid
       join pg_namespace n on n.oid = c.relnamespace
       join pg_class cf on cf.oid = con.confrelid
       join pg_namespace nf on nf.oid = cf.relnamespace
       join unnest(con.conkey) k(attnum) on true
       join pg_attribute a on a.attrelid = c.oid and a.attnum = k.attnum
      where con.contype = 'f' and n.nspname = 'public'
        and nf.nspname = 'auth' and cf.relname = 'users'
        and con.confdeltype = 'a'
   ) x),
  'none',
  'no reference to auth.users is left without an ON DELETE action'
);

-- ---------------------------------------------------------------------------
-- 6. Structure basics
-- ---------------------------------------------------------------------------

select is(
  (select coalesce(string_agg(c.relname, ', '), 'none')
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
      and not exists (select 1 from pg_constraint k
                       where k.conrelid = c.oid and k.contype = 'p')),
  'none',
  'every table has a primary key'
);

-- ---------------------------------------------------------------------------
-- 7. What anon can execute, exactly
--
-- Not "is it a short list" -- the list itself. A new security definer function accidentally
-- granted to anon is the single easiest way to open this database, and it would look like a
-- one-line grant in a migration nobody read twice.
-- ---------------------------------------------------------------------------

select bag_eq(
  $$select p.proname::text
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prosecdef
       and has_function_privilege('anon', p.oid, 'EXECUTE')$$,
  $$values ('ads_for'), ('board_requests'), ('get_public_settings'), ('get_request_by_token')$$,
  'anon can execute exactly four security definer functions, and these are they'
);

-- ---------------------------------------------------------------------------
-- 8. Duplicate prevention that does not depend on reading first
-- ---------------------------------------------------------------------------

select ok(
  exists (
    select 1 from pg_index i
      join pg_class c on c.oid = i.indexrelid
     where c.relname = 'requests_one_open_per_account' and i.indisunique and i.indpred is not null
  ),
  'one open request per account is a partial unique index, not just a check in a function'
);

select ok(
  exists (select 1 from pg_index i join pg_class c on c.oid = i.indexrelid
           where c.relname = 'dispatches_request_id_responder_id_key' and i.indisunique),
  'and a volunteer cannot be dispatched twice for the same request'
);

-- The rule itself, exercised. Two open requests for one account must be impossible whatever
-- the calling code believes.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
) values (
  '00000000-0000-0000-0000-000000000000', 'b1111111-0000-4000-8000-00000000000b',
  'authenticated', 'authenticated', 'audit-racer@example.invalid', 'x', now(),
  '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
);

insert into requests (
  requester_name, requester_phone, requester_user_id, location, vehicle_class, stuck_type,
  land_type, status, emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at
) values (
  'Racer', '+15125559401', 'b1111111-0000-4000-8000-00000000000b',
  extensions.st_setsrid(extensions.st_point(-97.74, 30.27), 4326)::extensions.geography,
  'truck', 'mud', 'public', 'submitted', now(), true,
  (select id from waivers where slug = 'requester_waiver' and is_current), now()
);

select throws_ok(
  $$insert into requests (
      requester_name, requester_phone, requester_user_id, location, vehicle_class, stuck_type,
      land_type, status, emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at
    ) values (
      'Racer', '+15125559401', 'b1111111-0000-4000-8000-00000000000b',
      extensions.st_setsrid(extensions.st_point(-97.74, 30.27), 4326)::extensions.geography,
      'truck', 'mud', 'public', 'submitted', now(), true,
      (select id from waivers where slug = 'requester_waiver' and is_current), now()
    )$$,
  '23505', null,
  'a second open request for the same account is refused by the database, not by the caller'
);

-- And once the first one is finished, they can file again. The index only covers open states.
update requests set status = 'recovered'
 where requester_user_id = 'b1111111-0000-4000-8000-00000000000b';

select lives_ok(
  $$insert into requests (
      requester_name, requester_phone, requester_user_id, location, vehicle_class, stuck_type,
      land_type, status, emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at
    ) values (
      'Racer', '+15125559401', 'b1111111-0000-4000-8000-00000000000b',
      extensions.st_setsrid(extensions.st_point(-97.74, 30.27), 4326)::extensions.geography,
      'truck', 'mud', 'public', 'submitted', now(), true,
      (select id from waivers where slug = 'requester_waiver' and is_current), now()
    )$$,
  'and stuck again next Sunday is a new request, because only open states are covered'
);

-- ---------------------------------------------------------------------------
-- 9. The columns that must never be readable through a grant
--
-- Column privileges, not just table ones. A policy mistake alone should not be enough to hand
-- out a phone number or an exact location.
-- ---------------------------------------------------------------------------

select ok(
  not has_column_privilege('anon', 'public.requests', 'requester_phone', 'SELECT'),
  'anon has no column privilege on requests.requester_phone'
);
select ok(
  not has_column_privilege('anon', 'public.requests', 'location', 'SELECT'),
  'nor on the exact location'
);
select ok(
  not has_column_privilege('authenticated', 'public.requests', 'requester_phone', 'SELECT'),
  'and neither does a signed-in member'
);

select * from finish();
rollback;
