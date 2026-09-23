-- Winch Up :: finding somebody to help, and seeing who offered
--
-- Two read paths the pull model needs and the push model never did.
--
-- responder_feed() is an inbox: it joins through dispatches and answers "what was I asked
-- about". That is the right shape for somebody who was rung. It cannot answer "who near me needs
-- help right now", because under the old model nobody was allowed to ask that -- you waited to
-- be texted. nearby_requests() is that question.
--
-- WHAT A BROWSING MEMBER IS ALLOWED TO SEE
--
-- The approximate pin, never the exact one. requests.approx_location is blurred to about a mile
-- and is what /board has always shown; the real coordinates are released to one person, once
-- they are assigned. That rule is older than this phase and this phase does not get to relax it
-- just because more people can now look. No name, no phone, no token.
--
-- A member with no position at all still gets a list -- spec section 5 says availability being
-- off must not stop somebody browsing, and the same reasoning covers not having shared where
-- they are. They get recency instead of distance, which is worse but is not nothing.

set search_path = public, extensions;

create or replace function public.nearby_requests(
  p_lat          double precision default null,
  p_lng          double precision default null,
  p_radius_miles integer          default 60,
  p_limit        integer          default 50
)
returns table (
  request_id         uuid,
  short_code         text,
  status             request_status,
  distance_miles     numeric,
  lat                double precision,
  lng                double precision,
  vehicle_class      vehicle_class,
  stuck_type         stuck_type,
  stuck_depth        stuck_depth,
  needs_tractor      boolean,
  needs_second_truck boolean,
  land_type          land_type,
  required_equipment equipment_type[],
  county             text,
  created_at         timestamptz,
  offer_state        dispatch_state,
  i_offered          boolean
)
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
  with me as (
    select
      r.id as responder_id,
      -- The browser's live position wins when the page has one, because somebody looking at this
      -- screen is usually already out somewhere. Then their shared position, then home.
      coalesce(
        case when p_lat is not null and p_lng is not null
             then extensions.st_setsrid(extensions.st_point(p_lng, p_lat), 4326)::extensions.geography
             else null end,
        case when r.share_location
              and r.last_location is not null
              and r.last_location_at > now() - make_interval(
                    mins => app.setting_int('dispatch.location_freshness_minutes', 120))
             then r.last_location else null end,
        r.home_location
      ) as origin
    from public.responders r
    where r.user_id = auth.uid()
  ),
  -- A member who has never opened the volunteer side has no responders row yet. They can still
  -- browse; they just have no stored position to fall back on.
  origin as (
    select
      (select responder_id from me) as responder_id,
      coalesce(
        (select origin from me),
        case when p_lat is not null and p_lng is not null
             then extensions.st_setsrid(extensions.st_point(p_lng, p_lat), 4326)::extensions.geography
             else null end
      ) as point
  )
  select
    r.id,
    r.short_code,
    r.status,
    case when o.point is null then null
         else round((extensions.st_distance(o.point, r.location) / 1609.344)::numeric, 2)
    end,
    -- Always the blurred pin. There is no branch here that can return r.location, which is the
    -- point: this feed is read by anybody signed in, and the exact position belongs to the one
    -- person who gets assigned.
    extensions.st_y(r.approx_location::extensions.geometry),
    extensions.st_x(r.approx_location::extensions.geometry),
    r.vehicle_class,
    r.stuck_type,
    r.stuck_depth,
    r.needs_tractor,
    r.needs_second_truck,
    r.land_type,
    r.required_equipment,
    r.county,
    r.created_at,
    d.state,
    d.state = 'offered'
  from public.requests r
  cross join origin o
  left join public.dispatches d
    on d.request_id = r.id and d.responder_id = o.responder_id
  where r.status in ('submitted', 'dispatching', 'unmatched')
    -- Not your own. You cannot help yourself out of a ditch and the list should not pretend
    -- otherwise.
    and (r.requester_user_id is distinct from auth.uid())
    and (
      o.point is null
      or extensions.st_dwithin(o.point, r.location, app.miles_to_meters(p_radius_miles))
    )
  order by
    case when o.point is null then null
         else extensions.st_distance(o.point, r.location) end
      nulls last,
    r.created_at desc
  limit greatest(1, least(p_limit, 100));
$fn$;

revoke all on function public.nearby_requests(double precision, double precision, integer, integer)
  from public, anon;
grant execute on function public.nearby_requests(double precision, double precision, integer, integer)
  to authenticated, service_role;

comment on function public.nearby_requests(double precision, double precision, integer, integer) is
  'Spec section 3. Open requests near the caller, blurred pin only. Signed-in members only: this '
  'is the discovery surface, and /board remains the public one.';

-- ---------------------------------------------------------------------------
-- Offers on the status page
-- ---------------------------------------------------------------------------
--
-- Added to get_request_by_token rather than given its own RPC. Two reasons, and the second is
-- the real one:
--
--   the status page already calls this and rendering offers is one round trip either way; and
--   schema_audit_test asserts that anon can execute exactly four security definer functions, by
--   name. A fifth would be a deliberate widening of the public surface, and offers do not need
--   one -- they are part of the request the caller already proved they can read.
--
-- What an offer exposes: a first name, what they drive, how far out, when they offered, and
-- whether an admin has verified them. Not a phone number. Contact details are still released to
-- exactly one person at exactly one moment, which is acceptance.

create or replace function public.get_request_by_token(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
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

  assigned := r.accepted_responder_id is not null
              and r.status in ('accepted', 'on_site', 'recovered');

  select value into radii from public.app_settings where key = 'dispatch.ring_radii_miles';

  result := jsonb_build_object(
    'id',              r.id,
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

    -- Spec section 8, steps 4 and 5. Only while the request is still open: once somebody is
    -- assigned, 'responder' below is the answer and a list of people who were passed over is not
    -- information the requester needs on a live recovery.
    'offers', case when r.accepted_responder_id is null
                    and r.status in ('submitted', 'dispatching', 'unmatched')
              then coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',             d.id,
               'first_name',     resp.first_name,
               'vehicle_class',  resp.vehicle_class,
               'vehicle_desc',   resp.vehicle_desc,
               'distance_miles', d.distance_miles,
               'eta_minutes',    d.offer_eta_minutes,
               'note',           d.offer_note,
               'origin',         d.origin,
               -- The badge that replaced the approval gate.
               'verified',       resp.approval = 'approved',
               'offered_at',     d.offered_at
             ) order by d.offered_at)
        from public.dispatches d
        join public.responders resp on resp.id = d.responder_id
       where d.request_id = r.id and d.state = 'offered'
    ), '[]'::jsonb) else '[]'::jsonb end,

    'responder', case when assigned then (
      select jsonb_build_object(
               'first_name',    resp.first_name,
               'vehicle_class', resp.vehicle_class,
               'vehicle_desc',  resp.vehicle_desc,
               'phone',         resp.phone
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
$fn$;
