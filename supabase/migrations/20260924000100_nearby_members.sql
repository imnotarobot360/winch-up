-- Winch Up :: a directory of members who chose to be in one
--
-- Screens 7 and 8 of the design reference: Nearby Members, and a member's public profile. This is
-- the first surface in the product that lets one member browse others, so the interesting part is
-- not the query -- it is who is in it, and what a row is allowed to say.
--
-- WHO IS LISTED
--
-- Two opt-ins, both of them explicit, both already in the schema and both defaulting to off:
--
--   profiles.profile_public    "other members may see my profile"
--   profiles.available_to_help "I am up for being called out"
--
-- Either one alone is not consent to be in a browsable list. available_to_help on its own means
-- "ring me when somebody near me is stuck", which is a different thing from "put me in a
-- directory strangers can page through". profile_public on its own means a profile exists to be
-- linked to, not that it should be pushed at people. So: both, or you are not here.
--
-- The list will start almost empty. That is the correct behaviour for a consent-based directory
-- on its first day, and the honest alternative to filling it with people who never agreed.
--
-- WHAT A ROW SAYS, AND WHAT IT DOES NOT
--
-- No coordinates leave this function. Distance is computed server-side and rounded to whole miles
-- -- and, above five miles, to the nearest five. An exact distance from a known point is a circle;
-- three of them is an address, and a directory that refreshes is three of them. Rounding costs a
-- browsing member nothing and takes trilateration off the table.
--
-- Distance is measured from home_location, which is the coarse thing responders give at signup,
-- never from last_location. A shared live position exists to match somebody to a recovery they
-- are near; it is not for telling strangers where a volunteer is standing right now.
--
-- No phone. No email. No exact pin. The way to reach somebody is the recovery they are on.
--
-- A redacted responder -- deleted account, or aged past retention -- is excluded outright rather
-- than shown as "Removed", which would be a tombstone in a directory of living people.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- The distance rounding, as its own function so the profile and the list agree
-- ---------------------------------------------------------------------------

create or replace function app.coarse_miles(p_meters double precision)
returns integer
language sql
immutable
set search_path = pg_catalog
as $$
  select case
    when p_meters is null then null
    -- Under five miles, whole miles: "2 mi away" is useful and is already a circle three miles
    -- across, which is not an address.
    when p_meters < 8046.72 then greatest(1, round(p_meters / 1609.344))::integer
    -- Beyond that, the nearest five. Precision stops being useful to a reader long before it
    -- stops being useful to somebody triangulating.
    else (round(p_meters / 1609.344 / 5) * 5)::integer
  end;
$$;

comment on function app.coarse_miles(double precision) is
  'Metres to a deliberately coarse mile figure. Whole miles under five, nearest five above, so a '
  'directory that refreshes cannot be averaged into a position.';

-- ---------------------------------------------------------------------------
-- The list
-- ---------------------------------------------------------------------------

create or replace function public.nearby_members(
  p_lat         double precision default null,
  p_lng         double precision default null,
  p_limit       integer default 50,
  p_equipment   text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me     uuid := auth.uid();
  v_origin extensions.geography;
  v_rows   jsonb;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  -- Where "nearby" is measured from. An explicit point wins -- the screen may be showing a map
  -- the member has panned -- and otherwise it is their own home location. Somebody with neither
  -- gets the list unsorted rather than an error: a member who has not set a home region can still
  -- browse, they just cannot be told how far away anybody is.
  if p_lat is not null and p_lng is not null then
    v_origin := extensions.st_setsrid(extensions.st_point(p_lng, p_lat), 4326)::extensions.geography;
  else
    select r.home_location into v_origin
      from public.responders r
     where r.user_id = v_me and r.redacted_at is null
     limit 1;
  end if;

  select coalesce(jsonb_agg(m order by m.sort_m nulls last, m.display_name), '[]'::jsonb)
    into v_rows
  from (
    select
      p.user_id,
      coalesce(p.display_name, r.first_name) as display_name,
      p.avatar_path,
      p.home_region,
      r.vehicle_desc,
      r.vehicle_class,
      r.equipment,
      -- Availability is the switch the member owns, not an inference from when they last opened
      -- the app. "Available" here means they said so.
      (r.availability = 'active') as available,
      -- The badge the approval gate turned into when universal membership removed the gate.
      (r.approval = 'approved') as verified,
      case
        when v_origin is null or r.home_location is null then null
        else app.coarse_miles(extensions.st_distance(v_origin, r.home_location))
      end as miles,
      case
        when v_origin is null or r.home_location is null then null
        else extensions.st_distance(v_origin, r.home_location)
      end as sort_m
      from public.profiles p
      join public.responders r on r.user_id = p.user_id
     where p.profile_public                      -- opted into being seen
       and p.available_to_help                   -- opted into being called out
       and r.redacted_at is null                 -- not a deleted or expired account
       and p.user_id <> v_me                     -- you are not nearby yourself
       -- The array is cast to text, not the parameter to the enum. Casting the parameter makes an
       -- unrecognised filter value -- a stale link, a typo, anything a client sends -- a 22P02
       -- error instead of an empty list.
       and (p_equipment is null or p_equipment = any (r.equipment::text[]))
     order by sort_m nulls last, display_name
     limit greatest(1, least(coalesce(p_limit, 50), 100))
  ) m;

  return jsonb_build_object('ok', true, 'members', v_rows);
end;
$fn$;

revoke all on function public.nearby_members(double precision, double precision, integer, text)
  from public, anon;
grant execute on function public.nearby_members(double precision, double precision, integer, text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- One member's public profile
-- ---------------------------------------------------------------------------
--
-- Same rule as the list: a profile is readable if its owner made it public AND is available to
-- help. Not a weaker rule -- otherwise the list is a consent gate with a link straight past it.
--
-- recoveries_count is the only number here, and it is a real column the dispatch path maintains.
-- The reference shows a rating and years of experience; neither exists in this product and
-- inventing them would be inventing a reputation for a volunteer.

create or replace function public.member_profile(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me  uuid := auth.uid();
  v_row jsonb;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  select jsonb_build_object(
           'user_id',      p.user_id,
           'display_name', coalesce(p.display_name, r.first_name),
           'avatar_path',  p.avatar_path,
           'home_region',  p.home_region,
           'vehicle_desc', r.vehicle_desc,
           'vehicle_class', r.vehicle_class,
           'equipment',    r.equipment,
           'available',    r.availability = 'active',
           'verified',     r.approval = 'approved',
           -- Maintained by the dispatch path on completion. The one metric that is real.
           'recoveries',   r.recoveries_count,
           'member_since', p.created_at,
           'miles',        case
                             when me.home_location is null or r.home_location is null then null
                             else app.coarse_miles(
                                    extensions.st_distance(me.home_location, r.home_location))
                           end
         ) into v_row
    from public.profiles p
    join public.responders r on r.user_id = p.user_id
    left join public.responders me on me.user_id = v_me and me.redacted_at is null
   where p.user_id = p_user_id
     and p.profile_public
     and p.available_to_help
     and r.redacted_at is null;

  if v_row is null then
    -- The same answer for "no such member", "not public" and "not available", so the directory
    -- cannot be used to test whether a given account exists.
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object('ok', true, 'member', v_row);
end;
$fn$;

revoke all on function public.member_profile(uuid) from public, anon;
grant execute on function public.member_profile(uuid) to authenticated, service_role;
