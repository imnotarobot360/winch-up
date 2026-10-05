-- Recovery Architecture V2: every active WINCH-UP member is a potential helper.
--
-- Owner decision (2026-10-05): universal membership is the source of truth. A member does not
-- need admin approval or a recurring "available to help" opt-in to be geographically eligible.
-- Moderation/suspension, an explicit pause, missing usable location, blocking, requester exclusion,
-- equipment/radius constraints and active-job capacity still apply.
--
-- Notification CHANNEL consent is evaluated after geographic matching. SMS consent never controls
-- candidate eligibility. Email and push may still reach the same selected helper.

set search_path = public, extensions;

-- Remove the two obsolete candidate gates added/reintroduced by the old volunteer model:
--   profiles.available_to_help
--   responders.approval = 'approved'
--
-- Patch the LIVE function so later safety/location/equipment work is preserved.
do $mig$
declare
  src text;
  old_available text;
  hits int;
begin
  src := pg_get_functiondef('app.candidates(uuid, integer, integer)'::regprocedure);

  -- Remove approval gate if present. Pending members are members and can help. Banned/suspended
  -- accounts remain protected by the existing suspension/moderation path.
  src := replace(src, E'\n    and r.approval = ''approved''', '');

  -- Remove the universal-membership era willingness gate. This exact block is intentionally
  -- matched as emitted by pg_get_functiondef (comments are not part of pg_get_functiondef).
  old_available := E'\n    AND CASE\n            WHEN (r.user_id IS NULL) THEN true\n            ELSE COALESCE(( SELECT p.available_to_help\n               FROM profiles p\n              WHERE (p.user_id = r.user_id)), false)\n        END';

  if position(old_available in src) > 0 then
    src := replace(src, old_available, '');
  else
    -- PostgreSQL versions/pretty-printers can vary. Fall back to a narrow regex deleting only
    -- the CASE expression that reads profiles.available_to_help.
    src := regexp_replace(
      src,
      E'\\n\\s+and case\\s+when r\\.user_id is null then true\\s+else coalesce\\(\\s*\\(select p\\.available_to_help from public\\.profiles p where p\\.user_id = r\\.user_id\\),\\s*false\\s*\\)\\s+end',
      '',
      'i'
    );
  end if;

  -- If available_to_help is still in the matcher, fail instead of silently deploying a half-fix.
  if position('available_to_help' in src) > 0 then
    raise exception 'Recovery V2 refused: available_to_help still appears in app.candidates()';
  end if;
  if position('r.approval = ''approved''' in src) > 0 then
    raise exception 'Recovery V2 refused: approval gate still appears in app.candidates()';
  end if;

  execute src;
end
$mig$;

-- Manual dispatch follows the same membership rule. An admin selecting a member must not be
-- blocked merely because the old volunteer approval field is pending.
do $manual$
declare
  src text;
begin
  src := pg_get_functiondef('public.admin_manual_dispatch(uuid, uuid)'::regprocedure);

  src := regexp_replace(
    src,
    E'\\n\\s*if resp\\.approval <> ''approved'' then\\s*return jsonb_build_object\\(''ok'', false, ''error'', ''not_approved'',\\s*''approval'', resp\\.approval\\);\\s*end if;',
    '',
    'i'
  );

  if position('resp.approval <> ''approved''' in src) > 0 then
    raise exception 'Recovery V2 refused: approval gate still appears in admin_manual_dispatch()';
  end if;

  execute src;
end
$manual$;

-- Existing profiles no longer need the old willingness flag. Keep the column for backward
-- compatibility for now, but normalize it so old UI/data cannot imply that false means ineligible.
update public.profiles
   set available_to_help = true,
       updated_at = now()
 where available_to_help = false
   and suspended_at is null;

comment on column public.profiles.available_to_help is
  'Legacy compatibility flag. Recovery V2 does NOT use this for candidate eligibility. Use the '
  'recovery-alert pause/notification controls instead.';

notify pgrst, 'reload schema';

-- Fail-fast verification.
do $verify$
declare
  c text := pg_get_functiondef('app.candidates(uuid, integer, integer)'::regprocedure);
  m text := pg_get_functiondef('public.admin_manual_dispatch(uuid, uuid)'::regprocedure);
begin
  if position('available_to_help' in c) > 0 then
    raise exception 'verification failed: candidate matcher still uses available_to_help';
  end if;
  if position('r.approval = ''approved''' in c) > 0 then
    raise exception 'verification failed: automatic dispatch still requires approval';
  end if;
  if position('resp.approval <> ''approved''' in m) > 0 then
    raise exception 'verification failed: manual dispatch still requires approval';
  end if;
  if position('sms_opt_in' in c) > 0 then
    raise exception 'verification failed: SMS consent leaked into candidate eligibility';
  end if;
end
$verify$;
