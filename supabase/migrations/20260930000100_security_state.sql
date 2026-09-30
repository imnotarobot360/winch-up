-- Winch Up :: what the Account & Security screen is allowed to know
--
-- One RPC answering "how can I get back into this account", for the signed-in caller and
-- nobody else.
--
-- WHY A DATABASE FUNCTION AND NOT THE SESSION OBJECT
--
-- Most of this is already in the browser's user object -- email, phone, the identities array --
-- and a screen could be built from that alone. Two things are not, and they are the two the
-- screen exists to answer:
--
--   * WHETHER A PASSWORD IS SET. GoTrue never exposes it, anywhere. The only truth is
--     auth.users.encrypted_password being non-empty, which no client may read. Without it the
--     screen has to offer "Set a password" to somebody who has one and "Change" to somebody
--     who does not, and one of those two is a lie every time.
--   * HOW MANY WAYS IN THERE ARE, counted consistently. The screen refuses to remove the last
--     one, and a guard computed from a stale client object is a guard that eventually locks
--     somebody out of their own account.
--
-- So the count is computed here, in the same snapshot as the facts it counts.
--
-- WHAT IT DELIBERATELY DOES NOT RETURN: the password hash, any token, any identity_data (which
-- holds the provider's raw profile payload -- name, avatar url, sub), and anything at all about
-- another account. The parameterless signature is part of that: there is no id to pass, so
-- there is no version of this call that reads somebody else.

set search_path = public, extensions;

create or replace function public.my_security_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_user      uuid := auth.uid();
  u           record;
  v_providers text[];
  v_methods   integer;
begin
  if v_user is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;

  select id,
         coalesce(email, '')                      as email,
         email_confirmed_at is not null           as email_confirmed,
         coalesce(phone, '')                      as phone,
         phone_confirmed_at is not null           as phone_confirmed,
         coalesce(encrypted_password, '') <> ''   as has_password,
         last_sign_in_at
    into u
    from auth.users
   where id = v_user;

  if not found then
    raise exception 'not signed in' using errcode = '42501';
  end if;

  -- Social identities only. GoTrue also stores an 'email' and a 'phone' identity, which would
  -- double-count against the columns above and would render as a "connected account" called
  -- email, which is not a thing anybody recognises.
  select coalesce(array_agg(distinct provider order by provider), '{}')
    into v_providers
    from auth.identities
   where user_id = v_user
     and provider not in ('email', 'phone');

  -- The ways back in, counted the way the screen must count them.
  --
  -- A CONFIRMED EMAIL IS NOT ONE. It looks like it should be -- you can always send yourself a
  -- reset link -- but a reset link sets a PASSWORD, and an account whose only email came from
  -- Google has no password to reset and no way to prove the address after the provider is
  -- disconnected. Counting it would let the screen cheerfully remove the genuinely last method.
  -- Under-counting refuses a removal that might have been survivable; over-counting locks
  -- somebody out of an account they cannot reach. Those costs are not symmetrical.
  v_methods := (case when u.has_password then 1 else 0 end)
             + (case when u.phone_confirmed then 1 else 0 end)
             + coalesce(array_length(v_providers, 1), 0);

  return jsonb_build_object(
    'email',           u.email,
    'email_confirmed', u.email_confirmed,
    'phone',           u.phone,
    'phone_confirmed', u.phone_confirmed,
    'has_password',    u.has_password,
    'providers',       to_jsonb(v_providers),
    'methods',         v_methods,
    'last_sign_in_at', u.last_sign_in_at
  );
end;
$fn$;

-- BY NAME, not `from public`.
--
-- Supabase ships `alter default privileges ... grant all on functions to anon, authenticated`,
-- so every new function is born executable by anon. `revoke ... from public` does NOT take that
-- back: the grants are held by those two roles specifically, not by PUBLIC. This exact mistake
-- left sign_membership_agreement anon-executable on 2026-09-28 and was invisible in testing,
-- because the function's own guard still refused -- the hole was that it could be CALLED.
--
-- And `public` is in the list as well, because the OTHER default is vanilla Postgres own: a new
-- function is executable by PUBLIC. Revoking only the two named roles leaves that in place, as
-- \df+ showed the first time this ran (`=X/postgres`). It takes all three to close.
-- Every other revoke in this repo names all three; this one was the outlier for about a minute.
revoke execute on function public.my_security_state() from public, anon, authenticated;
grant execute on function public.my_security_state() to authenticated;

comment on function public.my_security_state() is
  'The caller''s own sign-in methods, for /account/security. Never another account, never the hash.';

-- A new function is invisible to PostgREST until it reloads, and the symptom is a 404 that
-- reads exactly like an unapplied migration -- on the screen a member opens after losing their
-- phone. Every migration here ends this way for that reason.
notify pgrst, 'reload schema';
