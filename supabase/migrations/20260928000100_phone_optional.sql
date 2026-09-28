-- Winch Up :: a volunteer can sign up before SMS works
--
-- upsert_responder_profile refused any signup without a verified phone claim. That was right
-- while phone OTP was the only way in, and it is wrong now: Supabase Auth's SMS is not
-- configured, so nobody can verify a number, so nobody can become a volunteer at all. The
-- product's one remaining launch blocker is that there are no volunteers, and the signup path
-- for them is closed.
--
-- WHAT IS NOT CHANGING
--
-- The rule that a phone must come from the verified JWT claim, never from the form. That exists
-- so nobody can register somebody else's number and receive their dispatches, and it is intact:
-- a phone that IS present still has to be the verified one. What changes is that having none is
-- now allowed rather than fatal.
--
-- A volunteer with no phone is already a coherent thing everywhere else. app.candidates() filters
-- on approval, availability and sms_opt_in and never looks at the phone; app.queue_sms returns
-- early on a null number, so a call-out to them writes no row and raises nothing. They are
-- reachable by push and in-app, which is how recovery messages are carried anyway -- the SMS
-- allowlist ships with only the dispatch call-out on it.
--
-- THE ONE REAL COST, NAMED
--
-- public.blocklist is keyed by phone. A volunteer with no phone cannot be blocklisted that way.
-- Banning them means setting approval = 'banned' on their responder row, which an admin can do
-- and which app.candidates() honours. Worth knowing before this is left on permanently.

set search_path = public, extensions;

create or replace function public.upsert_responder_profile(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
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
  -- sign up as somebody else and be sent their recoveries.
  v_phone := case when claim ~ '^[0-9]{11}$' then '+' || claim else claim end;
  v_phone := nullif(btrim(coalesce(v_phone, '')), '');

  -- Present but malformed is still refused. Absent is now allowed.
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

  -- The phone half of this lookup is guarded: `phone = null` is never true, but writing it out
  -- says the match is by account when there is no number, rather than leaving a reader to work
  -- out why a null comparison was safe.
  select * into me from public.responders
   where user_id = uid
      or (v_phone is not null and phone = v_phone)
   order by (user_id = uid) desc
   limit 1;

  if found then
    update public.responders
       set user_id            = uid,
           -- coalesce, not assignment: a member who verified a number once must not lose it by
           -- editing their profile in a session whose JWT has no phone claim.
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
      coalesce(nullif(p_payload ->> 'drivetrain', '')::drivetrain, '4wd'),
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
    -- So the UI can say "we cannot text you" rather than the member assuming they will be.
    'has_phone', me.phone is not null
  );
end;
$$;
