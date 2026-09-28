-- Winch Up :: apply every migration this phase added, in order, stopping at the first error
--
-- Thirty files reach production by hand. Nine of them went across the Supabase SQL editor last
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
-- Run it from the REPO ROOT, in any terminal. The \i paths below are relative to it.
--
-- Get the connection string from the Supabase dashboard: Connect -> Session pooler -> URI. Use
-- the session pooler or the direct connection, NOT the transaction pooler -- this runs
-- multi-statement files and creates types, which the transaction pooler cannot do.
--
-- Then DELETE THE PASSWORD out of it, leaving the colon off too:
--
--     postgresql://postgres.abcdef:MyPassword@aws-0-us-east-1.pooler.supabase.com:5432/postgres
--     postgresql://postgres.abcdef@aws-0-us-east-1.pooler.supabase.com:5432/postgres
--
-- psql then prompts for it, reads it without echoing, and the password never reaches your shell
-- history, your scrollback or a screenshot. This is simpler and safer than juggling an
-- environment variable, and it avoids the fact that the obvious PowerShell incantation for
-- reading a secret (ConvertFrom-SecureString -AsPlainText) only exists in PowerShell 7.
--
--   PowerShell:
--     & "C:\\Users\\jjser\\tools\\pgsql\\bin\\psql.exe" "<URI-without-password>" -v ON_ERROR_STOP=1 -f docs/apply-pending.sql
--
--   Bash / Git Bash:
--     "/c/Users/jjser/tools/pgsql/bin/psql.exe" "<URI-without-password>" -v ON_ERROR_STOP=1 -f docs/apply-pending.sql
--
-- psql is not on PATH on this machine; it lives under tools/pgsql/bin. Any psql 14 or newer works.
--
-- Then confirm, which is the part that is not optional:
--
--     psql "<URI-without-password>" -f docs/verify-which-migrations.sql
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

-- OUT OF TIMESTAMP ORDER, ON PURPOSE.
--
-- 20260923001700 ends with a create-or-replace of claim_push_deliveries that changes its return
-- type, which Postgres refuses outright on any database that already has the 20260923000400
-- version. 002600 does the drop that makes it possible. Run in filename order, 001700 fails and
-- ON_ERROR_STOP halts the whole run before reaching the file that fixes it.
--
-- Run first, 002600 puts the function in its final shape, and 001700's version of the same
-- statement then has a matching signature and goes through as an ordinary no-op replace. One
-- clean pass instead of a documented manual workaround.
--
-- Safe to hoist because it depends on nothing above it: the function reads notifications,
-- notification_deliveries, push_subscriptions and responders, all of which exist from 000400.
\echo ''
\echo '=== First: the one statement in 001700 that cannot succeed without this ==='
\i supabase/migrations/20260923002600_claim_push_url.sql

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

-- ---------------------------------------------------------------------------------------------
-- THE EIGHT LINES BELOW HAD LOST THEIR BACKSLASHES, AND THAT IS WHY THIS KEPT HALF-WORKING
--
-- `\echo` had become `echo` and `\i` had become `i`, from here to the end of the file. Those
-- are not psql meta-commands, they are bare SQL, and `echo ''` is a syntax error -- so with
-- ON_ERROR_STOP=1 every run stopped dead at this line and NOTHING from 20260923002700 onward
-- was ever applied by this driver.
--
-- It fails in the most expensive possible way: the files above it apply perfectly, psql prints
-- one error among a lot of successful output, and the database is left part-way. That is
-- exactly the history in the notes -- "20260923002700 was missing and 20260924000100 had never
-- been applied, so /members was live in production calling functions that did not exist" -- and
-- those are precisely the first two files below this line. Confirmed again on 2026-09-28:
-- community_feed's p_topic overload from 20260927000200 is still absent from production.
--
-- If you are adding files here: they are `\i`, with a backslash. Check the run's output ends
-- with the "Applied." banner, which only prints if psql reached the bottom of this file.
-- ---------------------------------------------------------------------------------------------

\echo ''
\echo '=== The team can see where they are driving to ==='
\i supabase/migrations/20260923002700_thread_location.sql

\echo ''
\echo '=== A directory of members who chose to be in one ==='
\i supabase/migrations/20260924000100_nearby_members.sql
\i supabase/migrations/20260924000200_email_deliveries.sql
\i supabase/migrations/20260924000300_welcome_email.sql
\i supabase/migrations/20260925000100_dispatch_sms_on.sql
\i supabase/migrations/20260927000100_signup_name.sql
\i supabase/migrations/20260927000200_post_topics.sql
\i supabase/migrations/20260928000100_phone_optional.sql

\echo ''
\echo '=== The membership agreement: versions, signatures, and the gate (shipped OFF) ==='
-- 000600 opens with a guard that refuses to run if create_request is not the version the gate
-- was spliced into. If it raises, stop and re-splice rather than editing the file to pass.
\i supabase/migrations/20260928000200_membership_agreement.sql
\i supabase/migrations/20260928000300_membership_rpc.sql
\i supabase/migrations/20260928000400_membership_admin.sql
\i supabase/migrations/20260928000500_membership_signed_email.sql
\i supabase/migrations/20260928000600_membership_gate.sql

\echo ''
\echo '=== /terms stops saying PLACEHOLDER at A2P reviewers ==='
-- Prints a NOTICE saying whether it published or found the text already current. Safe to re-run:
-- it compares the text rather than the version number.
\i supabase/migrations/20260928000700_rules_v2.sql

\echo ''
\echo '=== Phone required to join again, and a photo of your rig ==='
\i supabase/migrations/20260928000800_phone_required_again.sql
\i supabase/migrations/20260928000900_vehicle_photos.sql
\i supabase/migrations/20260928001000_member_rig_photo.sql

-- PostgREST caches the schema at startup and does not notice new functions or columns. Without
-- this the app calls request_thread() and gets "function not found" against a database that
-- plainly has it -- which reads as the migration not having applied.
\echo ''
\echo '=== Telling PostgREST the schema changed ==='
notify pgrst, 'reload schema';

-- This banner is the proof the run finished. With ON_ERROR_STOP=1 psql cannot reach it unless
-- every file above applied -- so if you do not see it, the run stopped somewhere and the last
-- error printed is where. Do not judge a run by the absence of red.
\echo ''
\echo '================================================================'
\echo ' REACHED THE END. Every file above applied.'
\echo ' If you cannot see this line, the run halted -- scroll up.'
\echo '================================================================'
\echo ''
\echo 'Now run the same psql command with -f docs/verify-which-migrations.sql'
\echo 'Every row should say done.'
\echo ''
