-- Winch Up :: a campaign's life, and whether the label matches what is served
--
-- Run with:  supabase test db
--
-- Section 9 of the owner's spec. The lifecycle labels are DERIVED from status and dates rather than
-- stored, on the argument that two sources of truth about whether somebody's money is buying anything
-- is one too many. Section 5 of this file is where that argument is actually tested: for every phase,
-- "the screen says active" and "ads_for serves it" have to agree.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

create or replace function pg_temp.an_admin() returns uuid language sql stable as $$
  select user_id from public.user_roles where role = 'admin' order by user_id limit 1;
$$;

insert into public.businesses (id, name, slug, category, status, verification_note)
values ('b3000000-0000-4000-8000-00000000000b', 'Lifecycle Parts', 'lifecycle-parts',
        'parts', 'approved', 'checked for the test')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 1. Every phase the spec names
-- ---------------------------------------------------------------------------

select is(app.campaign_phase('draft', current_date, null, null), 'draft',
  'a draft is a draft');

select is(app.campaign_phase('pending', current_date, null, null), 'pending',
  'and something awaiting review says so rather than pretending to be scheduled');

select is(app.campaign_phase('rejected', current_date, null, null), 'rejected',
  'and a rejected campaign is not quietly a draft again');

select is(app.campaign_phase('approved', current_date + 7, null, null), 'scheduled',
  'approved with a start in the future is SCHEDULED');

select is(app.campaign_phase('approved', current_date, null, null), 'active',
  'approved and started is ACTIVE');

select is(app.campaign_phase('approved', current_date - 30, current_date + 1, null), 'active',
  'and stays active on the day before it ends');

select is(app.campaign_phase('approved', current_date - 30, current_date, null), 'active',
  'and on the last day itself -- an end date is inclusive, which is what an advertiser is buying');

select is(app.campaign_phase('approved', current_date - 30, current_date - 1, null), 'expired',
  'and is EXPIRED the day after');

select is(app.campaign_phase('paused', current_date - 1, null, null), 'paused',
  'a paused campaign reads paused, not expired -- it can come back');

select is(app.campaign_phase('ended', current_date - 1, null, null), 'expired',
  'and the stored `ended` status reads as expired, so there is one word for it on screen');

-- ARCHIVED BEATS EVERYTHING. An archived campaign that would otherwise be active must not read
-- "active" on any screen, or the list somebody archived it from still shows it as running.
select is(app.campaign_phase('approved', current_date, null, now()), 'archived',
  'archived wins over active');

select is(app.campaign_phase('draft', current_date, null, now()), 'archived',
  'and over draft');

-- ---------------------------------------------------------------------------
-- 2. Archiving is not a status
-- ---------------------------------------------------------------------------
--
-- The distinction the column comment makes: an archived campaign that was approved and ran for a
-- month is still that, and a report has to be able to say so.

insert into public.ad_campaigns (id, business_id, name, status, surfaces, starts_on, ends_on)
values ('cd000000-0000-4000-8000-00000000000c', 'b3000000-0000-4000-8000-00000000000b',
        'Ran last month', 'approved', array['community_feed']::ad_surface[],
        current_date - 60, current_date - 30);

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.an_admin(), 'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;

select is(
  public.set_campaign_archived('cd000000-0000-4000-8000-00000000000c', true) ->> 'ok',
  'true', 'an admin archives a finished campaign');

reset role;

select is(
  (select status::text from public.ad_campaigns where id = 'cd000000-0000-4000-8000-00000000000c'),
  'approved',
  'and its STATUS is untouched -- it was approved, and the record still says so');

select isnt(
  (select archived_at from public.ad_campaigns where id = 'cd000000-0000-4000-8000-00000000000c'),
  null, 'while archived_at records the hiding separately');

-- Reversible, because the warning text on any such control promises it is.
select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.an_admin(), 'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;

select is(
  public.set_campaign_archived('cd000000-0000-4000-8000-00000000000c', false) ->> 'ok',
  'true', 'and it can be un-archived');

reset role;

select is(
  (select archived_at from public.ad_campaigns where id = 'cd000000-0000-4000-8000-00000000000c'),
  null, 'which clears the timestamp rather than leaving a stale one');

-- ---------------------------------------------------------------------------
-- 3. A stranger cannot archive somebody else's campaign
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"00000000-0000-4000-8000-0000000000fe","role":"authenticated"}';

select is(
  public.set_campaign_archived('cd000000-0000-4000-8000-00000000000c', true) ->> 'error',
  'not_found',
  'somebody who neither owns the business nor administers the site is refused');

select is(
  public.duplicate_campaign('cd000000-0000-4000-8000-00000000000c') ->> 'error',
  'not_found',
  'and cannot duplicate it either -- which would otherwise be a way to read its targeting');

reset role;

-- ---------------------------------------------------------------------------
-- 4. Duplicating carries the work and none of the approval
-- ---------------------------------------------------------------------------
--
-- "Approval attaches to the words, not the row." Inheriting approval through a copy would make
-- "approve this, then duplicate it and change the headline" a two-step way past review.

insert into public.ad_creatives (id, campaign_id, headline, body, cta_url, status, is_active)
values ('dc000000-0000-4000-8000-00000000000d', 'cd000000-0000-4000-8000-00000000000c',
        'Approved words', 'Body', 'https://example.invalid/x', 'approved', true);

insert into public.target_locations (scope, target_id, kind, postal_code) values
  ('campaign', 'cd000000-0000-4000-8000-00000000000c', 'postal_code', '77429'),
  ('campaign', 'cd000000-0000-4000-8000-00000000000c', 'postal_code', '77494');

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.an_admin(), 'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;

select is(
  public.duplicate_campaign('cd000000-0000-4000-8000-00000000000c', 'Next month') ->> 'ok',
  'true', 'the campaign is duplicated');

reset role;

create temp table dup as select id from public.ad_campaigns where name = 'Next month';
grant select on dup to public;

select is(
  (select status::text from public.ad_campaigns where id = (select id from dup)),
  'draft',
  'THE COPY IS A DRAFT, whatever the original was');

select is(
  (select count(*)::int from public.ad_creatives
    where campaign_id = (select id from dup) and status = 'approved'),
  0,
  'and not one of its creatives inherited approval');

select is(
  (select count(*)::int from public.ad_creatives
    where campaign_id = (select id from dup) and is_active),
  0,
  'nor is any of them active');

select is(
  (select headline from public.ad_creatives where campaign_id = (select id from dup)),
  'Approved words',
  'while the words themselves came across -- the point is to save retyping');

select is(
  (select count(*)::int from public.target_locations
    where scope = 'campaign' and target_id = (select id from dup)),
  2,
  'and so did the targeting, which is the part nobody wants to retype');

select ok(
  (select starts_on from public.ad_campaigns where id = (select id from dup)) >= current_date,
  'the copy does not start in the past, so approving it cannot make it serve retroactively');

-- ---------------------------------------------------------------------------
-- 5. THE LABEL AND THE SERVING PATH CANNOT DISAGREE
-- ---------------------------------------------------------------------------
--
-- This is the section the derived-not-stored decision rests on. For each phase, the campaign is put
-- into that phase and then both questions are asked: what does app.campaign_phase() call it, and does
-- ads_for() actually return it? Anything other than "active serves, nothing else does" means the admin
-- screen is lying about somebody's money.

insert into public.businesses (id, name, slug, category, status, verification_note)
values ('b4000000-0000-4000-8000-00000000000b', 'Phase Parts', 'phase-parts',
        'parts', 'approved', 'checked for the test')
on conflict (id) do nothing;

insert into public.ad_campaigns (id, business_id, name, status, surfaces, starts_on)
values ('ce000000-0000-4000-8000-00000000000c', 'b4000000-0000-4000-8000-00000000000b',
        'Phase probe', 'approved', array['community_feed']::ad_surface[], current_date);

insert into public.ad_creatives (id, campaign_id, headline, body, cta_url, status, is_active)
values ('de000000-0000-4000-8000-00000000000d', 'ce000000-0000-4000-8000-00000000000c',
        'Phase probe creative', 'Body', 'https://example.invalid/p', 'approved', true);

create or replace function pg_temp.probe_served() returns boolean language sql stable as $$
  select exists (
    select 1 from jsonb_array_elements(public.ads_for('community_feed', null, null, null, 5) -> 'ads') x
     where x ->> 'headline' = 'Phase probe creative'
  );
$$;

-- SECURITY DEFINER, deliberately, and it is worth saying why rather than copying it.
--
-- The two questions this section asks are asked from different vantage points. "Is it served?" is what
-- a MEMBER sees, so pg_temp.probe_served() runs as the caller and goes through ads_for() exactly as
-- the page does. "What phase is it in?" is a server-side fact about a table that `authenticated` has
-- no grant on at all -- which is the deny-by-default floor working, and reading it as the member fails
-- with "permission denied for table ad_campaigns". So this one reads it as the owner.
create or replace function pg_temp.probe_phase()
returns text
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  select app.campaign_phase(status, starts_on, ends_on, archived_at)
    from public.ad_campaigns where id = 'ce000000-0000-4000-8000-00000000000c';
$$;

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"00000000-0000-4000-8000-0000000000fd","role":"authenticated"}';

select is(pg_temp.probe_phase(), 'active', 'active:');
select ok(pg_temp.probe_served(), '  ... and an active campaign IS served');

reset role;
update public.ad_campaigns set starts_on = current_date + 5
 where id = 'ce000000-0000-4000-8000-00000000000c';
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"00000000-0000-4000-8000-0000000000fd","role":"authenticated"}';

select is(pg_temp.probe_phase(), 'scheduled', 'scheduled:');
select ok(not pg_temp.probe_served(), '  ... and a scheduled campaign is NOT served yet');

reset role;
update public.ad_campaigns set starts_on = current_date - 30, ends_on = current_date - 1
 where id = 'ce000000-0000-4000-8000-00000000000c';
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"00000000-0000-4000-8000-0000000000fd","role":"authenticated"}';

select is(pg_temp.probe_phase(), 'expired', 'expired:');
select ok(not pg_temp.probe_served(), '  ... and an expired campaign is not served');

reset role;
update public.ad_campaigns set starts_on = current_date - 1, ends_on = null, status = 'paused'
 where id = 'ce000000-0000-4000-8000-00000000000c';
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"00000000-0000-4000-8000-0000000000fd","role":"authenticated"}';

select is(pg_temp.probe_phase(), 'paused', 'paused:');
select ok(not pg_temp.probe_served(), '  ... and a paused one is not served');

-- ARCHIVED, which is the new one and the reason ads_for was touched at all. A campaign that is
-- approved, inside its dates, with an approved active creative -- everything the old serving rule
-- asked for -- and archived.
reset role;
update public.ad_campaigns
   set status = 'approved', starts_on = current_date - 1, ends_on = null, archived_at = now()
 where id = 'ce000000-0000-4000-8000-00000000000c';
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"00000000-0000-4000-8000-0000000000fd","role":"authenticated"}';

select is(pg_temp.probe_phase(), 'archived', 'archived:');
select ok(not pg_temp.probe_served(),
  '  ... and an archived campaign stops serving even though every other condition still holds');

-- Back to active, as the control for all five refusals above: without this the whole section would
-- pass against a database where ads_for() had simply stopped returning anything.
reset role;
update public.ad_campaigns set archived_at = null
 where id = 'ce000000-0000-4000-8000-00000000000c';
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"00000000-0000-4000-8000-0000000000fd","role":"authenticated"}';

select is(pg_temp.probe_phase(), 'active', 'and back to active:');
select ok(pg_temp.probe_served(), '  ... served again, which is what makes the five refusals mean something');

reset role;

-- ---------------------------------------------------------------------------
-- 6. The admin list
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"00000000-0000-4000-8000-0000000000fd","role":"authenticated"}';

select throws_ok(
  $$select public.admin_campaigns()$$,
  '42501',
  null,
  'a member cannot read the campaign list');

reset role;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.an_admin(), 'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;

select is(public.admin_campaigns() ->> 'ok', 'true', 'an admin can');

select ok(
  (select (x ->> 'phase') is not null
     from jsonb_array_elements(public.admin_campaigns() -> 'campaigns') x
    where x ->> 'name' = 'Phase probe'),
  'and every row carries its phase');

-- Section 14: the number an admin needs BEFORE publishing is on the list, not buried on a detail
-- screen, because "is this aimed at anybody at all" is the decision being made on this page.
select ok(
  (select (x ->> 'audience')::int >= 0
     from jsonb_array_elements(public.admin_campaigns() -> 'campaigns') x
    where x ->> 'name' = 'Phase probe'),
  'and its estimated audience');

select ok(
  (select jsonb_array_length(x -> 'targets') = 2
     from jsonb_array_elements(public.admin_campaigns(null, true) -> 'campaigns') x
    where x ->> 'name' = 'Next month'),
  'and its targeting as a list of places rather than a string to parse');

-- Archived rows are out of the working list unless asked for. Both directions, because a filter that
-- excludes everything would pass the first half on its own.
reset role;
update public.ad_campaigns set archived_at = now()
 where id = 'cd000000-0000-4000-8000-00000000000c';

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.an_admin(), 'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;

select ok(
  not exists (
    select 1 from jsonb_array_elements(public.admin_campaigns() -> 'campaigns') x
     where x ->> 'name' = 'Ran last month'),
  'an archived campaign is out of the default list');

select ok(
  exists (
    select 1 from jsonb_array_elements(public.admin_campaigns(null, true) -> 'campaigns') x
     where x ->> 'name' = 'Ran last month'),
  'and back when they are asked for');

select ok(
  (select count(*) from jsonb_array_elements(public.admin_campaigns('active') -> 'campaigns')) >= 1,
  'and the list can be filtered to one phase');

select ok(
  not exists (
    select 1 from jsonb_array_elements(public.admin_campaigns('expired') -> 'campaigns') x
     where x ->> 'phase' <> 'expired'),
  'and a filtered list contains nothing from another phase');

reset role;

select * from finish();
rollback;
