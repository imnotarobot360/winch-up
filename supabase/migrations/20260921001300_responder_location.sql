-- Winch Up :: match on where a volunteer actually is
--
-- Phase 6: "use recent, permissioned location information rather than assuming a member's home
-- region represents their current position."
--
-- Until now every ring query measured from home_location, typed once at signup. A volunteer
-- already out on the trail forty miles from home -- which is exactly when they are most useful,
-- and often how they saw the group post in the first place -- was matched as if sitting in their
-- driveway. Meanwhile someone whose home is two miles away but is at work in another city got
-- texted and could not go.
--
-- What this is NOT: tracking. There is no background reporting, no periodic ping, and nothing
-- that runs when the app is closed. A volunteer presses a button, the browser asks permission,
-- and one point is stored. Phase 14 forbids claiming continuous location monitoring, and the
-- honest way to not claim it is to not build it.
--
-- Three things keep that honest:
--
--   * share_location defaults false. Nothing is stored until somebody opts in by acting.
--   * A point older than dispatch.location_freshness_minutes is ignored entirely and matching
--     silently falls back to home_location. Stale beats wrong: a volunteer who shared their
--     position on Saturday should not be matched from it on Tuesday.
--   * forget_my_location() nulls it and turns sharing off, in one call.
--
-- The point is never public. board_requests() and every other anon-reachable path read requests,
-- not responders, and responders has no anon grants at all.

set search_path = public, extensions;

alter table responders
  add column share_location    boolean not null default false,
  add column last_location     extensions.geography(Point, 4326),
  add column last_location_at  timestamptz,
  add column last_location_accuracy_m numeric;

-- Partial: most rows will never have one.
create index responders_last_location_idx
  on responders using gist (last_location)
  where last_location is not null;

comment on column responders.last_location is
  'Point-in-time position, stored only when the volunteer pressed a button and granted browser '
  'geolocation. Not tracking: nothing writes here in the background. Ignored by matching once '
  'older than dispatch.location_freshness_minutes.';

insert into app_settings (key, value, description, is_public) values
  ('dispatch.location_freshness_minutes', '120'::jsonb,
   'How long a volunteer''s shared position is trusted for matching before it is ignored and '
   'matching falls back to their home location.', false)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Sharing, and stopping
-- ---------------------------------------------------------------------------

create or replace function public.update_my_location(
  p_lat double precision,
  p_lng double precision,
  p_accuracy_m numeric default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_id   uuid;
begin
  if v_user is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  if p_lat is null or p_lng is null
     or p_lat < -90 or p_lat > 90 or p_lng < -180 or p_lng > 180 then
    return jsonb_build_object('ok', false, 'error', 'invalid_location');
  end if;

  -- A fix this vague cannot improve on a home address, and pretending otherwise would move
  -- somebody's apparent position by miles on the strength of a wifi guess.
  if p_accuracy_m is not null and p_accuracy_m > 10000 then
    return jsonb_build_object('ok', false, 'error', 'too_inaccurate');
  end if;

  select id into v_id from responders where user_id = v_user;

  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'not_a_responder');
  end if;

  -- Calling this IS the opt-in: the browser has already asked and the volunteer already agreed.
  update responders
     set share_location = true,
         last_location = extensions.st_setsrid(extensions.st_point(p_lng, p_lat), 4326)::extensions.geography,
         last_location_at = now(),
         last_location_accuracy_m = p_accuracy_m
   where id = v_id;

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.forget_my_location()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  update responders
     set share_location = false,
         last_location = null,
         last_location_at = null,
         last_location_accuracy_m = null
   where user_id = v_user;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.update_my_location(double precision, double precision, numeric)
  from public, anon;
grant execute on function public.update_my_location(double precision, double precision, numeric)
  to authenticated;

revoke all on function public.forget_my_location() from public, anon;
grant execute on function public.forget_my_location() to authenticated;

-- ---------------------------------------------------------------------------
-- Matching measures from where they are, falling back to where they live
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
