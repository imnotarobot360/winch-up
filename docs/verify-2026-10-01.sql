-- Winch Up :: did the four unprovable parts of 1 October land?
--
-- The companion to docs/verify-which-migrations.sql, which checks all 55 files. This checks only the
-- twelve things that CANNOT be established from outside the database, so it is short enough to paste
-- and read in one go.
--
-- Everything else about 1 October was already confirmed over HTTP with the publishable key: a function
-- answers 42501 when it exists and PGRST202 when it does not, and -- usefully -- PostgREST validates a
-- COLUMN name before it checks the table grant, so a missing column gives 42703 and an existing one
-- gives 42501. That settled nine functions and four columns. It cannot settle these:
--
--   * anything in schema `app`, which PostgREST cannot see by design
--   * a function REPLACED under the same signature, where "it exists" has been true for weeks
--   * an index
--   * a setting's value
--
-- One statement, one result set. Failures sort to the top. Read every row.

with expected(file, what, ok) as (
  values
    -- ---- file 3: 20261001000700_photos_for_ring.sql -------------------------
    ('000700', 'app.may_see_request_photos exists',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'app' and p.proname = 'may_see_request_photos')),

    -- ---- file 4: 20261001001000_open_directory.sql --------------------------
    ('001000', 'app.member_is_listable exists',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'app' and p.proname = 'member_is_listable')),
    ('001000', 'app.like_contains exists',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'app' and p.proname = 'like_contains')),
    -- The backslash is doubled. It shipped as a no-op -- a shell heredoc ate one of them -- and both
    -- forms are valid SQL, so there is nothing to see in review.
    --
    -- READ FROM THE SOURCE, not by calling it. The obvious version of this check was
    -- `select app.like_contains('a\b') = '%a\\b%'`, which is better evidence -- it asks what the
    -- function DOES rather than what it says. But naming a function that does not exist fails when the
    -- statement is PARSED, not when that row is evaluated, so on the one database where this check
    -- matters the whole query died with "function app.like_contains(unknown) does not exist" and
    -- reported none of the other seventeen rows. A verifier that cannot survive the absence it is
    -- looking for is worse than no verifier. Found by deliberately breaking four of these in a
    -- transaction to see whether the query could still answer.
    --
    -- strpos, not like, because the needle is four characters of quote and backslash and LIKE would
    -- need them escaped again.
    ('001000', 'app.like_contains escapes a backslash',
      coalesce((select strpos(pg_get_functiondef(p.oid), '''\\''') > 0
                  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname = 'app' and p.proname = 'like_contains'), false)),

    -- ---- file 5: 20261001001100_directory_open_rpcs.sql ---------------------
    -- The ARGUMENT, not the function: nearby_members has existed since September.
    ('001100', 'nearby_members takes p_query',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = 'nearby_members'
                 and 'p_query' = any (p.proargnames))),
    -- This file's job is a REMOVAL, so "does member_profile exist" proves nothing.
    ('001100', 'member_profile no longer reads profile_public',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = 'member_profile'
                 and pg_get_functiondef(p.oid) not like '%profile_public%')),

    -- ---- file 6: 20261001001200_dispatch_respects_suspension.sql ------------
    -- The one that matters most: a suspended member still being dispatched to is invisible to the
    -- community and still rung at 3am.
    ('001200', 'app.candidates excludes suspended members',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'app' and p.proname = 'candidates'
                 and pg_get_functiondef(p.oid) like '%suspended_at%')),
    ('001200', 'app.candidates honours blocking',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'app' and p.proname = 'candidates'
                 and pg_get_functiondef(p.oid) like '%blocks_between%')),
    -- And that file 1 did not get pasted afterwards, which would have reverted both of the above.
    ('001200', 'app.candidates still excludes the requester',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'app' and p.proname = 'candidates'
                 and pg_get_functiondef(p.oid) like '%requester_user_id%')),

    -- ---- file 7: 20261001001300_profile_rigs_and_activity.sql ---------------
    ('001300', 'member_profile returns rig_count',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = 'member_profile'
                 and pg_get_functiondef(p.oid) like '%rig_count%')),

    -- ---- file 9: 20261001001500_content_queue_excludes_members.sql ----------
    ('001500', 'moderation_queue excludes reported members',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = 'moderation_queue'
                 and pg_get_functiondef(p.oid) like '%target_kind <> %')),

    -- ---- file 10: 20261001001600_reported_members_by_member.sql -------------
    ('001600', 'the members queue is grouped per member',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = 'moderation_reported_members'
                 and pg_get_functiondef(p.oid) like '%reports_open%')),

    -- ---- file 11: 20261001001700_report_a_member_again.sql ------------------
    ('001700', 'one OPEN member report per reporter (partial index)',
      exists (select 1 from pg_indexes where schemaname = 'public'
               and indexname = 'content_reports_one_open_per_reporter_member')),
    ('001700', 'one report per reporter for content (partial index)',
      exists (select 1 from pg_indexes where schemaname = 'public'
               and indexname = 'content_reports_one_per_reporter_content')),
    -- The blanket constraint must be GONE, or a member still cannot be reported twice.
    ('001700', 'the old blanket unique constraint is gone',
      not exists (select 1 from pg_constraint
                   where conname = 'content_reports_target_kind_target_id_reporter_user_id_key')),
    ('001400', 'a member can be the target of a report',
      exists (select 1 from pg_constraint
               where conname = 'content_reports_target_kind_check'
                 and pg_get_constraintdef(oid) like '%member%')),

    -- ---- file 12: 20261001001800_community_report_conflict_target.sql ------
    -- Without this, reporting a POST raises "no unique or exclusion constraint matching the ON
    -- CONFLICT specification" -- broken by a migration about reporting people.
    ('001800', 'community_report infers the partial index',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = 'community_report'
                 and pg_get_functiondef(p.oid) like '%target_kind <> %')),

    -- ---- file 2: 20261001000600_first_ring_ten_miles.sql -------------------
    -- Data, not structure. Nothing about the schema shows whether this ran.
    ('000600', 'the first dispatch ring is 10 miles',
      (select value = '[10, 30, 60]'::jsonb from public.app_settings
        where key = 'dispatch.ring_radii_miles'))
)
select
  case when ok then 'ok' else '>>> MISSING' end as state,
  file,
  what
from expected
order by ok, file, what;
