-- Winch Up :: the bucket a member's photograph goes in (2026-10-04)
--
-- ONE FILE. Everything before it -- 20261003000100..20261003001800 -- is confirmed in production by
-- probe, not assumed. `docs/probe-2026-10-03.sh` re-runs that check any time with nothing but the
-- publishable key.
--
-- WHAT THIS IS
--
--   20261004000100  creates the private `member-avatars` storage bucket.
--
-- WHY IT MATTERS NOW. `profiles.avatar_path` has existed since phase 3 and was granted for UPDATE
-- to `authenticated` all along; what was missing was somewhere to put the file. The upload route,
-- the signer and the account-screen control are ALREADY DEPLOYED and reference this bucket, so
-- until it exists every attempt to add a photograph fails at the signing step and the member sees
-- "that photo did not upload".
--
-- It is a private bucket with no policies on storage.objects, deliberately. Uploads are signed by
-- the server from the SESSION, so the browser never picks the path; reads are signed server-side
-- too. A policy granting `authenticated` direct access would hand every member every other
-- member's object path, which is the thing signed URLs exist to avoid.
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
-- in this shell, and a plain `grep -cF '\i supabase/'` counts THIS COMMENT too.

\set ON_ERROR_STOP on
\timing off

\echo ''
\echo '=== Winch Up :: 2026-10-04, 1 file ==='
\echo ''

\echo '--- 1/1  the member-avatars bucket ---'
\i supabase/migrations/20261004000100_member_avatars.sql

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
  ('20261004000100')
on conflict (version) do nothing;

-- Did the bucket actually land? One row, said plainly, rather than trusting the absence of an
-- error -- `insert ... on conflict do nothing` succeeds whether or not it inserted anything.
\echo ''
select case
         when exists (select 1 from storage.buckets where id = 'member-avatars')
           then 'member-avatars bucket: PRESENT'
         else 'member-avatars bucket: MISSING -- the upload will still fail'
       end as bucket;

\echo ''
\echo '================================================================'
\echo ' REACHED THE END. Applied and recorded.'
\echo ' If you cannot see this line, the run halted -- scroll up.'
\echo '================================================================'
\echo ''
\echo 'Then add a photo at /account. The bucket is private, so the picture'
\echo 'is served through a short-lived signed URL rather than a public link.'
\echo ''
