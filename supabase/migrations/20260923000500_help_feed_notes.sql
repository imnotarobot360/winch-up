-- Winch Up :: the Help Someone feed was missing the one line that says what happened
--
-- nearby_requests() returned the vehicle, how stuck, how deep, distance, county and what kit was
-- asked for -- everything structured, and nothing the person actually wrote.
--
-- /board, which is the PUBLIC page and where nobody can act, has always shown `notes`. /help,
-- which is members-only and is where somebody decides whether to hitch up and drive forty
-- minutes, did not. That is backwards: "Rear end sank in a rut after the rain, tires spinning"
-- is often the difference between a winch job and a tractor job, and a volunteer with the wrong
-- kit finds out on arrival.
--
-- It is already public text. It carries the same CHECK as every other public free-text column --
-- contains_contact_info() rejects phone numbers and links on the way in -- so showing it here
-- exposes nothing /board has not shown since the first week.
--
-- Found by an end-to-end test that tried to identify a request by what its author wrote and
-- could not, which is a reasonable thing for a person to want to do too.
--
-- Fix-forward rather than an edit to 20260923000300: that file is pushed, and it may have been
-- pasted into production by the time this lands.

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
  notes              text,
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
    -- Still the blurred pin, and still no branch here that can return r.location.
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
    r.notes,
    r.created_at,
    d.state,
    d.state = 'offered'
  from public.requests r
  cross join origin o
  left join public.dispatches d
    on d.request_id = r.id and d.responder_id = o.responder_id
  where r.status in ('submitted', 'dispatching', 'unmatched')
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
