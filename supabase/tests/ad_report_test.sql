-- Winch Up :: the geographic report, and the suppression that makes it publishable
--
-- Run with:  supabase test db
--
-- Section 12 of the owner's spec asked for impressions and clicks by city and ZIP. CLAUDE.md's
-- standing rule is that the ad statistics must carry no column that could identify a person. A ZIP
-- with one member in it turns "impressions: 1" into "that member saw this advert", so the resolution
-- the owner approved on 2026-10-03 is: keep the breakdown, never report a bucket below a threshold.
--
-- THE TWO THINGS THAT HAVE TO BE TRUE TOGETHER, and either alone is useless:
--
--   a small bucket is not reported as a place        (or the privacy rule is not enforced)
--   the totals still add up                          (or somebody reconciles by hand and asks for
--                                                     the raw table, which defeats the whole thing)
--
-- Both are asserted below, against the same data, with a bucket above the threshold as the control.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

create or replace function pg_temp.an_admin() returns uuid language sql stable as $$
  select user_id from public.user_roles where role = 'admin' order by user_id limit 1;
$$;

-- A known threshold, rather than whatever the setting happens to be.
insert into public.app_settings (key, value) values ('analytics.min_cohort', '5'::jsonb)
on conflict (key) do update set value = '5'::jsonb;

insert into public.businesses (id, name, slug, category, status, verification_note)
values ('b5000000-0000-4000-8000-00000000000b', 'Report Parts', 'report-parts',
        'parts', 'approved', 'checked for the test')
on conflict (id) do nothing;

insert into public.ad_campaigns (id, business_id, name, status, surfaces, starts_on)
values ('cf100000-0000-4000-8000-00000000000c', 'b5000000-0000-4000-8000-00000000000b',
        'Report campaign', 'approved', array['community_feed']::ad_surface[], current_date);

insert into public.ad_creatives (id, campaign_id, headline, body, cta_url, status, is_active)
values ('df100000-0000-4000-8000-00000000000d', 'cf100000-0000-4000-8000-00000000000c',
        'Report creative', 'Body', 'https://example.invalid/r', 'approved', true);

-- ---------------------------------------------------------------------------
-- 1. Recording an impression records the place, and only the place
-- ---------------------------------------------------------------------------

select is(
  public.ad_record_event_at('df100000-0000-4000-8000-00000000000d', 'community_feed', 'impression',
                            'TX', 'Cypress', '77429') ->> 'ok',
  'true',
  'an impression is recorded against a stated area');

select is(
  (select impressions from public.ad_geo_daily_stats
    where creative_id = 'df100000-0000-4000-8000-00000000000d' and postal_code = '77429'),
  1,
  'and lands in the geographic table');

select is(
  (select impressions from public.ad_daily_stats
    where creative_id = 'df100000-0000-4000-8000-00000000000d'),
  1,
  'and in the pinned total table, which is the copy nothing suppresses');

-- An anonymous reader accumulates into ONE row rather than one row per page view. This is what the
-- empty-string sentinel is for: a null here would be distinct from every other null and the table
-- would grow a row per impression while the report read correctly.
select is(
  public.ad_record_event_at('df100000-0000-4000-8000-00000000000d', 'community_feed', 'impression',
                            null, null, null) ->> 'ok',
  'true', 'an impression from a reader with no stated area is recorded');
select is(
  public.ad_record_event_at('df100000-0000-4000-8000-00000000000d', 'community_feed', 'impression',
                            null, null, null) ->> 'ok',
  'true', 'and a second one');

select is(
  (select count(*)::int from public.ad_geo_daily_stats
    where creative_id = 'df100000-0000-4000-8000-00000000000d' and postal_code = ''),
  1,
  'and the two accumulate into ONE row, not two');

select is(
  (select impressions from public.ad_geo_daily_stats
    where creative_id = 'df100000-0000-4000-8000-00000000000d' and postal_code = ''),
  2,
  'with the count on it');

-- ---------------------------------------------------------------------------
-- 2. Nobody reads the table
-- ---------------------------------------------------------------------------

select ok(not has_table_privilege('authenticated', 'ad_geo_daily_stats', 'SELECT'),
  'a member cannot read the geographic counts, so the suppression cannot be walked around');
select ok(not has_table_privilege('anon', 'ad_geo_daily_stats', 'SELECT'),
  'nor can a stranger');
select ok(
  (select relrowsecurity from pg_class where relname = 'ad_geo_daily_stats'),
  'and RLS is on, so a future grant cannot quietly open it');

select ok(
  not has_function_privilege('authenticated',
    'public.ad_record_event_at(uuid, text, text, text, text, text)', 'execute'),
  'and a member cannot write a count either -- the browser is not a witness to money');

-- THE PLACE CANNOT COME FROM THE BROWSER. Asserted as a grant rather than argued about: the only
-- caller is the server route, which reads the session itself.
select ok(
  has_function_privilege('service_role',
    'public.ad_record_event_at(uuid, text, text, text, text, text)', 'execute'),
  'only the service role records one');

-- ---------------------------------------------------------------------------
-- 3. The statistics tables still have no column about a person
-- ---------------------------------------------------------------------------
--
-- The property CLAUDE.md pins for ad_daily_stats, extended to the two new tables. Named columns, not a
-- count, so adding one is a deliberate act.

select set_eq(
  $$select column_name::text from information_schema.columns
     where table_schema = 'public' and table_name = 'ad_geo_daily_stats'$$,
  array['creative_id', 'surface', 'day', 'state', 'city', 'postal_code', 'impressions', 'clicks'],
  'ad_geo_daily_stats is exactly these eight columns: a creative, a surface, a day, a PLACE, and two counts');

select set_eq(
  $$select column_name::text from information_schema.columns
     where table_schema = 'public' and table_name = 'event_daily_stats'$$,
  array['event_id', 'day', 'views'],
  'and event_daily_stats has no viewer column -- event_rsvps is where somebody chooses to say they are going');

-- ---------------------------------------------------------------------------
-- 4. THE SUPPRESSION
-- ---------------------------------------------------------------------------
--
-- Four areas, chosen so the threshold of five falls between them:
--
--   77429  9 impressions   reported by name
--   77494  6 impressions   reported by name
--   77007  2 impressions   SUPPRESSED
--   75201  1 impression    SUPPRESSED
--   ''     2 impressions   reported as "unknown area", which is not the same thing
--
-- Named buckets total 15, suppressed total 3, unknown 2. The grand total must be 20.

delete from public.ad_geo_daily_stats
 where creative_id = 'df100000-0000-4000-8000-00000000000d';
delete from public.ad_daily_stats
 where creative_id = 'df100000-0000-4000-8000-00000000000d';

insert into public.ad_geo_daily_stats (creative_id, surface, day, state, city, postal_code,
                                       impressions, clicks)
values
  ('df100000-0000-4000-8000-00000000000d', 'community_feed', current_date, 'TX', 'Cypress', '77429', 9, 3),
  ('df100000-0000-4000-8000-00000000000d', 'community_feed', current_date, 'TX', 'Katy',    '77494', 6, 1),
  ('df100000-0000-4000-8000-00000000000d', 'community_feed', current_date, 'TX', 'Houston', '77007', 2, 1),
  ('df100000-0000-4000-8000-00000000000d', 'community_feed', current_date, 'TX', 'Dallas',  '75201', 1, 1),
  ('df100000-0000-4000-8000-00000000000d', 'community_feed', current_date, '',   '',        '',      2, 0);

insert into public.ad_daily_stats (creative_id, surface, day, impressions, clicks)
values ('df100000-0000-4000-8000-00000000000d', 'community_feed', current_date, 20, 6);

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.an_admin(), 'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;

create or replace function pg_temp.rep() returns jsonb language sql stable as $$
  select public.admin_ad_report('cf100000-0000-4000-8000-00000000000c', null, 30);
$$;

select is(pg_temp.rep() ->> 'ok', 'true', 'the admin reads the report');
select is((pg_temp.rep() -> 'min_cohort')::int, 5, 'and it states the threshold it applied');

-- The named buckets.
select ok(
  exists (select 1 from jsonb_array_elements(pg_temp.rep() -> 'by_postal_code') x
           where x ->> 'postal_code' = '77429' and (x ->> 'impressions')::int = 9),
  '77429, with nine impressions, is reported by name');

select ok(
  exists (select 1 from jsonb_array_elements(pg_temp.rep() -> 'by_postal_code') x
           where x ->> 'postal_code' = '77494' and (x ->> 'impressions')::int = 6),
  'and 77494 with six -- the control that proves the refusals below are about the threshold');

-- THE REFUSALS.
select ok(
  not exists (select 1 from jsonb_array_elements(pg_temp.rep() -> 'by_postal_code') x
               where x ->> 'postal_code' = '77007'),
  '77007, with two, is NOT named');

select ok(
  not exists (select 1 from jsonb_array_elements(pg_temp.rep() -> 'by_postal_code') x
               where x ->> 'postal_code' = '75201'),
  'nor 75201 with one, which is the row closest to being a person');

-- Rolled up, not dropped.
select is(
  (select (x ->> 'impressions')::int from jsonb_array_elements(pg_temp.rep() -> 'by_postal_code') x
    where (x ->> 'suppressed')::boolean),
  3,
  'their three impressions are still in the report, in one suppressed row');

select is(
  (select (x ->> 'bucket_count')::int from jsonb_array_elements(pg_temp.rep() -> 'by_postal_code') x
    where (x ->> 'suppressed')::boolean),
  2,
  'which says how many areas went into it, so it is not mistaken for a place called Other');

-- "No stated area" is reported as itself. It is usually the biggest row on the page, and calling it
-- suppressed would be a lie about why it is not a city.
select is(
  (select (x ->> 'impressions')::int from jsonb_array_elements(pg_temp.rep() -> 'by_postal_code') x
    where (x ->> 'unknown_area')::boolean),
  2,
  'readers who have not said where they are get their own row, not the suppressed one');

-- THE ARITHMETIC. This is the half that stops anybody needing the raw table.
select is(
  (select sum((x ->> 'impressions')::int)::int
     from jsonb_array_elements(pg_temp.rep() -> 'by_postal_code') x),
  20,
  'and the parts add up to the total -- 9 + 6 + 3 suppressed + 2 unknown');

select is(
  ((pg_temp.rep() -> 'totals') ->> 'impressions')::int,
  20,
  'which is the total from ad_daily_stats, the copy no threshold touches');

-- A click inside a suppressed bucket travels with it rather than being reported alone. "0 impressions,
-- 1 click in 75201" would be a worse disclosure than the one being prevented: a click is one person
-- deliberately doing something.
select is(
  (select (x ->> 'clicks')::int from jsonb_array_elements(pg_temp.rep() -> 'by_postal_code') x
    where (x ->> 'suppressed')::boolean),
  2,
  'the clicks from suppressed areas are folded in with them, never published alone');

-- By city, the same rule.
select ok(
  exists (select 1 from jsonb_array_elements(pg_temp.rep() -> 'by_city') x
           where x ->> 'city' = 'Cypress'),
  'Cypress is named');
select ok(
  not exists (select 1 from jsonb_array_elements(pg_temp.rep() -> 'by_city') x
               where x ->> 'city' = 'Dallas'),
  'and Dallas, with one impression, is not');

-- ---------------------------------------------------------------------------
-- 5. Reach is estimated, and says so
-- ---------------------------------------------------------------------------

select ok(
  (pg_temp.rep() -> 'estimated_reach') is not null,
  'the report carries an estimated reach');

select ok(
  not (pg_temp.rep() ? 'unique_viewers'),
  'and NOT a unique-viewer count: counting people needs a per-person row, which these tables must '
  'never grow, and a field labelled unique viewers holding something else is worse than no field');

select ok(
  (pg_temp.rep() ->> 'note') like '%not a count of viewers%',
  'the payload says so itself, so a screen cannot present the breakdown as complete');

-- ---------------------------------------------------------------------------
-- 6. The threshold is a setting, and moving it moves the behaviour
-- ---------------------------------------------------------------------------
--
-- Otherwise everything above would also pass against a function with 5 hard-coded, and the owner
-- could not raise it when the membership grows.

reset role;
insert into public.app_settings (key, value) values ('analytics.min_cohort', '7'::jsonb)
on conflict (key) do update set value = '7'::jsonb;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.an_admin(), 'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;

select ok(
  not exists (select 1 from jsonb_array_elements(pg_temp.rep() -> 'by_postal_code') x
               where x ->> 'postal_code' = '77494'),
  'raising the threshold to seven suppresses 77494, which six impressions used to clear');

select is(
  (select sum((x ->> 'impressions')::int)::int
     from jsonb_array_elements(pg_temp.rep() -> 'by_postal_code') x),
  20,
  'and the parts still add up');

reset role;
insert into public.app_settings (key, value) values ('analytics.min_cohort', '5'::jsonb)
on conflict (key) do update set value = '5'::jsonb;

-- ---------------------------------------------------------------------------
-- 7. Who may read a report
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"00000000-0000-4000-8000-0000000000fc","role":"authenticated"}';

select throws_ok(
  $$select public.admin_ad_report('cf100000-0000-4000-8000-00000000000c')$$,
  '42501',
  null,
  'a member cannot read an advertising report');

select throws_ok(
  $$select public.admin_event_report()$$,
  '42501',
  null,
  'nor the event report');

reset role;

-- ---------------------------------------------------------------------------
-- 8. Event views
-- ---------------------------------------------------------------------------

insert into public.events (id, title, starts_at, status)
values ('11120000-0000-4000-8000-00000000001e', 'Counted event',
        now() + interval '4 days', 'published');

select is(public.record_event_view('11120000-0000-4000-8000-00000000001e') ->> 'ok', 'true',
  'a view of a published event is counted');
select is(public.record_event_view('11120000-0000-4000-8000-00000000001e') ->> 'ok', 'true',
  'and a second one');

select is(
  (select views from public.event_daily_stats
    where event_id = '11120000-0000-4000-8000-00000000001e'),
  2,
  'into one row per event per day');

insert into public.events (id, title, starts_at, status)
values ('11130000-0000-4000-8000-00000000001e', 'Draft event',
        now() + interval '4 days', 'draft');

select is(
  public.record_event_view('11130000-0000-4000-8000-00000000001e') ->> 'error',
  'not_found',
  'a draft event is not counted -- and refusing it is also how it stays unannounced');

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.an_admin(), 'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;

select ok(
  exists (select 1 from jsonb_array_elements(public.admin_event_report() -> 'events') x
           where x ->> 'title' = 'Counted event' and (x ->> 'views')::int = 2),
  'and the event report shows the count');

select ok(
  not exists (select 1 from jsonb_array_elements(public.admin_event_report() -> 'events') x
               where x ->> 'title' = 'Draft event'),
  'while a draft event is not in it at all');

reset role;

select * from finish();
rollback;
