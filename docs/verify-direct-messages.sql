-- Winch Up :: did the six direct-message migrations land?
--
-- One statement, one result set, failures sorted to the top. Read every row.
--
-- This checks ONLY what cannot be established from outside the database. Already settled over HTTP
-- with the publishable key, with controls in both directions:
--
--   dm_can_message, dm_send, dm_inbox, dm_thread, dm_mark_read  -> 42501, so present and gated
--   profiles.allow_direct_messages, notify_direct_messages      -> 42501, so the columns exist
--                                                                  (42703 would mean missing)
--   dm_threads, dm_messages                                     -> 42501, so the tables exist and
--                                                                  anon is refused (PGRST205 would
--                                                                  mean no such table)
--
-- What HTTP cannot see, and therefore what is below: an enum LABEL, anything in schema `app`, a
-- function REPLACED under the same signature, an index, a CHECK constraint, and a column GRANT. That
-- last one is the reason this file exists at all -- a missing grant is invisible from outside and
-- silently turns the whole notification screen into its own defaults.
--
-- EVERY TEXT SEARCH IS strpos, NOT LIKE. `_` is a wildcard to LIKE and every identifier here contains
-- one; `%notify_direct_messages%` would match text that merely looks like it. That mistake made
-- app.notify appear to reference a column it has never named, earlier the same day.
--
-- NOTHING HERE CALLS A FUNCTION BY NAME. Naming a function that does not exist fails when the
-- statement is PARSED, which would kill the whole query and report none of the other rows -- on
-- precisely the database where the answers matter. Learned from docs/verify-2026-10-01.sql, which was
-- wrong in exactly that way until it was tested against a deliberately broken database.

with expected(file, what, ok) as (
  values
    -- ---- 002000: the enum label and the two switches ----------------------
    ('002000', 'notification_kind has the direct_message label',
      exists (select 1 from pg_type t join pg_enum e on e.enumtypid = t.oid
               where t.typname = 'notification_kind' and e.enumlabel = 'direct_message')),
    ('002000', 'profiles.allow_direct_messages defaults to true',
      (select column_default = 'true' from information_schema.columns
        where table_name = 'profiles' and column_name = 'allow_direct_messages')),
    ('002000', 'profiles.notify_direct_messages defaults to true',
      (select column_default = 'true' from information_schema.columns
        where table_name = 'profiles' and column_name = 'notify_direct_messages')),

    -- ---- 002100: the tables, and the shape that makes them safe -----------
    --
    -- RLS enabled with no grant is the whole design. A future grant cannot quietly open these if RLS
    -- is on and there is no policy, so both halves are asserted.
    ('002100', 'dm_threads has row level security on',
      (select relrowsecurity from pg_class where relname = 'dm_threads')),
    ('002100', 'dm_messages has row level security on',
      (select relrowsecurity from pg_class where relname = 'dm_messages')),
    ('002100', 'authenticated has NO privilege on dm_threads',
      not exists (select 1 from information_schema.table_privileges
                   where table_name = 'dm_threads' and grantee = 'authenticated')),
    ('002100', 'authenticated has NO privilege on dm_messages',
      not exists (select 1 from information_schema.table_privileges
                   where table_name = 'dm_messages' and grantee = 'authenticated')),
    -- One thread per pair, enforced by the database rather than by a query.
    ('002100', 'the pair is unique, so a conversation cannot be duplicated',
      exists (select 1 from pg_indexes where schemaname = 'public'
               and indexname = 'dm_threads_pair_idx')),
    ('002100', 'and is stored in a canonical order (member_a < member_b)',
      exists (select 1 from pg_constraint where conname = 'dm_threads_ordered')),
    -- The idempotency key. Without this index a retry on one bar of signal writes a second message.
    ('002100', 'a message cannot be written twice for one client id',
      exists (select 1 from pg_indexes where schemaname = 'public'
               and indexname = 'dm_messages_sender_client_idx')),

    -- ---- 002200: app.notify knows the new kind ----------------------------
    --
    -- The function has existed since September, so "does it exist" proves nothing. What matters is the
    -- branch -- without it an unmapped kind falls through to `else notify_recovery`, and a direct
    -- message would be governed by the RECOVERY switch.
    ('002200', 'app.notify maps direct_message to its own preference',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'app' and p.proname = 'notify'
                 and strpos(pg_get_functiondef(p.oid), 'notify_direct_messages') > 0)),

    -- ---- 002300: the access rule ------------------------------------------
    ('002300', 'app.dm_members_ok exists',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'app' and p.proname = 'dm_members_ok')),
    -- It must reuse the directory's predicate rather than reimplementing it: three places deciding
    -- "can this member see that one" is three places to get it wrong.
    ('002300', 'and decides through app.member_is_listable, not its own copy of the rule',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'app' and p.proname = 'dm_members_ok'
                 and strpos(pg_get_functiondef(p.oid), 'member_is_listable') > 0)),
    ('002300', 'dm_send rate limits NEW conversations separately',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = 'dm_send'
                 and strpos(pg_get_functiondef(p.oid), 'dm_start:') > 0)),
    -- The push payload carries who, not what. A direct message can come from a stranger.
    ('002300', 'and puts no message body in the notification',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public' and p.proname = 'dm_send'
                 and strpos(pg_get_functiondef(p.oid), 'jsonb_build_object(''name'', v_name)') > 0)),

    -- ---- 002400: the read path --------------------------------------------
    ('002400', 'app.dm_other_member exists',
      exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'app' and p.proname = 'dm_other_member')),

    -- ---- 002500: the grant that is invisible from outside ------------------
    --
    -- THE ONE THAT MATTERS MOST despite being the smallest file. Without it the notification screen's
    -- select is refused in full and every switch on it -- availability, marketing, recovery alerts --
    -- renders its default instead of the member's real setting, silently.
    ('002500', 'a member can READ their own allow_direct_messages',
      exists (select 1 from information_schema.column_privileges
               where table_name = 'profiles' and grantee = 'authenticated'
                 and column_name = 'allow_direct_messages' and privilege_type = 'SELECT')),
    ('002500', 'and CHANGE it',
      exists (select 1 from information_schema.column_privileges
               where table_name = 'profiles' and grantee = 'authenticated'
                 and column_name = 'allow_direct_messages' and privilege_type = 'UPDATE')),
    ('002500', 'a member can READ their own notify_direct_messages',
      exists (select 1 from information_schema.column_privileges
               where table_name = 'profiles' and grantee = 'authenticated'
                 and column_name = 'notify_direct_messages' and privilege_type = 'SELECT')),
    ('002500', 'and CHANGE it',
      exists (select 1 from information_schema.column_privileges
               where table_name = 'profiles' and grantee = 'authenticated'
                 and column_name = 'notify_direct_messages' and privilege_type = 'UPDATE')),
    -- The inverse, so the four above cannot be satisfied by granting everything.
    ('002500', 'while suspension is still granted neither way',
      not exists (select 1 from information_schema.column_privileges
                   where table_name = 'profiles' and grantee = 'authenticated'
                     and column_name in ('suspended_at', 'suspended_reason', 'suspended_by')))
)
select
  case when ok then 'ok' else '>>> MISSING' end as state,
  file,
  what
from expected
order by ok, file, what;
