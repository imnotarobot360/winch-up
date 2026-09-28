-- Winch Up :: a phone number is required again, for new members only
--
-- 20260928000100 made it optional because Supabase Auth's SMS was not configured, nobody could
-- verify a number, and so nobody could become a volunteer at all. That is fixed: the A2P
-- campaign is approved, Twilio is configured in both places, and a verification code was
-- delivered to a real handset on 2026-09-28.
--
-- So the reason for the exception is gone, and the cost it named is worth reversing:
-- public.blocklist is keyed by phone, and a member with no number cannot be blocklisted that
-- way.
--
-- NEW MEMBERS ONLY. THE UPDATE PATH STILL ACCEPTS A MISSING NUMBER.
--
-- The requirement is enforced where the row is CREATED, not on every save. A member who joined
-- during the window when phones were optional can still edit their profile, change their radius
-- and turn their availability on and off; they are prompted to add a number, not locked out of
-- the account they already have. Enforcing it on update would mean a volunteer who joined last
-- week discovering, mid-recovery, that they cannot change their own availability.
--
-- Same shape as the membership agreement: required at the door, prompted afterwards, and the
-- path to asking for help is never blocked.

set search_path = public, extensions;

create or replace function public.upsert_responder_profile(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
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

  -- Still the verified claim, never the form. A number supplied by the browser would let anyone
  -- sign up as somebody else and be sent their recoveries. This has never changed and must not.
  v_phone := case when claim ~ '^[0-9]{11}$' then '+' || claim else claim end;
  v_phone := nullif(btrim(coalesce(v_phone, '')), '');

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
           availability_hours = coalesce(p_payload -> 'availability_hours', availability_hours)
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
      equipment, vehicle_class, vehicle_desc, drivetrain, night_ok, always_available
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
      coalesce((p_payload ->> 'always_available')::boolean, true)
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
$fn$;

-- Supabase's default privileges re-grant execute to anon on every CREATE, and `create or
-- replace` is a create. See 20260928000300.
revoke all on function public.upsert_responder_profile(jsonb) from public, anon;
grant execute on function public.upsert_responder_profile(jsonb) to authenticated, service_role;

notify pgrst, 'reload schema';
