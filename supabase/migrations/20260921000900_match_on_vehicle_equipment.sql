-- Winch Up :: match on what is actually in the driveway
--
-- Until now a volunteer matched on responders.equipment alone -- one flat list typed at signup.
-- Phase 4 gave members rigs with their own equipment, and a winch added to the Jeep did nothing
-- for matching. This closes that gap.
--
-- Capability is the UNION of the declared list and everything across their vehicles, not the
-- best single rig. Two reasons:
--
--  * Most of this kit is portable. Straps, soft shackles, boards, a compressor and a jack move
--    between trucks in a couple of minutes. Requiring one rig to carry the whole list would
--    exclude people who can plainly do the job.
--  * The declared list stays meaningful for things no vehicle row can express -- a tractor at
--    the property, a second driver, a trailer that lives on a different hitch.
--
-- The honest limit: a winch is bolted to one truck, so the union can suggest a pairing the
-- volunteer cannot actually bring in a single trip. That is a false positive on a text message
-- asking whether they can help, which they answer with 1 or 2. The opposite error -- not texting
-- somebody who could have come -- leaves a person sitting in a ditch, and is the one worth
-- avoiding.
--
-- The subquery is per candidate row rather than an aggregate over the whole table, and
-- vehicles_user_idx covers it. Responders with no account (user_id null, left behind by an
-- account deletion) simply contribute nothing and keep matching on their declared list.

set search_path = public, extensions;

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
