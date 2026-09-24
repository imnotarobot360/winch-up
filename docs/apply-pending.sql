-- Winch Up :: apply every migration this phase added, in order, stopping at the first error
--
-- Sixteen files reach production by hand. Nine of them went across the Supabase SQL editor last
-- time and most silently did not land: the editor shows only the LAST result set, and a large
-- paste appears to truncate. That cost a session, took app.candidates() down, and was only
-- noticed because a verification query was rewritten to put its verdict first.
--
-- This removes the whole class of failure. psql reads the files off disk, so nothing is truncated;
-- ON_ERROR_STOP means it halts at the first problem instead of carrying on into a half-applied
-- schema; and the order is written down once here rather than reassembled by hand each time.
--
-- ---------------------------------------------------------------------------------------------
-- HOW TO RUN IT
--
-- From the repo root, with the connection string in an environment variable so it never lands in
-- a shell history file, a screenshot or a chat window. Supabase gives it to you under
-- Project Settings -> Database -> Connection string -> URI. Use the SESSION pooler or the direct
-- connection, NOT the transaction pooler: this runs multi-statement files and creates types.
--
--   Bash:
--     read -rs SUPABASE_DB_URL && export SUPABASE_DB_URL
--     psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f docs/apply-pending.sql
--
--   PowerShell:
--     $env:SUPABASE_DB_URL = Read-Host -AsSecureString | ConvertFrom-SecureString -AsPlainText
--     psql $env:SUPABASE_DB_URL -v ON_ERROR_STOP=1 -f docs/apply-pending.sql
--
-- Then confirm, which is the part that is not optional:
--
--     psql "$SUPABASE_DB_URL" -f docs/verify-which-migrations.sql
--
-- Every row should read `done`. Any `>>> RE-RUN` names the file to look at.
--
-- ---------------------------------------------------------------------------------------------
-- WHY THERE IS NO SINGLE TRANSACTION AROUND THIS
--
-- Two of these files are ALTER TYPE ... ADD VALUE, and Postgres will not let a label be USED in
-- the transaction that adds it. Wrapping everything in one BEGIN would fail on the next file.
-- So each statement commits as it goes and ON_ERROR_STOP is what protects you: it stops on the
-- first error, and the fix is another migration rather than a rollback.
--
-- Every file is written to be safe to run twice (create or replace, if not exists, on conflict
-- do nothing), so re-running after a fix is fine.
-- ---------------------------------------------------------------------------------------------

\echo ''
\echo '=== Recovery teams: the labels, the table, and who can read a conversation ==='
\i supabase/migrations/20260923001000_team_chat_enums.sql
\i supabase/migrations/20260923001100_recovery_participants.sql
\i supabase/migrations/20260923001200_thread_access.sql
\i supabase/migrations/20260923001300_team_membership_sync.sql
\i supabase/migrations/20260923001400_participant_actions.sql
\i supabase/migrations/20260923001500_participants_policy_fix.sql
\i supabase/migrations/20260923001600_status_team.sql

\echo ''
\echo '=== Notifications for a team, and the two columns nobody could read ==='
\i supabase/migrations/20260923001700_chat_notifications.sql
\i supabase/migrations/20260923001800_notify_column_grants.sql

\echo ''
\echo '=== Recovery SMS off, and the outbox stops keeping what it carried ==='
\i supabase/migrations/20260923001900_sms_suppressed.sql
\i supabase/migrations/20260923002000_sms_off.sql

\echo ''
\echo '=== Messages that cannot be sent twice, and a socket that opens no tables ==='
\i supabase/migrations/20260923002100_message_client_id.sql
\i supabase/migrations/20260923002200_realtime_broadcast.sql

\echo ''
\echo '=== The second helper: accepting them, showing them, and their way back ==='
\i supabase/migrations/20260923002300_second_helper.sql
\i supabase/migrations/20260923002400_offers_after_accept.sql
\i supabase/migrations/20260923002500_second_helper_dashboard.sql

-- PostgREST caches the schema at startup and does not notice new functions or columns. Without
-- this the app calls request_thread() and gets "function not found" against a database that
-- plainly has it -- which reads as the migration not having applied.
\echo ''
\echo '=== Telling PostgREST the schema changed ==='
notify pgrst, 'reload schema';

\echo ''
\echo 'Applied. Now run: psql "$SUPABASE_DB_URL" -f docs/verify-which-migrations.sql'
\echo 'Every row should say done.'
\echo ''
