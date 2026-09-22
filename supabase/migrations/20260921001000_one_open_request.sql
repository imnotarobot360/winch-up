-- Winch Up :: one open recovery per account
--
-- Phase 5 asks for duplicate active requests to be prevented. submission_id already catches a
-- retried submit of the same form; this catches the different case of somebody filling the form
-- again because they lost the status link, or because a bad connection left them unsure the
-- first one went through.
--
-- It hands back the existing request instead of refusing. A refusal tells someone who is stuck
-- that they have done something wrong; returning their link gives them the thing they were
-- looking for. The client already treats a replayed response as success and lands on the status
-- page, so this needed no UI change -- existing_open is there for a later screen that wants to
-- say "you already have one open" rather than simply showing it.
--
-- Checked after the account requirement and before the phone format check, so that a request
-- with a malformed phone still fails on the phone rather than being silently absorbed.

set search_path = public, extensions;

create or replace function public.create_request(p_payload jsonb, p_site_url text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_submission_id uuid   := nullif(p_payload ->> 'submission_id', '')::uuid;
  v_phone         text   := btrim(p_payload ->> 'phone');
  v_locale        text   := coalesce(nullif(p_payload ->> 'locale', ''), 'en');
  v_ip            inet   := nullif(p_payload ->> 'ip', '')::inet;
  v_lat           double precision := (p_payload ->> 'lat')::double precision;
  v_lng           double precision := (p_payload ->> 'lng')::double precision;
  v_user_id       uuid   := nullif(p_payload ->> 'requester_user_id', '')::uuid;
  v_waiver_id     uuid;
  v_existing      public.requests%rowtype;
  v_open          public.requests%rowtype;
  v_request       public.requests%rowtype;
  v_photo         jsonb;
  v_max_phone     integer;
  v_max_ip        integer;
  v_url           text;
begin
  -- Replay of a retried submit: hand back the same request instead of making a second one.
  if v_submission_id is not null then
    select * into v_existing from public.requests where submission_id = v_submission_id;
    if found then
      return jsonb_build_object(
        'ok', true, 'replayed', true,
        'request_id', v_existing.id,
        'token', v_existing.public_token,
        'short_code', v_existing.short_code
      );
    end if;
  end if;

  -- A request belongs to an account. Checked after the replay guard so a retried submit still
  -- returns the original request rather than failing differently the second time.
  if v_user_id is null then
    return jsonb_build_object('ok', false, 'error', 'account_required');
  end if;

  -- One open recovery per account.
  --
  -- The per-phone rate limit allows three a day, which is right for "stuck again on Sunday"
  -- and wrong for three at once: each would dispatch separately and send volunteers to the
  -- same truck three times. Someone who submits twice has usually lost the link, or is on a
  -- bad connection and unsure the first one went through, so hand back the request they
  -- already have rather than refusing them. Only open states block; once recovered, cancelled
  -- or expired they can file again.
  select * into v_open
    from public.requests
   where requester_user_id = v_user_id
     and status in ('submitted', 'dispatching', 'unmatched', 'accepted', 'on_site')
   order by created_at desc
   limit 1;

  if found then
    return jsonb_build_object(
      'ok', true, 'replayed', true, 'existing_open', true,
      'request_id', v_open.id,
      'token', v_open.public_token,
      'short_code', v_open.short_code
    );
  end if;

  if v_phone is null or v_phone !~ '^\+1[0-9]{10}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_phone');
  end if;

  if v_lat is null or v_lng is null
     or v_lat not between -90 and 90 or v_lng not between -180 and 180 then
    return jsonb_build_object('ok', false, 'error', 'invalid_location');
  end if;

  if exists (
    select 1 from public.blocklist b
     where (b.phone is not null and b.phone = v_phone)
        or (b.ip is not null and v_ip is not null and b.ip = v_ip)
  ) then
    return jsonb_build_object('ok', false, 'error', 'blocked');
  end if;

  select coalesce((value #>> '{}')::integer, 3) into v_max_phone
    from public.app_settings where key = 'limits.max_requests_per_phone_per_day';
  select coalesce((value #>> '{}')::integer, 5) into v_max_ip
    from public.app_settings where key = 'limits.max_requests_per_ip_per_hour';

  if not app.check_rate_limit('request:phone:' || v_phone, coalesce(v_max_phone, 3), interval '24 hours') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited_phone');
  end if;

  if v_ip is not null
     and not app.check_rate_limit('request:ip:' || host(v_ip), coalesce(v_max_ip, 5), interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited_ip');
  end if;

  select id into v_waiver_id
    from public.waivers where slug = 'requester_waiver' and is_current;

  if v_waiver_id is null then
    raise exception 'no current requester_waiver row: run supabase/seed.sql';
  end if;

  insert into public.requests (
    submission_id, locale, requester_user_id,
    requester_name, requester_phone,
    location, location_accuracy_m, location_source, location_note, county,
    vehicle_class, vehicle_make, vehicle_model, vehicle_year, drivetrain,
    stuck_type, stuck_depth, needs_tractor, needs_second_truck,
    land_type, land_permission_note, notes,
    emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at,
    waiver_ip, waiver_user_agent, created_ip, created_user_agent,
    next_action_at
  ) values (
    v_submission_id,
    case when v_locale in ('en', 'es') then v_locale else 'en' end,
    v_user_id,
    btrim(p_payload ->> 'name'),
    v_phone,
    extensions.st_setsrid(extensions.st_point(v_lng, v_lat), 4326)::extensions.geography,
    nullif(p_payload ->> 'accuracy_m', '')::numeric,
    coalesce(nullif(p_payload ->> 'location_source', ''), 'gps')::location_source,
    nullif(btrim(coalesce(p_payload ->> 'location_note', '')), ''),
    nullif(btrim(coalesce(p_payload ->> 'county', '')), ''),
    (p_payload ->> 'vehicle_class')::vehicle_class,
    nullif(btrim(coalesce(p_payload ->> 'vehicle_make', '')), ''),
    nullif(btrim(coalesce(p_payload ->> 'vehicle_model', '')), ''),
    nullif(p_payload ->> 'vehicle_year', '')::smallint,
    coalesce(nullif(p_payload ->> 'drivetrain', ''), 'unknown')::drivetrain,
    (p_payload ->> 'stuck_type')::stuck_type,
    nullif(p_payload ->> 'stuck_depth', '')::stuck_depth,
    coalesce((p_payload ->> 'needs_tractor')::boolean, false),
    coalesce((p_payload ->> 'needs_second_truck')::boolean, false),
    (p_payload ->> 'land_type')::land_type,
    nullif(btrim(coalesce(p_payload ->> 'land_permission_note', '')), ''),
    nullif(btrim(coalesce(p_payload ->> 'notes', '')), ''),
    now(), true, v_waiver_id, now(),
    v_ip, nullif(p_payload ->> 'user_agent', ''), v_ip, nullif(p_payload ->> 'user_agent', ''),
    -- The 60 s tick picks this up immediately and starts ring 1.
    now()
  )
  returning * into v_request;

  for v_photo in select * from jsonb_array_elements(coalesce(p_payload -> 'photos', '[]'::jsonb))
  loop
    begin
      insert into public.request_photos (request_id, storage_path, content_type, bytes, width, height, sort_order)
      values (
        v_request.id,
        v_photo ->> 'path',
        coalesce(nullif(v_photo ->> 'content_type', ''), 'image/jpeg'),
        nullif(v_photo ->> 'bytes', '')::integer,
        nullif(v_photo ->> 'width', '')::integer,
        nullif(v_photo ->> 'height', '')::integer,
        coalesce(nullif(v_photo ->> 'sort_order', '')::smallint, 0)
      );
    exception when others then
      -- A photo that will not attach must never cost someone their recovery request.
      raise notice 'create_request: skipped photo % (%)', v_photo ->> 'path', sqlerrm;
    end;
  end loop;

  v_url := rtrim(coalesce(p_site_url, ''), '/') || '/r/' || v_request.public_token;

  perform app.queue_sms(
    v_request.requester_phone,
    'requester.created',
    jsonb_build_object('short_code', v_request.short_code, 'url', v_url),
    v_request.locale,
    v_request.id
  );

  return jsonb_build_object(
    'ok', true, 'replayed', false,
    'request_id', v_request.id,
    'token', v_request.public_token,
    'short_code', v_request.short_code,
    'status_url', v_url
  );
end;
$$;
