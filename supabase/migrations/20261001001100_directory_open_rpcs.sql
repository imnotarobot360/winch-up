-- Winch Up :: the directory stops asking permission
--
-- Rewrites the two functions that decide who is in the directory. Everything about WHAT a row says
-- is kept from 20260924000100 and 20260928001000 -- the field whitelist, the coarse distance, the
-- primary rig photo -- because none of that was the problem. Only the WHERE changes.
--
-- Built on the LIVE definitions, read out of pg_proc rather than taken from the migration files:
-- member_profile() is defined twice in the history and the earlier copy is a version behind.

set search_path = public, extensions;

-- The 4-argument version has to go rather than be replaced. Adding p_query with a default would
-- otherwise leave two candidates for a 4-argument call, and Postgres answers that with
-- "function is not unique" -- an error the frontend would hit on every directory load.
drop function if exists public.nearby_members(double precision, double precision, integer, text);

create or replace function public.nearby_members(
  p_lat       double precision default null,
  p_lng       double precision default null,
  p_limit     integer default 50,
  p_equipment text default null,
  p_query     text default null
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

  -- Where "nearby" is measured from. An explicit point wins -- the screen may be showing a map the
  -- member has panned -- otherwise their own home location. Somebody with neither gets the list
  -- unsorted rather than an error: they can still browse, they just are not told distances.
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
      -- A member who has set neither a display name nor a first name still appears; naming them is
      -- the UI's job. Returning the account id as a name, or dropping the row, are both worse.
      coalesce(nullif(btrim(p.display_name), ''), r.first_name) as display_name,
      p.avatar_path,
      p.home_region,
      r.vehicle_desc,
      r.vehicle_class,
      coalesce(r.equipment, '{}'::equipment_type[]) as equipment,
      -- AVAILABILITY IS NOW A FIELD, NOT A FILTER. §2: shown when the member has enabled it. Both
      -- halves are required -- the profile switch is the member's intent, and availability='paused'
      -- is what replying STOP sets, so a paused member is not offered as available.
      (p.available_to_help and coalesce(r.availability, 'paused') = 'active') as available,
      coalesce(r.approval = 'approved', false) as verified,
      case
        when v_origin is null or r.home_location is null then null
        else app.coarse_miles(extensions.st_distance(v_origin, r.home_location))
      end as miles,
      case
        when v_origin is null or r.home_location is null then null
        else extensions.st_distance(v_origin, r.home_location)
      end as sort_m
      from public.profiles p
      -- LEFT, and this is the whole point. ensure_recovery_profile() only runs when somebody turns
      -- availability on, so an inner join hides every member who never did -- which is most of
      -- them, and exactly the people this change exists to make visible.
      left join public.responders r on r.user_id = p.user_id
     where app.member_is_listable(p, r, v_me)
       -- A directory of other members. member_is_listable deliberately does not say this, so
       -- that member_profile() can use the same rule for the member looking at their own page.
       and p.user_id <> v_me
       -- The array is cast to text, not the parameter to the enum: casting the parameter turns an
       -- unrecognised filter value -- a stale link, a typo, anything a client sends -- into a 22P02
       -- instead of an empty list. A member with no responder row has no equipment to match.
       and (p_equipment is null
            or p_equipment = any (coalesce(r.equipment, '{}'::equipment_type[])::text[]))
       and (nullif(btrim(coalesce(p_query, '')), '') is null
            or coalesce(nullif(btrim(p.display_name), ''), r.first_name, '')
                 ilike app.like_contains(btrim(p_query)))
     order by sort_m nulls last, display_name
     limit greatest(1, least(coalesce(p_limit, 50), 100))
  ) m;

  return jsonb_build_object('ok', true, 'members', v_rows);
end;
$fn$;

revoke all on function
  public.nearby_members(double precision, double precision, integer, text, text)
  from public, anon;
grant execute on function
  public.nearby_members(double precision, double precision, integer, text, text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- One member's profile
-- ---------------------------------------------------------------------------
--
-- Same listability rule as the list, through the same function, so a row in the directory always
-- opens. The reverse matters too: a profile that opened for somebody the list refuses to show
-- would make the 404 a way to test whether an account exists.

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
           'user_id',       p.user_id,
           'display_name',  coalesce(nullif(btrim(p.display_name), ''), r.first_name),
           'avatar_path',   p.avatar_path,
           'home_region',   p.home_region,
           'vehicle_desc',  r.vehicle_desc,
           'vehicle_class', r.vehicle_class,
           'equipment',     coalesce(r.equipment, '{}'::equipment_type[]),
           'available',     (p.available_to_help
                             and coalesce(r.availability, 'paused') = 'active'),
           'verified',      coalesce(r.approval = 'approved', false),
           -- Maintained by the dispatch path on completion. The one metric here that is real: the
           -- design reference also shows a rating and years of experience, and inventing either
           -- would be inventing a reputation for a volunteer.
           'recoveries',    coalesce(r.recoveries_count, 0),
           'member_since',  p.created_at,
           -- The primary rig, is_primary first then oldest -- the same ordering
           -- my_rig_photo_status() prompts against, so the photo they were asked for is the photo
           -- that appears. The PATH only: the bucket is private and signing it is the caller's job,
           -- because a signed URL baked into an RPC result is stale before anything caches it.
           'rig_photo_path', (
              select v.photo_path
                from public.vehicles v
               where v.user_id = p.user_id and v.photo_path is not null
               order by v.is_primary desc, v.created_at asc
               limit 1
           ),
           'miles',         case
                              when me.home_location is null or r.home_location is null then null
                              else app.coarse_miles(
                                     extensions.st_distance(me.home_location, r.home_location))
                            end
         ) into v_row
    from public.profiles p
    left join public.responders r on r.user_id = p.user_id
    left join public.responders me on me.user_id = v_me and me.redacted_at is null
   where p.user_id = p_user_id
     and app.member_is_listable(p, r, v_me);

  if v_row is null then
    -- One answer for "no such member", "suspended" and "blocked", so the profile route cannot be
    -- used to tell those apart.
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object('ok', true, 'member', v_row);
end;
$fn$;

revoke all on function public.member_profile(uuid) from public, anon;
grant execute on function public.member_profile(uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
