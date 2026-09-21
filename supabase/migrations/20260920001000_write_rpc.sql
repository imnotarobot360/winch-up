-- Winch Up M2 :: write RPCs
--
-- Everything a requester can do to their own request, plus the SMS outbox claim used by the
-- sender. All of these are service-role only: they are called from Next.js server actions, never
-- from the browser. That is deliberate — the caller supplies the IP address used for rate
-- limiting, so it has to be a value the server derived, not one the client can choose.
--
-- The dispatch state machine (start dispatch, rings, accept, decline) is M3. These functions
-- only cover create / cancel / on-site-by-requester / recovered / thank you.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- Idempotency for submissions
--
-- A stranded driver on one bar of signal taps Send, sees nothing happen, and taps again. That
-- must not produce two requests and two dispatch storms.
-- ---------------------------------------------------------------------------

alter table requests add column if not exists submission_id uuid;

create unique index if not exists requests_submission_id_idx
  on requests (submission_id) where submission_id is not null;

-- ---------------------------------------------------------------------------
-- Outbox helper
--
-- SQL never writes message copy. It queues a template key plus params; the sender renders the
-- text in the recipient's own language.
-- ---------------------------------------------------------------------------

create or replace function app.queue_sms(
  p_to_phone     text,
  p_template_key text,
  p_params       jsonb default '{}'::jsonb,
  p_locale       text default 'en',
  p_request_id   uuid default null,
  p_responder_id uuid default null,
  p_dispatch_id  uuid default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  new_id uuid;
begin
  if p_to_phone is null then
    return null;
  end if;

  insert into public.sms_messages (
    direction, state, to_phone, template_key, params, locale,
    request_id, responder_id, dispatch_id
  ) values (
    'outbound', 'queued', p_to_phone, p_template_key, coalesce(p_params, '{}'::jsonb),
    case when p_locale in ('en', 'es') then p_locale else 'en' end,
    p_request_id, p_responder_id, p_dispatch_id
  )
  returning id into new_id;

  return new_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- create_request
--
-- One transaction: rate limit, blocklist, insert, attach photos, queue the requester's SMS.
-- Returns a structured result rather than raising for the two failures the UI has real copy for
-- (rate limited, blocked), so the wizard can say something useful instead of "error".
-- ---------------------------------------------------------------------------

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
  v_waiver_id     uuid;
  v_existing      public.requests%rowtype;
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
    submission_id, locale,
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

-- ---------------------------------------------------------------------------
-- Rate limit wrapper
--
-- `app.check_rate_limit` lives in the private schema, which supabase-js cannot reach (PostgREST
-- only exposes `public`). This is the thin public door for the photo-upload endpoint, which has
-- to be throttled before a request row exists.
-- ---------------------------------------------------------------------------

create or replace function public.check_rate_limit(
  p_key           text,
  p_max           integer,
  p_window_seconds integer
)
returns boolean
language sql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
  select app.check_rate_limit(
    p_key,
    greatest(1, p_max),
    make_interval(secs => greatest(1, p_window_seconds))
  );
$$;

-- ---------------------------------------------------------------------------
-- Requester actions on their own request, authorised by the token alone
-- ---------------------------------------------------------------------------

create or replace function public.cancel_request_by_token(p_token text, p_reason text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  r public.requests%rowtype;
begin
  select * into r from public.requests where public_token = p_token for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if r.status in ('recovered', 'cancelled', 'expired') then
    return jsonb_build_object('ok', false, 'error', 'already_closed', 'status', r.status);
  end if;

  update public.requests
     set status        = 'cancelled',
         cancelled_at  = now(),
         cancel_reason = nullif(btrim(coalesce(p_reason, '')), ''),
         next_action_at = null
   where id = r.id
   returning * into r;

  -- Stop anyone who is still driving toward them.
  update public.dispatches
     set state = 'superseded'
   where request_id = r.id
     and state in ('queued', 'sent', 'delivered');

  if r.accepted_responder_id is not null then
    perform app.queue_sms(
      resp.phone, 'responder.job_cancelled',
      jsonb_build_object('short_code', r.short_code),
      resp.locale, r.id, resp.id
    )
    from public.responders resp where resp.id = r.accepted_responder_id;
  end if;

  return jsonb_build_object('ok', true, 'status', r.status);
end;
$$;

create or replace function public.mark_recovered_by_token(p_token text, p_thank_you text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  r    public.requests%rowtype;
  note text := nullif(btrim(coalesce(p_thank_you, '')), '');
begin
  if note is not null and public.contains_contact_info(note) then
    return jsonb_build_object('ok', false, 'error', 'contact_info_in_note');
  end if;

  select * into r from public.requests where public_token = p_token for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if r.status in ('recovered', 'cancelled', 'expired') then
    return jsonb_build_object('ok', false, 'error', 'already_closed', 'status', r.status);
  end if;

  update public.requests
     set status         = 'recovered',
         recovered_at   = now(),
         thank_you_note = coalesce(note, thank_you_note),
         next_action_at = null
   where id = r.id
   returning * into r;

  update public.dispatches
     set state = 'superseded'
   where request_id = r.id
     and state in ('queued', 'sent', 'delivered');

  if r.accepted_responder_id is not null then
    update public.responders
       set recoveries_count = recoveries_count + 1
     where id = r.accepted_responder_id;

    perform app.queue_sms(
      resp.phone,
      case when note is null then 'responder.recovered' else 'responder.thanks' end,
      jsonb_build_object('short_code', r.short_code, 'note', note, 'name', r.requester_name),
      resp.locale, r.id, resp.id
    )
    from public.responders resp where resp.id = r.accepted_responder_id;
  end if;

  return jsonb_build_object('ok', true, 'status', r.status);
end;
$$;

-- Thank-you sent after the fact, from an already-recovered status page.
create or replace function public.thank_responder_by_token(p_token text, p_note text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  r    public.requests%rowtype;
  note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if note is null then
    return jsonb_build_object('ok', false, 'error', 'empty_note');
  end if;

  if public.contains_contact_info(note) then
    return jsonb_build_object('ok', false, 'error', 'contact_info_in_note');
  end if;

  select * into r from public.requests where public_token = p_token for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if r.accepted_responder_id is null then
    return jsonb_build_object('ok', false, 'error', 'no_responder');
  end if;

  if r.thank_you_note is not null then
    return jsonb_build_object('ok', false, 'error', 'already_thanked');
  end if;

  update public.requests set thank_you_note = note where id = r.id;

  perform app.queue_sms(
    resp.phone, 'responder.thanks',
    jsonb_build_object('short_code', r.short_code, 'note', note, 'name', r.requester_name),
    resp.locale, r.id, resp.id
  )
  from public.responders resp where resp.id = r.accepted_responder_id;

  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- Outbox: claim, then confirm
--
-- Claiming bumps `attempts` and pushes `send_after` out, so a sender that dies mid-flight leaves
-- the message to be retried later rather than stuck or double-sent in the same minute.
-- ---------------------------------------------------------------------------

create or replace function public.claim_sms_batch(p_limit integer default 20)
returns setof public.sms_messages
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  return query
  with claimed as (
    select id
      from public.sms_messages
     where direction = 'outbound'
       and state = 'queued'
       and send_after <= now()
       and attempts < 4
     order by send_after
     limit greatest(1, least(coalesce(p_limit, 20), 100))
     for update skip locked
  )
  update public.sms_messages m
     set attempts   = m.attempts + 1,
         send_after = now() + (interval '2 minutes' * (m.attempts + 1))
    from claimed
   where m.id = claimed.id
  returning m.*;
end;
$$;

-- The rendered body is stored on success, so the admin SMS log shows exactly what a volunteer
-- received rather than a template key someone has to go look up.
create or replace function public.mark_sms_sent(
  p_id uuid,
  p_twilio_sid text default null,
  p_body text default null
)
returns void
language sql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
  update public.sms_messages
     set state = 'sent',
         sent_at = now(),
         twilio_sid = p_twilio_sid,
         body = coalesce(p_body, body),
         error_message = null
   where id = p_id;
$$;

create or replace function public.mark_sms_failed(p_id uuid, p_error text)
returns void
language sql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
  update public.sms_messages
     set state = case when attempts >= 4 then 'failed'::sms_state else 'queued'::sms_state end,
         error_message = left(coalesce(p_error, ''), 500)
   where id = p_id;
$$;

-- ---------------------------------------------------------------------------
-- Grants: server-side only.
--
-- These are not granted to anon. Every one of them is reached through a Next.js server action
-- using the service-role key, which is also where the IP address and the site URL come from.
-- ---------------------------------------------------------------------------

revoke execute on function public.check_rate_limit(text, integer, integer) from public, anon, authenticated;
revoke execute on function public.create_request(jsonb, text)               from public, anon, authenticated;
revoke execute on function public.cancel_request_by_token(text, text)       from public, anon, authenticated;
revoke execute on function public.mark_recovered_by_token(text, text)       from public, anon, authenticated;
revoke execute on function public.thank_responder_by_token(text, text)      from public, anon, authenticated;
revoke execute on function public.claim_sms_batch(integer)                  from public, anon, authenticated;
revoke execute on function public.mark_sms_sent(uuid, text, text)                 from public, anon, authenticated;
revoke execute on function public.mark_sms_failed(uuid, text)               from public, anon, authenticated;

grant execute on function public.check_rate_limit(text, integer, integer) to service_role;
grant execute on function public.create_request(jsonb, text)               to service_role;
grant execute on function public.cancel_request_by_token(text, text)       to service_role;
grant execute on function public.mark_recovered_by_token(text, text)       to service_role;
grant execute on function public.thank_responder_by_token(text, text)      to service_role;
grant execute on function public.claim_sms_batch(integer)                  to service_role;
grant execute on function public.mark_sms_sent(uuid, text, text)                 to service_role;
grant execute on function public.mark_sms_failed(uuid, text)               to service_role;
grant execute on function app.queue_sms(text, text, jsonb, text, uuid, uuid, uuid) to service_role;
