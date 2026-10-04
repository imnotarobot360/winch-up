-- Winch Up :: apply the one migration production is still missing (2026-10-03, third batch)
--
-- ONE FILE. Everything before it in this phase (20261003000100..20261003001700) is confirmed in
-- production by probe, not assumed -- every function answers 42501, the two dropped columns answer
-- 42703, and two invented names answer PGRST202/42703 as controls. `docs/probe-2026-10-03.sh`
-- re-runs that check any time with nothing but the publishable key.
--
-- Narrow on purpose, for the reason the second batch was narrowed: these migrations are idempotent,
-- but ON_ERROR_STOP halts at the first problem, and a halt partway through a re-run of seventeen
-- known-good files would leave production in a state none of them intended. Re-reaching a state it
-- is already in buys nothing.
--
-- WHAT THIS IS
--
--   20261003001800  admin_session_state() -- reports whether a session may use the admin console,
--                   and WHICH refusal applies: signed_out, not_admin, mfa_required, or ok.
--
-- WHY IT MATTERS MORE THAN IT LOOKS. app.require_admin() raises, which is right for an RPC and
-- useless for a page deciding what to render, so the admin layout only ever asked "is this person
-- an admin". With security.require_admin_mfa on and a session still at aal1 -- the state the owner
-- hit on 2026-10-03 -- a real admin passed that check, got the whole console, and then watched
-- every screen show an empty list, because each RPC behind them was raising `mfa_required` and
-- nothing in the app rendered it. Locked and broken look identical from the outside.
--
-- The deployed frontend ALREADY calls this function. Until it exists, the admin layout's call fails
-- and the console falls back to the old behaviour -- so this is the migration that stops the
-- console lying, not one that adds a feature.
--
-- ---------------------------------------------------------------------------------------------
-- HOW TO RUN IT
--
-- From the REPO ROOT -- the \i path below is relative to it.
--
-- Connection string from the Supabase dashboard: Connect -> Session pooler -> URI. SESSION pooler,
-- port 5432, not the transaction pooler (6543). Then DELETE THE PASSWORD out of it, colon and all:
--
--     postgresql://postgres.abcdef:MyPassword@aws-0-us-east-1.pooler.supabase.com:5432/postgres
--     postgresql://postgres.abcdef@aws-0-us-east-1.pooler.supabase.com:5432/postgres
--
-- psql prompts for it and reads it without echoing, so it never reaches your shell history.
--
-- THE USERNAME IS `postgres.<project-ref>`, with the dot. "password authentication failed for user
-- postgres" is what a BARE `postgres` gets at the pooler: a wrong username that reads as a wrong
-- password.
--
--     cd "C:\Users\jjser\New folder\txrecover"; $U = Read-Host "URI"; & "C:\Users\jjser\tools\pgsql\bin\psql.exe" $U -v ON_ERROR_STOP=1 -f docs/apply-pending.sql
--
-- ---------------------------------------------------------------------------------------------
-- JUDGE THE RUN BY THE BANNER AT THE BOTTOM, NEVER BY THE ABSENCE OF RED
--
-- With ON_ERROR_STOP=1 psql cannot reach the final banner unless the file applied. On 2026-09-28
-- this driver silently applied nothing for days because eight lines had lost their backslashes --
-- `\i` had become `i`, which is bare SQL and a syntax error, so every run halted there and each
-- looked like one stray error in a wall of success.
--
--     grep -c '^[\]i supabase/' docs/apply-pending.sql     must print 1
--
-- Anchored, and the backslash inside a bracket expression: a bare `grep -c '^\\i '` matches nothing
-- in this shell, and a plain `grep -cF '\i supabase/'` counts THIS COMMENT too. The first version
-- of this line said "must print 2" and printed 3, having matched itself.

\set ON_ERROR_STOP on
\timing off

\echo ''
\echo '=== Winch Up :: 2026-10-03 third batch, 1 file ==='
\echo ''

\echo '--- 1/1  admin_session_state(): which refusal is it ---'
\i supabase/migrations/20261003001800_admin_session_state.sql

\echo ''
\echo '=== Telling PostgREST the schema changed ==='
notify pgrst, 'reload schema';

-- RECORD IT IN THE LEDGER, so `supabase db push` does not try to run it again. Applying by hand
-- leaves supabase_migrations.schema_migrations behind, and the next working CI run then re-runs
-- whatever is missing and fails on "already exists" -- which reads as a broken migration rather
-- than as bookkeeping.
\echo ''
\echo '=== Recording it in the migration ledger ==='

create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (version text primary key);

insert into supabase_migrations.schema_migrations (version) values
  ('20261003001800')
on conflict (version) do nothing;

-- Eighteen, not one: the earlier batches recorded the rest. Anything less and CI will try to
-- re-apply the gap the next time it works.
\echo ''
select count(*) || ' of 18 versions from 2026-10-03 are in the ledger' as ledger
  from supabase_migrations.schema_migrations
 where version like '20261003%';

\echo ''
\echo '================================================================'
\echo ' REACHED THE END. Applied and recorded.'
\echo ' If you cannot see this line, the run halted -- scroll up.'
\echo '================================================================'
\echo ''
\echo 'Now verify from outside, with no password:  bash docs/probe-2026-10-03.sh'
\echo 'Every line should say APPLIED except the two controls at the bottom.'
\echo ''
