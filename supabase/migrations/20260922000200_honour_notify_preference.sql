-- Winch Up :: honour the notification preference the app already offers
--
-- profiles.notify_recovery has existed since Phase 3 and the account page has been writing it
-- since then. Nothing read it. A volunteer could switch off "Recovery alerts", watch it save, and
-- still be texted at 2am -- which is worse than never offering the control, because they believe
-- it worked.
--
-- Phase 13 asks that users can manage notification preferences. They could; the preference just
-- did not do anything.
--
-- Two switches, deliberately kept separate:
--
--   responders.sms_opt_in     the carrier channel. Flipped by replying STOP, and legally the
--                             one that must be obeyed regardless of anything in the app.
--   profiles.notify_recovery  the person's own choice, made on a screen they can see.
--
-- Both must hold. A volunteer with no account has no profile row and keeps being matched, since
-- they were never given the chance to choose.

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
  ),
  fresh as (
    select app.setting_int('dispatch.location_freshness_minutes', 120) as minutes
  ),
  -- Where to measure from. A shared position that is still fresh, otherwise home. Stale beats
  -- wrong: somebody who shared their position on Saturday should not be matched from it on
  -- Tuesday.
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
  where r.approval = 'approved'
    and r.availability = 'active'
    and r.sms_opt_in
    and r.sms_opt_out_at is null
    -- The volunteer's own preference, set on /account. Two switches exist and they mean
    -- different things: sms_opt_in is the carrier-level channel, flipped by replying STOP, and
    -- notify_recovery is the person deciding in the app. Both have to hold.
    --
    -- coalesce true, because a volunteer with no account never had the chance to express a
    -- preference and silently dropping them would be worse than texting them.
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
$$;
