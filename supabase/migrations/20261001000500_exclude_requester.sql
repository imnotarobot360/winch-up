-- Winch Up :: never dispatch somebody to their own recovery
--
-- app.candidates() did not exclude the requester, and with universal membership that is not
-- an edge case: a member who offers help and then needs it is the closest possible match to
-- their own request.
--
-- Found auditing against the owner's location-alerts spec on 2026-10-01 ("Exclude the
-- requester"), and verified both ways -- the requester is absent from their own candidates,
-- and another available member at the same point is still returned, so this is an exclusion
-- rather than an off switch.
--
-- RECREATED FROM THE LIVE DEFINITION, not from the migration that first created this
-- function. Later files changed these filters -- the old sms_opt_in gate is long gone,
-- replaced by available_to_help and notify_recovery -- and rebuilding from the original
-- source would have silently reverted them.

set search_path = public, extensions;

CREATE OR REPLACE FUNCTION app.candidates(p_request_id uuid, p_radius_miles integer, p_limit integer)
 RETURNS TABLE(responder_id uuid, distance_miles numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  with req as (
    -- requester_user_id joins the CTE so the exclusion below can name it.
    select id, location, required_equipment, requester_user_id
      from public.requests where id = p_request_id
  ),
  clock as (
    select (extract(hour from (now() at time zone 'America/Chicago')) >= 21
            or extract(hour from (now() at time zone 'America/Chicago')) < 6) as is_night
  ),
  fresh as (
    select app.setting_int('dispatch.location_freshness_minutes', 120) as minutes
  ),
  r as (
    select
      resp.*,
      case
        when resp.share_location
         and resp.last_location is not null
         and resp.last_location_at > now() - make_interval(mins => fresh.minutes)
        then resp.last_location
        else resp.home_location
      end as effective_location
    from public.responders resp
    cross join fresh
  )
  select
    r.id,
    round((extensions.st_distance(r.effective_location, req.location) / 1609.344)::numeric, 2)
  from r
  cross join req
  cross join clock
  where r.availability = 'active'
    -- NOBODY IS DISPATCHED TO THEIR OWN RECOVERY.
    --
    -- Since universal membership every member can both ask for help and offer it, so the
    -- person stuck in the mud is very often an available responder with a fresh position
    -- sitting zero miles from their own request -- which made them the FIRST candidate
    -- returned. The alert reads 'a fellow off-roader needs help 0.0 miles away'; it is
    -- their own request coming back at them.
    --
    -- Proven before this line existed rather than inferred: a fixture where one account was
    -- both the requester and an active responder at the same point returned that responder.
    --
    -- user_id is null for a legacy responder with no account, who cannot be the requester.
    and (r.user_id is null or r.user_id is distinct from req.requester_user_id)
    -- The member said they are willing to be called out. coalesce false for an account holder
    -- with no profile row, true for a legacy responder with no account at all: the first is a
    -- data gap we should not read as consent, the second never had the chance to choose.
    and case
          when r.user_id is null then true
          else coalesce(
                 (select p.available_to_help from public.profiles p where p.user_id = r.user_id),
                 false
               )
        end
    and coalesce(
          (select p.notify_recovery from public.profiles p where p.user_id = r.user_id),
          true
        )
    and (r.paused_until is null or r.paused_until <= now())
    and (not clock.is_night or r.night_ok)
    and (
          r.equipment
          || coalesce(
               (select array_agg(distinct e)
                  from public.vehicles v, unnest(v.equipment) e
                 where v.user_id = r.user_id),
               '{}'::equipment_type[]
             )
        ) @> req.required_equipment
    and extensions.st_dwithin(
          r.effective_location,
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
  order by extensions.st_distance(r.effective_location, req.location)
  limit greatest(1, p_limit);
$function$


