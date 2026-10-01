-- Winch Up :: no advertising beside the emergency contacts
--
-- The resources section gains a seventh guide, "emergency" -- who to call when the answer is
-- not a volunteer: 911, the Texas DPS line for a disabled vehicle on a highway shoulder, road
-- conditions, and when a paid wrecker is the right call.
--
-- That makes it the THIRD guide which is emergency guidance rather than reference, and
-- app.ad_slot_allowed() names the other two by slug. Shipping the page without this line would
-- have put a paid advert beside a list of numbers somebody reads from the side of a highway,
-- sold to whoever bid for it -- which is exactly the arrangement the ad rules exist to prevent.
-- The enum already keeps ads away from requests, live recoveries and threads; this is the same
-- rule one level down, where the surface is allowed in general and two specific pages are not.
--
-- Fix-forward recreate of the function from 20260922001500, with 'emergency' added and
-- everything else identical.

set search_path = public, extensions;

create or replace function app.ad_slot_allowed(p_surface ad_surface, p_slug text)
returns boolean
language sql
immutable
set search_path = public, extensions, pg_temp
as $fn$
  select case
    -- THREE of the seven resource guides are emergency guidance: what to do when you are the
    -- one stuck, how to run a recovery without hurting somebody, and who to phone when it is
    -- past what volunteers can do. Selling space beside any of them is not a thing this
    -- product does.
    when p_surface = 'resources' and coalesce(p_slug, '') in ('stuck', 'safety', 'emergency')
      then false
    else true
  end;
$fn$;

comment on function app.ad_slot_allowed(ad_surface, text) is
  'False for surfaces and guides that must never carry an advert. Emergency guidance is named by slug.';
