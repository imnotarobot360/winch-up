-- /join and the account screen can now ASK about recovery SMS, which they could not before.
--
-- 20261004000200 made responders.sms_opt_in default false: a verified phone is not consent. That
-- left a hole on the way IN. upsert_responder_profile -- the only way a member creates or edits a
-- recovery profile -- never read sms_opt_in from its payload, so under the new default a member who
-- joins is opted out with no way to say otherwise.
--
-- THE FIELD WAS ALREADY BEING SENT AND SILENTLY DROPPED. lifecycle_test has passed
-- 'sms_opt_in', true in its payload since it was written, and the assertion that a text is queued
-- passed because the COLUMN defaulted to true, not because the payload did anything. A decorative
-- field in a consent payload is worse than a missing one: to anybody adding a screen it reads as
-- though asking the question is already wired up.
--
-- Two different rules for one field, deliberately:
--   INSERT  absent means FALSE.     A missing answer is not a yes.
--   UPDATE  absent means UNCHANGED. Editing a radius must not withdraw consent -- the same
--           reasoning as the phone coalesce this function already carries.
--
-- The body below is EXTRACTED from 20260928000800 and extended, not retyped: a create-or-replace of
-- a hundred-line function is how an earlier migration here silently reverted a later one.

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
$fn$;

-- The signature is unchanged, so this is belt and braces rather than strictly required -- but a
-- replaced body is exactly the case where a stale cache is hardest to spot, because the function
-- still answers and simply behaves like its old self.
notify pgrst, 'reload schema';

-- Did the signature survive, and does the body now mention the column? Two cheap facts, because a
-- create-or-replace that quietly dropped a branch still reports CREATE FUNCTION.
select
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'upsert_responder_profile')             as fn_count,
  strpos(pg_get_functiondef(
    (select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'upsert_responder_profile' limit 1)),
    'sms_opt_in') > 0                                                                 as honours_consent;
