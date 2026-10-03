-- Winch Up :: the server fills in the centroid, nobody else
--
-- 20261003000100 gave a member city, state and postal code, and deliberately gave them NO way to
-- write `postal_center`: the whole value of that column is that it FOLLOWS FROM the postal code
-- rather than from a claim. set_my_location() clears it on every write, so after a member changes
-- their ZIP there is a window in which they match no radius-targeted campaign at all, which is the
-- safe direction for the window to fail in.
--
-- This closes the window. One writer, service_role only, called by the server right after it has
-- geocoded the postal code the member actually saved.
--
-- IT LIVES IN `public`, NOT `app`. PostgREST is configured `db-schemas = "public"`, so an `app.*`
-- function is invisible to supabase-js: the call 404s forever while every pgTAP suite passes,
-- because pgTAP calls it directly and never goes through PostgREST. That is the same reasoning that
-- put `claim_email_deliveries` and `claim_push_deliveries` in `public`, and it has already cost this
-- project a silently-filling queue once.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. Writing the centroid
-- ---------------------------------------------------------------------------

create or replace function public.set_member_postal_center(
  p_user_id     uuid,
  p_postal_code text,
  p_lng         double precision,
  p_lat         double precision
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_postal text := nullif(btrim(coalesce(p_postal_code, '')), '');
begin
  if p_user_id is null or v_postal is null then
    return jsonb_build_object('ok', false, 'error', 'bad_request');
  end if;

  -- Rough sanity on the coordinate. A geocoder that answers with a point in the Atlantic should
  -- not be allowed to put it on a member's profile; radius targeting would then quietly measure
  -- from the wrong continent and the only symptom would be campaigns reaching nobody.
  if p_lng is null or p_lat is null
     or p_lng not between -180 and 180
     or p_lat not between -90 and 90 then
    return jsonb_build_object('ok', false, 'error', 'bad_coordinate');
  end if;

  -- THE POSTAL CODE IS PART OF THE WHERE CLAUSE, and that is the point of this function.
  --
  -- Geocoding happens after the member's write has returned, so by the time the answer arrives the
  -- member may have saved a different ZIP from another tab, or cleared it entirely. Writing the
  -- centroid unconditionally would then pin a stale point onto a current postal code -- the exact
  -- failure set_my_location() clears the column to avoid, reintroduced one step later. Matching on
  -- the ZIP the geocoder was asked about means a late answer is DISCARDED rather than applied.
  update public.profiles
     set postal_center = extensions.st_setsrid(extensions.st_point(p_lng, p_lat), 4326)::extensions.geography,
         updated_at    = now()
   where user_id = p_user_id
     and postal_code = v_postal;

  if not found then
    -- Not an error worth raising: the member moved on, and the next save geocodes again.
    return jsonb_build_object('ok', false, 'error', 'stale');
  end if;

  return jsonb_build_object('ok', true);
end;
$fn$;

revoke all on function public.set_member_postal_center(uuid, text, double precision, double precision)
  from public, anon, authenticated;
grant execute on function public.set_member_postal_center(uuid, text, double precision, double precision)
  to service_role;

comment on function public.set_member_postal_center(uuid, text, double precision, double precision) is
  'Server-only writer for profiles.postal_center. Guarded on the postal code it was geocoded from, '
  'so a slow geocoder cannot pin a stale point onto a newer ZIP.';

-- ---------------------------------------------------------------------------
-- 2. Finding the ones still missing a centroid
-- ---------------------------------------------------------------------------
--
-- A member whose geocode failed -- no token configured, a timeout, Mapbox down -- keeps a postal
-- code and no centroid, and silently matches no radius-targeted campaign. Without this they would
-- stay that way until they happened to edit their profile again, so there is something for the
-- drain to pick up. Same shape as the email and push queues: the work is visible and retried
-- rather than lost.

create or replace function public.members_missing_postal_center(p_limit integer default 20)
returns table (user_id uuid, postal_code text)
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
  select p.user_id, p.postal_code
    from public.profiles p
   where p.postal_code is not null
     and p.postal_center is null
     and p.suspended_at is null
   order by p.location_set_at nulls last
   limit greatest(1, least(coalesce(p_limit, 20), 100));
$fn$;

revoke all on function public.members_missing_postal_center(integer)
  from public, anon, authenticated;
grant execute on function public.members_missing_postal_center(integer) to service_role;

notify pgrst, 'reload schema';
