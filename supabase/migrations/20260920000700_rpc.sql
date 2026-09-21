-- Winch Up M1 :: read RPCs
--
-- These are the only doors into the data for anonymous requesters and for volunteers who need
-- more than the column grants allow. Each one redacts at the source: there is no code path where
-- a phone number or an exact pin is returned to someone who should not have it.
--
-- Write RPCs (create_request, accept, cancel, mark recovered) land in M2/M3.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- Settings the client is allowed to know about (ring radii, timers, copy flags)
-- ---------------------------------------------------------------------------

create or replace function public.get_public_settings()
returns jsonb
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    from public.app_settings
   where is_public;
$$;

-- ---------------------------------------------------------------------------
-- Requester status page: /r/[token]
-- ---------------------------------------------------------------------------

create or replace function public.get_request_by_token(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  r        public.requests%rowtype;
  radii    jsonb;
  assigned boolean;
  result   jsonb;
begin
  if p_token is null or length(p_token) < 16 then
    return null;
  end if;

  select * into r from public.requests where public_token = p_token;
  if not found then
    return null;
  end if;

  -- Contact details are released only once someone has actually taken the job.
  assigned := r.accepted_responder_id is not null
              and r.status in ('accepted', 'on_site', 'recovered');

  select value into radii from public.app_settings where key = 'dispatch.ring_radii_miles';

  result := jsonb_build_object(
    'short_code',      r.short_code,
    'status',          r.status,
    'locale',          r.locale,
    'created_at',      r.created_at,
    'requester_name',  r.requester_name,
    'lat',             extensions.st_y(r.location::extensions.geometry),
    'lng',             extensions.st_x(r.location::extensions.geometry),
    'accuracy_m',      r.location_accuracy_m,
    'county',          r.county,
    'vehicle', jsonb_build_object(
      'class', r.vehicle_class, 'make', r.vehicle_make,
      'model', r.vehicle_model, 'year', r.vehicle_year, 'drivetrain', r.drivetrain
    ),
    'situation', jsonb_build_object(
      'stuck_type', r.stuck_type, 'stuck_depth', r.stuck_depth,
      'needs_tractor', r.needs_tractor, 'needs_second_truck', r.needs_second_truck,
      'land_type', r.land_type, 'notes', r.notes
    ),
    'dispatch', jsonb_build_object(
      'current_ring',    r.current_ring,
      'radius_miles',    case when r.current_ring between 1 and 3
                              then (radii -> (r.current_ring - 1)) else null end,
      'notified_count',  r.notified_count,
      'started_at',      r.dispatch_started_at,
      'unmatched_at',    r.unmatched_at
    ),
    'eta_minutes',   r.eta_minutes,
    'on_site_at',    r.on_site_at,
    'recovered_at',  r.recovered_at,
    'cancelled_at',  r.cancelled_at,
    'thanked',       r.thank_you_note is not null,
    'photos', coalesce((
      select jsonb_agg(jsonb_build_object('path', p.storage_path, 'sort', p.sort_order)
                       order by p.sort_order)
        from public.request_photos p where p.request_id = r.id
    ), '[]'::jsonb),
    'timeline', coalesce((
      select jsonb_agg(jsonb_build_object(
               'type', e.event_type, 'at', e.created_at, 'data', e.data
             ) order by e.created_at, e.id)
        from public.request_events e
       where e.request_id = r.id and e.is_public
    ), '[]'::jsonb),
    'responder', case when assigned then (
      select jsonb_build_object(
               'first_name',    resp.first_name,
               'vehicle_class', resp.vehicle_class,
               'vehicle_desc',  resp.vehicle_desc,
               'phone',         resp.phone          -- released only in this branch
             )
        from public.responders resp where resp.id = r.accepted_responder_id
    ) else null end,
    'pro_options', case when r.status = 'unmatched' then coalesce((
      select jsonb_agg(jsonb_build_object(
               'name', po.name, 'phone', po.phone, 'url', po.url,
               'blurb', case when r.locale = 'es' then po.blurb_es else po.blurb_en end
             ) order by po.sort_order)
        from public.pro_options po where po.is_active
    ), '[]'::jsonb) else null end
  );

  return result;
end;
$$;

comment on function public.get_request_by_token(text) is
  'Requester view of their own request. The responder phone appears only after acceptance.';

-- ---------------------------------------------------------------------------
-- Public board: /board
-- ---------------------------------------------------------------------------
--
-- Blurred pin, no names, no phones. By default the pin stays blurred even after acceptance;
-- flip app_settings key `board.reveal_exact_after_accept` to change that.

create or replace function public.board_requests(p_limit integer default 50)
returns table (
  short_code      text,
  status          request_status,
  lat             double precision,
  lng             double precision,
  is_approximate  boolean,
  county          text,
  state           text,
  vehicle_class   vehicle_class,
  stuck_type      stuck_type,
  stuck_depth     stuck_depth,
  needs_tractor   boolean,
  needs_second_truck boolean,
  notes           text,
  photo_count     integer,
  responder_first_name text,
  created_at      timestamptz,
  accepted_at     timestamptz,
  recovered_at    timestamptz
)
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  with cfg as (
    select coalesce(
             (select (value #>> '{}')::boolean from public.app_settings
               where key = 'board.reveal_exact_after_accept'),
             false
           ) as reveal_exact
  ),
  visible as (
    select r.*,
           (select cfg.reveal_exact from cfg) as reveal_exact
      from public.requests r
     where not r.is_test
       and (
         r.status in ('submitted', 'dispatching', 'unmatched', 'accepted', 'on_site')
         or (r.status = 'recovered' and r.recovered_at > now() - interval '24 hours')
       )
  )
  select
    v.short_code,
    v.status,
    extensions.st_y((case when v.reveal_exact and v.accepted_responder_id is not null
                          then v.location else v.approx_location end)::extensions.geometry),
    extensions.st_x((case when v.reveal_exact and v.accepted_responder_id is not null
                          then v.location else v.approx_location end)::extensions.geometry),
    not (v.reveal_exact and v.accepted_responder_id is not null),
    v.county,
    v.state,
    v.vehicle_class,
    v.stuck_type,
    v.stuck_depth,
    v.needs_tractor,
    v.needs_second_truck,
    v.notes,
    (select count(*)::integer from public.request_photos p where p.request_id = v.id),
    (select resp.first_name from public.responders resp where resp.id = v.accepted_responder_id),
    v.created_at,
    v.accepted_at,
    v.recovered_at
  from visible v
  order by v.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 200));
$$;

-- ---------------------------------------------------------------------------
-- Volunteer: the jobs I have been offered
-- ---------------------------------------------------------------------------

create or replace function public.responder_feed()
returns table (
  request_id      uuid,
  short_code      text,
  status          request_status,
  dispatch_state  dispatch_state,
  ring            smallint,
  distance_miles  numeric,
  lat             double precision,
  lng             double precision,
  is_approximate  boolean,
  vehicle_class   vehicle_class,
  stuck_type      stuck_type,
  stuck_depth     stuck_depth,
  needs_tractor   boolean,
  needs_second_truck boolean,
  land_type       land_type,
  notes           text,
  is_mine         boolean,
  created_at      timestamptz
)
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  select
    r.id,
    r.short_code,
    r.status,
    d.state,
    d.ring,
    d.distance_miles,
    extensions.st_y((case when r.accepted_responder_id = d.responder_id
                          then r.location else r.approx_location end)::extensions.geometry),
    extensions.st_x((case when r.accepted_responder_id = d.responder_id
                          then r.location else r.approx_location end)::extensions.geometry),
    r.accepted_responder_id is distinct from d.responder_id,
    r.vehicle_class,
    r.stuck_type,
    r.stuck_depth,
    r.needs_tractor,
    r.needs_second_truck,
    r.land_type,
    r.notes,
    r.accepted_responder_id = d.responder_id,
    r.created_at
  from public.dispatches d
  join public.requests r on r.id = d.request_id
  where d.responder_id = app.current_responder_id()
  order by r.created_at desc
  limit 100;
$$;

-- The one place a volunteer can get the requester's phone and exact pin: their own accepted job.
create or replace function public.get_job_contact(p_request_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  me uuid := app.current_responder_id();
  r  public.requests%rowtype;
begin
  if me is null then
    return null;
  end if;

  select * into r
    from public.requests
   where id = p_request_id
     and accepted_responder_id = me
     and status in ('accepted', 'on_site', 'recovered');

  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'short_code',      r.short_code,
    'requester_name',  r.requester_name,
    'requester_phone', r.requester_phone,
    'lat',             extensions.st_y(r.location::extensions.geometry),
    'lng',             extensions.st_x(r.location::extensions.geometry),
    'accuracy_m',      r.location_accuracy_m,
    'location_note',   r.location_note,
    'photos', coalesce((
      select jsonb_agg(p.storage_path order by p.sort_order)
        from public.request_photos p where p.request_id = r.id
    ), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Admin detail (the private columns admins legitimately need)
-- ---------------------------------------------------------------------------

create or replace function public.admin_request_detail(p_request_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  r public.requests%rowtype;
begin
  if not app.is_admin() then
    raise exception 'forbidden' using errcode = 'insufficient_privilege';
  end if;

  select * into r from public.requests where id = p_request_id;
  if not found then
    return null;
  end if;

  -- The parentheses matter: Postgres binds binary `-` tighter than `||`, so without them the
  -- key removal applies to the little lat/lng object instead of the row, and the raw geography
  -- blobs stay in the payload.
  return (to_jsonb(r) - 'location' - 'approx_location')
         || jsonb_build_object(
              'lat', extensions.st_y(r.location::extensions.geometry),
              'lng', extensions.st_x(r.location::extensions.geometry)
            );
end;
$$;

-- ---------------------------------------------------------------------------
-- Lock the door: nothing in `public` is callable unless it is listed below.
-- ---------------------------------------------------------------------------

revoke execute on all functions in schema public from public;
revoke execute on all functions in schema public from anon, authenticated;

grant execute on function public.contains_contact_info(text) to anon, authenticated, service_role;
grant execute on function public.get_public_settings()        to anon, authenticated, service_role;
grant execute on function public.get_request_by_token(text)   to anon, authenticated, service_role;
grant execute on function public.board_requests(integer)      to anon, authenticated, service_role;
grant execute on function public.responder_feed()             to authenticated, service_role;
grant execute on function public.get_job_contact(uuid)        to authenticated, service_role;
grant execute on function public.admin_request_detail(uuid)   to authenticated, service_role;
