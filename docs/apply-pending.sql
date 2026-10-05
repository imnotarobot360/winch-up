-- Winch Up :: a call-out goes out by email as well as by text (2026-10-05)
--
-- ONE FILE. Everything up to 20261004000800 is already in production and confirmed by probe.
--
--   20261005000100  email_deliveries gains request_id + dispatch_id, notify_ring queues a
--                   'recovery.offer' email beside the text, and claim_email_deliveries hands the
--                   sender the recovery facts at claim time.
--
-- WHAT CHANGES THE MOMENT THIS LANDS. Every volunteer already reached by a text will ALSO get an
-- email, and so will the ones who never consented to texts. That is the point -- sms_opt_in is
-- consent to be TEXTED, email is a different thing, and gating one behind the other would mean
-- almost nobody hears anything. Email is already deliverable: Resend is configured, DKIM is on the
-- apex and SPF on send.winch-up.com, so this does not have an A2P-shaped gate waiting behind it.
--
-- IT CONTAINS A DROP, DELIBERATELY. Adding `params` to claim_email_deliveries' result changes its
-- return type, and Postgres refuses a create-or-replace that does that. The drop sits inside the
-- migration so every replay gets it -- the last time this was worked around in a script instead,
-- the script worked while `supabase db reset` and anybody following the README did not. The grants
-- are restored immediately after, because a drop takes them with it.
--
-- NOTHING ELSE IN THE DISPATCHER MOVES. The migration re-creates app.notify_ring from the body
-- read out of the live database, and asserts at the end that yesterday's per-wave tuning survived.
--
-- ---------------------------------------------------------------------------------------------
-- HOW TO RUN IT
--
-- From the REPO ROOT -- the \i path below is relative to it.
--
-- Connection string: Supabase dashboard -> Connect -> Session pooler -> URI. SESSION pooler, port
-- 5432, not the transaction pooler (6543). Delete the password out of it, colon and all, so psql
-- prompts and it never reaches your shell history:
--
--     postgresql://postgres.abcdef:MyPassword@aws-0-us-east-1.pooler.supabase.com:5432/postgres
--     postgresql://postgres.abcdef@aws-0-us-east-1.pooler.supabase.com:5432/postgres
--
-- The username is `postgres.<project-ref>`, with the dot, and the host is a REAL region -- the CI
-- secret spent three days holding `aws-0-REGION.pooler.supabase.com` out of a documentation
-- example. `bash scripts/check-db-url.sh` vets a string first and prints no password.
--
--     cd "C:\Users\jjser\New folder\txrecover"; $U = Read-Host "URI"; & "C:\Users\jjser\tools\pgsql\bin\psql.exe" $U -v ON_ERROR_STOP=1 -f docs/apply-pending.sql
--
-- ---------------------------------------------------------------------------------------------
-- JUDGE THE RUN BY THE BANNER AT THE BOTTOM, NEVER BY THE ABSENCE OF RED
--
-- With ON_ERROR_STOP=1 psql cannot reach the banner unless the file applied. On 2026-09-28 this
-- driver silently applied nothing for days because `\i` had lost its backslash and become `i`,
-- which is a syntax error that looked like one stray line in a wall of success.
--
--     grep -c '^[\]i supabase/' docs/apply-pending.sql     must print 1

\set ON_ERROR_STOP on
\timing off

\echo ''
\echo '=== Winch Up :: recovery call-out email, 1 file ==='
\echo ''

\echo '--- 1/1  email beside the text ---'
\i supabase/migrations/20261005000100_recovery_offer_email.sql

\echo ''
\echo '=== Telling PostgREST the schema changed ==='
-- The migration does this itself; once more costs nothing and covers the case where that line is
-- lost in a later edit. Without it the two new columns are invisible to the app and read as 42703.
notify pgrst, 'reload schema';

\echo ''
\echo '=== Recording it in the migration ledger ==='
-- So a future `supabase db push` does not try to run it again and fail on "already exists", which
-- reads as a broken migration rather than as bookkeeping. scripts/check-migration-ledger.sh
-- refuses a push that would replay history, so a missed version shows up as a clear refusal.

create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (version text primary key);

insert into supabase_migrations.schema_migrations (version) values
  ('20261005000100')
on conflict (version) do nothing;

\echo ''
select
  (select count(*) from information_schema.columns
    where table_schema = 'public' and table_name = 'email_deliveries'
      and column_name in ('request_id', 'dispatch_id'))                       as columns_added,
  strpos(pg_get_functiondef('app.notify_ring(uuid, integer)'::regprocedure),
         'recovery.offer') > 0                                                as ring_queues_email,
  strpos(pg_get_functiondef('public.claim_email_deliveries(integer)'::regprocedure),
         'short_code') > 0                                                    as claim_builds_params,
  strpos(pg_get_functiondef('app.notify_ring(uuid, integer)'::regprocedure),
         'ring_max_helpers') > 0                                              as per_wave_intact,
  has_function_privilege('service_role', 'public.claim_email_deliveries(integer)', 'execute')
                                                                              as drain_can_still_claim;

\echo ''
\echo '================================================================'
\echo ' REACHED THE END. Applied and recorded.'
\echo ' If you cannot see this line, the run halted -- scroll up.'
\echo '================================================================'
\echo ''
\echo 'All five columns above must read 2 / t / t / t / t.'
\echo 'per_wave_intact and drain_can_still_claim are the two that catch a'
\echo 'regression rather than a missing feature: the first proves this did not'
\echo 'revert yesterday''s wave tuning, the second that the DROP did not leave'
\echo 'the drain unable to claim its own mail.'
\echo ''
