-- TxRecover M3 :: the dispatch state machine
--
-- One function owns every transition: `app.advance_one(request_id)` for the timed moves, and a
-- small set of `app.*` action functions for the ones a person triggers. Everything takes a row
-- lock on the request before it decides anything, which is what makes a double accept
-- impossible: the second "1" to arrive reads a row that already has a winner.
--
-- Nothing here sends anything. It queues rows in `sms_messages` with a template key, and the
-- sender renders them. That keeps the copy translatable and the state machine testable.

set search_path = public, extensions;

-- Phones that get the "nobody has taken this in 25 minutes" alert.
insert into app_settings (key, value, description, is_public)
values ('contact.admin_phones', '[]'::jsonb,
        'E.164 numbers alerted when a request goes unmatched. Edit in /admin.', false)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Fix forward on the M1 timeline trigger
--
-- Ring 1 already produces a `dispatch_started` row when the status moves to `dispatching`.
-- Logging `ring_escalated` for it as well made the requester's timeline say the search was
-- widening before it had started. Only rings 2 and 3 are escalations.
-- ---------------------------------------------------------------------------

create or replace function app.requests_log_events()
returns trigger
language plpgsql
set search_path = public, extensions, pg_temp
as $$
declare
  evt request_event_type;
begin
  if tg_op = 'INSERT' then
    insert into public.request_events (request_id, event_type, actor_kind, data)
    values (new.id, 'created', 'requester', jsonb_build_object('short_code', new.short_code));
    return new;
  end if;

  if new.status is distinct from old.status then
    evt := case new.status
             when 'dispatching' then 'dispatch_started'
             when 'unmatched'   then 'unmatched'
             when 'accepted'    then 'accepted'
             when 'on_site'     then 'on_site'
             when 'recovered'   then 'recovered'
             when 'cancelled'   then 'cancelled'
             when 'expired'     then 'expired'
             else null
           end;

    if evt is not null then
      insert into public.request_events (request_id, event_type, actor_kind, actor_responder_id, data)
      values (
        new.id,
        evt,
        case when new.status in ('accepted', 'on_site') then 'responder' else 'system' end,
        new.accepted_responder_id,
        jsonb_strip_nulls(jsonb_build_object(
          'from', old.status,
          'to', new.status,
          'eta_minutes', new.eta_minutes
        ))
      );
    end if;
  end if;

  if new.current_ring is distinct from old.current_ring and new.current_ring > 1 then
    insert into public.request_events (request_id, event_type, actor_kind, data)
    values (
      new.id, 'ring_escalated', 'system',
      jsonb_build_object('ring', new.current_ring, 'notified_count', new.notified_count)
    );
  end if;

  if new.thank_you_note is distinct from old.thank_you_note and new.thank_you_note is not null then
    insert into public.request_events (request_id, event_type, actor_kind, actor_responder_id, data)
    values (new.id, 'thanked', 'requester', new.accepted_responder_id, '{}'::jsonb);
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Tuning, read once per decision
-- ---------------------------------------------------------------------------

create or replace function app.setting_int(p_key text, p_default integer)
returns integer
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  select coalesce((select (value #>> '{}')::integer from public.app_settings where key = p_key), p_default);
$$;

create or replace function app.ring_radius_miles(p_ring integer)
returns integer
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  select coalesce(
    (select (value -> (p_ring - 1))::text::integer
       from public.app_settings where key = 'dispatch.ring_radii_miles'),
    case p_ring when 1 then 15 when 2 then 30 else 60 end
  );
$$;

-- ---------------------------------------------------------------------------
-- Who gets this job
--
-- Hard filters only. A volunteer has to be approved, active, reachable by SMS, inside both our
-- ring and their own stated radius, carrying whatever the request actually requires, and not
-- already holding as many jobs as they said they would take.
-- ---------------------------------------------------------------------------

create or replace function app.candidates(p_request_id uuid, p_radius_miles integer, p_limit integer)
returns table (responder_id uuid, distance_miles numeric)
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  with req as (
    select id, location, required_equipment
      from public.requests where id = p_request_id
  ),
  -- Night is 21:00-06:00 Central. Someone who said they do not do night calls should not be
  -- woken up, but they stay eligible during the day.
  clock as (
    select (extract(hour from (now() at time zone 'America/Chicago')) >= 21
            or extract(hour from (now() at time zone 'America/Chicago')) < 6) as is_night
  )
  select
    r.id,
    round((extensions.st_distance(r.home_location, req.location) / 1609.344)::numeric, 2)
  from public.responders r
  cross join req
  cross join clock
  where r.approval = 'approved'
    and r.availability = 'active'
    and r.sms_opt_in
    and r.sms_opt_out_at is null
    and (r.paused_until is null or r.paused_until <= now())
    and (not clock.is_night or r.night_ok)
    and r.equipment @> req.required_equipment
    and extensions.st_dwithin(
          r.home_location,
          req.location,
          app.miles_to_meters(least(p_radius_miles, r.radius_miles))
        )
    and not exists (
      select 1 from public.dispatches d
       where d.request_id = req.id and d.responder_id = r.id
    )
    and (
      select count(*) from public.requests active
       where active.accepted_responder_id = r.id
         and active.status in ('accepted', 'on_site')
    ) < r.max_active_jobs
  order by extensions.st_distance(r.home_location, req.location)
  limit greatest(1, p_limit);
$$;

-- ---------------------------------------------------------------------------
-- Text one ring
-- ---------------------------------------------------------------------------

create or replace function app.notify_ring(p_request_id uuid, p_ring integer)
returns integer
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  req         public.requests%rowtype;
  radius      integer := app.ring_radius_miles(p_ring);
  per_ring    integer := app.setting_int('dispatch.max_per_ring', 10);
  wait_min    integer := app.setting_int('dispatch.ring_wait_minutes', 7);
  candidate   record;
  sent_count  integer := 0;
  new_dispatch uuid;
begin
  select * into req from public.requests where id = p_request_id;
  if not found then
    return 0;
  end if;

  for candidate in
    select * from app.candidates(p_request_id, radius, per_ring)
  loop
    insert into public.dispatches (request_id, responder_id, ring, distance_miles, state)
    values (p_request_id, candidate.responder_id, p_ring, candidate.distance_miles, 'queued')
    returning id into new_dispatch;

    perform app.queue_sms(
      resp.phone,
      'responder.offer',
      jsonb_build_object(
        'short_code',    req.short_code,
        'miles',         candidate.distance_miles,
        'stuck_type',    req.stuck_type,
        'stuck_depth',   req.stuck_depth,
        'vehicle_class', req.vehicle_class,
        'county',        req.county,
        'land_type',     req.land_type,
        'needs_tractor', req.needs_tractor,
        'needs_second_truck', req.needs_second_truck
      ),
      resp.locale,
      p_request_id,
      candidate.responder_id,
      new_dispatch
    )
    from public.responders resp where resp.id = candidate.responder_id;

    update public.responders
       set last_notified_at = now()
     where id = candidate.responder_id;

    insert into public.request_events (request_id, event_type, actor_kind, actor_responder_id, data, is_public)
    values (p_request_id, 'responder_notified', 'system', candidate.responder_id,
            jsonb_build_object('ring', p_ring, 'miles', candidate.distance_miles), false);

    sent_count := sent_count + 1;
  end loop;

  update public.requests
     set current_ring       = p_ring,
         ring_started_at    = now(),
         notified_count     = notified_count + sent_count,
         dispatch_started_at = coalesce(dispatch_started_at, now()),
         status             = case when status = 'submitted' then 'dispatching' else status end,
         next_action_at     = now() + make_interval(mins => wait_min)
   where id = p_request_id;

  return sent_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- The timed transitions
--
-- Called once per request that is due. Everything it can decide, it decides from the row it has
-- locked, so two ticks running at once cannot both escalate the same request.
-- ---------------------------------------------------------------------------

create or replace function app.advance_one(p_request_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  req          public.requests%rowtype;
  wait_min     integer := app.setting_int('dispatch.ring_wait_minutes', 7);
  unmatched_after integer := app.setting_int('dispatch.unmatched_after_minutes', 25);
  expire_hours integer := app.setting_int('dispatch.expire_after_hours', 24);
  elapsed_min  numeric;
  notified     integer;
  admin_phone  text;
begin
  select * into req from public.requests where id = p_request_id for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  -- Anything already settled is none of this function's business.
  if req.status in ('accepted', 'on_site', 'recovered', 'cancelled', 'expired') then
    if req.next_action_at is not null then
      update public.requests set next_action_at = null where id = req.id;
    end if;
    return jsonb_build_object('ok', true, 'action', 'none', 'status', req.status);
  end if;

  if req.next_action_at is null or req.next_action_at > now() then
    return jsonb_build_object('ok', true, 'action', 'not_due');
  end if;

  -- First run: open ring 1. The status-change trigger writes the `dispatch_started` timeline row.
  if req.status = 'submitted' and req.current_ring = 0 then
    notified := app.notify_ring(req.id, 1);
    return jsonb_build_object('ok', true, 'action', 'ring_1', 'notified', notified);
  end if;

  elapsed_min := extract(epoch from (now() - coalesce(req.dispatch_started_at, req.created_at))) / 60.0;

  -- Out of patience: tell the admins, show the requester paid options, keep the request open so
  -- a volunteer can still pick it up.
  if elapsed_min >= unmatched_after and req.status = 'dispatching' then
    update public.requests
       set status           = 'unmatched',
           unmatched_at     = now(),
           admin_alerted_at = now(),
           next_action_at   = now() + make_interval(hours => expire_hours)
     where id = req.id;

    for admin_phone in
      select jsonb_array_elements_text(value)
        from public.app_settings where key = 'contact.admin_phones'
    loop
      perform app.queue_sms(
        admin_phone, 'admin.unmatched_alert',
        jsonb_build_object(
          'short_code', req.short_code,
          'minutes', round(elapsed_min),
          'notified', req.notified_count,
          'county', req.county
        ),
        'en', req.id
      );
    end loop;

    perform app.queue_sms(
      req.requester_phone, 'requester.unmatched',
      jsonb_build_object('short_code', req.short_code),
      req.locale, req.id
    );

    return jsonb_build_object('ok', true, 'action', 'unmatched');
  end if;

  -- Still inside the window: widen the search.
  if req.status = 'dispatching' and req.current_ring < 3 then
    notified := app.notify_ring(req.id, req.current_ring + 1);
    return jsonb_build_object(
      'ok', true, 'action', 'ring_' || (req.current_ring + 1), 'notified', notified
    );
  end if;

  -- Ring 3 is exhausted but the 25 minutes are not up yet. Wait for the rest of it.
  if req.status = 'dispatching' and req.current_ring >= 3 then
    update public.requests
       set next_action_at = coalesce(req.dispatch_started_at, req.created_at)
                            + make_interval(mins => unmatched_after)
     where id = req.id;
    return jsonb_build_object('ok', true, 'action', 'waiting_for_unmatched');
  end if;

  -- Unmatched and nobody ever came.
  if req.status = 'unmatched' then
    update public.requests
       set status = 'expired', next_action_at = null
     where id = req.id;

    update public.dispatches
       set state = 'expired'
     where request_id = req.id and state in ('queued', 'sent', 'delivered');

    return jsonb_build_object('ok', true, 'action', 'expired');
  end if;

  update public.requests set next_action_at = now() + make_interval(mins => wait_min)
   where id = req.id;

  return jsonb_build_object('ok', true, 'action', 'deferred');
end;
$$;

-- The tick. `skip locked` so two overlapping runs share the work instead of blocking.
create or replace function public.advance_dispatch(p_limit integer default 50)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  target  uuid;
  results jsonb := '[]'::jsonb;
  outcome jsonb;
  seen    integer := 0;
begin
  for target in
    select id from public.requests
     where status in ('submitted', 'dispatching', 'unmatched')
       and next_action_at is not null
       and next_action_at <= now()
     order by next_action_at
     limit greatest(1, least(coalesce(p_limit, 50), 200))
     for update skip locked
  loop
    outcome := app.advance_one(target);
    results := results || jsonb_build_array(jsonb_build_object('request_id', target) || outcome);
    seen := seen + 1;
  end loop;

  return jsonb_build_object('processed', seen, 'results', results);
end;
$$;

-- ---------------------------------------------------------------------------
-- Accept — the one that must never race
-- ---------------------------------------------------------------------------

create or replace function app.accept_request(
  p_request_id   uuid,
  p_responder_id uuid,
  p_eta_minutes  integer default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  req     public.requests%rowtype;
  resp    public.responders%rowtype;
  offer   public.dispatches%rowtype;
  loser   record;
begin
  select * into resp from public.responders where id = p_responder_id;
  if not found or resp.approval <> 'approved' then
    return jsonb_build_object('ok', false, 'error', 'not_approved');
  end if;

  -- The lock. Everything after this point is decided against a row nobody else can change.
  select * into req from public.requests where id = p_request_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  -- Closed states first. A request that was accepted and then cancelled still carries a
  -- responder id, and telling that volunteer "already covered" would be a lie — it is over.
  if req.status in ('recovered', 'cancelled', 'expired') then
    return jsonb_build_object('ok', false, 'error', 'already_closed', 'status', req.status);
  end if;

  if req.accepted_responder_id is not null then
    return jsonb_build_object(
      'ok', false,
      'error', case when req.accepted_responder_id = p_responder_id
                    then 'already_yours' else 'already_covered' end
    );
  end if;

  if req.status not in ('submitted', 'dispatching', 'unmatched') then
    return jsonb_build_object('ok', false, 'error', 'already_closed', 'status', req.status);
  end if;

  select * into offer
    from public.dispatches
   where request_id = p_request_id and responder_id = p_responder_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_offered');
  end if;

  update public.requests
     set status                = 'accepted',
         accepted_responder_id = p_responder_id,
         accepted_at           = now(),
         eta_minutes           = p_eta_minutes,
         next_action_at        = null
   where id = p_request_id
   returning * into req;

  update public.dispatches
     set state = 'accepted', responded_at = now()
   where id = offer.id;

  update public.responders
     set last_accepted_at = now()
   where id = p_responder_id;

  -- Everyone else stands down. Only people who actually got a text get told.
  for loser in
    select d.id, d.state, r2.phone, r2.locale
      from public.dispatches d
      join public.responders r2 on r2.id = d.responder_id
     where d.request_id = p_request_id
       and d.responder_id <> p_responder_id
       and d.state in ('queued', 'sent', 'delivered')
  loop
    if loser.state in ('sent', 'delivered') then
      perform app.queue_sms(
        loser.phone, 'responder.already_covered',
        jsonb_build_object('short_code', req.short_code), loser.locale, req.id
      );
    end if;

    update public.dispatches set state = 'superseded' where id = loser.id;
  end loop;

  -- The winner gets what nobody else ever sees: the name, the number and the exact pin.
  perform app.queue_sms(
    resp.phone, 'responder.assigned',
    jsonb_build_object(
      'short_code',      req.short_code,
      'requester_name',  req.requester_name,
      'requester_phone', req.requester_phone,
      'lat',             round(extensions.st_y(req.location::extensions.geometry)::numeric, 5),
      'lng',             round(extensions.st_x(req.location::extensions.geometry)::numeric, 5),
      'location_note',   req.location_note
    ),
    resp.locale, req.id, resp.id, offer.id
  );

  perform app.queue_sms(
    req.requester_phone, 'requester.accepted',
    jsonb_build_object(
      'short_code',    req.short_code,
      'first_name',    resp.first_name,
      'vehicle_desc',  coalesce(resp.vehicle_desc, ''),
      'vehicle_class', resp.vehicle_class,
      'phone',         resp.phone,
      'eta_minutes',   p_eta_minutes
    ),
    req.locale, req.id, resp.id
  );

  return jsonb_build_object('ok', true, 'short_code', req.short_code);
end;
$$;

create or replace function app.decline_dispatch(p_request_id uuid, p_responder_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  update public.dispatches
     set state = 'declined', responded_at = now()
   where request_id = p_request_id
     and responder_id = p_responder_id
     and state in ('queued', 'sent', 'delivered');

  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_open_offer');
  end if;

  insert into public.request_events (request_id, event_type, actor_kind, actor_responder_id, is_public)
  values (p_request_id, 'declined', 'responder', p_responder_id, false);

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function app.responder_on_site(p_request_id uuid, p_responder_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  req public.requests%rowtype;
begin
  select * into req from public.requests
   where id = p_request_id and accepted_responder_id = p_responder_id for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_yours');
  end if;

  if req.status <> 'accepted' then
    return jsonb_build_object('ok', false, 'error', 'wrong_status', 'status', req.status);
  end if;

  update public.requests
     set status = 'on_site', on_site_at = now()
   where id = p_request_id
   returning * into req;

  perform app.queue_sms(
    req.requester_phone, 'requester.on_site',
    jsonb_build_object('short_code', req.short_code), req.locale, req.id
  );

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function app.responder_complete(p_request_id uuid, p_responder_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  req public.requests%rowtype;
begin
  select * into req from public.requests
   where id = p_request_id and accepted_responder_id = p_responder_id for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_yours');
  end if;

  if req.status in ('recovered', 'cancelled', 'expired') then
    return jsonb_build_object('ok', false, 'error', 'already_closed', 'status', req.status);
  end if;

  update public.requests
     set status = 'recovered', recovered_at = now(), next_action_at = null
   where id = p_request_id
   returning * into req;

  update public.responders
     set recoveries_count = recoveries_count + 1
   where id = p_responder_id;

  perform app.queue_sms(
    req.requester_phone, 'requester.recovered_by_responder',
    jsonb_build_object('short_code', req.short_code, 'token', req.public_token),
    req.locale, req.id
  );

  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- Thin wrappers for a signed-in volunteer
-- ---------------------------------------------------------------------------

create or replace function public.accept_request(p_request_id uuid, p_eta_minutes integer default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  me uuid := app.current_responder_id();
begin
  if me is null then
    return jsonb_build_object('ok', false, 'error', 'not_a_responder');
  end if;
  return app.accept_request(p_request_id, me, p_eta_minutes);
end;
$$;

create or replace function public.decline_request(p_request_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  me uuid := app.current_responder_id();
begin
  if me is null then
    return jsonb_build_object('ok', false, 'error', 'not_a_responder');
  end if;
  return app.decline_dispatch(p_request_id, me);
end;
$$;

create or replace function public.report_on_site(p_request_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  me uuid := app.current_responder_id();
begin
  if me is null then
    return jsonb_build_object('ok', false, 'error', 'not_a_responder');
  end if;
  return app.responder_on_site(p_request_id, me);
end;
$$;

create or replace function public.report_complete(p_request_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  me uuid := app.current_responder_id();
begin
  if me is null then
    return jsonb_build_object('ok', false, 'error', 'not_a_responder');
  end if;
  return app.responder_complete(p_request_id, me);
end;
$$;

-- ---------------------------------------------------------------------------
-- Responder profile
--
-- Goes through an RPC rather than a direct insert because the home location is a PostGIS point
-- and because approval state has to stay out of the caller's hands.
-- ---------------------------------------------------------------------------

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

  -- The phone comes from the verified OTP claim, never from the form. Otherwise anyone could
  -- sign up with someone else's number and receive their dispatches.
  v_phone := case when claim ~ '^[0-9]{11}$' then '+' || claim else claim end;

  if v_phone is null or v_phone !~ '^\+1[0-9]{10}$' then
    return jsonb_build_object('ok', false, 'error', 'no_verified_phone');
  end if;

  if exists (select 1 from public.blocklist b where b.phone = v_phone) then
    return jsonb_build_object('ok', false, 'error', 'blocked');
  end if;

  if v_lat is null or v_lng is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_location');
  end if;

  select coalesce(array_agg(value::equipment_type), '{}'::equipment_type[])
    into v_equip
    from jsonb_array_elements_text(coalesce(p_payload -> 'equipment', '[]'::jsonb));

  select * into me from public.responders
   where user_id = uid or phone = v_phone
   order by (user_id = uid) desc
   limit 1;

  if found then
    update public.responders
       set user_id            = uid,
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
    'availability', me.availability
  );
end;
$$;

create or replace function public.set_my_availability(p_availability text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  me uuid := app.current_responder_id();
begin
  if me is null then
    return jsonb_build_object('ok', false, 'error', 'not_a_responder');
  end if;

  if p_availability not in ('active', 'paused') then
    return jsonb_build_object('ok', false, 'error', 'bad_value');
  end if;

  update public.responders
     set availability = p_availability::availability_state,
         paused_until = null
   where id = me;

  return jsonb_build_object('ok', true, 'availability', p_availability);
end;
$$;

-- What /me renders.
create or replace function public.my_responder_profile()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  me public.responders%rowtype;
begin
  select * into me from public.responders where user_id = auth.uid();
  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'id', me.id,
    'first_name', me.first_name,
    'last_name', me.last_name,
    'phone', me.phone,
    'locale', me.locale,
    'lat', extensions.st_y(me.home_location::extensions.geometry),
    'lng', extensions.st_x(me.home_location::extensions.geometry),
    'home_address_text', me.home_address_text,
    'radius_miles', me.radius_miles,
    'equipment', to_jsonb(me.equipment),
    'vehicle_class', me.vehicle_class,
    'vehicle_desc', me.vehicle_desc,
    'drivetrain', me.drivetrain,
    'night_ok', me.night_ok,
    'approval', me.approval,
    'availability', me.availability,
    'recoveries_count', me.recoveries_count,
    'created_at', me.created_at,
    'current_job', (
      select jsonb_build_object(
               'request_id', r.id,
               'short_code', r.short_code,
               'status', r.status,
               'accepted_at', r.accepted_at,
               'eta_minutes', r.eta_minutes
             )
        from public.requests r
       where r.accepted_responder_id = me.id
         and r.status in ('accepted', 'on_site')
       order by r.accepted_at desc
       limit 1
    ),
    'history', coalesce((
      select jsonb_agg(jsonb_build_object(
               'short_code', h.short_code,
               'status', h.status,
               'recovered_at', h.recovered_at,
               'stuck_type', h.stuck_type,
               'thank_you', h.thank_you_note
             ) order by h.recovered_at desc nulls last)
        from (
          select * from public.requests
           where accepted_responder_id = me.id
             and status in ('recovered', 'cancelled')
           order by recovered_at desc nulls last
           limit 20
        ) h
    ), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Inbound SMS
--
-- The webhook stays thin: it verifies the Twilio signature, hands the body to this function, and
-- renders whatever reply comes back. Every branch is testable without a network.
-- ---------------------------------------------------------------------------

create or replace function public.handle_inbound_sms(
  p_from       text,
  p_body       text,
  p_to         text default null,
  p_twilio_sid text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  resp     public.responders%rowtype;
  body     text := upper(btrim(coalesce(p_body, '')));
  word     text;
  eta      integer;
  offer    record;
  job      record;
  outcome  jsonb;
begin
  -- Log it first. Even an unparseable reply is part of the conversation.
  insert into public.sms_messages (direction, state, to_phone, from_phone, body, twilio_sid)
  values ('inbound', 'received', coalesce(p_to, 'unknown'), p_from, p_body, p_twilio_sid)
  on conflict (twilio_sid) do nothing;

  select * into resp from public.responders where phone = p_from;

  word := split_part(body, ' ', 1);
  eta  := nullif(regexp_replace(coalesce(split_part(body, ' ', 2), ''), '[^0-9]', '', 'g'), '')::integer;

  -- Carrier-required keywords come first, and they work whether or not we know the sender.
  if word in ('STOP', 'STOPALL', 'UNSUBSCRIBE', 'CANCEL', 'END', 'QUIT', 'BAJA') then
    if resp.id is not null then
      update public.responders
         set sms_opt_in = false, sms_opt_out_at = now(), availability = 'paused'
       where id = resp.id;
    end if;
    -- Twilio itself sends the compliance confirmation; do not send a second one.
    return jsonb_build_object('ok', true, 'action', 'stop', 'reply_template', null);
  end if;

  if word in ('START', 'UNSTOP', 'YES-START', 'ALTA') then
    if resp.id is not null then
      update public.responders
         set sms_opt_in = true, sms_opt_out_at = null, availability = 'active'
       where id = resp.id;
    end if;
    return jsonb_build_object(
      'ok', true, 'action', 'start',
      'reply_template', 'responder.started',
      'locale', coalesce(resp.locale, 'en'), 'params', '{}'::jsonb
    );
  end if;

  if resp.id is null then
    return jsonb_build_object(
      'ok', true, 'action', 'unknown_sender',
      'reply_template', 'unknown.no_account',
      'locale', 'en', 'params', '{}'::jsonb
    );
  end if;

  if word in ('HELP', 'INFO', 'AYUDA') then
    return jsonb_build_object(
      'ok', true, 'action', 'help',
      'reply_template', 'responder.help',
      'locale', resp.locale, 'params', '{}'::jsonb
    );
  end if;

  -- Reporting on the job they already hold.
  if word in ('HERE', 'ONSITE', 'ON', 'LLEGUE', 'LLEGUÉ') then
    select r.id, r.short_code into job
      from public.requests r
     where r.accepted_responder_id = resp.id and r.status = 'accepted'
     order by r.accepted_at desc limit 1;

    if job.id is null then
      return jsonb_build_object('ok', true, 'action', 'no_job',
        'reply_template', 'responder.no_open_job', 'locale', resp.locale, 'params', '{}'::jsonb);
    end if;

    outcome := app.responder_on_site(job.id, resp.id);
    return jsonb_build_object('ok', true, 'action', 'on_site',
      'reply_template', 'responder.on_site_ack', 'locale', resp.locale,
      'params', jsonb_build_object('short_code', job.short_code));
  end if;

  if word in ('DONE', 'OUT', 'RECOVERED', 'LISTO', 'YA') then
    select r.id, r.short_code into job
      from public.requests r
     where r.accepted_responder_id = resp.id and r.status in ('accepted', 'on_site')
     order by r.accepted_at desc limit 1;

    if job.id is null then
      return jsonb_build_object('ok', true, 'action', 'no_job',
        'reply_template', 'responder.no_open_job', 'locale', resp.locale, 'params', '{}'::jsonb);
    end if;

    outcome := app.responder_complete(job.id, resp.id);
    return jsonb_build_object('ok', true, 'action', 'complete',
      'reply_template', 'responder.complete_ack', 'locale', resp.locale,
      'params', jsonb_build_object('short_code', job.short_code));
  end if;

  -- Answering an offer. Most recent open offer wins, which is what someone means when they
  -- reply "1" to the text that just arrived.
  select d.request_id, r.short_code into offer
    from public.dispatches d
    join public.requests r on r.id = d.request_id
   where d.responder_id = resp.id
     and d.state in ('queued', 'sent', 'delivered')
     and r.status in ('submitted', 'dispatching', 'unmatched')
   order by d.queued_at desc
   limit 1;

  if word in ('1', 'YES', 'Y', 'SI', 'SÍ', 'OK', 'TAKE') then
    if offer.request_id is null then
      return jsonb_build_object('ok', true, 'action', 'no_offer',
        'reply_template', 'responder.no_open_job', 'locale', resp.locale, 'params', '{}'::jsonb);
    end if;

    outcome := app.accept_request(offer.request_id, resp.id, eta);

    if (outcome ->> 'ok')::boolean then
      -- The assignment text with the phone and pin is already queued by accept_request.
      return jsonb_build_object('ok', true, 'action', 'accepted', 'reply_template', null);
    end if;

    return jsonb_build_object('ok', true, 'action', outcome ->> 'error',
      'reply_template', 'responder.already_covered', 'locale', resp.locale,
      'params', jsonb_build_object('short_code', offer.short_code));
  end if;

  if word in ('2', 'NO', 'N', 'PASS', 'PASO') then
    if offer.request_id is null then
      return jsonb_build_object('ok', true, 'action', 'no_offer',
        'reply_template', 'responder.no_open_job', 'locale', resp.locale, 'params', '{}'::jsonb);
    end if;

    perform app.decline_dispatch(offer.request_id, resp.id);
    return jsonb_build_object('ok', true, 'action', 'declined',
      'reply_template', 'responder.declined_ack', 'locale', resp.locale, 'params', '{}'::jsonb);
  end if;

  return jsonb_build_object('ok', true, 'action', 'unparsed',
    'reply_template', 'responder.help', 'locale', resp.locale, 'params', '{}'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

revoke execute on function public.advance_dispatch(integer)                from public, anon, authenticated;
revoke execute on function public.handle_inbound_sms(text, text, text, text)     from public, anon, authenticated;
revoke execute on function public.accept_request(uuid, integer)            from public, anon;
revoke execute on function public.decline_request(uuid)                    from public, anon;
revoke execute on function public.report_on_site(uuid)                     from public, anon;
revoke execute on function public.report_complete(uuid)                    from public, anon;
revoke execute on function public.upsert_responder_profile(jsonb)          from public, anon;
revoke execute on function public.set_my_availability(text)                from public, anon;
revoke execute on function public.my_responder_profile()                   from public, anon;

grant execute on function public.advance_dispatch(integer)             to service_role;
grant execute on function public.handle_inbound_sms(text, text, text, text)  to service_role;
grant execute on function public.accept_request(uuid, integer)         to authenticated, service_role;
grant execute on function public.decline_request(uuid)                 to authenticated, service_role;
grant execute on function public.report_on_site(uuid)                  to authenticated, service_role;
grant execute on function public.report_complete(uuid)                 to authenticated, service_role;
grant execute on function public.upsert_responder_profile(jsonb)       to authenticated, service_role;
grant execute on function public.set_my_availability(text)             to authenticated, service_role;
grant execute on function public.my_responder_profile()                to authenticated, service_role;

grant execute on all functions in schema app to service_role;
