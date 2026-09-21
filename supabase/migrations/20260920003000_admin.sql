-- Winch Up M4 :: admin console
--
-- Every function here starts by checking `app.is_admin()` and raising if it fails, and every one
-- that changes something writes an audit row. Admins are the only people in the system who can
-- see a requester's phone number in bulk, so their actions need a trail.
--
-- These are granted to `authenticated`, not to service_role only: the admin console runs in the
-- browser as the signed-in admin, and the gate is `auth.uid()`, not a shared key.

set search_path = public, extensions;

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
end;
$$;

create or replace function app.audit(
  p_action    text,
  p_entity    text default null,
  p_entity_id text default null,
  p_data      jsonb default '{}'::jsonb
)
returns void
language sql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
  insert into public.audit_log (actor_kind, actor_user_id, action, entity, entity_id, data)
  values ('admin', auth.uid(), p_action, p_entity, p_entity_id, coalesce(p_data, '{}'::jsonb));
$$;

-- ---------------------------------------------------------------------------
-- Dashboard
--
-- Exact pins and phone numbers, because that is the point of the admin map: when a request has
-- been sitting for 20 minutes somebody has to be able to pick up the phone.
-- ---------------------------------------------------------------------------

create or replace function public.admin_dashboard()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  perform app.require_admin();

  return jsonb_build_object(
    'counts', jsonb_build_object(
      'open', (select count(*) from public.requests
                where status in ('submitted', 'dispatching', 'unmatched')),
      'assigned', (select count(*) from public.requests
                    where status in ('accepted', 'on_site')),
      'unmatched', (select count(*) from public.requests where status = 'unmatched'),
      'recovered_today', (select count(*) from public.requests
                           where status = 'recovered'
                             and recovered_at > (now() at time zone 'America/Chicago')::date),
      'responders_active', (select count(*) from public.responders
                             where approval = 'approved' and availability = 'active'),
      'responders_pending', (select count(*) from public.responders where approval = 'pending'),
      'sms_failed', (select count(*) from public.sms_messages where state = 'failed')
    ),
    'queue', coalesce((
      select jsonb_agg(to_jsonb(q) order by q.created_at)
        from (
          select
            r.id,
            r.short_code,
            r.public_token,
            r.status,
            r.created_at,
            r.dispatch_started_at,
            r.current_ring,
            r.notified_count,
            r.requester_name,
            r.requester_phone,
            r.county,
            r.vehicle_class,
            r.stuck_type,
            r.stuck_depth,
            r.needs_tractor,
            r.needs_second_truck,
            r.notes,
            extensions.st_y(r.location::extensions.geometry) as lat,
            extensions.st_x(r.location::extensions.geometry) as lng,
            round(extract(epoch from (now() - r.created_at)) / 60.0) as age_minutes,
            resp.first_name as responder_first_name,
            resp.phone as responder_phone,
            r.eta_minutes
          from public.requests r
          left join public.responders resp on resp.id = r.accepted_responder_id
          where r.status in ('submitted', 'dispatching', 'unmatched', 'accepted', 'on_site')
          order by r.created_at
          limit 100
        ) q
    ), '[]'::jsonb),
    'responders', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', r.id,
               'first_name', r.first_name,
               'availability', r.availability,
               'radius_miles', r.radius_miles,
               'equipment', to_jsonb(r.equipment),
               'lat', extensions.st_y(r.home_location::extensions.geometry),
               'lng', extensions.st_x(r.home_location::extensions.geometry),
               'busy', exists (
                 select 1 from public.requests busy
                  where busy.accepted_responder_id = r.id
                    and busy.status in ('accepted', 'on_site')
               )
             ))
        from public.responders r
       where r.approval = 'approved'
    ), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Volunteers
-- ---------------------------------------------------------------------------

create or replace function public.admin_list_responders(p_approval text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  perform app.require_admin();

  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.created_at desc)
      from (
        select
          r.id, r.first_name, r.last_name, r.phone, r.locale,
          r.home_address_text, r.radius_miles, r.equipment,
          r.vehicle_class, r.vehicle_desc, r.drivetrain,
          r.approval, r.availability, r.night_ok, r.sms_opt_in,
          r.recoveries_count, r.last_notified_at, r.last_accepted_at,
          r.admin_notes, r.review_reason, r.created_at
        from public.responders r
        where p_approval is null or r.approval = p_approval::responder_approval
        order by r.created_at desc
        limit 500
      ) x
  ), '[]'::jsonb);
end;
$$;

create or replace function public.admin_set_responder_approval(
  p_responder_id uuid,
  p_approval     text,
  p_reason       text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  resp public.responders%rowtype;
begin
  perform app.require_admin();

  if p_approval not in ('pending', 'approved', 'rejected', 'banned') then
    return jsonb_build_object('ok', false, 'error', 'bad_value');
  end if;

  update public.responders
     set approval      = p_approval::responder_approval,
         approved_by   = case when p_approval = 'approved' then auth.uid() else null end,
         review_reason = nullif(btrim(coalesce(p_reason, '')), ''),
         availability  = case when p_approval in ('rejected', 'banned')
                              then 'paused'::availability_state else availability end
   where id = p_responder_id
   returning * into resp;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  perform app.audit('responder.approval', 'responder', p_responder_id::text,
                    jsonb_build_object('approval', p_approval, 'reason', p_reason));

  return jsonb_build_object('ok', true, 'approval', resp.approval);
end;
$$;

-- ---------------------------------------------------------------------------
-- Manual dispatch and reassignment
--
-- The escape hatch for when the rings found nobody and an admin knows who to call.
-- ---------------------------------------------------------------------------

create or replace function public.admin_manual_dispatch(p_request_id uuid, p_responder_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  req      public.requests%rowtype;
  resp     public.responders%rowtype;
  distance numeric;
  offer_id uuid;
begin
  perform app.require_admin();

  select * into req from public.requests where id = p_request_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  select * into resp from public.responders where id = p_responder_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_responder');
  end if;

  if exists (select 1 from public.dispatches
              where request_id = p_request_id and responder_id = p_responder_id) then
    return jsonb_build_object('ok', false, 'error', 'already_offered');
  end if;

  distance := round((extensions.st_distance(resp.home_location, req.location) / 1609.344)::numeric, 2);

  insert into public.dispatches (request_id, responder_id, ring, distance_miles, state, is_manual)
  values (p_request_id, p_responder_id, greatest(1, req.current_ring), distance, 'queued', true)
  returning id into offer_id;

  perform app.queue_sms(
    resp.phone, 'responder.offer',
    jsonb_build_object(
      'short_code', req.short_code, 'miles', distance,
      'stuck_type', req.stuck_type, 'stuck_depth', req.stuck_depth,
      'vehicle_class', req.vehicle_class, 'county', req.county,
      'land_type', req.land_type,
      'needs_tractor', req.needs_tractor, 'needs_second_truck', req.needs_second_truck
    ),
    resp.locale, p_request_id, p_responder_id, offer_id
  );

  update public.requests set notified_count = notified_count + 1 where id = p_request_id;

  perform app.audit('request.manual_dispatch', 'request', p_request_id::text,
                    jsonb_build_object('responder_id', p_responder_id, 'miles', distance));

  return jsonb_build_object('ok', true, 'miles', distance);
end;
$$;

-- Hand a job directly to somebody, releasing whoever had it.
create or replace function public.admin_reassign(p_request_id uuid, p_responder_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  req      public.requests%rowtype;
  previous uuid;
  result   jsonb;
begin
  perform app.require_admin();

  select * into req from public.requests where id = p_request_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  previous := req.accepted_responder_id;

  if previous is not null then
    perform app.queue_sms(
      resp.phone, 'responder.job_cancelled',
      jsonb_build_object('short_code', req.short_code), resp.locale, req.id, resp.id
    )
    from public.responders resp where resp.id = previous;

    update public.requests
       set accepted_responder_id = null,
           accepted_at = null,
           eta_minutes = null,
           status = 'dispatching'
     where id = p_request_id;

    update public.dispatches
       set state = 'superseded'
     where request_id = p_request_id and responder_id = previous;
  end if;

  -- Make sure the new volunteer has an offer row, since accept_request insists on one.
  if not exists (select 1 from public.dispatches
                  where request_id = p_request_id and responder_id = p_responder_id) then
    perform public.admin_manual_dispatch(p_request_id, p_responder_id);
  end if;

  result := app.accept_request(p_request_id, p_responder_id, null);

  perform app.audit('request.reassign', 'request', p_request_id::text,
                    jsonb_build_object('from', previous, 'to', p_responder_id));

  insert into public.request_events (request_id, event_type, actor_kind, actor_user_id, data)
  values (p_request_id, 'reassigned', 'admin', auth.uid(),
          jsonb_build_object('from', previous, 'to', p_responder_id));

  return result;
end;
$$;

-- ---------------------------------------------------------------------------
-- Settings, paid options, legal copy, blocklist
-- ---------------------------------------------------------------------------

create or replace function public.admin_list_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  perform app.require_admin();

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'key', key, 'value', value, 'description', description,
             'is_public', is_public, 'updated_at', updated_at
           ) order by key)
      from public.app_settings
  ), '[]'::jsonb);
end;
$$;

create or replace function public.admin_update_setting(p_key text, p_value jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  old_value jsonb;
begin
  perform app.require_admin();

  select value into old_value from public.app_settings where key = p_key;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'unknown_key');
  end if;

  update public.app_settings
     set value = p_value, updated_at = now(), updated_by = auth.uid()
   where key = p_key;

  perform app.audit('setting.update', 'app_settings', p_key,
                    jsonb_build_object('from', old_value, 'to', p_value));

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.admin_upsert_pro_option(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  target uuid := nullif(p_payload ->> 'id', '')::uuid;
begin
  perform app.require_admin();

  if target is null then
    insert into public.pro_options (name, phone, url, blurb_en, blurb_es, counties, is_active, sort_order)
    values (
      btrim(p_payload ->> 'name'),
      nullif(btrim(coalesce(p_payload ->> 'phone', '')), ''),
      nullif(btrim(coalesce(p_payload ->> 'url', '')), ''),
      nullif(btrim(coalesce(p_payload ->> 'blurb_en', '')), ''),
      nullif(btrim(coalesce(p_payload ->> 'blurb_es', '')), ''),
      coalesce((select array_agg(value) from jsonb_array_elements_text(coalesce(p_payload -> 'counties', '[]'::jsonb))), '{}'),
      coalesce((p_payload ->> 'is_active')::boolean, true),
      coalesce((p_payload ->> 'sort_order')::smallint, 100)
    )
    returning id into target;
  else
    update public.pro_options
       set name       = coalesce(nullif(btrim(p_payload ->> 'name'), ''), name),
           phone      = nullif(btrim(coalesce(p_payload ->> 'phone', '')), ''),
           url        = nullif(btrim(coalesce(p_payload ->> 'url', '')), ''),
           blurb_en   = nullif(btrim(coalesce(p_payload ->> 'blurb_en', '')), ''),
           blurb_es   = nullif(btrim(coalesce(p_payload ->> 'blurb_es', '')), ''),
           is_active  = coalesce((p_payload ->> 'is_active')::boolean, is_active),
           sort_order = coalesce((p_payload ->> 'sort_order')::smallint, sort_order),
           updated_at = now()
     where id = target;
  end if;

  perform app.audit('pro_option.upsert', 'pro_options', target::text, p_payload);

  return jsonb_build_object('ok', true, 'id', target);
end;
$$;

-- Publishing legal copy always makes a NEW version. Editing in place would rewrite what people
-- already agreed to, and `requests.waiver_id` promises that cannot happen.
create or replace function public.admin_publish_waiver(
  p_slug    text,
  p_body_en text,
  p_body_es text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  next_version integer;
  new_id       uuid;
begin
  perform app.require_admin();

  if p_slug not in ('requester_waiver', 'responder_waiver', 'rules') then
    return jsonb_build_object('ok', false, 'error', 'bad_slug');
  end if;

  if length(btrim(coalesce(p_body_en, ''))) < 20 or length(btrim(coalesce(p_body_es, ''))) < 20 then
    return jsonb_build_object('ok', false, 'error', 'both_languages_required');
  end if;

  select coalesce(max(version), 0) + 1 into next_version
    from public.waivers where slug = p_slug;

  insert into public.waivers (slug, version, body_en, body_es, is_current)
  values (p_slug, next_version, p_body_en, p_body_es, true)
  returning id into new_id;

  perform app.audit('waiver.publish', 'waivers', new_id::text,
                    jsonb_build_object('slug', p_slug, 'version', next_version));

  return jsonb_build_object('ok', true, 'version', next_version);
end;
$$;

create or replace function public.admin_block_phone(p_phone text, p_reason text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  perform app.require_admin();

  if p_phone !~ '^\+1[0-9]{10}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_phone');
  end if;

  insert into public.blocklist (phone, reason, created_by)
  values (p_phone, nullif(btrim(coalesce(p_reason, '')), ''), auth.uid())
  on conflict (phone) do update set reason = excluded.reason;

  perform app.audit('blocklist.add', 'blocklist', p_phone,
                    jsonb_build_object('reason', p_reason));

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.admin_unblock_phone(p_phone text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  perform app.require_admin();
  delete from public.blocklist where phone = p_phone;
  perform app.audit('blocklist.remove', 'blocklist', p_phone);
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- Intake from a Facebook post
--
-- Somebody posts in the group instead of using the site. An admin pastes what they wrote, and
-- the request joins the normal dispatch flow. `location_source = 'admin_intake'` keeps it honest
-- about where the pin came from.
-- ---------------------------------------------------------------------------

create or replace function public.admin_create_request(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_lat    double precision := (p_payload ->> 'lat')::double precision;
  v_lng    double precision := (p_payload ->> 'lng')::double precision;
  v_phone  text := btrim(coalesce(p_payload ->> 'phone', ''));
  req      public.requests%rowtype;
begin
  perform app.require_admin();

  if v_lat is null or v_lng is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_location');
  end if;

  if v_phone !~ '^\+1[0-9]{10}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_phone');
  end if;

  insert into public.requests (
    locale, requester_name, requester_phone,
    location, location_source, location_note, county,
    vehicle_class, vehicle_make, vehicle_model, drivetrain,
    stuck_type, stuck_depth, needs_tractor, needs_second_truck,
    land_type, notes,
    emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at,
    created_by, next_action_at
  ) values (
    coalesce(nullif(p_payload ->> 'locale', ''), 'en'),
    btrim(coalesce(p_payload ->> 'name', 'From the group')),
    v_phone,
    extensions.st_setsrid(extensions.st_point(v_lng, v_lat), 4326)::extensions.geography,
    'admin_intake',
    nullif(btrim(coalesce(p_payload ->> 'location_note', '')), ''),
    nullif(btrim(coalesce(p_payload ->> 'county', '')), ''),
    coalesce(nullif(p_payload ->> 'vehicle_class', ''), 'truck')::vehicle_class,
    nullif(btrim(coalesce(p_payload ->> 'vehicle_make', '')), ''),
    nullif(btrim(coalesce(p_payload ->> 'vehicle_model', '')), ''),
    coalesce(nullif(p_payload ->> 'drivetrain', ''), 'unknown')::drivetrain,
    coalesce(nullif(p_payload ->> 'stuck_type', ''), 'other')::stuck_type,
    nullif(p_payload ->> 'stuck_depth', '')::stuck_depth,
    coalesce((p_payload ->> 'needs_tractor')::boolean, false),
    coalesce((p_payload ->> 'needs_second_truck')::boolean, false),
    coalesce(nullif(p_payload ->> 'land_type', ''), 'public')::land_type,
    nullif(btrim(coalesce(p_payload ->> 'notes', '')), ''),
    -- An admin transcribing a post has spoken to nobody about 911, so record who vouched for it.
    now(), true,
    (select id from public.waivers where slug = 'requester_waiver' and is_current),
    now(), auth.uid(), now()
  )
  returning * into req;

  perform app.audit('request.admin_intake', 'request', req.id::text,
                    jsonb_build_object('short_code', req.short_code));

  return jsonb_build_object(
    'ok', true,
    'request_id', req.id,
    'short_code', req.short_code,
    'token', req.public_token
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Audit log
-- ---------------------------------------------------------------------------

create or replace function public.admin_audit_log(p_limit integer default 100)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  perform app.require_admin();

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', a.id, 'action', a.action, 'entity', a.entity, 'entity_id', a.entity_id,
             'data', a.data, 'created_at', a.created_at,
             'actor', coalesce(u.email, u.phone, a.actor_user_id::text)
           ) order by a.created_at desc)
      from (
        select * from public.audit_log order by created_at desc
        limit greatest(1, least(coalesce(p_limit, 100), 500))
      ) a
      left join auth.users u on u.id = a.actor_user_id
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

do $$
declare
  fn text;
begin
  foreach fn in array array[
    'public.admin_dashboard()',
    'public.admin_list_responders(text)',
    'public.admin_set_responder_approval(uuid, text, text)',
    'public.admin_manual_dispatch(uuid, uuid)',
    'public.admin_reassign(uuid, uuid)',
    'public.admin_list_settings()',
    'public.admin_update_setting(text, jsonb)',
    'public.admin_upsert_pro_option(jsonb)',
    'public.admin_publish_waiver(text, text, text)',
    'public.admin_block_phone(text, text)',
    'public.admin_unblock_phone(text)',
    'public.admin_create_request(jsonb)',
    'public.admin_audit_log(integer)'
  ]
  loop
    execute format('revoke execute on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated, service_role', fn);
  end loop;
end
$$;

grant execute on all functions in schema app to service_role;
