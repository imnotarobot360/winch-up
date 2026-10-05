-- A phone verified AFTER sign-in must still reach the volunteer profile.
--
-- upsert_responder_profile took the number from `auth.jwt() ->> 'phone'`, and a JWT is a snapshot
-- taken when the session was issued. Verify a phone mid-session and the token carries no phone
-- claim until it refreshes -- so the claim was null, the coalesce kept the existing null, and the
-- save reported success having written no number.
--
-- The member is then left believing they are reachable while the dispatcher has nothing to text,
-- with no error on any screen. It happened to the owner's own account on 2026-10-05: account phone
-- verified, volunteer profile empty, and the only way to see it was a database query. They were
-- the single volunteer on call in production at the time.
--
-- THE SECURITY PROPERTY IS UNCHANGED. The number still never comes from the form -- a
-- browser-supplied one would let anyone sign up as somebody else and be sent their recoveries.
-- The fallback reads auth.users for the CALLER'S OWN uid and only when phone_confirmed_at is set:
-- server-side truth, not input. The claim stays the primary, so nothing changes for a session that
-- already carries one; it is only consulted when the cache is stale.
--
-- The screen that reported this honestly is docs/who-covers.sql, and the one that will now explain
-- it to the member is /account/notifications -- but neither should have been necessary.
--
-- Body read out of the live database rather than copied from a file.

set search_path = public, extensions;

CREATE OR REPLACE FUNCTION public.upsert_responder_profile(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  uid       uuid := auth.uid();
  claim     text := auth.jwt() ->> 'phone';
  me        public.responders%rowtype;
  v_phone   text;
  v_lat     double precision := (p_payload ->> 'lat')::double precision;
  v_lng     double precision := (p_payload ->> 'lng')::double precision;
  v_equip   equipment_type[];
begin
  if uid is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  -- Still never the form. A number supplied by the browser would let anyone sign up as somebody
  -- else and be sent their recoveries. That has never changed and must not.
  --
  -- BUT THE CLAIM IS A CACHE, AND auth.users IS THE TRUTH. A JWT is a snapshot taken when the
  -- session was issued, so a member who verifies a phone AFTER signing in carries a token with no
  -- phone claim until it refreshes. Saving /join then wrote no number, kept the existing null
  -- through the coalesce below, and reported success -- and the member was left believing they
  -- were reachable while the dispatcher had nothing to text. That is exactly what happened to the
  -- owner's own account on 2026-10-05: account_phone_verified true, on_volunteer_profile false,
  -- and no error anywhere.
  --
  -- The fallback reads the SERVER's record for the caller's own uid, and only when it is
  -- CONFIRMED. It is not browser input and cannot be spoofed -- which is the property the claim
  -- was protecting, kept intact while the staleness goes.
  v_phone := case when claim ~ '^[0-9]{11}$' then '+' || claim else claim end;
  v_phone := nullif(btrim(coalesce(v_phone, '')), '');

  if v_phone is null then
    select u.phone into v_phone
      from auth.users u
     where u.id = uid
       and u.phone_confirmed_at is not null;

    v_phone := nullif(btrim(coalesce(v_phone, '')), '');
    if v_phone is not null and left(v_phone, 1) <> '+' then
      v_phone := '+' || v_phone;
    end if;
  end if;

  -- Present but malformed is refused whether this is an insert or an update.
  if v_phone is not null and v_phone !~ '^\+1[0-9]{10}$' then
    return jsonb_build_object('ok', false, 'error', 'no_verified_phone');
  end if;

  if v_phone is not null
     and exists (select 1 from public.blocklist b where b.phone = v_phone) then
    return jsonb_build_object('ok', false, 'error', 'blocked');
  end if;

  if v_lat is null or v_lng is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_location');
  end if;

  select coalesce(array_agg(value::equipment_type), '{}'::equipment_type[])
    into v_equip
    from jsonb_array_elements_text(coalesce(p_payload -> 'equipment', '[]'::jsonb));

  select * into me from public.responders
   where user_id = uid
      or (v_phone is not null and phone = v_phone)
   order by (user_id = uid) desc
   limit 1;

  if found then
    update public.responders
       set user_id            = uid,
           -- coalesce, not assignment: a member who verified a number once must not lose it by
           -- editing their profile in a session whose JWT has no phone claim. This is also what
           -- lets a member who joined without one keep using their account.
           phone              = coalesce(v_phone, phone),
           first_name         = coalesce(nullif(btrim(p_payload ->> 'first_name'), ''), first_name),
           last_name          = nullif(btrim(coalesce(p_payload ->> 'last_name', '')), ''),
           locale             = coalesce(nullif(p_payload ->> 'locale', ''), locale),
           home_location      = extensions.st_setsrid(extensions.st_point(v_lng, v_lat), 4326)::extensions.geography,
           home_address_text  = nullif(btrim(coalesce(p_payload ->> 'home_address_text', '')), ''),
           radius_miles       = coalesce((p_payload ->> 'radius_miles')::integer, radius_miles),
           equipment          = v_equip,
           vehicle_class      = coalesce(nullif(p_payload ->> 'vehicle_class', '')::vehicle_class, vehicle_class),
           vehicle_desc       = nullif(btrim(coalesce(p_payload ->> 'vehicle_desc', '')), ''),
           drivetrain         = coalesce(nullif(p_payload ->> 'drivetrain', '')::drivetrain, drivetrain),
           night_ok           = coalesce((p_payload ->> 'night_ok')::boolean, night_ok),
           always_available   = coalesce((p_payload ->> 'always_available')::boolean, always_available),
           availability_hours = coalesce(p_payload -> 'availability_hours', availability_hours),
           -- COALESCE, like phone above and for the same reason: a payload that omits the field
           -- must not withdraw a consent the member gave. Only an explicit false withdraws it.
           sms_opt_in         = coalesce((p_payload ->> 'sms_opt_in')::boolean, sms_opt_in),
           -- Granting consent clears the STOP stamp, because a trigger forbids holding both.
           sms_opt_out_at     = case
                                  when coalesce((p_payload ->> 'sms_opt_in')::boolean, sms_opt_in)
                                    then null
                                  else sms_opt_out_at
                                end
     where id = me.id
     returning * into me;
  else
    -- THE DOOR. A new member must have verified a number to get through it.
    if v_phone is null then
      return jsonb_build_object('ok', false, 'error', 'phone_required');
    end if;

    insert into public.responders (
      user_id, phone, first_name, last_name, locale,
      home_location, home_address_text, radius_miles,
      equipment, vehicle_class, vehicle_desc, drivetrain, night_ok, always_available,
      sms_opt_in
    ) values (
      uid, v_phone,
      btrim(p_payload ->> 'first_name'),
      nullif(btrim(coalesce(p_payload ->> 'last_name', '')), ''),
      coalesce(nullif(p_payload ->> 'locale', ''), 'en'),
      extensions.st_setsrid(extensions.st_point(v_lng, v_lat), 4326)::extensions.geography,
      nullif(btrim(coalesce(p_payload ->> 'home_address_text', '')), ''),
      coalesce((p_payload ->> 'radius_miles')::integer, 30),
      v_equip,
      coalesce(nullif(p_payload ->> 'vehicle_class', '')::vehicle_class, 'truck'),
      nullif(btrim(coalesce(p_payload ->> 'vehicle_desc', '')), ''),
      coalesce(nullif(p_payload ->> 'drivetrain', ''), '4wd')::drivetrain,
      coalesce((p_payload ->> 'night_ok')::boolean, true),
      coalesce((p_payload ->> 'always_available')::boolean, true),
      -- FALSE when the payload is silent, which is the opposite of every other default here.
      -- Those are conveniences; this one is consent, and a missing answer is not a yes.
      coalesce((p_payload ->> 'sms_opt_in')::boolean, false)
    )
    returning * into me;
  end if;

  return jsonb_build_object(
    'ok', true,
    'responder_id', me.id,
    'approval', me.approval,
    'availability', me.availability,
    -- Still reported, because a member who joined during the optional window may not have one
    -- and the UI needs to be able to say so rather than implying they will be texted.
    'has_phone', me.phone is not null
  );
end;
$function$;

notify pgrst, 'reload schema';

select
  strpos(pg_get_functiondef('public.upsert_responder_profile(jsonb)'::regprocedure),
         'phone_confirmed_at is not null') > 0                        as falls_back_to_auth_users,
  -- The two properties that must survive: the form is never trusted, and editing a profile
  -- without a phone to hand does not blank the one already stored.
  strpos(pg_get_functiondef('public.upsert_responder_profile(jsonb)'::regprocedure),
         'auth.jwt() ->> ''phone''') > 0                              as claim_still_primary,
  strpos(pg_get_functiondef('public.upsert_responder_profile(jsonb)'::regprocedure),
         'phone              = coalesce(v_phone, phone)') > 0         as never_blanks_a_phone,
  strpos(pg_get_functiondef('public.upsert_responder_profile(jsonb)'::regprocedure),
         'sms_opt_in') > 0                                            as consent_handling_intact;
