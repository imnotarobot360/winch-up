-- Winch Up :: the participants policy referred to itself
--
-- 20260923001100 shipped this:
--
--   create policy recovery_participants_read_own_team ... using (
--     exists (select 1 from public.recovery_participants me
--              where me.request_id = recovery_participants.request_id
--                and me.user_id = auth.uid() and me.left_at is null))
--
-- which reads the table it is guarding. Evaluating the policy runs the subquery, the subquery is
-- itself subject to the policy, and Postgres stops it with "infinite recursion detected in policy
-- for relation recovery_participants".
--
-- It is invisible until somebody selects from the table as an ordinary member. The RPCs are
-- security definer and bypass RLS, so every function kept working and all sixteen assertions in
-- recovery_team_test passed; the first direct read from an authenticated role is what found it.
--
-- THE FIX
--
-- Ask a security definer function instead. app.is_request_participant() already exists, already
-- expresses exactly this rule, and runs as its owner, so the read inside it is not policed and
-- cannot recurse. One rule, one place -- which is what it was supposed to be before this policy
-- quietly wrote a second copy of it.
--
-- Granting EXECUTE to authenticated is not a new surface: the function lives in schema `app`,
-- which PostgREST is not configured to expose, and it answers one boolean about the caller's own
-- membership.

set search_path = public, extensions;

grant execute on function app.is_request_participant(uuid) to authenticated;

drop policy if exists recovery_participants_read_own_team on public.recovery_participants;
create policy recovery_participants_read_own_team on public.recovery_participants
  for select to authenticated
  using (app.is_request_participant(request_id));
