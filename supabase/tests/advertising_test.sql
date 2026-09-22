-- Winch Up :: proof that advertising cannot reach the parts of this app that matter
--
-- Run with:  supabase test db
--
-- Phase 10's specification is mostly a list of things that must never happen. This file is those
-- things, checked. In rough order of how badly each one would go:
--
--   1. No ad can appear on an emergency surface. The enum has three values and none of them is
--      the request wizard, a live recovery, or the thread between two people on a job. Two of
--      the six resource guides are emergency guidance and are refused by name.
--
--   2. Nobody can buy priority in volunteer matching. Checked by reading the source of every
--      function in the dispatch path and asserting it mentions no advertising table -- because
--      "we would never do that" is not a guarantee, and whoever next edits matching will not
--      have read the comment at the top of the migration.
--
--   3. Every served ad carries its label in the same row as its headline, and a recovery or
--      towing advertiser carries a second one saying they are not a volunteer.
--
--   4. The ad system stores nothing that could identify a person. Not a user id, not a session,
--      not an IP. That is the privacy control, and it is checked here rather than promised.
--
--   5. No fabricated numbers. A new campaign reports zero, because zero is what happened.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- ---------------------------------------------------------------------------
-- A known starting point, as in the community and trails suites.
-- ---------------------------------------------------------------------------

delete from ad_daily_stats;
delete from ad_creatives;
delete from ad_campaigns;
delete from businesses;

-- ---------------------------------------------------------------------------
-- Fixtures: an admin, a tow operator, an off-road shop.
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
)
select '00000000-0000-0000-0000-000000000000', v.id, 'authenticated', 'authenticated',
       v.email, 'x', now(), '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
from (values
  ('e1111111-0000-4000-8000-00000000000e'::uuid, 'ad-admin@example.invalid'),
  ('e2222222-0000-4000-8000-00000000000e'::uuid, 'ad-tow@example.invalid'),
  ('e3333333-0000-4000-8000-00000000000e'::uuid, 'ad-shop@example.invalid'),
  ('e4444444-0000-4000-8000-00000000000e'::uuid, 'ad-member@example.invalid')
) as v(id, email);

insert into user_roles (user_id, role) values
  ('e1111111-0000-4000-8000-00000000000e', 'admin')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 1. The surfaces that do not exist
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::integer from pg_enum e join pg_type t on t.oid = e.enumtypid
    where t.typname = 'ad_surface'),
  3,
  'ad_surface has exactly three values'
);

select ok(
  not exists (
    select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
     where t.typname = 'ad_surface'
       and e.enumlabel in ('request', 'status', 'recovery', 'messages', 'thread', 'board')
  ),
  'and not one of them is a request, a live recovery, a message thread or the board'
);

select is(
  public.ads_for('request') ->> 'error', 'bad_surface',
  'asking for ads on the request wizard is not a permission error, it is a nonexistent surface'
);

select is(
  public.ads_for('recovery_status') ->> 'error', 'bad_surface',
  'nor is there a surface for a live recovery'
);

-- The two resource guides that are emergency guidance.
select ok(not app.ad_slot_allowed('resources', 'stuck'),
  'no ad beside "when the stuck one is you"');
select ok(not app.ad_slot_allowed('resources', 'safety'),
  'no ad beside "doing a recovery without hurting anyone"');
select ok(app.ad_slot_allowed('resources', 'gear'),
  'the gear checklist may carry one');
select ok(app.ad_slot_allowed('community_feed', null),
  'and so may the community feed');

-- ---------------------------------------------------------------------------
-- 2. Advertising is invisible to matching
--
-- Read the source. A comment is not a control.
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::integer
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname || '.' || p.proname in (
            'app.candidates', 'public.advance_dispatch',
            'app.decline_dispatch', 'public.admin_manual_dispatch')
      and (p.prosrc ~* '\mbusinesses\M'
           or p.prosrc ~* '\mad_campaigns\M'
           or p.prosrc ~* '\mad_creatives\M'
           or p.prosrc ~* '\mad_daily_stats\M')),
  0,
  'no function in the dispatch path so much as mentions an advertising table'
);

select is(
  (select count(*)::integer
     from pg_depend d
     join pg_class c on c.oid = d.refobjid
     join pg_proc p on p.oid = d.objid
     join pg_namespace n on n.oid = p.pronamespace
    where c.relname in ('businesses', 'ad_campaigns', 'ad_creatives', 'ad_daily_stats')
      and n.nspname || '.' || p.proname = 'app.candidates'),
  0,
  'and candidates() has no dependency on one either'
);

-- ---------------------------------------------------------------------------
-- 3. The counting table cannot identify anybody
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::integer from information_schema.columns
    where table_schema = 'public' and table_name = 'ad_daily_stats'
      and (column_name ~* 'user|session|ip|agent|referr|device|fingerprint|cookie')),
  0,
  'ad_daily_stats has no column that could identify a person, which is the whole privacy story'
);

select bag_eq(
  $$select column_name::text from information_schema.columns
     where table_schema = 'public' and table_name = 'ad_daily_stats'$$,
  $$values ('creative_id'), ('surface'), ('day'), ('impressions'), ('clicks')$$,
  'it is a count per creative per surface per day and nothing else'
);

-- ---------------------------------------------------------------------------
-- 4. Nothing is reachable except through the functions
-- ---------------------------------------------------------------------------

select ok(not has_table_privilege('anon', 'businesses', 'SELECT'),
  'anon cannot read businesses');
select ok(not has_table_privilege('authenticated', 'ad_campaigns', 'SELECT'),
  'a signed-in user cannot read campaigns directly');
select ok(not has_table_privilege('authenticated', 'ad_daily_stats', 'UPDATE'),
  'nor write to the counts');

select ok(
  has_function_privilege('anon',
    'public.ads_for(text, text, double precision, double precision, integer)', 'EXECUTE'),
  'anon may fetch an ad, because the resources section is public'
);
select ok(
  not has_function_privilege('anon', 'public.ad_record_event(uuid, text, text)', 'EXECUTE'),
  'but nobody may record an event from the browser'
);
select ok(
  not has_function_privilege('authenticated', 'public.ad_record_event(uuid, text, text)', 'EXECUTE'),
  'not even signed in -- counting goes through the server route that sees the IP it limits on'
);

-- ---------------------------------------------------------------------------
-- 5. Approval discipline
-- ---------------------------------------------------------------------------

select throws_ok(
  $$insert into businesses (name, slug, category, status)
    values ('Self Approved', 'self-approved', 'other', 'approved')$$,
  '23514', null,
  'a business cannot be approved without recording what was checked'
);

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"e2222222-0000-4000-8000-00000000000e","role":"authenticated"}';

select is(
  public.save_business(jsonb_build_object(
    'name', 'Hill Country Towing', 'slug', 'hill-country-towing',
    'category', 'recovery_towing',
    'description', 'Heavy recovery and towing, Austin and out.',
    'contact_phone', '+15125550111')) ->> 'ok',
  'true',
  'a business owner registers a business'
);

select is(
  public.save_business(jsonb_build_object(
    'name', 'X', 'slug', 'Not A Slug', 'category', 'other')) ->> 'error',
  'bad_slug',
  'with a URL name that is actually a URL name'
);

set local request.jwt.claims =
  '{"sub":"e3333333-0000-4000-8000-00000000000e","role":"authenticated"}';

select is(
  public.save_business(jsonb_build_object(
    'name', 'Bastrop Offroad', 'slug', 'bastrop-offroad', 'category', 'offroad_shop',
    'description', 'Tyres, lifts and recovery gear.')) ->> 'ok',
  'true',
  'and so does a shop'
);

reset role;
create temp table bids as select slug, id, owner_user_id from businesses;
grant select on bids to public;

-- An ordinary member cannot review anything.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"e4444444-0000-4000-8000-00000000000e","role":"authenticated"}';

select throws_ok(
  $$select public.admin_ad_queue('pending')$$,
  '42501', null,
  'an ordinary member cannot see the advertising queue'
);

select throws_ok(
  $$select public.admin_review_ad('business',
      (select id from bids where slug = 'hill-country-towing'), 'approved', null, 'sure')$$,
  '42501', null,
  'nor approve a business'
);

-- Nor act on somebody else's business.
select is(
  public.save_campaign(jsonb_build_object(
    'business_id', (select id from bids where slug = 'bastrop-offroad'),
    'name', 'Not mine', 'surfaces', jsonb_build_array('trails'))) ->> 'error',
  'not_found',
  'and cannot make a campaign for a business they do not own'
);

-- ---------------------------------------------------------------------------
-- 6. The admin approves, and that is where business_owner starts meaning something
-- ---------------------------------------------------------------------------

set local request.jwt.claims =
  '{"sub":"e1111111-0000-4000-8000-00000000000e","role":"authenticated","aal":"aal2"}';

select is(
  public.admin_review_ad('business',
    (select id from bids where slug = 'hill-country-towing'), 'approved') ->> 'error',
  'verification_note_required',
  'an admin cannot approve a business without saying what they checked'
);

select is(
  public.admin_review_ad('business',
    (select id from bids where slug = 'hill-country-towing'), 'approved', null,
    'LLC registered in Texas, phone answered, address matches the tow yard') ->> 'ok',
  'true',
  'and can with it'
);

select is(
  public.admin_review_ad('business',
    (select id from bids where slug = 'bastrop-offroad'), 'approved', null,
    'Storefront visited, sign matches the name') ->> 'ok',
  'true',
  'the shop too'
);

reset role;

select ok(
  exists (select 1 from user_roles
           where user_id = 'e2222222-0000-4000-8000-00000000000e' and role = 'business_owner'),
  'approving a business grants its owner the business_owner role, which until now did nothing'
);

select ok(
  not exists (select 1 from user_roles
               where user_id = 'e4444444-0000-4000-8000-00000000000e'
                 and role = 'business_owner'),
  'and grants it to nobody else'
);

-- ---------------------------------------------------------------------------
-- 7. A campaign, a creative, and what it takes to be served
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"e2222222-0000-4000-8000-00000000000e","role":"authenticated"}';

select is(
  public.save_campaign(jsonb_build_object(
    'business_id', (select id from bids where slug = 'hill-country-towing'),
    'name', 'Autumn', 'surfaces', jsonb_build_array('community_feed', 'resources'),
    'monthly_price_cents', 15000)) ->> 'ok',
  'true',
  'a campaign is created'
);

select is(
  public.save_campaign(jsonb_build_object(
    'business_id', (select id from bids where slug = 'hill-country-towing'),
    'name', 'Nowhere', 'surfaces', jsonb_build_array())) ->> 'error',
  'no_surfaces',
  'a campaign has to run somewhere'
);

reset role;
create temp table cmp as select name, id, business_id from ad_campaigns;
grant select on cmp to public;

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"e2222222-0000-4000-8000-00000000000e","role":"authenticated"}';

select is(
  public.save_creative(jsonb_build_object(
    'campaign_id', (select id from cmp where name = 'Autumn'),
    'headline', 'Heavy recovery, day or night',
    'body', 'Wreckers and rotators, Travis and Bastrop.',
    'cta_label', 'Call us', 'cta_url', 'https://example.invalid/tow')) ->> 'ok',
  'true',
  'a creative is uploaded'
);

select is(
  public.save_creative(jsonb_build_object(
    'campaign_id', (select id from cmp where name = 'Autumn'),
    'headline', 'Bad link', 'cta_url', 'javascript:alert(1)')) ->> 'error',
  'bad_url',
  'and has to point somewhere that is http or https'
);

-- Nothing is served yet: the campaign and the creative are still pending.
set local request.jwt.claims =
  '{"sub":"e4444444-0000-4000-8000-00000000000e","role":"authenticated"}';

select is(
  jsonb_array_length(public.ads_for('community_feed') -> 'ads'), 0,
  'a pending campaign shows nobody anything'
);

reset role;
create temp table crv as select headline, id, campaign_id from ad_creatives;
grant select on crv to public;

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"e1111111-0000-4000-8000-00000000000e","role":"authenticated","aal":"aal2"}';

select is(
  public.admin_review_ad('campaign', (select id from cmp where name = 'Autumn'), 'approved')
    ->> 'ok',
  'true', 'the admin approves the campaign');

select is(
  jsonb_array_length(public.ads_for('community_feed') -> 'ads'), 0,
  'and still nothing shows, because the creative has not been looked at'
);

select is(
  public.admin_review_ad('creative',
    (select id from crv where headline like 'Heavy recovery%'), 'approved') ->> 'ok',
  'true', 'the admin approves the creative too');

-- ---------------------------------------------------------------------------
-- 8. What a served ad carries
-- ---------------------------------------------------------------------------

set local request.jwt.claims =
  '{"sub":"e4444444-0000-4000-8000-00000000000e","role":"authenticated"}';

select is(
  jsonb_array_length(public.ads_for('community_feed') -> 'ads'), 1,
  'now it is served'
);

select ok(
  (public.ads_for('community_feed') -> 'ads' -> 0 ->> 'labelled')::boolean,
  'and arrives labelled, in the same row as the headline, so it cannot be rendered without it'
);

select ok(
  (public.ads_for('community_feed') -> 'ads' -> 0 ->> 'not_a_volunteer')::boolean,
  'a towing advertiser carries the second line: they are not a Winch Up volunteer'
);

select is(
  jsonb_array_length(public.ads_for('trails') -> 'ads'), 0,
  'a campaign not bought for trails does not appear on trails'
);

select is(
  jsonb_array_length(public.ads_for('resources', 'gear') -> 'ads'), 1,
  'it does appear beside the gear checklist, which is not emergency guidance'
);

select is(
  jsonb_array_length(public.ads_for('resources', 'stuck') -> 'ads'), 0,
  'and not beside the guide for somebody who is stuck right now'
);

select ok(
  (public.ads_for('resources', 'safety') ->> 'blocked')::boolean,
  'the serving function says plainly that it refused, rather than quietly returning nothing'
);

-- ---------------------------------------------------------------------------
-- 9. Scheduling, pausing and geography
-- ---------------------------------------------------------------------------

reset role;
update ad_campaigns set starts_on = current_date + 3 where name = 'Autumn';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"e4444444-0000-4000-8000-00000000000e","role":"authenticated"}';
select is(
  jsonb_array_length(public.ads_for('community_feed') -> 'ads'), 0,
  'a campaign that has not started yet is not served'
);

reset role;
update ad_campaigns set starts_on = current_date - 30, ends_on = current_date - 1
 where name = 'Autumn';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"e4444444-0000-4000-8000-00000000000e","role":"authenticated"}';
select is(
  jsonb_array_length(public.ads_for('community_feed') -> 'ads'), 0,
  'nor one that has finished'
);

reset role;
update ad_campaigns set starts_on = current_date - 1, ends_on = null,
  target_center = extensions.st_setsrid(
                    extensions.st_point(-97.74, 30.27), 4326)::extensions.geography,
  target_radius_miles = 20
 where name = 'Autumn';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"e4444444-0000-4000-8000-00000000000e","role":"authenticated"}';

select is(
  jsonb_array_length(public.ads_for('community_feed', null, -97.75, 30.28) -> 'ads'), 1,
  'a targeted campaign is served to a reader inside the radius'
);

select is(
  jsonb_array_length(public.ads_for('community_feed', null, -95.37, 29.76) -> 'ads'), 0,
  'and not to one in Houston'
);

select is(
  jsonb_array_length(public.ads_for('community_feed') -> 'ads'), 1,
  'a reader whose browser gave no position still sees it, rather than targeting quietly meaning nobody'
);

-- Pausing, by the advertiser.
set local request.jwt.claims =
  '{"sub":"e2222222-0000-4000-8000-00000000000e","role":"authenticated"}';
select is(
  public.set_campaign_running((select id from cmp where name = 'Autumn'), false) ->> 'ok',
  'true', 'the advertiser pauses their own campaign');

set local request.jwt.claims =
  '{"sub":"e4444444-0000-4000-8000-00000000000e","role":"authenticated"}';
select is(
  jsonb_array_length(public.ads_for('community_feed') -> 'ads'), 0,
  'and it stops being served'
);

-- ---------------------------------------------------------------------------
-- 10. An advertiser cannot approve their own work
-- ---------------------------------------------------------------------------

set local request.jwt.claims =
  '{"sub":"e3333333-0000-4000-8000-00000000000e","role":"authenticated"}';

select is(
  public.save_campaign(jsonb_build_object(
    'business_id', (select id from bids where slug = 'bastrop-offroad'),
    'name', 'Shop spring', 'surfaces', jsonb_build_array('trails'))) ->> 'ok',
  'true', 'the shop makes a campaign, which starts as a draft');

reset role;
create temp table cmp2 as select name, id from ad_campaigns where name = 'Shop spring';
grant select on cmp2 to public;

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"e3333333-0000-4000-8000-00000000000e","role":"authenticated"}';

select is(
  public.set_campaign_running((select id from cmp2 where name = 'Shop spring'), true) ->> 'error',
  'not_found',
  'and cannot resume a draft into a running campaign -- resume is not a way to self-approve'
);

select is(
  public.submit_for_review('campaign', (select id from cmp2 where name = 'Shop spring')) ->> 'ok',
  'true', 'they submit it for review instead');

-- ---------------------------------------------------------------------------
-- 11. Approval attaches to the words, not to the row
-- ---------------------------------------------------------------------------

set local request.jwt.claims =
  '{"sub":"e2222222-0000-4000-8000-00000000000e","role":"authenticated"}';

select is(
  public.save_creative(jsonb_build_object(
    'id', (select id from crv where headline like 'Heavy recovery%'),
    'campaign_id', (select id from cmp where name = 'Autumn'),
    'headline', 'Completely different offer now',
    'cta_url', 'https://example.invalid/other')) ->> 'ok',
  'true',
  'an advertiser edits an approved creative'
);

reset role;
select is(
  (select status::text from ad_creatives where headline = 'Completely different offer now'),
  'pending',
  'and it goes straight back to pending, because approval was of the words and not the row'
);

select is(
  (select status::text from businesses where slug = 'hill-country-towing'),
  'approved',
  'the business itself is untouched by that'
);

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"e2222222-0000-4000-8000-00000000000e","role":"authenticated"}';

select is(
  public.save_business(jsonb_build_object(
    'id', (select id from bids where slug = 'hill-country-towing'),
    'name', 'Hill Country Towing and Recovery', 'slug', 'hill-country-towing',
    'category', 'recovery_towing')) ->> 'ok',
  'true',
  'editing an approved business is allowed'
);

reset role;
select is(
  (select status::text from businesses where slug = 'hill-country-towing'),
  'pending',
  'but sends it back for review -- otherwise "approve the shop, then rename it" is a way past approval'
);

select is(
  (select verification_note from businesses where slug = 'hill-country-towing'),
  null,
  'and clears what the admin said they had checked, because they had not checked this'
);

-- ---------------------------------------------------------------------------
-- 12. Counting, and the absence of invented numbers
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"e3333333-0000-4000-8000-00000000000e","role":"authenticated"}';

select is(
  ((public.advertiser_overview() -> 'businesses' -> 0 -> 'campaigns' -> 0) ->> 'impressions'),
  '0',
  'a campaign nobody has seen reports zero impressions, not a plausible-looking number'
);

reset role;

select is(
  public.ad_record_event(
    (select id from crv where headline like 'Heavy recovery%'), 'community_feed', 'impression')
    ->> 'error',
  'not_live',
  'an event against a creative that is not live is refused, so a cached page cannot inflate a bill'
);

select is((select count(*)::integer from ad_daily_stats), 0,
  'and nothing was written');

reset role;

select * from finish();
rollback;
