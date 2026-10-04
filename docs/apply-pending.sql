-- Winch Up :: apply the two migrations production is still missing (2026-10-03, second batch)
--
-- TWO FILES, NOT SEVENTEEN, and that is a deliberate narrowing. The first fifteen of this phase
-- (20261003000100..20261003001500) were applied earlier today and are CONFIRMED IN PRODUCTION by
-- probe, not by assumption: every one of their functions answered 42501 and every new table was
-- reachable, with two pre-existing names answering 42501 and two invented ones answering
-- PGRST202/42703 as controls. `docs/probe-2026-10-03.sh` re-runs that check any time.
--
-- WHY NOT JUST RE-RUN ALL SEVENTEEN. They are idempotent -- that was measured, twice, against a
-- scratch database -- and filename order even ends in the right state, because 20261003001700
-- drops the image columns that 20261003000600 would re-add and recreates the three functions
-- 20261003000700 and 20261003001500 would revert. But ON_ERROR_STOP halts at the first problem, and
-- a halt in the middle of that sequence would leave production with the image columns back and
-- three functions reverted to versions that still SELECT them. Re-applying fifteen files that are
-- known good, to re-reach a state they are already in, buys nothing and risks exactly that.
--
-- WHAT THESE TWO ARE
--
--   20261003001600  event_detail() -- one published event for its own page, not limited to
--                   upcoming ones. /events/[eventId] IS ALREADY DEPLOYED and calls it, so until
--                   this runs every event title in the Events tab links to a 404.
--   20261003001700  drops events.cover_image_path and events.image_paths, which were columns with
--                   no uploader and no renderer, and recreates events_upcoming(), admin_save_event()
--                   and admin_events() without them.
--
-- ORDER MATTERS BETWEEN THEM: 001700 recreates events_upcoming(), and 001600 does not, so running
-- 001700 first then 001600 would be fine too -- but run them as listed and it is one less thing to
-- reason about.
--
-- ---------------------------------------------------------------------------------------------
-- HOW TO RUN IT
--
-- From the REPO ROOT -- the \i paths below are relative to it.
--
-- Connection string from the Supabase dashboard: Connect -> Session pooler -> URI. SESSION pooler,
-- port 5432. Not the transaction pooler (6543): this runs multi-statement files, which a
-- transaction-mode pooler cannot do. Then DELETE THE PASSWORD out of it, leaving the colon off too:
--
--     postgresql://postgres.abcdef:MyPassword@aws-0-us-east-1.pooler.supabase.com:5432/postgres
--     postgresql://postgres.abcdef@aws-0-us-east-1.pooler.supabase.com:5432/postgres
--
-- psql prompts for it and reads it without echoing, so the password never reaches your shell
-- history, your scrollback or a screenshot.
--
-- NOTE THE USERNAME IS `postgres.<project-ref>`, with the dot. "password authentication failed for
-- user postgres" -- the error that stopped psql working here on 2026-09-30 -- is what a BARE
-- `postgres` username gets at the pooler. It reads like a wrong password and is a wrong username.
--
--     cd "C:\Users\jjser\New folder\txrecover"; $U = Read-Host "URI"; & "C:\Users\jjser\tools\pgsql\bin\psql.exe" $U -v ON_ERROR_STOP=1 -f docs/apply-pending.sql
--
-- One self-contained line on purpose: nothing depends on a variable surviving between windows.
--
-- ---------------------------------------------------------------------------------------------
-- JUDGE THE RUN BY THE BANNER AT THE BOTTOM, NEVER BY THE ABSENCE OF RED
--
-- With ON_ERROR_STOP=1 psql cannot reach the final banner unless both files applied. On 2026-09-28
-- this driver had silently applied nothing for days because eight lines had lost their backslashes
-- -- `\i` had become `i`, which is bare SQL and a syntax error. Every run halted there, and each
-- looked like one stray error in a wall of success.
--
--     grep -c '^[\]i supabase/' docs/apply-pending.sql     must print 2
--
-- Anchored, and the backslash in a bracket expression because a bare `grep -c '^\\i '` matches
-- nothing in this shell and a plain `grep -cF '\i supabase/'` counts THIS COMMENT too -- the first
-- version of this line said "must print 2" and printed 3, having matched itself.

\set ON_ERROR_STOP on
\timing off

\echo ''
\echo '=== Winch Up :: 2026-10-03 second batch, 2 files ==='
\echo ''

\echo '--- 1/2  event_detail(): one published event, for /events/[eventId] ---'
\i supabase/migrations/20261003001600_event_detail.sql

\echo '--- 2/2  drop the event image columns; recreate the three functions that used them ---'
\i supabase/migrations/20261003001700_drop_event_images.sql

\echo ''
\echo '=== Telling PostgREST the schema changed ==='
notify pgrst, 'reload schema';

-- RECORD THEM IN THE LEDGER, so `supabase db push` does not try to run them again.
--
-- The step that is cheap to skip and expensive to skip: applying by hand leaves
-- supabase_migrations.schema_migrations behind, and the next working CI run then re-runs these and
-- fails on "already exists" -- which reads as a broken migration rather than as bookkeeping.
-- `on conflict do nothing` makes it a no-op if some other path already recorded them.
\echo ''
\echo '=== Recording them in the migration ledger ==='

create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (version text primary key);

insert into supabase_migrations.schema_migrations (version) values
  ('20261003001600'), ('20261003001700')
on conflict (version) do nothing;

-- A one-line check that the ledger now covers this whole phase. Seventeen, not two: the first
-- fifteen were recorded by the earlier run of this driver. If this says anything less, CI will try
-- to re-apply whatever is missing the next time it works.
\echo ''
select count(*) || ' of 17 versions from 2026-10-03 are in the ledger' as ledger
  from supabase_migrations.schema_migrations
 where version like '20261003%';

\echo ''
\echo '================================================================'
\echo ' REACHED THE END. Both files applied and recorded.'
\echo ' If you cannot see this line, the run halted -- scroll up.'
\echo '================================================================'
\echo ''
\echo 'Now verify from outside, with no password:  bash docs/probe-2026-10-03.sh'
\echo 'Every line should say APPLIED except the two controls at the bottom.'
\echo ''
