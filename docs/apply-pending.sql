-- Winch Up :: the closest-helper SMS work (2026-10-04)
--
-- SEVEN FILES, IN ORDER. Everything before 20261004000100 is confirmed in production by probe.
-- `docs/probe-2026-10-03.sh` re-runs that check any time with nothing but the publishable key.
--
-- RUN THIS BEFORE TURNING SMS ON. That is the whole point of the ordering, and it is not a
-- formality: production has one reachable volunteer, smsConfigured true and smsSenderOk true, so
-- the next recovery after the switch is thrown sends a real text to a real person. Today that
-- person's row still says sms_opt_in = true BY DEFAULT -- they never agreed to anything, the
-- column was simply born that way -- and 20261004000200 is what makes consent a choice. Flipping
-- the switch first means the first text this product ever sends goes out under the rule the owner
-- asked to have removed.
--
-- WHAT THIS IS
--
--   20261004000200  recovery SMS consent defaults to FALSE, + set_my_recovery_sms()
--   20261004000300  /join and the account screen can ask for that consent
--   20261004000400  per-wave helper counts and waits (5/10/10 helpers, 2/3/3 minutes)
--   20261004000500  the first wave widens from 10 to 15 miles -- the owner's call
--   20261004000600  the dispatcher READS those per-wave numbers (without this, 000400 is inert)
--   20261004000700  requests.helpers_needed: the search continues until the crew is full
--   20261004000800  admin_recovery_alert_stats() for /admin/alerts
--
-- ORDER MATTERS TWICE OVER. 000600 replaces notify_ring and advance_one with bodies extracted
-- from their latest definitions; running it before 000400 leaves it calling functions that do not
-- exist yet. And 000500 is guarded to change the radius only if it currently reads [10, 30, 60],
-- so it is safe to re-run and safe if somebody has already tuned it by hand.
--
-- ONE CONSENT DECISION IS RECORDED HERE RATHER THAN BURIED. 20261004000200 sets sms_opt_in = false
-- for every existing responder that has not already said STOP. In production that is a small
-- number of rows and nobody loses anything they had -- no recovery SMS has ever been sent -- but
-- it does mean nobody is textable until they opt in. That is the intended state, and it is the
-- reason to do this before the switch rather than after.
--
-- ---------------------------------------------------------------------------------------------
-- HOW TO RUN IT
--
-- From the REPO ROOT -- the \i paths below are relative to it.
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
-- password. And the host is a REAL region -- the CI secret spent three days holding
-- `aws-0-REGION.pooler.supabase.com`, straight out of a documentation example, which never
-- resolved. `bash scripts/check-db-url.sh` checks a string before you use it and prints no password.
--
--     cd "C:\Users\jjser\New folder\txrecover"; $U = Read-Host "URI"; & "C:\Users\jjser\tools\pgsql\bin\psql.exe" $U -v ON_ERROR_STOP=1 -f docs/apply-pending.sql
--
-- ---------------------------------------------------------------------------------------------
-- JUDGE THE RUN BY THE BANNER AT THE BOTTOM, NEVER BY THE ABSENCE OF RED
--
-- With ON_ERROR_STOP=1 psql cannot reach the final banner unless every file applied. On 2026-09-28
-- this driver silently applied nothing for days because eight lines had lost their backslashes --
-- `\i` had become `i`, which is bare SQL and a syntax error, so every run halted there and each
-- looked like one stray error in a wall of success.
--
--     grep -c '^[\]i supabase/' docs/apply-pending.sql     must print 7
--
-- Anchored, and the backslash inside a bracket expression: a bare `grep -c '^\\i '` matches nothing
-- in this shell, and a plain `grep -cF '\i supabase/'` counts THIS COMMENT too.

\set ON_ERROR_STOP on
\timing off

\echo ''
\echo '=== Winch Up :: closest-helper SMS, 7 files ==='
\echo ''

\echo '--- 1/7  recovery SMS consent defaults to false ---'
\i supabase/migrations/20261004000200_recovery_sms_consent.sql

\echo '--- 2/7  signup and profile editing can ask for consent ---'
\i supabase/migrations/20261004000300_signup_sms_consent.sql

\echo '--- 3/7  per-wave helper counts and waits ---'
\i supabase/migrations/20261004000400_per_wave_tuning.sql

\echo '--- 4/7  first wave widens to fifteen miles ---'
\i supabase/migrations/20261004000500_first_wave_fifteen_miles.sql

\echo '--- 5/7  the dispatcher reads the per-wave numbers ---'
\i supabase/migrations/20261004000600_dispatch_reads_per_wave.sql

\echo '--- 6/7  helpers_needed, and the search continues until the crew is full ---'
\i supabase/migrations/20261004000700_helpers_needed.sql

\echo '--- 7/7  the admin alert statistics ---'
\i supabase/migrations/20261004000800_recovery_alert_stats.sql

\echo ''
\echo '=== Telling PostgREST the schema changed ==='
-- Each migration does this itself where it matters. Once more at the end costs nothing and covers
-- the case where one of them is edited later and the line is lost: without it a new function
-- answers PGRST202 and a new column answers 42703, both of which read like an unapplied migration
-- rather than a stale cache. /admin/alerts hit exactly this during development.
notify pgrst, 'reload schema';

-- RECORD IT IN THE LEDGER, so `supabase db push` does not try to run these again. Applying by hand
-- leaves supabase_migrations.schema_migrations behind, and the next working CI run then re-runs
-- whatever is missing and fails on "already exists" -- which reads as a broken migration rather
-- than as bookkeeping. scripts/check-migration-ledger.sh refuses a push that would replay history,
-- so a missed version here shows up as a clear refusal instead of a surprise.
\echo ''
\echo '=== Recording them in the migration ledger ==='

create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (version text primary key);

insert into supabase_migrations.schema_migrations (version) values
  ('20261004000200'), ('20261004000300'), ('20261004000400'), ('20261004000500'),
  ('20261004000600'), ('20261004000700'), ('20261004000800')
on conflict (version) do nothing;

-- Did the things that matter actually land? Said plainly, rather than trusting the absence of an
-- error -- `insert ... on conflict do nothing` succeeds whether or not it inserted anything.
\echo ''
select
  (select column_default from information_schema.columns
    where table_schema = 'public' and table_name = 'responders'
      and column_name = 'sms_opt_in')                                    as consent_default_now,
  (select count(*) from public.responders where sms_opt_in)              as responders_opted_in,
  app.ring_radius_miles(1)                                               as wave_1_miles,
  app.ring_max_helpers(1)                                                as wave_1_helpers,
  app.ring_wait_minutes(1)                                               as wave_1_wait_minutes,
  (select count(*) from information_schema.columns
    where table_schema = 'public' and table_name = 'requests'
      and column_name = 'helpers_needed')                                as helpers_needed_column;

\echo ''
\echo '================================================================'
\echo ' REACHED THE END. Applied and recorded.'
\echo ' If you cannot see this line, the run halted -- scroll up.'
\echo '================================================================'
\echo ''
\echo 'Expected above: consent_default_now = false, responders_opted_in = 0,'
\echo 'wave_1_miles = 15, wave_1_helpers = 5, wave_1_wait_minutes = 2,'
\echo 'helpers_needed_column = 1.'
\echo ''
\echo 'responders_opted_in = 0 is CORRECT and is the point: nobody has been asked'
\echo 'yet. Until members opt in, turning sms.outbound_enabled on sends nothing.'
\echo 'That is the safe order -- the switch can go on before anybody has consented'
\echo 'without a single unexpected text leaving the building.'
\echo ''
