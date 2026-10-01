-- Winch Up :: every member is in the directory
--
-- The owner's spec: "every registered member can discover and view every other registered
-- member's profile", and "remove the existing 'Show my profile to other members' privacy toggle".
--
-- WHAT THIS REVERSES, AND WHY THAT IS A DECISION AND NOT A CLEANUP
--
-- The directory shipped as a double opt-in: profiles.profile_public AND profiles.available_to_help,
-- both defaulting to off. The reasoning is still in 20260924000100 and it was not silly -- being
-- willing to be rung is not the same as agreeing to be browsed. But the product it produced was a
-- directory that was empty, and a community nobody could see is not a community. The owner has
-- decided the other way, and this is that decision, applied at the only place it is enforced.
--
-- WHAT DOES NOT CHANGE, AND MUST NOT
--
-- Being listed is NOT being reachable. app.candidates() and app.may_see_request_photos() still
-- read available_to_help, so a member who has not turned it on is in the directory and is still
-- never rung by the dispatcher and still cannot see a stuck member's photographs. §4 of the spec
-- is explicit about keeping those separate, and the two functions this migration deliberately
-- does not touch are where that separation lives.
--
-- No coordinates leave here. Distance is still app.coarse_miles() of a server-side st_distance,
-- still measured from home_location and never from last_location. No phone. No email.
--
-- THREE THINGS GET FIXED ON THE WAY
--
--   1. The join was INNER. app.ensure_recovery_profile() only runs when somebody turns
--      availability on, so a member who never did has no responders row and was invisible --
--      removing the gates alone would NOT have listed them. "Every active member appears" would
--      have been false with nothing on screen to say why.
--   2. Blocking was not honoured. A member you blocked, or who blocked you, was in your directory.
--      app.blocks_between() already exists and is symmetric; the directory just never called it.
--   3. There was no way to suspend anybody. /rules tells members "An account that breaks these
--      rules can be suspended", which until now the schema could not do. §6 asks for it, and a
--      directory that lists everyone is exactly when it starts to matter.
--
-- profiles.profile_public is left in place for now. It is read by nothing after this migration,
-- and it is dropped in a follow-up once the frontend that still selects it is live -- a column
-- removed in the same push as the code that reads it is a broken /account for however long the
-- build takes.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. Suspension
-- ---------------------------------------------------------------------------
--
-- On profiles rather than a new table: it is one nullable timestamp, every read of it is alongside
-- the rest of the profile, and a join for a column that is null for almost everybody buys nothing.

alter table public.profiles
  add column if not exists suspended_at     timestamptz,
  add column if not exists suspended_reason text,
  add column if not exists suspended_by     uuid references auth.users (id) on delete set null;

create index if not exists profiles_suspended_idx
  on public.profiles (suspended_at)
  where suspended_at is not null;

-- schema_audit_test asserts every foreign key has an index, which is not pedantry here: this
-- one is read when an admin's account is deleted and auth.users cascades through it.
create index if not exists profiles_suspended_by_idx
  on public.profiles (suspended_by)
  where suspended_by is not null;

comment on column public.profiles.suspended_at is
  'Set by an admin. A suspended member is not in the directory, has no readable profile, and is '
  'not matched by the dispatcher. Null means active.';

-- No column grant for these three. authenticated can already only select
-- available_to_help/notify_chat/notify_recovery_status on this table (20260923001800), so a member
-- cannot read or write their own suspension, which is the point of it.

-- ---------------------------------------------------------------------------
-- 2. Who counts as a listable member
-- ---------------------------------------------------------------------------
--
-- One predicate, used by the list and by the single-profile read, so the two can never disagree
-- about who exists. A directory whose rows link to a 404, or whose 404 can be used to probe for
-- accounts the list won't show, is worse than either behaviour on its own.
--
-- r is LEFT JOINed by the callers, so every test here has to be true of a NULL responder row.
-- `r.redacted_at is null` is true when r is absent, which is what we want: a member who never
-- volunteered has nothing to redact.
--
-- NOT IN HERE: "you are not yourself". That belongs to the LIST -- a directory of other members --
-- and putting it in this shared predicate made every member's OWN profile page 404, because
-- member_profile() asks the same question about the member being viewed. rig_photos_test caught it,
-- by reading a profile as its owner on purpose. The list adds the condition itself.

create or replace function app.member_is_listable(
  p_profile   public.profiles,
  p_responder public.responders,
  p_viewer    uuid
)
returns boolean
language sql
stable
set search_path = public, extensions, pg_temp
as $$
  select p_profile.user_id is not null
     and p_profile.suspended_at is null          -- §6: suspended accounts are not community members
     and p_responder.redacted_at is null         -- deleted account, or aged past retention
     and not app.blocks_between(p_viewer, p_profile.user_id);
$$;

revoke all on function app.member_is_listable(public.profiles, public.responders, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. A name search that cannot be turned into a wildcard
-- ---------------------------------------------------------------------------
--
-- §2 asks for search by name. pg_trgm and unaccent are NOT installed here -- the local stack has
-- pgcrypto, plpgsql and postgis and nothing else -- so this is a plain case-insensitive contains,
-- and a migration that assumed otherwise would not replay.
--
-- The escaping is the part that matters. A member typing _ or % into a search box is typing
-- characters, not wildcards; without this, "_" matches every name of any length and the box
-- quietly becomes a way to enumerate the membership one pattern at a time.
--
-- THE BACKSLASH GOES FIRST, and it has to be doubled. Postgres LIKE uses \ as its own escape
-- character, so a backslash in the needle has to become two before anything else is escaped --
-- otherwise the \ this function inserts in front of % and _ could be read as escaping a character
-- the member actually typed. The first version of this line shipped as replace(p_needle, '\', '\'),
-- which is a no-op: a shell heredoc ate one of the backslashes on the way into the file, and the
-- loss is invisible in review because both forms are valid SQL. The cost was small and real --
-- searching for `back\slash` matched `backslash` -- and the tests did not catch it because they
-- only ever asked about _ and %.

create or replace function app.like_contains(p_needle text)
returns text
language sql
immutable
set search_path = pg_catalog
as $$
  select '%' ||
         replace(replace(replace(p_needle, '\', '\\'), '%', '\%'), '_', '\_')
         || '%';
$$;

revoke all on function app.like_contains(text) from public, anon, authenticated;
