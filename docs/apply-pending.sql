-- Winch Up :: apply the 2026-10-03 geo-targeting migrations, in order, stopping at the first error
--
-- Fifteen files. They are committed and pushed, CI reported success, and NONE of them reached
-- production: the `apply migrations to production` job skipped its two working steps because
-- `secrets.SUPABASE_DB_URL` arrives empty at the workflow. The job going green while applying
-- nothing is the exact failure this repo keeps re-learning, so it is worth saying plainly at the
-- top of the file that exists to work around it.
--
-- Verified absent by probe, not assumed: every new function answered PGRST202 and every new table
-- PGRST205, with two pre-existing names answering 42501 as controls. docs/probe-2026-10-03.sh.
--
-- ---------------------------------------------------------------------------------------------
-- WHY THIS FILE RATHER THAN THE SQL EDITOR
--
-- The Supabase editor shows only the LAST result set, and a large paste truncates silently. The
-- symptom is always the same and always misleading: the last object in a file is missing while
-- everything above it landed, so a verification query reports "1 of 6 missing" and reads like a
-- logic bug. Nine files went that way on 2026-09-23 and app.candidates() was down unnoticed.
--
-- psql reads the files off disk, so nothing is truncated, and ON_ERROR_STOP=1 halts at the first
-- problem instead of carrying on into a half-applied schema.
--
-- ---------------------------------------------------------------------------------------------
-- HOW TO RUN IT
--
-- From the REPO ROOT -- the \i paths below are relative to it.
--
-- Get the connection string from the Supabase dashboard: Connect -> Session pooler -> URI.
-- SESSION pooler, port 5432. Not the transaction pooler (6543): this runs multi-statement files
-- and creates types, which a transaction-mode pooler cannot do. Not the direct connection either
-- if you can avoid it -- it is IPv6-only.
--
-- Then DELETE THE PASSWORD out of it, leaving the colon off too:
--
--     postgresql://postgres.abcdef:MyPassword@aws-0-us-east-1.pooler.supabase.com:5432/postgres
--     postgresql://postgres.abcdef@aws-0-us-east-1.pooler.supabase.com:5432/postgres
--
-- psql prompts for it and reads it without echoing, so the password never reaches your shell
-- history, your scrollback or a screenshot.
--
-- NOTE THE USERNAME IS `postgres.<project-ref>`, with the dot. "password authentication failed
-- for user postgres" -- the error that stopped psql working here on 2026-09-30 -- is what a BARE
-- `postgres` username gets at the pooler. It reads like a wrong password and is a wrong username.
--
--     cd "C:\Users\jjser\New folder\txrecover"; $U = Read-Host "URI"; & "C:\Users\jjser\tools\pgsql\bin\psql.exe" $U -v ON_ERROR_STOP=1 -f docs/apply-pending.sql
--
-- One self-contained line on purpose: nothing depends on a variable surviving between windows.
-- When that was assumed, psql fell back to localhost:5432 and the error looked like the server
-- being down.
--
-- ---------------------------------------------------------------------------------------------
-- JUDGE THE RUN BY THE BANNER AT THE BOTTOM, NEVER BY THE ABSENCE OF RED
--
-- With ON_ERROR_STOP=1 psql cannot reach the final banner unless every file applied. On
-- 2026-09-28 this driver had silently applied nothing for days because eight lines had lost their
-- backslashes -- `\i` had become `i`, which is bare SQL and a syntax error. Every run halted
-- there, and each looked like one stray error in a wall of success.
--
--     grep -cE "^(i|echo) " docs/apply-pending.sql     must print 0
--
-- ---------------------------------------------------------------------------------------------
-- ORDER MATTERS IN TWO PLACES, and both are why these are separate files
--
--   000500 creates the `event_type` enum; 000600 uses it as a column default.
--   001200 creates the announcement enums; 001300 uses them.
--
-- A new enum label cannot be USED in the transaction that adds it. psql is autocommit, so each
-- statement commits as it goes and the split works -- which is exactly what `supabase db push`
-- would NOT give you if these were one file, because it wraps each migration in a transaction.
--
-- 000800 adds four `ad_surface` labels for the same reason.

\set ON_ERROR_STOP on
\timing off

\echo ''
\echo '=== Winch Up :: 2026-10-03 geo-targeting, 15 files ==='
\echo ''

\echo '--- 1/15  member location on profiles (spec 11) ---'
\i supabase/migrations/20261003000100_member_location.sql

\echo '--- 2/15  the shared targeting model (spec 2, 6, 10) ---'
\i supabase/migrations/20261003000200_targeting.sql

\echo '--- 3/15  server-side postal centroid writer ---'
\i supabase/migrations/20261003000300_member_postal_center.sql

\echo '--- 4/15  ads_for() ENFORCES targeting (spec 6) ---'
\i supabase/migrations/20261003000400_ads_enforce_targeting.sql

\echo '--- 5/15  event_type enum (its own file: a label cannot be used where it is added) ---'
\i supabase/migrations/20261003000500_event_type_enum.sql

\echo '--- 6/15  event detail columns (spec 2) ---'
\i supabase/migrations/20261003000600_event_details.sql

\echo '--- 7/15  event admin RPCs; REPLACES events_upcoming(integer) ---'
\i supabase/migrations/20261003000700_event_admin_rpcs.sql

\echo '--- 8/15  four more ad surfaces (spec 8) ---'
\i supabase/migrations/20261003000800_ad_surface_labels.sql

\echo '--- 9/15  campaign lifecycle; ads_for() switches to app.campaign_phase() (spec 9) ---'
\i supabase/migrations/20261003000900_campaign_lifecycle.sql

\echo '--- 10/15  geographic ad stats + event views (spec 12) ---'
\i supabase/migrations/20261003001000_ad_geo_analytics.sql

\echo '--- 11/15  the report, with the agreed suppression (spec 12) ---'
\i supabase/migrations/20261003001100_ad_report.sql

\echo '--- 12/15  announcement enums (own file, same enum rule) ---'
\i supabase/migrations/20261003001200_announcement_enums.sql

\echo '--- 13/15  announcements + dismissals (spec 1) ---'
\i supabase/migrations/20261003001300_announcements.sql

\echo '--- 14/15  announcement RPCs (spec 1, 14) ---'
\i supabase/migrations/20261003001400_announcement_rpcs.sql

\echo '--- 15/15  targeting round-trip + admin_events (spec 14, 16) ---'
\i supabase/migrations/20261003001500_targets_round_trip.sql

\echo ''
\echo '=== Telling PostgREST the schema changed ==='
notify pgrst, 'reload schema';

-- RECORD THEM IN THE LEDGER, so `supabase db push` does not try to run them again.
--
-- This is the step that is easy to skip and expensive to skip. The CLI tracks what it has applied
-- in supabase_migrations.schema_migrations; applying by hand leaves that table behind, and the
-- next successful CI run then re-runs all fifteen and fails on "already exists" -- which reads as
-- a broken migration rather than a bookkeeping gap. `on conflict do nothing` makes this a no-op if
-- some other path already recorded them.
\echo ''
\echo '=== Recording them in the migration ledger ==='

create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (version text primary key);

insert into supabase_migrations.schema_migrations (version) values
  ('20261003000100'), ('20261003000200'), ('20261003000300'), ('20261003000400'),
  ('20261003000500'), ('20261003000600'), ('20261003000700'), ('20261003000800'),
  ('20261003000900'), ('20261003001000'), ('20261003001100'), ('20261003001200'),
  ('20261003001300'), ('20261003001400'), ('20261003001500')
on conflict (version) do nothing;

-- This banner is the proof the run finished. With ON_ERROR_STOP=1 psql cannot reach it unless
-- every file above applied -- so if you do not see it, the run stopped somewhere and the last
-- error printed is where. Do not judge a run by the absence of red.
\echo ''
\echo '================================================================'
\echo ' REACHED THE END. All fifteen files applied and recorded.'
\echo ' If you cannot see this line, the run halted -- scroll up.'
\echo '================================================================'
\echo ''
