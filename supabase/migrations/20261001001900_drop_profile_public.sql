-- Winch Up :: profiles.profile_public goes
--
-- The second half of a two-step, promised in 20261001001000. That file stopped READING the column and
-- deliberately left it in place: the migrations apply before Vercel finishes building, so a column
-- dropped in the same push as the code selecting it is a broken /account for however long the build
-- takes. The frontend that no longer selects it has been live since f4e2982.
--
-- WHY DROP IT AT ALL. It holds a choice nobody can make any more and nothing acts on. Left there it is
-- a loaded gun for the next person: a boolean called profile_public, defaulting to false, sitting on
-- the table a directory reads, is an invitation to re-gate on it -- and the owner's decision was that
-- every member is visible. A dead column that looks like a policy is worse than no column.
--
-- The data is not preserved anywhere, and that is the decision rather than an oversight. It records who
-- had opted in under a rule that no longer exists; keeping it would only be useful for putting the gate
-- back, which is the thing this phase exists to prevent. If the owner ever wants the toggle again it is
-- a new column with a new default and a fresh choice from each member, not a revival of consents given
-- to a different question.
--
-- CHECKED BEFORE DROPPING, by three means rather than by memory:
--
--   src/              one comment explaining the removal; no code.
--   pg_proc           no function in public or app names it. app.notify appeared to, and did not --
--                     the search was `like '%profile_public%'`, and LIKE reads `_` as a wildcard, so
--                     the pattern matched its declaration `v_profile public.profiles%rowtype` with the
--                     underscore standing in for a space. strpos said 0. That false positive is why
--                     both verifiers now use strpos.
--   supabase/tests    one comment in auth_roles_test, which asserts the column grants instead.
--
-- app.notify does select profiles%rowtype, so it depends on the table's SHAPE. That is fine: a rowtype
-- is resolved per call and `select * into` is positional, so dropping a column it never reads changes
-- nothing about it.

set search_path = public, extensions;

alter table public.profiles drop column if exists profile_public;
