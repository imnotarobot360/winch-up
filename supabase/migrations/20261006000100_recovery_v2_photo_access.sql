-- Recovery V2: photo access follows universal member eligibility.
--
-- The original ring-photo authorization predates universal membership and still required
-- profiles.available_to_help. That legacy opt-in is no longer a recovery eligibility gate,
-- so a geographically eligible active member could see the SOS card but be denied its photos.

set search_path = public, extensions;

create or replace function app.may_see_request_photos(p_request_id uuid, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
  with req as (
    select r.id, r.location, r.status, r.current_ring, r.requester_user_id
      from public.requests r
     where r.id = p_request_id
  ),
  ring as (
    select coalesce(
             (value -> (greatest(coalesce((select current_ring from req), 1), 1) - 1))::integer,
             60
           ) as miles
      from public.app_settings
     where key = 'dispatch.ring_radii_miles'
  )
  select exists (
    select 1
      from req
      join public.responders resp
        on resp.user_id = p_user
       and resp.redacted_at is null
      cross join ring
     where req.status in ('submitted', 'dispatching', 'unmatched')
       and req.requester_user_id is distinct from p_user
       and resp.availability = 'active'
       and extensions.st_dwithin(
             case
               when resp.last_location is not null
                and resp.last_location_at > now() - make_interval(
                      mins => app.setting_int('dispatch.location_freshness_minutes', 120))
               then resp.last_location
               else resp.home_location
             end,
             req.location,
             app.miles_to_meters(least(ring.miles, resp.radius_miles))
           )
  );
$fn$;

comment on function app.may_see_request_photos(uuid, uuid) is
  'Recovery V2: true for an active, geographically eligible member in the request current ring; legacy available_to_help is not an eligibility gate.';

notify pgrst, 'reload schema';
