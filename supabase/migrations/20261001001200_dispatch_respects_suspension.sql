-- Winch Up :: suspension, deletion and blocking reach the dispatcher
--
-- Found by the control assertion in directory_test.sql, which is the whole reason it is there.
-- Asking "is a suspended member excluded?" on its own passes when app.candidates() returns
-- nothing at all; pairing it with "is a willing member included?" is what showed that the
-- suspended fixture came back as the SECOND-NEAREST candidate, 0.07 miles from the recovery.
--
-- Making every profile visible is what raised the stakes. Suspension is now the only thing that
-- removes an abusive account from the community, so it has to remove them from everything: the
-- directory, their profile, and the ring.
--
-- Rebuilt from the LIVE definition out of pg_proc rather than from the newest migration that
-- mentions candidates(). This function has been redefined at least three times -- universal
-- membership rewrote it, 20261001000500 added the self-dispatch exclusion -- and taking any one
-- file as the base would silently revert the others.
--
-- Three conditions added. Nothing else changed.

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
    -- A SUSPENDED MEMBER IS NOT ON CALL.
    --
    -- Added with the open directory (20261001001100). Suspension removes somebody from the
    -- directory and makes their profile unreadable, and if it stopped there the worst of both
    -- would be true: invisible to the community and still rung at 3am to go and help a stranger,
    -- with the requester told a volunteer is coming.
    and coalesce(
          (select p.suspended_at is null from public.profiles p where p.user_id = r.user_id),
          true
        )
    -- A DELETED ACCOUNT IS NOT ON CALL EITHER.
    --
    -- app.scrub_responder nulls home_location on deletion, so in practice a redacted responder
    -- already falls out when st_dwithin yields null against a null location -- which is why this
    -- was never a live leak. But it depended on a side effect of the scrub two files away
    -- rather than on anything stated here, and a fixture with redacted_at set and a location
    -- still in place came straight back as the second-nearest candidate.
    and r.redacted_at is null
    -- NOBODY IS SENT TO SOMEBODY THEY BLOCKED, OR WHO BLOCKED THEM.
    --
    -- Section 6 of the spec: blocked members must not be able to initiate contact. Dispatching a
    -- volunteer to a requester one of them has blocked is initiating contact, by SMS and push,
    -- with the requester's phone number handed over on acceptance. blocks_between is symmetric,
    -- and is false when either side is null, so a request filed by no account is unaffected.
    and not app.blocks_between(req.requester_user_id, r.user_id)
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
$function$;
