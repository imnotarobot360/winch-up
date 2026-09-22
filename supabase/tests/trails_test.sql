-- Winch Up :: proof that a trail listing cannot claim more than somebody checked
--
-- Run with:  supabase test db
--
-- The spec's line for this phase is "Do not assume that a trail is open or legally accessible
-- without reliable supporting information." Most of this file exists to prove that line is
-- enforced by the database rather than by whoever is filling in the form at the time.
--
-- Three properties, in order of how much they matter:
--
--   1. A row cannot assert an access status without naming its source, and cannot be published
--      without a named human having verified it. Both are CHECK constraints, so no code path,
--      admin screen or future migration can route around them.
--
--   2. Verified and user-submitted never merge. `trails` is what an admin checked;
--      `trail_conditions` is what a member saw. A condition report ages out of the page after
--      45 days rather than sitting there reading as current.
--
--   3. A moderator can hide a bad condition report and still cannot touch a trail listing.
--      Saying "this place is legal to drive on" is a different kind of claim from "this comment
--      is spam", and it belongs to the people who answer for it.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- ---------------------------------------------------------------------------
-- Fixtures: an admin, two ordinary members, one moderator.
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
)
select '00000000-0000-0000-0000-000000000000', v.id, 'authenticated', 'authenticated',
       v.email, 'x', now(), '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
from (values
  ('a1111111-0000-4000-8000-00000000000a'::uuid, 'trail-admin@example.invalid'),
  ('a2222222-0000-4000-8000-00000000000a'::uuid, 'trail-member@example.invalid'),
  ('a3333333-0000-4000-8000-00000000000a'::uuid, 'trail-other@example.invalid'),
  ('a4444444-0000-4000-8000-00000000000a'::uuid, 'trail-mod@example.invalid')
) as v(id, email);

insert into profiles (user_id, display_name)
select v.id, v.name
from (values
  ('a1111111-0000-4000-8000-00000000000a'::uuid, 'Admin'),
  ('a2222222-0000-4000-8000-00000000000a'::uuid, 'Marie'),
  ('a3333333-0000-4000-8000-00000000000a'::uuid, 'Otis'),
  ('a4444444-0000-4000-8000-00000000000a'::uuid, 'Mod')
) as v(id, name)
on conflict (user_id) do update set display_name = excluded.display_name;

insert into user_roles (user_id, role) values
  ('a1111111-0000-4000-8000-00000000000a', 'admin'),
  ('a4444444-0000-4000-8000-00000000000a', 'moderator')
on conflict do nothing;


-- ---------------------------------------------------------------------------
-- A known starting point.
--
-- This file's counts are only meaningful if the directory starts empty. Run against a
-- database somebody has been clicking around in, they were not: two posts left over from a
-- browser session made "all three posts" read four, and a `like` lookup match two rows. Rolled
-- back with everything else, so nothing here touches real data.
-- ---------------------------------------------------------------------------

delete from content_reports;
delete from trails;

-- ---------------------------------------------------------------------------
-- 1. Nothing is reachable except through the functions
-- ---------------------------------------------------------------------------

select ok(not has_table_privilege('anon', 'trails', 'SELECT'),
  'anon cannot read trails');
select ok(not has_table_privilege('authenticated', 'trails', 'SELECT'),
  'nor can a signed-in member read the table directly');
select ok(not has_table_privilege('authenticated', 'trails', 'INSERT'),
  'and certainly cannot insert one, which is how the source requirement stays enforceable');
select ok(not has_table_privilege('authenticated', 'trail_conditions', 'INSERT'),
  'condition reports go through the function, so the rate limit and contact-info check apply');

select ok(
  not has_function_privilege('anon', 'public.trail_detail(text)', 'EXECUTE'),
  'the directory is behind an account: anon cannot open a trail'
);
select ok(
  not has_function_privilege('authenticated', 'public.admin_save_trail(jsonb)', 'EXECUTE')
  = false,
  'admin_save_trail is granted to authenticated -- the gate is app.require_admin(), not the grant'
);

-- ---------------------------------------------------------------------------
-- 2. The constraints that carry the spec
--
-- These are the whole point. Each is attempted as the table owner, with RLS and every function
-- out of the way, so what is being tested is the constraint itself and nothing else.
-- ---------------------------------------------------------------------------

select throws_ok(
  $$insert into trails (slug, name, location, access)
    values ('claimed-open', 'Claimed Open',
            extensions.st_setsrid(extensions.st_point(-97.7, 30.3), 4326)::extensions.geography,
            'open_public')$$,
  '23514', null,
  'a trail cannot say it is open to the public without naming where that came from'
);

select throws_ok(
  $$insert into trails (slug, name, location, access, access_source)
    values ('blank-source', 'Blank Source',
            extensions.st_setsrid(extensions.st_point(-97.7, 30.3), 4326)::extensions.geography,
            'private_permission', '   ')$$,
  '23514', null,
  'and whitespace is not a source'
);

select lives_ok(
  $$insert into trails (slug, name, location)
    values ('unknown-access', 'Unknown Access',
            extensions.st_setsrid(extensions.st_point(-97.7, 30.3), 4326)::extensions.geography)$$,
  'but a trail may say it does not know, which is the default and needs no source'
);

select throws_ok(
  $$insert into trails (slug, name, location, status)
    values ('self-published', 'Self Published',
            extensions.st_setsrid(extensions.st_point(-97.7, 30.3), 4326)::extensions.geography,
            'published')$$,
  '23514', null,
  'nothing is published without a named human having verified it'
);

select throws_ok(
  $$insert into trails (slug, name, location, difficulty)
    values ('rated-by-nobody', 'Rated By Nobody',
            extensions.st_setsrid(extensions.st_point(-97.7, 30.3), 4326)::extensions.geography,
            'extreme')$$,
  '23514', null,
  'a difficulty rating has to say whose opinion it is'
);

-- ---------------------------------------------------------------------------
-- 3. Two published trails and one pending one, made the way an admin makes them
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"a1111111-0000-4000-8000-00000000000a","role":"authenticated","aal":"aal2"}';

select is(
  public.admin_save_trail(jsonb_build_object(
    'slug', 'river-crossing', 'name', 'River Crossing', 'region', 'Travis County',
    'lng', -97.74, 'lat', 30.27,
    'access', 'open_public', 'access_source', 'County road, checked on the county GIS map',
    'difficulty', 'moderate', 'difficulty_source', 'Rated by the group admins',
    'summary', 'Shallow crossing, soft on the far bank.',
    'min_drivetrain', '4wd',
    'recommended_equipment', jsonb_build_array('traction_boards', 'winch'),
    'status', 'published')) ->> 'ok',
  'true',
  'an admin publishes a trail with its source'
);

select is(
  public.admin_save_trail(jsonb_build_object(
    'slug', 'no-source', 'name', 'No Source', 'lng', -97.7, 'lat', 30.3,
    'access', 'open_public', 'status', 'published')) ->> 'error',
  'access_source_required',
  'and is told in words when the source is missing, rather than being shown a 23514'
);

select is(
  public.admin_save_trail(jsonb_build_object(
    'slug', 'gate-road', 'name', 'Gate Road', 'region', 'Bastrop County',
    'lng', -97.31, 'lat', 30.11,
    'access', 'private_permission',
    'access_source', 'Owner gave the group permission by phone, 2026-09-01',
    'status', 'published')) ->> 'ok',
  'true',
  'a private-permission trail is allowed, because it says so and says who said so'
);

select is(
  public.admin_save_trail(jsonb_build_object(
    'slug', 'somebody-suggested', 'name', 'Somebody Suggested',
    'lng', -96.9, 'lat', 30.6, 'status', 'pending')) ->> 'ok',
  'true',
  'a suggestion can sit in the queue with access unknown'
);

reset role;
create temp table tids as select slug, id from trails;
grant select on tids to public;

set local role authenticated;

-- ---------------------------------------------------------------------------
-- 4. Only published trails exist as far as members are concerned
-- ---------------------------------------------------------------------------

set local request.jwt.claims =
  '{"sub":"a2222222-0000-4000-8000-00000000000a","role":"authenticated"}';

select is(
  jsonb_array_length(public.trails_search() -> 'trails'), 2,
  'search shows the two published trails and not the pending one'
);

select ok(
  not (public.trails_search() -> 'trails' @> '[{"slug":"somebody-suggested"}]'::jsonb),
  'specifically: a pending suggestion is not a search result'
);

select is(
  public.trail_detail('somebody-suggested') ->> 'error', 'not_found',
  'and its page does not open, so a guessed URL is not a way in'
);

select ok(
  public.trails_search() -> 'trails'
    @> '[{"slug":"river-crossing","access":"open_public",
          "access_source":"County road, checked on the county GIS map"}]'::jsonb,
  'every search result carries its access source, not just its access status'
);

select is(
  public.trails_search('bastrop') -> 'trails' -> 0 ->> 'slug', 'gate-road',
  'search matches on region as well as name'
);

select is(
  jsonb_array_length(public.trails_search(null, 'private_permission') -> 'trails'), 1,
  'and filters by access, which is how somebody avoids driving to a locked gate'
);

-- Distance, from a point a few miles from the river crossing.
select ok(
  (public.trails_search(null, null, null, false, -97.80, 30.27) -> 'trails' -> 0 ->> 'distance_miles')::numeric
    between 3 and 5,
  'searching from a point returns miles, nearest first'
);

-- ---------------------------------------------------------------------------
-- 5. Condition reports: user-submitted, dated, and rate limited
-- ---------------------------------------------------------------------------

select is(
  public.report_trail_condition(
    (select id from tids where slug = 'river-crossing'), 'flooded',
    'Water over the hood on the far bank, turned around.') ->> 'ok',
  'true',
  'a member reports what they saw'
);

select is(
  public.report_trail_condition(
    (select id from tids where slug = 'river-crossing'), 'good') ->> 'error',
  'already_reported',
  'and cannot report the same trail again within the hour'
);

select is(
  public.report_trail_condition(
    (select id from tids where slug = 'gate-road'), 'access_blocked',
    'call me at 512-555-0134 for the gate code') ->> 'error',
  'contact_info',
  'a condition note carrying a phone number is refused'
);

select is(
  public.report_trail_condition(
    (select id from tids where slug = 'gate-road'), 'sunny') ->> 'error',
  'bad_state',
  'and an invented state is refused'
);

select is(
  jsonb_array_length(public.trail_detail('river-crossing') -> 'conditions'), 1,
  'the trail page carries the report'
);

select ok(
  public.trail_detail('river-crossing') -> 'conditions' -> 0 ? 'created_at',
  'with its date, every time -- a condition report without one is a claim about today'
);

select ok(
  public.trail_detail('river-crossing') -> 'conditions' -> 0 ->> 'author_name' = 'Marie',
  'and who said it'
);

-- Aging out. A report from two months ago is not information about this weekend.
reset role;
insert into trail_conditions (trail_id, author_user_id, state, note, created_at)
values ((select id from tids where slug = 'gate-road'),
        'a3333333-0000-4000-8000-00000000000a', 'good', 'Dry and easy.',
        now() - interval '60 days');

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"a2222222-0000-4000-8000-00000000000a","role":"authenticated"}';

select is(
  jsonb_array_length(public.trail_detail('gate-road') -> 'conditions'), 0,
  'a report from sixty days ago has aged off the page rather than reading as current'
);

select is(
  (public.trail_detail('gate-road') ->> 'condition_window_days')::integer, 45,
  'and the page is told the window, so it can say how far back it is showing'
);

-- ---------------------------------------------------------------------------
-- 6. Blocking carries over from the feed
-- ---------------------------------------------------------------------------

reset role;
update trail_conditions set created_at = now()
 where trail_id = (select id from tids where slug = 'gate-road');

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"a2222222-0000-4000-8000-00000000000a","role":"authenticated"}';

select is(
  jsonb_array_length(public.trail_detail('gate-road') -> 'conditions'), 1,
  'with the date brought forward, Otis'' report is on the page'
);

select is(public.community_block('a3333333-0000-4000-8000-00000000000a', true) ->> 'ok', 'true',
  'Marie blocks Otis');

select is(
  jsonb_array_length(public.trail_detail('gate-road') -> 'conditions'), 0,
  'and somebody she blocked does not get to talk to her on a trail page either'
);

select is(public.community_block('a3333333-0000-4000-8000-00000000000a', false) ->> 'ok', 'true',
  'unblocked again for the rest of this file');

-- ---------------------------------------------------------------------------
-- 7. Saved trails
-- ---------------------------------------------------------------------------

select is(
  public.trail_save((select id from tids where slug = 'river-crossing'), true) ->> 'ok',
  'true', 'a member saves a trail');

select is(
  jsonb_array_length(public.trails_search(null, null, null, true) -> 'trails'), 1,
  'and can list only the saved ones'
);

select ok(
  (public.trail_detail('river-crossing') -> 'trail' ->> 'saved')::boolean,
  'the trail page knows it is saved, so the control renders in the right state'
);

select is(
  public.trail_save((select id from tids where slug = 'somebody-suggested'), true) ->> 'error',
  'not_found',
  'an unpublished trail cannot be saved'
);

select is(
  public.trail_save((select id from tids where slug = 'river-crossing'), false) ->> 'ok',
  'true', 'saving is a toggle');

select is(
  jsonb_array_length(public.trails_search(null, null, null, true) -> 'trails'), 0,
  'and unsaving empties the list'
);

-- ---------------------------------------------------------------------------
-- 8. Members submitting trails and corrections
-- ---------------------------------------------------------------------------

select is(
  public.submit_trail_edit(jsonb_build_object(
    'kind', 'new', 'name', 'Sand Pit Loop', 'region', 'Fayette County',
    'lng', -96.88, 'lat', 29.98,
    'body', 'Runs off the county road past the second cattle guard.')) ->> 'ok',
  'true',
  'a member can suggest a trail'
);

select is(
  public.submit_trail_edit(jsonb_build_object(
    'kind', 'new', 'body', 'There is a good spot out past the river.')) ->> 'error',
  'incomplete',
  'but not without saying where, because a trail with no location is not a suggestion'
);

select is(
  public.submit_trail_edit(jsonb_build_object(
    'kind', 'problem', 'trail_id', (select id from tids where slug = 'gate-road'),
    'body', 'New fence and a no-trespassing sign as of Saturday.')) ->> 'ok',
  'true',
  'and can report that a listing has gone wrong, which is the one that matters most'
);

select is(
  public.submit_trail_edit(jsonb_build_object(
    'kind', 'correction',
    'trail_id', (select id from tids where slug = 'somebody-suggested'),
    'body', 'anything')) ->> 'error',
  'not_found',
  'a correction to an unpublished trail answers not_found, so ids cannot be probed'
);

select is(
  public.submit_trail_edit(jsonb_build_object(
    'kind', 'problem', 'trail_id', (select id from tids where slug = 'gate-road'),
    'body', 'text me on 512-555-0134')) ->> 'error',
  'contact_info',
  'and the contact-info rule applies here too'
);

-- ---------------------------------------------------------------------------
-- 9. Who may do what
-- ---------------------------------------------------------------------------

select throws_ok(
  $$select public.admin_save_trail('{"slug":"mine","name":"Mine","lng":-97,"lat":30}'::jsonb)$$,
  '42501', null,
  'an ordinary member cannot add a trail'
);

select throws_ok(
  $$select public.admin_trail_edits('new')$$,
  '42501', null,
  'nor read the suggestions queue'
);

-- The moderator can deal with a bad condition report and nothing else.
set local request.jwt.claims =
  '{"sub":"a4444444-0000-4000-8000-00000000000a","role":"authenticated","aal":"aal2"}';

select throws_ok(
  $$select public.admin_save_trail('{"slug":"mine","name":"Mine","lng":-97,"lat":30}'::jsonb)$$,
  '42501', null,
  'a moderator cannot publish a trail: asserting a place is legal to drive on is not their call'
);

select throws_ok(
  $$select public.admin_trails(null)$$,
  '42501', null,
  'nor open the trail admin at all'
);

reset role;
create temp table cids as select state::text as state, id from trail_conditions;
grant select on cids to public;

set local role authenticated;

-- ---------------------------------------------------------------------------
-- 10. A reported condition goes to the queue the moderator already uses
-- ---------------------------------------------------------------------------

set local request.jwt.claims =
  '{"sub":"a3333333-0000-4000-8000-00000000000a","role":"authenticated"}';

select is(
  public.community_report('trail_condition',
    (select id from cids where state = 'flooded'), 'unsafe_advice') ->> 'ok',
  'true',
  'a member reports a condition report through the same control as a bad post'
);

set local request.jwt.claims =
  '{"sub":"a4444444-0000-4000-8000-00000000000a","role":"authenticated","aal":"aal2"}';

select ok(
  public.moderation_queue('new') -> 'items'
    @> '[{"target_kind":"trail_condition","trail_name":"River Crossing"}]'::jsonb,
  'and it lands in the one moderation queue, naming the trail it is on'
);

select is(
  public.moderate_content('trail_condition',
    (select id from cids where state = 'flooded'), 'hide') ->> 'ok',
  'true',
  'the moderator can hide it'
);

set local request.jwt.claims =
  '{"sub":"a2222222-0000-4000-8000-00000000000a","role":"authenticated"}';

select is(
  jsonb_array_length(public.trail_detail('river-crossing') -> 'conditions'), 0,
  'and it leaves the trail page'
);

select ok(
  (public.trail_detail('river-crossing') -> 'trail' ->> 'name') = 'River Crossing',
  'while the trail listing itself is untouched, because those are different things'
);

reset role;

select * from finish();
rollback;
