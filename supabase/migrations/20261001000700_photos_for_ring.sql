-- Winch Up :: the photographs, for the people who would be called out
--
-- Until now a request's photographs reached exactly two places: the requester's own status
-- page, and the helper who had already been accepted (get_job_contact). Somebody deciding
-- whether to drive forty minutes saw a vehicle class and a sentence of text.
--
-- The owner's decision (2026-10-01) is to show them to members in the ring. That is the narrow
-- reading on purpose: not "any member with an account", but the people this recovery would
-- have alerted anyway.
--
-- WHY NOT "ANYBODY WHO CAN SEE IT IN /help". nearby_requests() takes the radius as a PARAMETER
-- supplied by the caller, defaulting to 60 miles, so "it is in my feed" means "I asked for a
-- big enough circle". Authorising photographs on that would be authorising them to every
-- member who sends a larger number, which is not a rule at all.
--
-- The rule here is the dispatcher's own: fresh position, willing to be called out, and inside
-- BOTH the request's current ring and the radius that member chose for themselves -- the same
-- least() the matcher uses. One deliberate difference from app.candidates(): this does not
-- exclude somebody who has already been dispatched. They are exactly who needs to see the
-- photographs; candidates() skips them only to avoid texting twice.
--
-- A photograph of a stuck vehicle shows where it is and often whose it is. This widens who can
-- see one from "the person who committed to coming" to "the people being asked to come", and
-- no further: not the public board, which still shows a count and a blurred pin, and not a
-- member sitting three counties away.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- May this member see this request's photographs?
-- ---------------------------------------------------------------------------

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
    -- The radius of the ring the request has reached. current_ring is 1-based; a request that
    -- has not started dispatching yet is treated as ring 1.
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
       -- Never the requester's own row through this path; they read their photographs through
       -- their status token, which is a different door with a different key.
       and req.requester_user_id is distinct from p_user
       and resp.availability = 'active'
       and coalesce(
             (select p.available_to_help from public.profiles p where p.user_id = p_user),
             false
           )
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
  'True for a member the dispatcher would call out for this request at its current ring.';

-- ---------------------------------------------------------------------------
-- The paths, for a member who qualifies
-- ---------------------------------------------------------------------------
--
-- Returns storage paths, never URLs. The bucket is private and a signed URL has to be minted
-- by the server with the service role, which is the same shape get_request_by_token uses --
-- the database decides WHO, the server decides for how long.

create or replace function public.request_photos_for_helper(p_request_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me    uuid := auth.uid();
  v_paths jsonb;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  if not app.may_see_request_photos(p_request_id, v_me) then
    -- The same answer whether the request does not exist, is closed, or is simply too far
    -- away. Otherwise this endpoint reports whether a given id is a live recovery.
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  select coalesce(jsonb_agg(storage_path order by sort_order, created_at), '[]'::jsonb)
    into v_paths
    from public.request_photos
   where request_id = p_request_id;

  return jsonb_build_object('ok', true, 'paths', v_paths);
end;
$fn$;

revoke execute on function public.request_photos_for_helper(uuid) from public, anon, authenticated;
grant execute on function public.request_photos_for_helper(uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
