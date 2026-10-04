-- Winch Up :: can this session actually use the admin console, and if not, which "no" is it
--
-- `app.require_admin()` RAISES. That is right for an RPC -- a refusal must not be mistakable for an
-- empty result -- and useless for a page that has to decide what to render. The admin layout
-- therefore checked only the ROLE, which answers one of the two questions.
--
-- WHAT THAT COST, found by the owner hitting it on 2026-10-03: with
-- `security.require_admin_mfa` on and a session still at aal1, a real admin passed the layout's
-- role check, got the full console, and then every screen quietly showed an empty list. Each RPC
-- behind them was raising `mfa_required`, and nothing in the app renders that -- `AdminSignIn` knew
-- only `signed_out` and `not_admin`. The console looked broken rather than locked.
--
-- So this reports rather than raises. It is the only function in the admin surface that answers a
-- refusal with data instead of an exception, which is exactly why it is safe to call before knowing
-- whether the caller is an admin at all.
--
-- IT LEAKS NOTHING. To a signed-in member it says `is_admin: false` and whether the site enforces
-- admin MFA -- a policy fact, not a fact about anybody. It names no admin, counts nothing, and
-- cannot be used to find out who is one.

set search_path = public, extensions;

create or replace function public.admin_session_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_admin    boolean := app.is_admin();
  v_enforced boolean := app.setting_bool('security.require_admin_mfa', false);
  v_aal      text    := app.current_aal();
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'reason', 'signed_out');
  end if;

  if not v_admin then
    return jsonb_build_object('ok', false, 'reason', 'not_admin');
  end if;

  -- The same condition app.require_admin() applies, phrased as an answer. Keeping it a copy rather
  -- than calling require_admin() in a block that swallows the exception is deliberate: swallowing
  -- would also swallow a genuine error and report it as "needs MFA".
  if v_enforced and v_aal is distinct from 'aal2' then
    return jsonb_build_object('ok', false, 'reason', 'mfa_required', 'aal', v_aal);
  end if;

  return jsonb_build_object('ok', true, 'reason', 'ok', 'aal', v_aal);
end;
$fn$;

revoke all on function public.admin_session_state() from public, anon;
-- To `authenticated`, not to admins only: its whole job is to be callable by somebody whose admin
-- status is the question.
grant execute on function public.admin_session_state() to authenticated;

comment on function public.admin_session_state() is
  'Reports whether this session may use the admin console, and which refusal applies: signed_out, '
  'not_admin, mfa_required, or ok. The one admin-surface function that answers with data rather '
  'than an exception, so a page can choose what to render.';

notify pgrst, 'reload schema';
