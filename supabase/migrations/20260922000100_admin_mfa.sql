-- Winch Up :: multi-factor authentication for administrators
--
-- Phase 11 requires it. An admin account can approve volunteers, read every requester's phone
-- number and exact location through the admin RPCs, ban people, and edit the waiver text that
-- everybody has legally accepted. Until now the only thing between all of that and the internet
-- was one password.
--
-- Enforced at app.require_admin(), NOT at app.is_admin().
--
-- That distinction is the whole design. app.is_admin() backs a dozen RLS read policies; making
-- it demand aal2 would lock an admin out of everything the moment this shipped -- including the
-- page where they would enrol. require_admin() gates the privileged *actions*, which is where
-- the risk actually is.
--
-- And it is behind a setting that defaults OFF. Turning it on before anybody has enrolled would
-- lock the only admin out of their own system with no way back in except SQL. The sequence is:
-- enrol, confirm it works, then flip the setting. /admin/security does that in order and refuses
-- to flip it early.

set search_path = public, extensions;

create or replace function app.setting_bool(p_key text, p_default boolean)
returns boolean
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  select coalesce((select (value #>> '{}')::boolean from public.app_settings where key = p_key), p_default);
$$;

-- Authenticator Assurance Level, from the JWT Supabase issues. 'aal2' means a second factor was
-- verified in this session, not merely that one is enrolled -- which is the point: an enrolled
-- factor that is never challenged protects nothing.
create or replace function app.current_aal()
returns text
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  select coalesce(nullif(auth.jwt() ->> 'aal', ''), 'aal1');
$$;

create or replace function app.require_admin()
returns void
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = 'insufficient_privilege';
  end if;

  if app.setting_bool('security.require_admin_mfa', false)
     and app.current_aal() is distinct from 'aal2' then
    -- Distinct from 'forbidden' so the UI can tell "you are not an admin" from "you are, but
    -- this session has not been challenged". Those need different screens.
    raise exception 'mfa_required' using errcode = 'insufficient_privilege';
  end if;
end;
$$;

insert into app_settings (key, value, description, is_public) values
  ('security.require_admin_mfa', 'false'::jsonb,
   'When true, every admin RPC requires a session that has passed a second factor (aal2). '
   'Leave false until at least one admin has enrolled and signed in with it, or you will lock '
   'yourself out.', false)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- What the security screen needs to know about itself
-- ---------------------------------------------------------------------------

create or replace function public.admin_security_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_enrolled integer;
begin
  -- Deliberately not require_admin(): this is the screen an admin uses to get OUT of a
  -- half-configured state, so it must stay reachable at aal1. It reveals nothing beyond the
  -- caller's own factor count and a setting.
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = 'insufficient_privilege';
  end if;

  select count(*) into v_enrolled
    from auth.mfa_factors f
   where f.user_id = auth.uid() and f.status = 'verified';

  return jsonb_build_object(
    'ok', true,
    'required', app.setting_bool('security.require_admin_mfa', false),
    'enrolled', v_enrolled,
    'current_aal', app.current_aal(),
    -- How many admins could still get in if enforcement were switched on right now. If this is
    -- zero, turning it on locks everybody out.
    'admins_with_mfa', (
      select count(distinct r.user_id)
        from public.user_roles r
        join auth.mfa_factors f on f.user_id = r.user_id and f.status = 'verified'
       where r.role = 'admin'
    ),
    'admins_total', (
      select count(*) from public.user_roles where role = 'admin'
    )
  );
end;
$$;

-- Turning enforcement on and off, with the one guard that matters.
create or replace function public.admin_set_mfa_required(p_required boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_with_mfa integer;
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = 'insufficient_privilege';
  end if;

  if p_required then
    -- The caller must have passed a second factor themselves. Otherwise an admin could switch on
    -- a requirement they cannot meet and lose their own console on the next request.
    if app.current_aal() is distinct from 'aal2' then
      return jsonb_build_object('ok', false, 'error', 'enrol_and_sign_in_first');
    end if;

    select count(distinct r.user_id) into v_with_mfa
      from public.user_roles r
      join auth.mfa_factors f on f.user_id = r.user_id and f.status = 'verified'
     where r.role = 'admin';

    if v_with_mfa = 0 then
      return jsonb_build_object('ok', false, 'error', 'no_admin_has_mfa');
    end if;
  end if;

  update app_settings
     set value = to_jsonb(p_required), updated_at = now(), updated_by = auth.uid()
   where key = 'security.require_admin_mfa';

  perform app.audit('security.mfa_requirement_changed', 'app_setting',
                    'security.require_admin_mfa',
                    jsonb_build_object('required', p_required));

  return jsonb_build_object('ok', true);
end;
$$;

do $$
declare fn text;
begin
  foreach fn in array array[
    'public.admin_security_state()',
    'public.admin_set_mfa_required(boolean)'
  ]
  loop
    execute format('revoke execute on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated, service_role', fn);
  end loop;
end
$$;
