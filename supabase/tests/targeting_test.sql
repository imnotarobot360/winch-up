-- Winch Up :: who is in the audience, and who is not
--
-- Run with:  supabase test db
--
-- Section 17 of the owner's spec is a test matrix, so this is it. Its worked example is reproduced
-- exactly -- four members in four places, a campaign targeting two ZIP codes, and a stated
-- expectation for each -- and then the other five targeting modes are put through the same shape.
--
-- EVERY EXCLUSION IS PAIRED WITH AN INCLUSION. A targeting rule that matches nobody passes every
-- "does not see it" assertion in this file, and the whole feature would be silently broken while
-- reading green. That failure mode is not hypothetical here: radius targeting has existed in this
-- schema for weeks and narrowed nothing, because ads_for() treated "we do not know where the reader
-- is" as a reason to show the advert.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- ---------------------------------------------------------------------------
-- The four members from the spec, plus two the spec implies
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
)
select '00000000-0000-0000-0000-000000000000', v.id, 'authenticated', 'authenticated',
       v.email, 'x', now(), '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
from (values
  ('a1000000-0000-4000-8000-00000000000a'::uuid, 'target-cypress@example.invalid'),
  ('a2000000-0000-4000-8000-00000000000a'::uuid, 'target-katy@example.invalid'),
  ('a3000000-0000-4000-8000-00000000000a'::uuid, 'target-houston@example.invalid'),
  ('a4000000-0000-4000-8000-00000000000a'::uuid, 'target-dallas@example.invalid'),
  -- Not in the spec's list, and the most important row in this file. See section 6 below.
  ('a5000000-0000-4000-8000-00000000000a'::uuid, 'target-nowhere@example.invalid'),
  -- Suspended, to prove the audience estimate does not count people who cannot see anything.
  ('a6000000-0000-4000-8000-00000000000a'::uuid, 'target-suspended@example.invalid')
) as v(id, email)
on conflict (id) do nothing;

-- Real centroids, so radius assertions measure a real distance rather than a made-up one.
-- Cypress 77429, Katy 77494, Houston 77007, Dallas 75201.
update public.profiles set city = 'Cypress', state = 'TX', postal_code = '77429',
       postal_center = extensions.st_setsrid(extensions.st_point(-95.6972, 29.9691), 4326)::extensions.geography
 where user_id = 'a1000000-0000-4000-8000-00000000000a';
update public.profiles set city = 'Katy', state = 'TX', postal_code = '77494',
       postal_center = extensions.st_setsrid(extensions.st_point(-95.8244, 29.7633), 4326)::extensions.geography
 where user_id = 'a2000000-0000-4000-8000-00000000000a';
update public.profiles set city = 'Houston', state = 'TX', postal_code = '77007',
       postal_center = extensions.st_setsrid(extensions.st_point(-95.3998, 29.7752), 4326)::extensions.geography
 where user_id = 'a3000000-0000-4000-8000-00000000000a';
update public.profiles set city = 'Dallas', state = 'TX', postal_code = '75201',
       postal_center = extensions.st_setsrid(extensions.st_point(-96.7970, 32.7831), 4326)::extensions.geography
 where user_id = 'a4000000-0000-4000-8000-00000000000a';
-- a5 keeps every location field null, deliberately.
update public.profiles set city = 'Cypress', state = 'TX', postal_code = '77429',
       suspended_at = now(), suspended_reason = 'test',
       postal_center = extensions.st_setsrid(extensions.st_point(-95.6972, 29.9691), 4326)::extensions.geography
 where user_id = 'a6000000-0000-4000-8000-00000000000a';

-- A helper so each assertion reads as the question it is asking.
create or replace function pg_temp.sees(p_target uuid, p_member uuid)
returns boolean
language sql
stable
as $$
  select app.member_matches_target('campaign', p_target, p.state, p.city,
                                   p.postal_code, p.postal_center)
    from public.profiles p where p.user_id = p_member;
$$;

-- ---------------------------------------------------------------------------
-- 1. The spec's own example: two ZIP codes
-- ---------------------------------------------------------------------------
--
--   Member A — Cypress, TX 77429   SEE AD
--   Member B — Katy, TX 77494      SEE AD
--   Member C — Houston, TX 77007   DO NOT SEE
--   Member D — Dallas, TX          DO NOT SEE

insert into public.target_locations (scope, target_id, kind, postal_code) values
  ('campaign', 'c1000000-0000-4000-8000-00000000000c', 'postal_code', '77429'),
  ('campaign', 'c1000000-0000-4000-8000-00000000000c', 'postal_code', '77494');

select ok(pg_temp.sees('c1000000-0000-4000-8000-00000000000c',
                       'a1000000-0000-4000-8000-00000000000a'),
  'Cypress 77429 is in a campaign targeting 77429 and 77494');
select ok(pg_temp.sees('c1000000-0000-4000-8000-00000000000c',
                       'a2000000-0000-4000-8000-00000000000a'),
  'and so is Katy 77494');
select ok(not pg_temp.sees('c1000000-0000-4000-8000-00000000000c',
                           'a3000000-0000-4000-8000-00000000000a'),
  'Houston 77007 is not');
select ok(not pg_temp.sees('c1000000-0000-4000-8000-00000000000c',
                           'a4000000-0000-4000-8000-00000000000a'),
  'nor Dallas 75201');

-- ---------------------------------------------------------------------------
-- 2. One city, and several
-- ---------------------------------------------------------------------------

insert into public.target_locations (scope, target_id, kind, city, state) values
  ('campaign', 'c2000000-0000-4000-8000-00000000000c', 'city', 'Cypress', 'TX');

select ok(pg_temp.sees('c2000000-0000-4000-8000-00000000000c',
                       'a1000000-0000-4000-8000-00000000000a'),
  'a city target reaches that city');
select ok(not pg_temp.sees('c2000000-0000-4000-8000-00000000000c',
                           'a2000000-0000-4000-8000-00000000000a'),
  'and not the one next to it');

-- Case is not a place. "cypress" typed into an admin form is Cypress.
insert into public.target_locations (scope, target_id, kind, city, state) values
  ('campaign', 'c3000000-0000-4000-8000-00000000000c', 'city', 'cYpReSs', 'TX');

select ok(pg_temp.sees('c3000000-0000-4000-8000-00000000000c',
                       'a1000000-0000-4000-8000-00000000000a'),
  'city matching ignores case, because a typist is not a geographer');

-- Several cities, which is the spec's "Houston, Katy, Cypress" example.
insert into public.target_locations (scope, target_id, kind, city, state) values
  ('campaign', 'c4000000-0000-4000-8000-00000000000c', 'city', 'Houston', 'TX'),
  ('campaign', 'c4000000-0000-4000-8000-00000000000c', 'city', 'Katy', 'TX'),
  ('campaign', 'c4000000-0000-4000-8000-00000000000c', 'city', 'Cypress', 'TX');

select is(
  (select count(*)::int from (values
     ('a1000000-0000-4000-8000-00000000000a'::uuid),
     ('a2000000-0000-4000-8000-00000000000a'::uuid),
     ('a3000000-0000-4000-8000-00000000000a'::uuid)) as m(id)
    where pg_temp.sees('c4000000-0000-4000-8000-00000000000c', m.id)),
  3,
  'targets are ADDITIVE: three cities reach all three members');

select ok(not pg_temp.sees('c4000000-0000-4000-8000-00000000000c',
                           'a4000000-0000-4000-8000-00000000000a'),
  'and still not Dallas');

-- ---------------------------------------------------------------------------
-- 3. A state
-- ---------------------------------------------------------------------------

insert into public.target_locations (scope, target_id, kind, state) values
  ('campaign', 'c5000000-0000-4000-8000-00000000000c', 'state', 'TX');

select ok(pg_temp.sees('c5000000-0000-4000-8000-00000000000c',
                       'a4000000-0000-4000-8000-00000000000a'),
  'statewide reaches Dallas, which city targeting did not');

insert into public.target_locations (scope, target_id, kind, state) values
  ('campaign', 'c6000000-0000-4000-8000-00000000000c', 'state', 'OK');

select ok(not pg_temp.sees('c6000000-0000-4000-8000-00000000000c',
                           'a1000000-0000-4000-8000-00000000000a'),
  'and a different state reaches nobody here -- the control for the row above');

-- ---------------------------------------------------------------------------
-- 4. A radius
-- ---------------------------------------------------------------------------
--
-- Centred on Cypress. Katy is about 16 miles away and Houston about 18; Dallas is 225. So a 25-mile
-- radius must catch the first three and not the fourth, and a 5-mile radius must catch only Cypress.
-- Two radii rather than one, because a single radius that happened to match everything would pass.

insert into public.target_locations (scope, target_id, kind, center, radius_miles) values
  ('campaign', 'c7000000-0000-4000-8000-00000000000c', 'radius',
   extensions.st_setsrid(extensions.st_point(-95.6972, 29.9691), 4326)::extensions.geography, 25);

select ok(pg_temp.sees('c7000000-0000-4000-8000-00000000000c',
                       'a1000000-0000-4000-8000-00000000000a'),
  'a 25-mile radius around Cypress reaches Cypress');
select ok(pg_temp.sees('c7000000-0000-4000-8000-00000000000c',
                       'a2000000-0000-4000-8000-00000000000a'),
  'and Katy, sixteen miles off');
select ok(not pg_temp.sees('c7000000-0000-4000-8000-00000000000c',
                           'a4000000-0000-4000-8000-00000000000a'),
  'and not Dallas, two hundred and twenty-five miles off');

insert into public.target_locations (scope, target_id, kind, center, radius_miles) values
  ('campaign', 'c8000000-0000-4000-8000-00000000000c', 'radius',
   extensions.st_setsrid(extensions.st_point(-95.6972, 29.9691), 4326)::extensions.geography, 5);

select ok(pg_temp.sees('c8000000-0000-4000-8000-00000000000c',
                       'a1000000-0000-4000-8000-00000000000a'),
  'five miles still reaches Cypress itself');
select ok(not pg_temp.sees('c8000000-0000-4000-8000-00000000000c',
                           'a2000000-0000-4000-8000-00000000000a'),
  'but no longer Katy -- so the radius is a radius and not a pass');

-- ---------------------------------------------------------------------------
-- 5. All members
-- ---------------------------------------------------------------------------
--
-- Represented by the ABSENCE of rows rather than a magic one, so that adding a city to an
-- all-members campaign cannot leave an "everyone" rule behind that silently overrides it.

select ok(pg_temp.sees('c9000000-0000-4000-8000-00000000000c',
                       'a4000000-0000-4000-8000-00000000000a'),
  'a campaign with no targeting rows reaches everybody');
select ok(pg_temp.sees('c9000000-0000-4000-8000-00000000000c',
                       'a5000000-0000-4000-8000-00000000000a'),
  'including a member who has never said where they are');

-- ---------------------------------------------------------------------------
-- 6. The member who has not said where they are
-- ---------------------------------------------------------------------------
--
-- THE BEHAVIOUR CHANGE, asserted so it is a decision rather than an accident. ads_for() currently
-- treats an unknown location as a reason to SHOW a targeted campaign -- "untargeted, or we do not
-- know where the reader is, or inside the radius" -- which is why radius targeting has never
-- narrowed anything. §6 says only matching members should see a campaign, so unknown is now a miss.
--
-- The cost is real and belongs in a test rather than a surprise: until members fill in a location,
-- targeted campaigns reach fewer people.

select ok(not pg_temp.sees('c1000000-0000-4000-8000-00000000000c',
                           'a5000000-0000-4000-8000-00000000000a'),
  'no stated location means no ZIP match -- "we do not know" is not "show it to them"');
select ok(not pg_temp.sees('c5000000-0000-4000-8000-00000000000c',
                           'a5000000-0000-4000-8000-00000000000a'),
  'nor a state match');
select ok(not pg_temp.sees('c7000000-0000-4000-8000-00000000000c',
                           'a5000000-0000-4000-8000-00000000000a'),
  'nor a radius match, because there is no centroid to measure from');

-- ---------------------------------------------------------------------------
-- 7. The estimated audience
-- ---------------------------------------------------------------------------
--
-- Section 14 puts this number in front of an admin before they publish, so it has to mean what it
-- says. A count that included people who cannot see anything would make every campaign look better
-- than it is.

select is(
  app.target_audience_count('campaign', 'c1000000-0000-4000-8000-00000000000c'),
  2,
  'the two-ZIP campaign estimates two members');

select is(
  app.target_audience_count('campaign', 'c2000000-0000-4000-8000-00000000000c'),
  1,
  'and the single-city one estimates one');

-- The suspended member is in Cypress 77429 and matches the rule perfectly. They are not counted,
-- and they must not be: a suspended account sees nothing.
select ok(
  app.target_audience_count('campaign', 'c1000000-0000-4000-8000-00000000000c') < 3,
  'a suspended member matching the targeting is NOT in the estimate');

-- ---------------------------------------------------------------------------
-- 8. The shape constraint is real
-- ---------------------------------------------------------------------------
--
-- One table serving four kinds of target only works if a row cannot be half a city and half a
-- radius. Asserted rather than trusted, because the constraint is the only thing holding it.

select throws_ok(
  $$insert into public.target_locations (scope, target_id, kind, city)
    values ('campaign', 'cf000000-0000-4000-8000-00000000000c', 'city', 'Houston')$$,
  '23514',
  null,
  'a city target without a state is refused: Houston TX is not Houston MO');

select throws_ok(
  $$insert into public.target_locations (scope, target_id, kind, postal_code)
    values ('campaign', 'cf000000-0000-4000-8000-00000000000c', 'postal_code', '7742')$$,
  '23514',
  null,
  'a four-digit postal code is refused rather than stored unmatchable');

select throws_ok(
  $$insert into public.target_locations (scope, target_id, kind, center, radius_miles)
    values ('campaign', 'cf000000-0000-4000-8000-00000000000c', 'radius',
            extensions.st_setsrid(extensions.st_point(-95.6, 29.9), 4326)::extensions.geography, 0)$$,
  '23514',
  null,
  'and a zero-mile radius, which would match nobody and look like a working campaign');

-- ---------------------------------------------------------------------------
-- 9. Nobody but the server reads this table
-- ---------------------------------------------------------------------------

select ok(not has_table_privilege('authenticated', 'target_locations', 'SELECT'),
  'a member cannot read who else is being targeted');
select ok(not has_table_privilege('authenticated', 'target_locations', 'INSERT'),
  'nor target themselves into a campaign');
select ok(
  (select relrowsecurity from pg_class where relname = 'target_locations'),
  'and RLS is on, so a future grant cannot quietly open it');

-- ---------------------------------------------------------------------------
-- 10. Deleting a campaign takes its targeting with it
-- ---------------------------------------------------------------------------
--
-- The price of one polymorphic table is no foreign key. The sweep trigger is what pays it, so it is
-- asserted rather than assumed -- an orphaned rule is invisible and would come back to life if a new
-- campaign were ever issued the same uuid.

insert into public.businesses (id, name, slug, category, status)
values ('b1000000-0000-4000-8000-00000000000b', 'Test Shop', 'test-shop-targeting', 'parts', 'pending')
on conflict (id) do nothing;

insert into public.ad_campaigns (id, business_id, name, status, surfaces, starts_on)
values ('cc000000-0000-4000-8000-00000000000c', 'b1000000-0000-4000-8000-00000000000b',
        'Sweep test', 'draft', array['community_feed']::ad_surface[], current_date);

insert into public.target_locations (scope, target_id, kind, postal_code)
values ('campaign', 'cc000000-0000-4000-8000-00000000000c', 'postal_code', '77429');

select is(
  (select count(*)::int from public.target_locations
    where target_id = 'cc000000-0000-4000-8000-00000000000c'),
  1,
  'the campaign has a targeting row');

delete from public.ad_campaigns where id = 'cc000000-0000-4000-8000-00000000000c';

select is(
  (select count(*)::int from public.target_locations
    where target_id = 'cc000000-0000-4000-8000-00000000000c'),
  0,
  'and deleting the campaign takes it with them');

-- ---------------------------------------------------------------------------
-- 11. The centroid is written by the server, from the ZIP it was asked about
-- ---------------------------------------------------------------------------
--
-- set_my_location() CLEARS postal_center, and set_member_postal_center() refills it after the
-- server has geocoded. The gap between those two is the whole reason this function takes a postal
-- code it could have looked up itself.

update public.profiles
   set postal_code = '77429', postal_center = null
 where user_id = 'a1000000-0000-4000-8000-00000000000a';

select ok(
  (public.set_member_postal_center('a1000000-0000-4000-8000-00000000000a', '77429',
                                   -95.6972, 29.9691) ->> 'ok')::boolean,
  'the server can fill in a centroid for the ZIP the member actually saved');

select isnt(
  (select postal_center from public.profiles
    where user_id = 'a1000000-0000-4000-8000-00000000000a'),
  null,
  'and it lands');

-- A LATE ANSWER ABOUT AN OLD ZIP IS DISCARDED. Geocoding happens after the member's save has
-- returned, so by the time Mapbox answers they may have saved a different postal code from another
-- tab. Writing it anyway would pin a stale point onto a current ZIP -- which is exactly the failure
-- clearing the column was meant to prevent, reintroduced one step later, and nothing on any screen
-- would look wrong.
update public.profiles
   set postal_code = '77494', postal_center = null
 where user_id = 'a1000000-0000-4000-8000-00000000000a';

select is(
  public.set_member_postal_center('a1000000-0000-4000-8000-00000000000a', '77429',
                                  -95.6972, 29.9691) ->> 'error',
  'stale',
  'a geocode of the PREVIOUS postal code is refused, not applied');

select is(
  (select postal_center from public.profiles
    where user_id = 'a1000000-0000-4000-8000-00000000000a'),
  null,
  'and the member is left with no centroid rather than the wrong one');

-- A geocoder answering with nonsense must not put a member in the ocean: radius targeting would
-- then measure from the wrong continent, and campaigns reaching nobody is a symptom nobody reads
-- as a bad coordinate.
select is(
  public.set_member_postal_center('a1000000-0000-4000-8000-00000000000a', '77494',
                                  -400, 29.9691) ->> 'error',
  'bad_coordinate',
  'an impossible longitude is refused');

-- Control for the row above: the SAME call with a real coordinate works, so the refusal is about
-- the coordinate and not about the function having stopped working.
select ok(
  (public.set_member_postal_center('a1000000-0000-4000-8000-00000000000a', '77494',
                                   -95.8244, 29.7633) ->> 'ok')::boolean,
  'and the same call with a real coordinate succeeds');

select ok(
  not has_function_privilege('authenticated',
    'public.set_member_postal_center(uuid, text, double precision, double precision)', 'execute'),
  'a member cannot write their own centroid -- it follows from the ZIP, not from a claim');

select ok(
  not has_function_privilege('authenticated',
    'public.members_missing_postal_center(integer)', 'execute'),
  'nor read the queue of members whose location has not been resolved');

-- The retry queue exists at all, which is what stops a failed geocode being a member who silently
-- matches no radius campaign until they next happen to edit their profile.
update public.profiles
   set postal_code = '75201', postal_center = null
 where user_id = 'a4000000-0000-4000-8000-00000000000a';

select ok(
  (select count(*) from public.members_missing_postal_center(50)
    where user_id = 'a4000000-0000-4000-8000-00000000000a') = 1,
  'a member with a ZIP and no centroid is queued for the drain to resolve');

select ok(
  (select count(*) from public.members_missing_postal_center(50)
    where user_id = 'a6000000-0000-4000-8000-00000000000a') = 0,
  'and a suspended member is not, because nothing will be shown to them anyway');

-- ---------------------------------------------------------------------------
-- 12. Targeting is enforced where an advert is actually SERVED
-- ---------------------------------------------------------------------------
--
-- app.member_matches_target() being right proves nothing about whether ads_for() uses it. That is
-- the lesson from the recovery-team phase, which shipped with 686 passing assertions and a feature
-- that did not work because three layers each had to allow it and only two did. These assertions go
-- through the function the page actually calls.

insert into public.businesses (id, name, slug, category, status, verification_note)
values ('b2000000-0000-4000-8000-00000000000b', 'Cypress Offroad', 'cypress-offroad-targeting',
        'parts', 'approved', 'checked for the test')
on conflict (id) do nothing;

-- Two campaigns on the same surface: one aimed at Cypress and Katy, one at nobody in particular.
-- The untargeted one is the CONTROL. Without it, "Houston sees nothing" would also be true of a
-- database where ads_for() had simply stopped returning anything at all.
insert into public.ad_campaigns (id, business_id, name, status, surfaces, starts_on)
values
  ('ca000000-0000-4000-8000-00000000000c', 'b2000000-0000-4000-8000-00000000000b',
   'Targeted', 'approved', array['community_feed']::ad_surface[], current_date),
  ('cb000000-0000-4000-8000-00000000000c', 'b2000000-0000-4000-8000-00000000000b',
   'Everybody', 'approved', array['community_feed']::ad_surface[], current_date);

insert into public.ad_creatives (id, campaign_id, headline, body, cta_url, status, is_active)
values
  ('da000000-0000-4000-8000-00000000000d', 'ca000000-0000-4000-8000-00000000000c',
   'Cypress and Katy only', 'Targeted creative', 'https://example.invalid/a', 'approved', true),
  ('db000000-0000-4000-8000-00000000000d', 'cb000000-0000-4000-8000-00000000000c',
   'Anyone at all', 'Untargeted creative', 'https://example.invalid/b', 'approved', true);

insert into public.target_locations (scope, target_id, kind, postal_code) values
  ('campaign', 'ca000000-0000-4000-8000-00000000000c', 'postal_code', '77429'),
  ('campaign', 'ca000000-0000-4000-8000-00000000000c', 'postal_code', '77494');

-- Restore the two members section 11 moved about, so this section tests what it says it does.
update public.profiles set postal_code = '77429',
       postal_center = extensions.st_setsrid(extensions.st_point(-95.6972, 29.9691), 4326)::extensions.geography
 where user_id = 'a1000000-0000-4000-8000-00000000000a';
update public.profiles set postal_code = '75201',
       postal_center = extensions.st_setsrid(extensions.st_point(-96.7970, 32.7831), 4326)::extensions.geography
 where user_id = 'a4000000-0000-4000-8000-00000000000a';

create or replace function pg_temp.served(p_headline text)
returns boolean
language sql
stable
as $$
  select exists (
    select 1
      from jsonb_array_elements(public.ads_for('community_feed', null, null, null, 5) -> 'ads') x
     where x ->> 'headline' = p_headline
  );
$$;

set local role authenticated;

-- The member in Cypress 77429.
set local request.jwt.claims =
  '{"sub":"a1000000-0000-4000-8000-00000000000a","role":"authenticated"}';

select ok(pg_temp.served('Cypress and Katy only'),
  'a member in a targeted ZIP is SERVED the targeted advert by ads_for()');
select ok(pg_temp.served('Anyone at all'),
  'and the untargeted one as well');

-- The member in Dallas.
set local request.jwt.claims =
  '{"sub":"a4000000-0000-4000-8000-00000000000a","role":"authenticated"}';

select ok(not pg_temp.served('Cypress and Katy only'),
  'a member in Dallas is NOT served it -- this is the line that was false until today');
select ok(pg_temp.served('Anyone at all'),
  'but is still served the untargeted one, which is what proves the refusal above is targeting '
  'and not a broken query');

-- The member who has never said where they are. THE BEHAVIOUR CHANGE, through the serving path.
set local request.jwt.claims =
  '{"sub":"a5000000-0000-4000-8000-00000000000a","role":"authenticated"}';

select ok(not pg_temp.served('Cypress and Katy only'),
  'a member with no stated location is not served a targeted advert');
select ok(pg_temp.served('Anyone at all'),
  'and still sees untargeted adverts, so the cost of the change is bounded');

reset role;

-- ---------------------------------------------------------------------------
-- 13. The advertising path still cannot read recovery data
-- ---------------------------------------------------------------------------
--
-- Section 7. Until today ads_for() could not read a member's recovery location because it did not
-- know who the reader was; it looks up auth.uid() now, so the property has to be asserted rather
-- than inherited. This is the guard that stops the dispatch path reading an advertising table,
-- pointed the other way.
--
-- Word boundaries, not LIKE: `%home_location%` would match other identifiers because `_` is a
-- single-character wildcard, and that mistake has twice reported the opposite of the truth here.

select is(
  (select count(*)::int from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname, p.proname) in (('public', 'ads_for'), ('app', 'member_matches_target'),
                                     ('app', 'target_audience_count'))
      and (p.prosrc ~* '\mhome_location\M' or p.prosrc ~* '\mresponders\M')),
  0,
  'no function in the advertising path names responders or home_location');

-- Control: the same query DOES find the dispatch function that legitimately reads it, so a zero
-- above means "it is not there" rather than "this query finds nothing anywhere".
select ok(
  (select count(*) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname = 'candidates'
      and (p.prosrc ~* '\mhome_location\M' or p.prosrc ~* '\mresponders\M')) > 0,
  'and the same check finds it in app.candidates(), where recovery location belongs');

select * from finish();
rollback;
