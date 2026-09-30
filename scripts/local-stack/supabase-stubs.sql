-- Stand-in for the parts of a Supabase database that the migrations assume already exist.
--
-- Used by the no-Docker local stack (see README.md in this folder). This is NOT a Supabase
-- replica -- it is enough to run the schema, the RLS policies and the test suites faithfully.

-- ---- roles -----------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end
$$;

grant usage on schema public to anon, authenticated, service_role;

-- Supabase hands out blanket privileges on new objects in `public`. Reproducing that matters:
-- without it, the `revoke all ... from anon, authenticated` in the RLS migration would be a
-- no-op and the privacy tests would pass for the wrong reason.
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

create schema if not exists extensions;
grant usage on schema extensions to anon, authenticated, service_role;

-- ---- auth ------------------------------------------------------------------
create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role;

create table if not exists auth.users (
  instance_id             uuid,
  id                      uuid primary key,
  aud                     varchar(255),
  role                    varchar(255),
  email                   varchar(255),
  encrypted_password      varchar(255),
  email_confirmed_at      timestamptz,
  invited_at              timestamptz,
  confirmation_token      varchar(255),
  confirmation_sent_at    timestamptz,
  recovery_token          varchar(255),
  recovery_sent_at        timestamptz,
  email_change_token_new  varchar(255),
  email_change            varchar(255),
  email_change_sent_at    timestamptz,
  last_sign_in_at         timestamptz,
  raw_app_meta_data       jsonb,
  raw_user_meta_data      jsonb,
  is_super_admin          boolean,
  created_at              timestamptz,
  updated_at              timestamptz,
  phone                   text unique,
  phone_confirmed_at      timestamptz
);

-- Same definitions Supabase ships, so `set local request.jwt.claims` behaves identically.
create or replace function auth.uid() returns uuid
language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

create or replace function auth.jwt() returns jsonb
language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')
  )::jsonb
$$;

create or replace function auth.role() returns text
language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )
$$;

grant execute on function auth.uid(), auth.jwt(), auth.role() to anon, authenticated, service_role;

-- ---- storage ---------------------------------------------------------------
create schema if not exists storage;
grant usage on schema storage to anon, authenticated, service_role;

create table if not exists storage.buckets (
  id                 text primary key,
  name               text not null,
  owner              uuid,
  created_at         timestamptz default now(),
  updated_at         timestamptz default now(),
  public             boolean default false,
  avif_autodetection boolean default false,
  file_size_limit    bigint,
  allowed_mime_types text[]
);

create table if not exists storage.objects (
  id               uuid primary key default gen_random_uuid(),
  bucket_id        text references storage.buckets (id),
  name             text,
  owner            uuid,
  created_at       timestamptz default now(),
  updated_at       timestamptz default now(),
  last_accessed_at timestamptz default now(),
  metadata         jsonb
);

alter table storage.objects enable row level security;

-- ---- PostgREST -------------------------------------------------------------
-- PostgREST logs in as `authenticator`, which owns nothing and can only SET ROLE to the three
-- Supabase roles. Exactly how a real Supabase instance is wired.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator noinherit login password 'authenticator';
  end if;
end
$$;

grant anon, authenticated, service_role to authenticator;

-- ---- auth.mfa_factors ------------------------------------------------------
-- GoTrue owns this table on a real Supabase project. The admin MFA work reads it (see
-- 20260922000100_admin_mfa.sql) and auth_roles_test.sql writes to it, so a database rebuilt from
-- these stubs needs it or thirteen assertions die on "relation does not exist" -- which is how
-- this was found: every suite passed on the machine's working database and not on a fresh one.
--
-- Columns and defaults match what GoTrue creates, because the migration joins on `status` and
-- the test inserts without naming `factor_type`.
do $$
begin
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 'auth' and t.typname = 'factor_type') then
    create type auth.factor_type as enum ('totp', 'webauthn', 'phone');
  end if;

  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 'auth' and t.typname = 'factor_status') then
    create type auth.factor_status as enum ('unverified', 'verified');
  end if;
end
$$;

create table if not exists auth.mfa_factors (
  -- NO DEFAULT, matching the real table, where GoTrue mints the id. A default here is the
  -- third instance in one day of a stub being kinder than production and hiding a bug until
  -- CI: auth.identities missing entirely, then its created_at defaulted, now this. Each one
  -- passed locally and failed somewhere with a worse error message.
  id            uuid primary key,
  user_id       uuid not null references auth.users (id) on delete cascade,
  friendly_name text,
  factor_type   auth.factor_type not null default 'totp',
  status        auth.factor_status not null default 'unverified',
  secret        text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- ---- auth.identities -------------------------------------------------------
-- GoTrue owns this table too, and it is the record of HOW somebody signs in: one row per
-- method, so a member with a password and Google has two. `my_security_state()` reads it to
-- decide whether disconnecting a provider would remove the last way into the account.
--
-- Added 2026-09-30, for the same reason mfa_factors was: without it the RPC and its pgTAP
-- suite fail on a freshly built database with "relation does not exist", while passing on a
-- machine whose database predates the need.
--
-- Shaped after the real one, including the generated `email` column and the (provider_id,
-- provider) uniqueness -- that pair is what makes "this Google account is already attached to
-- somebody else" a constraint violation rather than a silent second link.
create table if not exists auth.identities (
  id              uuid primary key default gen_random_uuid(),
  provider_id     text not null,
  user_id         uuid not null references auth.users (id) on delete cascade,
  identity_data   jsonb not null,
  provider        text not null,
  last_sign_in_at timestamptz,
  -- NULLABLE AND WITHOUT A DEFAULT, matching the real one, which is the whole point.
  --
  -- These were `not null default now()` for about six hours on 2026-09-30, and that kindness
  -- cost a CI run. The demo seed inserted identity rows without timestamps; locally the default
  -- filled them in and everything worked, while on real Supabase they landed NULL and GoTrue
  -- refused to scan them -- every sign-in 500ing with "Database error querying schema", and 20
  -- specs timing out on page.waitForURL with no hint as to why.
  --
  -- A stub that is more forgiving than production does not make local development easier. It
  -- moves the failure somewhere with a worse error message and a slower feedback loop.
  created_at      timestamptz,
  updated_at      timestamptz,
  email           text generated always as (lower(identity_data ->> 'email')) stored,
  unique (provider_id, provider)
);

create index if not exists identities_user_id_idx on auth.identities (user_id);
