-- Winch Up :: targeting survives being read back and saved again
--
-- Run with:  supabase test db
--
-- THE BUG THIS EXISTS FOR, because it failed no assertion and raised no error.
--
-- The admin listings returned a radius target's distance and not its centre. The editor loads a row's
-- targets, the admin adds a ZIP code, the save sends the whole array, and the writer replaces targeting
-- wholesale -- which is correct and is what "this is for everybody now" needs. A radius the editor could
-- not represent would simply not be in the array sent back, so it would be deleted. The campaign quietly
-- stops reaching the area it was bought for and the only evidence is a number on a report getting
-- smaller.
--
-- So the round trip is asserted as a round trip: write a radius, read it back the way the screen does,
-- send exactly that back, and check the radius is still there.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

create or replace function pg_temp.an_admin() returns uuid language sql stable as $$
  select user_id from public.user_roles where role = 'admin' order by user_id limit 1;
$$;

insert into public.businesses (id, name, slug, category, status, verification_note)
values ('b6000000-0000-4000-8000-00000000000b', 'Round Trip Parts', 'round-trip-parts',
        'parts', 'approved', 'checked for the test')
on conflict (id) do nothing;

insert into public.ad_campaigns (id, business_id, name, status, surfaces, starts_on)
values ('c1100000-0000-4000-8000-00000000000c', 'b6000000-0000-4000-8000-00000000000b',
        'Round trip', 'approved', array['community_feed']::ad_surface[], current_date);

-- ---------------------------------------------------------------------------
-- 1. Only an admin sets targeting
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"00000000-0000-4000-8000-0000000000fb","role":"authenticated"}';

select throws_ok(
  $$select public.admin_save_campaign_targets('c1100000-0000-4000-8000-00000000000c', '[]'::jsonb)$$,
  '42501',
  null,
  'a member cannot retarget somebody else''s campaign');

select throws_ok(
  $$select public.admin_events()$$,
  '42501',
  null,
  'nor read the admin event list');

reset role;

-- ---------------------------------------------------------------------------
-- 2. A radius target round-trips
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.an_admin(), 'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;

select is(
  public.admin_save_campaign_targets('c1100000-0000-4000-8000-00000000000c',
    jsonb_build_array(
      jsonb_build_object('kind', 'radius', 'lng', -95.6972, 'lat', 29.9691, 'radius_miles', 25),
      jsonb_build_object('kind', 'postal_code', 'postal_code', '77494'))) ->> 'ok',
  'true',
  'an admin saves a radius and a ZIP');

-- READ IT BACK THE WAY THE SCREEN DOES, which is the whole point.
create or replace function pg_temp.targets() returns jsonb language sql stable as $$
  select x -> 'targets'
    from jsonb_array_elements(public.admin_campaigns(null, true, 200) -> 'campaigns') x
   where x ->> 'name' = 'Round trip';
$$;

select is(jsonb_array_length(pg_temp.targets()), 2, 'both come back');

select ok(
  exists (select 1 from jsonb_array_elements(pg_temp.targets()) x
           where x ->> 'kind' = 'radius'
             and (x ->> 'lng')::numeric = -95.6972
             and (x ->> 'lat')::numeric = 29.9691
             and (x ->> 'radius_miles')::int = 25),
  'and the radius carries its CENTRE, not only its distance -- which is the fix');

-- Now send back exactly what was read, as the editor does after the admin adds something, and confirm
-- the radius survives. Without the centre in the payload this is the step that silently deleted it.
select is(
  public.admin_save_campaign_targets('c1100000-0000-4000-8000-00000000000c',
    pg_temp.targets() || jsonb_build_array(
      jsonb_build_object('kind', 'postal_code', 'postal_code', '77429'))) ->> 'ok',
  'true',
  'the screen sends back what it read, plus one more place');

select is(jsonb_array_length(pg_temp.targets()), 3, 'three targets now');

select ok(
  exists (select 1 from jsonb_array_elements(pg_temp.targets()) x
           where x ->> 'kind' = 'radius' and (x ->> 'radius_miles')::int = 25),
  'AND THE RADIUS IS STILL THERE -- the assertion this file exists for');

select ok(
  exists (select 1 from jsonb_array_elements(pg_temp.targets()) x
           where x ->> 'postal_code' = '77494'),
  'along with the ZIP that was already there');

-- An empty array really does mean everybody, which is the intention that makes the wholesale replace
-- correct rather than merely convenient.
select is(
  public.admin_save_campaign_targets('c1100000-0000-4000-8000-00000000000c', '[]'::jsonb) ->> 'ok',
  'true', 'and an empty array is accepted');

select is(jsonb_array_length(pg_temp.targets()), 0,
  'leaving the campaign aimed at everybody');

-- A half-specified place is refused as a sentence rather than a constraint name.
select is(
  public.admin_save_campaign_targets('c1100000-0000-4000-8000-00000000000c',
    jsonb_build_array(jsonb_build_object('kind', 'city', 'city', 'Houston'))) ->> 'error',
  'bad_target',
  'a city with no state is refused -- Houston TX is not Houston MO');

reset role;

-- The refusal left nothing behind. A failed save that had already deleted the old targeting would be
-- the same data loss by another route.
select is(
  (select count(*)::int from public.target_locations
    where scope = 'campaign' and target_id = 'c1100000-0000-4000-8000-00000000000c'),
  0,
  'and the failed save is a no-op rather than a half-applied one');

-- ---------------------------------------------------------------------------
-- 3. An admin can find the draft they created
-- ---------------------------------------------------------------------------
--
-- admin_save_event() existed with no way to read an event back: events_upcoming() is the member's view,
-- published only and nothing more than six hours past, so a draft was write-only.

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.an_admin(), 'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;

select is(
  public.admin_save_event(jsonb_build_object(
    'title', 'Draft clinic', 'starts_at', (now() + interval '30 days')::text,
    'event_type', 'training', 'city', 'Katy', 'state', 'TX',
    'lng', -95.8244, 'lat', 29.7633)) ->> 'ok',
  'true', 'an admin saves a draft event with a pin');

select ok(
  exists (select 1 from jsonb_array_elements(public.admin_events() -> 'events') x
           where x ->> 'title' = 'Draft clinic' and x ->> 'status' = 'draft'),
  'and can find it again, which events_upcoming() would never have shown');

select ok(
  (select (x ->> 'lng')::numeric = -95.8244 and (x ->> 'lat')::numeric = 29.7633
     from jsonb_array_elements(public.admin_events() -> 'events') x
    where x ->> 'title' = 'Draft clinic'),
  'with its pin, so editing the title cannot silently clear the map point');

-- An edit that does not carry a point keeps the one that is there. The COALESCE in admin_save_event,
-- asserted: this is the case where a one-field correction would otherwise wipe the location.
select is(
  public.admin_save_event(jsonb_build_object(
    'id', (select x ->> 'id' from jsonb_array_elements(public.admin_events() -> 'events') x
            where x ->> 'title' = 'Draft clinic'),
    'title', 'Draft clinic renamed',
    'starts_at', (now() + interval '30 days')::text)) ->> 'ok',
  'true', 'the admin corrects the title and sends no point');

select ok(
  (select (x ->> 'lng')::numeric = -95.8244
     from jsonb_array_elements(public.admin_events() -> 'events') x
    where x ->> 'title' = 'Draft clinic renamed'),
  'and the pin is still there');

reset role;

select * from finish();
rollback;
