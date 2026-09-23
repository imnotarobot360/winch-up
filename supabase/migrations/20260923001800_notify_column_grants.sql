-- Winch Up :: the new preference columns were invisible to the people they belong to
--
-- profiles is deny-by-default and column-granted in BOTH directions: authenticated is given
-- SELECT and UPDATE on a named list, not on the table. Three columns were added without either
-- grant -- available_to_help in 20260923000100, notify_chat and notify_recovery_status in
-- 20260923001700 -- so the member they belong to could neither read nor write them.
--
-- The failure is silent in a specific and nasty way. A PostgREST select naming an ungranted
-- column 403s the WHOLE row, so the settings screen got null, fell back to its defaults, and
-- rendered every switch in a plausible-looking off state. Nothing in the UI said no.
--
-- Which means the Available to help toggle added to /account in the last phase has never worked:
-- it read null, showed off, and a member turning it on was writing through the RPC while the
-- screen could not see the result. Found by flipping a switch on the new settings page,
-- reloading, and watching it flip back.
--
-- This is the deny-by-default design doing its job rather than failing. A new column on this
-- table is born unwritable, and that is the right default for a table that also holds
-- profile_public and avatar_path. It just has to be finished.
--
-- available_to_help gets SELECT but deliberately NOT UPDATE. It is written through
-- public.set_available_to_help(), which is security definer and also creates the member's
-- recovery capability row; a direct grant would let a client set the flag without the row and
-- end up marked available and never rung.

set search_path = public, extensions;

grant select (available_to_help, notify_chat, notify_recovery_status) on public.profiles to authenticated;
grant update (notify_chat, notify_recovery_status) on public.profiles to authenticated;
