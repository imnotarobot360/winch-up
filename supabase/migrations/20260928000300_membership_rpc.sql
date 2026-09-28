-- Winch Up :: reading the membership agreement, and signing it
--
-- Two entry points with deliberately different reach:
--
--  * public.membership_agreement() is readable by anyone, signed in or not. It has to be: a
--    visitor partway through registration must be able to READ what they are being asked to
--    agree to before they have an account, and requirement 3 wants the full text on the page
--    rather than behind a link.
--
--  * public.sign_membership_agreement() is service_role ONLY. It is reached through a server
--    action, never from the browser, for the same reason create_request is: the IP and user
--    agent stored against a signature are audit evidence, and evidence the signer supplies
--    about themselves is not evidence. `authenticated` is never granted this.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- Has this member signed what is currently in force?
--
-- The gate, the UI prompt and the admin report all have to agree on the answer, so there is one
-- function and they all call it.
-- ---------------------------------------------------------------------------

create or replace function app.membership_state(p_user uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  a           public.membership_agreements%rowtype;
  v_signed_at timestamptz;
  v_any       boolean;
begin
  select * into a from public.membership_agreements
   where is_current and effective_at is not null and effective_at <= now()
   limit 1;

  if p_user is not null then
    select s.signed_at into v_signed_at
      from public.membership_signatures s
     where s.user_id = p_user and s.agreement_version = a.version;

    select exists (select 1 from public.membership_signatures s where s.user_id = p_user)
      into v_any;
  else
    v_any := false;
  end if;

  return jsonb_build_object(
    -- No current effective agreement means nothing to sign and nothing to enforce. This is the
    -- state the product ships in, and every caller has to handle it.
    'has_agreement', a.id is not null,
    'version',       a.version,
    'signed',        v_signed_at is not null,
    'signed_at',     v_signed_at,
    'signed_any',    coalesce(v_any, false),
    -- Requirement 14: a new signature only when the change is material. Somebody who signed v1
    -- is NOT re-prompted by a v2 published with requires_resignature false -- that is the typo
    -- fix case. Somebody who has never signed anything always needs to.
    'needs_signature', case
      when a.id is null            then false
      when v_signed_at is not null then false
      when a.requires_resignature  then true
      else not coalesce(v_any, false)
    end
  );
end;
$fn$;

comment on function app.membership_state(uuid) is
  'One answer to "is this member current on the agreement", shared by the gate, the UI prompt '
  'and the admin report so they cannot disagree.';

-- ---------------------------------------------------------------------------
-- Would the gate stop this member acting?
--
-- Two conditions, both required. The setting alone is not enough: switching `membership.required`
-- on with no published agreement would lock every member out of the product with no way for any
-- of them to fix it, so the absence of an agreement holds the gate open regardless.
-- ---------------------------------------------------------------------------

create or replace function app.membership_gate_blocks(p_user uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_required boolean;
  v_state    jsonb;
begin
  select coalesce((value #>> '{}')::boolean, false) into v_required
    from public.app_settings where key = 'membership.required';

  if not coalesce(v_required, false) then
    return false;
  end if;

  v_state := app.membership_state(p_user);

  return (v_state ->> 'has_agreement')::boolean
     and not (v_state ->> 'signed')::boolean;
end;
$fn$;

comment on function app.membership_gate_blocks(uuid) is
  'True when this member must sign before acting. Requires BOTH the setting and a published, '
  'effective agreement -- turning the setting on alone cannot lock anybody out.';

-- ---------------------------------------------------------------------------
-- Read the agreement
-- ---------------------------------------------------------------------------

create or replace function public.membership_agreement()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  uid uuid := auth.uid();
  a   public.membership_agreements%rowtype;
  v_required boolean;
begin
  select * into a from public.membership_agreements
   where is_current and effective_at is not null and effective_at <= now()
   limit 1;

  select coalesce((value #>> '{}')::boolean, false) into v_required
    from public.app_settings where key = 'membership.required';

  return jsonb_build_object(
    'ok', true,
    -- Whether the gate is armed. The UI needs it to choose between "you must sign to continue"
    -- and "please review and sign", and saying the wrong one is a lie either way.
    'required', coalesce(v_required, false),
    'agreement', case when a.id is null then null else jsonb_build_object(
      'id',         a.id,
      'version',    a.version,
      'body_en',    a.body_en,
      'body_es',    a.body_es,
      -- Sent so the client can echo it back when signing. That round trip is what proves the
      -- member signed the text they were actually shown, rather than whatever happens to be
      -- current by the time the form is submitted.
      'body_hash',  a.body_hash,
      'effective_at', a.effective_at
    ) end,
    'state', app.membership_state(uid)
  );
end;
$fn$;

comment on function public.membership_agreement() is
  'The current agreement plus the caller''s standing. Anon-readable: registration shows the full '
  'text before an account exists.';

-- ---------------------------------------------------------------------------
-- Sign it
-- ---------------------------------------------------------------------------

create or replace function public.sign_membership_agreement(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_user      uuid := nullif(p_payload ->> 'user_id', '')::uuid;
  v_legal     text := nullif(btrim(coalesce(p_payload ->> 'legal_name', '')), '');
  v_signature text := nullif(btrim(coalesce(p_payload ->> 'signature_text', '')), '');
  v_hash      text := nullif(btrim(coalesce(p_payload ->> 'body_hash', '')), '');
  v_locale    text := coalesce(nullif(p_payload ->> 'locale', ''), 'en');
  v_via       text := coalesce(nullif(p_payload ->> 'signed_via', ''), 'web');
  a           public.membership_agreements%rowtype;
  v_row       public.membership_signatures%rowtype;
begin
  if v_user is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  select * into a from public.membership_agreements
   where is_current and effective_at is not null and effective_at <= now()
   limit 1;

  if a.id is null then
    return jsonb_build_object('ok', false, 'error', 'no_agreement');
  end if;

  -- The member signed what they were shown, or they signed nothing. If an admin published a new
  -- version while this form sat open, the hash no longer matches, and the answer is to re-read
  -- it -- not to record consent to words that were never on screen.
  if v_hash is distinct from a.body_hash then
    return jsonb_build_object('ok', false, 'error', 'agreement_changed', 'version', a.version);
  end if;

  if v_legal is null or length(v_legal) < 2 then
    return jsonb_build_object('ok', false, 'error', 'legal_name_required');
  end if;

  if v_signature is null or length(v_signature) < 2 then
    return jsonb_build_object('ok', false, 'error', 'signature_required');
  end if;

  -- Requirement 4: the typed signature IS the legal name. Compared case- and whitespace-
  -- insensitively, because "juan  serra" is the same person being slightly imprecise rather than
  -- somebody signing a different name.
  if lower(regexp_replace(v_legal, '\s+', ' ', 'g'))
     is distinct from lower(regexp_replace(v_signature, '\s+', ' ', 'g')) then
    return jsonb_build_object('ok', false, 'error', 'signature_mismatch');
  end if;

  -- Idempotent. A double submit, or a retry after a dropped response, must not write a second
  -- row or move the timestamp on the first -- the original signing time is the fact worth
  -- keeping.
  select * into v_row from public.membership_signatures
   where user_id = v_user and agreement_version = a.version;

  if found then
    return jsonb_build_object(
      'ok', true, 'replayed', true,
      'signature_id', v_row.id, 'version', a.version, 'signed_at', v_row.signed_at
    );
  end if;

  insert into public.membership_signatures (
    user_id, agreement_id, agreement_version, body_hash,
    legal_name, signature_text, locale,
    signed_ip, signed_user_agent, signed_via
  ) values (
    v_user, a.id, a.version, a.body_hash,
    v_legal, v_signature,
    case when v_locale in ('en', 'es') then v_locale else 'en' end,
    nullif(p_payload ->> 'ip', '')::inet,
    nullif(btrim(coalesce(p_payload ->> 'user_agent', '')), ''),
    v_via
  )
  returning * into v_row;

  return jsonb_build_object(
    'ok', true, 'replayed', false,
    'signature_id', v_row.id, 'version', a.version, 'signed_at', v_row.signed_at
  );
end;
$fn$;

comment on function public.sign_membership_agreement(jsonb) is
  'Records a membership signature. service_role only -- reached through a server action so the '
  'IP and user agent are derived, not supplied by the signer.';

-- ---------------------------------------------------------------------------
-- Grants
--
-- EVERY NEW FUNCTION IN THIS DATABASE IS BORN EXECUTABLE BY anon.
--
-- Supabase ships `alter default privileges in schema public grant execute on functions to anon,
-- authenticated, service_role`, so a function is reachable from an unauthenticated browser the
-- moment it is created. Those are direct grants to those roles: `revoke ... from public` does
-- NOT remove them, which is the trap, because it reads as though it does.
--
-- 20260920000700 does a blanket `revoke execute on all functions in schema public from anon,
-- authenticated`, but that ran once, against the functions that existed then. Anything added
-- afterwards -- including these -- has to revoke for itself, by name.
--
-- The pgTAP suite asserts the outcome rather than trusting the revoke, which is how this was
-- caught in the first place.
-- ---------------------------------------------------------------------------

revoke all on function public.membership_agreement() from public, anon, authenticated;
-- Genuinely open: registration has to show the text before an account exists.
grant execute on function public.membership_agreement() to anon, authenticated, service_role;

revoke all on function public.sign_membership_agreement(jsonb) from public, anon, authenticated;
-- service_role only. Not anon, and deliberately not `authenticated` either: see the header.
grant execute on function public.sign_membership_agreement(jsonb) to service_role;

notify pgrst, 'reload schema';
