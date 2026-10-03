-- Winch Up :: adverts stop reaching people they were never targeted at
--
-- Section 6 of the owner's spec: "only members who match the targeting rules should receive or
-- display the campaign". Until now that was false in the most complete way possible.
--
-- WHAT WAS WRONG. ads_for() took the reader's position as a PARAMETER, and the one caller --
-- src/components/ads/ad-slot.tsx -- passes `p_lng: null, p_lat: null`. The rule read:
--
--     c.target_center is null          -- untargeted
--     or v_here is null                -- OR WE DO NOT KNOW WHERE THE READER IS
--     or st_dwithin(...)               -- or they are inside the radius
--
-- so the middle line matched every reader, every time, and a radius-targeted campaign was shown to
-- everybody. `target_center` and `target_radius_miles` have been in this schema for weeks and have
-- never once narrowed anything. Nothing on any screen looked wrong, which is why it lasted: a
-- targeting feature that over-delivers looks identical to one that works.
--
-- THE BEHAVIOUR CHANGE, STATED PLAINLY. "We do not know where the reader is" is now a MISS rather
-- than a match. A member who has not filled in /account/location, and every signed-out reader on a
-- public page, matches only UNTARGETED campaigns. Targeted campaigns will reach fewer people the
-- day this ships. That is targeting beginning to work, not targeting breaking, and it is asserted
-- in supabase/tests/targeting_test.sql so it stays a decision rather than becoming a surprise.
--
-- HOW SECTION 7 SURVIVES THIS.
--
-- Section 7 forbids advertising from using recovery location data. Until now the ad path could not
-- read it because it did not know who the reader was -- a real property, held by accident. Looking
-- up auth.uid() gives that up, so the property is now held on purpose and in three ways:
--
--   1. This function reads the four STATED location fields into local variables and nothing else
--      from the member's row. It never names `responders` or `home_location`.
--   2. app.member_matches_target() takes those VALUES rather than a user id, so no function in the
--      matching path is even able to reach for the recovery point.
--   3. targeting_test.sql reads this function's own source and fails if it names either -- the same
--      guard, pointed the other way, that stops the dispatch path reading an advertising table.
--
-- THE SIGNATURE IS UNCHANGED. Adding a parameter would OVERLOAD this function rather than replace
-- it, and PostgREST cannot then choose between the two for a call matching the shorter one -- every
-- ad slot starts failing with an ambiguity error that says nothing about the cause. Same five
-- arguments, same return type, new body.

set search_path = public, extensions;

create or replace function public.ads_for(
  p_surface text,
  p_slug    text default null,
  p_lng     double precision default null,
  p_lat     double precision default null,
  p_limit   integer default 1
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_surface ad_surface;
  v_here    extensions.geography;
  v_rows    jsonb;

  -- The reader's STATED location, and nothing else about them. Four scalars, read once.
  v_me      uuid := auth.uid();
  v_city    text;
  v_state   text;
  v_postal  text;
  v_center  extensions.geography;
begin
  begin
    v_surface := p_surface::ad_surface;
  exception when others then
    -- Including, deliberately, every emergency surface somebody might try to name. There is no
    -- enum value for the request wizard, a live recovery, or a message thread.
    return jsonb_build_object('ok', false, 'error', 'bad_surface');
  end;

  if not app.ad_slot_allowed(v_surface, p_slug) then
    return jsonb_build_object('ok', true, 'ads', '[]'::jsonb, 'blocked', true);
  end if;

  -- The advertising-purpose location, declared by the member on /account/location for exactly this.
  -- It is NOT the recovery position held on a volunteer record, which is what a call-out is measured
  -- from. A member who has never volunteered has no such position and must still be reachable by a
  -- campaign; a member who has one must not have it quietly repurposed to sell to them.
  --
  -- THAT SENTENCE AVOIDS THE TWO IDENTIFIERS ON PURPOSE, and so must anything written here later.
  -- The section 7 guard in targeting_test.sql is a textual check over this function's source, and a
  -- textual check cannot tell a comment from a reference -- naming either identifier in a comment
  -- fails the suite with a message about reading recovery data, which is exactly the kind of
  -- confusing failure that gets a guard deleted instead of understood. The guard stays blunt because
  -- blunt is what survives; the comment works around it.
  if v_me is not null then
    select p.city, p.state, p.postal_code, p.postal_center
      into v_city, v_state, v_postal, v_center
      from public.profiles p
     where p.user_id = v_me;
  end if;

  -- WHICH POINT A RADIUS IS MEASURED FROM.
  --
  -- The member's own stated centroid wins: they chose it for this purpose, and it is derived from
  -- their postal code by the server rather than claimed by a browser. The caller-supplied point is
  -- the fallback, and it is the ONLY way a signed-out reader on a public page can ever match a
  -- geo-targeted campaign -- /trails and /resources serve adverts to anonymous visitors.
  --
  -- What a null point is no longer is a LICENCE. It used to mean "show it anyway"; it now means the
  -- reader matches no radius target, which is the whole point of this migration.
  v_center := coalesce(
    v_center,
    case
      when p_lng is not null and p_lat is not null
        then extensions.st_setsrid(extensions.st_point(p_lng, p_lat), 4326)::extensions.geography
    end
  );
  v_here := v_center;

  select coalesce(jsonb_agg(to_jsonb(a)), '[]'::jsonb) into v_rows
  from (
    select
      cr.id as creative_id,
      cr.headline,
      cr.body,
      cr.cta_label,
      cr.cta_url,
      cr.image_path,
      b.name as business_name,
      b.category::text as category,
      v_surface::text as surface,

      -- Both labels travel with the ad. `labelled` is always true and is asserted by a test:
      -- an ad that arrives without it is a bug, not a styling choice.
      true as labelled,
      -- The second line, for the category where confusing a paid advertiser with a volunteer
      -- actually costs somebody money at the roadside.
      (b.category = 'recovery_towing') as not_a_volunteer
    from ad_creatives cr
    join ad_campaigns c on c.id = cr.campaign_id
    join businesses b on b.id = c.business_id
   where cr.status = 'approved'
     and cr.is_active
     and c.status = 'approved'
     and b.status = 'approved'
     and v_surface = any (c.surfaces)
     and c.starts_on <= current_date
     and (c.ends_on is null or c.ends_on >= current_date)

     -- The structured targeting from section 10: state, city, several cities, ZIP, several ZIPs,
     -- radius. No rows for this campaign means everybody, which is the spec's "All Members".
     and app.member_matches_target('campaign', c.id, v_state, v_city, v_postal, v_center)

     -- THE LEGACY RADIUS COLUMNS, STILL HONOURED.
     --
     -- target_center / target_radius_miles predate target_locations and may already be set on a
     -- campaign somebody configured. BOTH gates have to pass, which is the conservative reading of
     -- section 6 -- a campaign narrowed two ways reaches the intersection, never the union. The
     -- alternative would let a new city target WIDEN an existing radius campaign, which is not what
     -- anybody adding a city believes they are doing.
     --
     -- And a null point is no longer an escape hatch here either.
     and (
       c.target_center is null
       or (
         v_here is not null
         and extensions.st_dwithin(c.target_center, v_here,
                                   c.target_radius_miles * 1609.344)
       )
     )
   -- Random rather than by price. With inventory this small, ordering by what somebody paid
   -- turns the one slot on the page into a permanent billboard for whoever bid most once.
   order by random()
   limit greatest(1, least(coalesce(p_limit, 1), 5))
  ) a;

  return jsonb_build_object('ok', true, 'ads', v_rows);
end;
$fn$;

notify pgrst, 'reload schema';
