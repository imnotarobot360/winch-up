-- Winch Up :: an admin can cancel a request (2026-10-05)
--
-- ONE FILE. Everything up to 20261005000100 is already in production.
--
--   20261005000200  app.cancel_request() extracted as the single definition of what cancelling
--                   means; cancel_request_by_token rewired through it; admin_cancel_request added.
--
-- WHY THIS EXISTS. cancel_request_by_token needs the requester's TOKEN, and it was the only cancel
-- path there has ever been. A request filed and then abandoned therefore sat on the public board
-- until the 24-hour expiry with nobody able to clear it -- which is how TX-FMHP spent a day there.
-- An admin can close one now, from the queue, with a confirmation in front of it.
--
-- IT TOUCHES A FUNCTION STRANDED DRIVERS USE. cancel_request_by_token is rewired to call the
-- shared core rather than carry its own copy, so its behaviour has to be unchanged, and five of
-- admin_cancel_test's seventeen assertions exist to prove exactly that: the token still works,
-- still records the requester's own reason, still refuses a bad token, and still writes no audit
-- row. If anything in this migration is going to hurt, it is that function, and that is where to
-- look.
--
-- The verification at the end reads `token_path_shares_core`, which is the one-line version of the
-- same question.
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
-- The username is `postgres.<project-ref>`, with the dot, and the host is a REAL region.
-- `bash scripts/check-db-url.sh` vets a string first and prints no password.
--
-- RUN IT THROUGH THE GUARD, not psql directly:
--
--     cd "C:\Users\jjser\New folder\txrecover"; git pull; node scripts/apply-pending.mjs
--
-- It fetches and REFUSES if this checkout is behind the remote -- which is the failure that cost a
-- round trip on 2026-10-05, when this file had been rewritten five times in a day and the copy
-- being run predated the newest migration. A stale driver and a broken migration look identical
-- from the outside: the run succeeds, the banner prints, nothing changed. It also re-checks the
-- backslashes and that no migration on disk has been left out, then prompts for the URI and hands
-- it to psql, which asks for the password itself without echoing.
--
-- Straight psql still works and is the fallback if node is unavailable:
--
--     cd "C:\Users\jjser\New folder\txrecover"; $U = Read-Host "URI"; & "C:\Users\jjser\tools\pgsql\bin\psql.exe" $U -v ON_ERROR_STOP=1 -f docs/apply-pending.sql
--
-- ---------------------------------------------------------------------------------------------
-- JUDGE THE RUN BY THE BANNER AT THE BOTTOM, NEVER BY THE ABSENCE OF RED
--
--     grep -c '^[\]i supabase/' docs/apply-pending.sql     must print 7

\set ON_ERROR_STOP on
\timing off

\echo ''
\echo '=== Winch Up :: the day's dispatch fixes, 7 files ==='
\echo ''

\echo '--- 1/7  admin_cancel_request + the shared core ---'
\i supabase/migrations/20261005000200_admin_cancel_request.sql

\echo '--- 2/7  admin Text honours STOP, and can re-send ---'
\i supabase/migrations/20261005000300_manual_dispatch_consent.sql

\echo '--- 3/7  a recovery cannot fall out of the scheduler ---'
\i supabase/migrations/20261005000400_unmatched_cannot_get_stuck.sql

\echo '--- 4/7  a phone verified after sign-in reaches the volunteer profile ---'
\i supabase/migrations/20261005000500_phone_from_auth_users.sql

\echo '--- 5/7  pressing Text sends the email too ---'
\i supabase/migrations/20261005000600_manual_dispatch_emails_too.sql

\echo '--- 6/7  completing /join is what makes somebody dispatchable, + backfill ---'
\i supabase/migrations/20261005000700_join_sets_available_to_help.sql

\echo '--- 7/7  a recovery call-out reaches a phone, not only the app ---'
\i supabase/migrations/20261005000800_callout_pushes.sql

\echo ''
\echo '=== Telling PostgREST the schema changed ==='
notify pgrst, 'reload schema';

\echo ''
\echo '=== Recording it in the migration ledger ==='

create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (version text primary key);

insert into supabase_migrations.schema_migrations (version) values
  ('20261005000200'), ('20261005000300'), ('20261005000400'), ('20261005000500'),
  ('20261005000600'), ('20261005000700'), ('20261005000800')
on conflict (version) do nothing;

\echo ''
select
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'admin_cancel_request')         as admin_fn_exists,
  has_function_privilege('authenticated', 'public.admin_cancel_request(uuid, text)', 'execute')
                                                                               as admin_callable,
  has_function_privilege('anon', 'public.admin_cancel_request(uuid, text)', 'execute')
                                                                               as anon_callable,
  strpos(pg_get_functiondef('public.cancel_request_by_token(text, text)'::regprocedure),
         'app.cancel_request') > 0                                             as token_path_shares_core,
  has_function_privilege('service_role', 'public.cancel_request_by_token(text, text)', 'execute')
                                                                               as token_path_still_granted,
  -- THE ROOT CAUSE OF THE STUCK RECOVERY. wait_min was declared and never assigned, so every
  -- deferral wrote `now() + make_interval(mins => null)` -- a null due time, after which the
  -- scheduler never looked at the request again.
  strpos(pg_get_functiondef('app.advance_one(uuid)'::regprocedure),
         'wait_min := app.ring_wait_minutes') > 0                              as deferral_has_a_wait,
  strpos(pg_get_functiondef('public.advance_dispatch(integer)'::regprocedure),
         'next_action_at is null') > 0                                         as stuck_rows_rescued,
  -- A phone verified AFTER sign-in: the JWT claim is a snapshot and goes stale, so the writer
  -- falls back to the server's own record for the caller. Confirmed only, never the form.
  strpos(pg_get_functiondef('public.upsert_responder_profile(jsonb)'::regprocedure),
         'phone_confirmed_at is not null') > 0                                 as phone_survives_a_stale_token,
  -- Pressing Text must alert by both channels, as the automatic waves do. It did not, and on the
  -- day Twilio refused the account's token that meant the button reached nobody at all.
  strpos(pg_get_functiondef('public.admin_manual_dispatch(uuid, uuid)'::regprocedure),
         'recovery.offer') > 0                                                 as text_button_emails_too;

\echo ''
\echo '================================================================'
\echo ' REACHED THE END. Applied and recorded.'
\echo ' If you cannot see this line, the run halted -- scroll up.'
\echo '================================================================'
\echo ''
\echo 'Every value above must read t, except the first (1) and anon_callable (f).'
\echo ''
\echo 'anon_callable must be FALSE -- the gate is auth.uid() through'
\echo 'app.require_admin(), so there is no shared key that confers admin.'
\echo 'The last two are the regression guards on the path a stranded driver'
\echo 'uses to cancel their own recovery: it must still share the core, and'
\echo 'the drop-free replace must not have cost it its grant.'
\echo ''
\echo 'Then TX-FMHP can be closed from /admin -- or it has expired by itself'
\echo 'by now, 24 hours after it went unmatched.'
\echo ''
