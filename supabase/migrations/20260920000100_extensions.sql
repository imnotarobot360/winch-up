-- TxRecover M1 :: extensions + internal schema
--
-- Convention: application tables live in `public` (PostgREST reaches them).
-- Internal helpers live in `app`, which PostgREST cannot see at all.

set search_path = public, extensions;

create extension if not exists postgis with schema extensions;
create extension if not exists pgcrypto with schema extensions;

create schema if not exists app;

revoke all on schema app from public;
revoke all on schema app from anon, authenticated;
grant usage on schema app to postgres, service_role;

-- anon/authenticated need USAGE after all, because RLS policy expressions are evaluated with the
-- privileges of the querying role, and the policies call app.is_admin() / app.current_responder_id().
-- Privacy here comes from PostgREST exposing only `public`, plus per-function EXECUTE grants:
-- exactly two functions in this schema are callable, and they are granted at the end of
-- 20260920000300_helpers.sql.
grant usage on schema app to anon, authenticated;

comment on schema app is
  'TxRecover internal helpers. Not exposed over PostgREST. Only the two identity helpers used by RLS policies are executable by anon/authenticated.';
