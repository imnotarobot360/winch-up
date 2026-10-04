-- Winch Up :: what an event may say, and who may say it
--
-- Run with:  supabase test db
--
-- Section 2 of the owner's spec added an organiser, a registration link, a website and a phone number
-- to events. `create_event` is open to every member and takes `status` from its payload, so those
-- fields on an unguarded row would turn "post an event" into "put my towing company's number in front
-- of the whole membership". The CHECK that stops it is the most important thing in this file, and it
-- is asserted from both ends: a member cannot write them, and an admin can.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- The demo seed's admin and an ordinary member. Read rather than assumed, so this suite fails with a
-- sentence about the seed instead of a confusing permission error.
select ok(
  (select count(*) from public.user_roles where role = 'admin') > 0,
  'the seed has an admin to act as');

create or replace function pg_temp.an_admin() returns uuid language sql stable as $$
  select user_id from public.user_roles where role = 'admin' order by user_id limit 1;
$$;

-- Somebody whose role is 'member' and nothing else. NOT "has no row in user_roles": every seeded
-- account has one, so that spelling returned null and the suite died on a null uuid two sections
-- later with an error about a regex.
create or replace function pg_temp.a_member() returns uuid language sql stable as $$
  select p.user_id from public.profiles p
   where p.suspended_at is null
     and exists (select 1 from public.user_roles r
                  where r.user_id = p.user_id and r.role = 'member')
     and not exists (select 1 from public.user_roles r
                      where r.user_id = p.user_id and r.role in ('admin', 'moderator'))
   order by p.user_id limit 1;
$$;

select isnt(pg_temp.a_member(), null, 'and an ordinary member who is not an admin or a moderator');

-- ---------------------------------------------------------------------------
-- 1. The promotional columns are unreachable without is_official
-- ---------------------------------------------------------------------------
--
-- Asserted against the CONSTRAINT rather than against create_event's behaviour. create_event not
-- reading those keys is true today and is one careless edit from being false; the constraint is what
-- makes it impossible, and a future RPC that forgets the rule fails here instead of shipping.

select throws_ok(
  $$insert into public.events (title, starts_at, status, organizer_name)
    values ('Member event', now() + interval '2 days', 'published', 'Totally Legit Towing')$$,
  '23514',
  null,
  'an organiser name on a row that is not official is REFUSED');

select throws_ok(
  $$insert into public.events (title, starts_at, status, contact_phone)
    values ('Member event', now() + interval '2 days', 'published', '+15551234567')$$,
  '23514',
  null,
  'and a phone number');

select throws_ok(
  $$insert into public.events (title, starts_at, status, website_url)
    values ('Member event', now() + interval '2 days', 'published', 'https://example.invalid')$$,
  '23514',
  null,
  'and a website');

select throws_ok(
  $$insert into public.events (title, starts_at, status, registration_url)
    values ('Member event', now() + interval '2 days', 'published', 'https://example.invalid/signup')$$,
  '23514',
  null,
  'and a registration link');

-- THE CONTROL. Every refusal above would also pass if `events` had simply stopped accepting inserts.
insert into public.events (id, title, starts_at, status, event_type)
values ('11110000-0000-4000-8000-00000000001e', 'Saturday run at the pits',
        now() + interval '2 days', 'published', 'trail_ride');

select is(
  (select title from public.events where id = '11110000-0000-4000-8000-00000000001e'),
  'Saturday run at the pits',
  'while a plain member event with no promotional fields is accepted');

-- And the same values ARE allowed once the row says it came through the admin surface, which is what
-- makes this a gate rather than a ban on the feature the spec asked for.
insert into public.events (id, title, starts_at, status, is_official,
                           organizer_name, website_url, registration_url, contact_phone, contact_email)
values ('11110000-0000-4000-8000-00000000002e', 'Recovery clinic',
        now() + interval '9 days', 'published', true,
        'Texas Off-Road Recovery', 'https://example.invalid',
        'https://example.invalid/signup', '+15551234567', 'clinic@example.invalid');

select is(
  (select organizer_name from public.events where id = '11110000-0000-4000-8000-00000000002e'),
  'Texas Off-Road Recovery',
  'and an official event may carry all of them');

-- ---------------------------------------------------------------------------
-- 2. The title gap that was open until today
-- ---------------------------------------------------------------------------
--
-- description and meet_note have called contains_contact_info() since phase 12. The title -- the one
-- field every member reads first -- only ever checked its length.

select throws_ok(
  $$insert into public.events (title, starts_at, status)
    values ('Tow truck call 555-123-4567', now() + interval '2 days', 'published')$$,
  '23514',
  null,
  'a phone number in an event TITLE is refused');

select throws_ok(
  $$insert into public.events (title, starts_at, status, city)
    values ('Meetup', now() + interval '2 days', 'published', 'Houston https://spam.invalid')$$,
  '23514',
  null,
  'and a link in the city');

-- ---------------------------------------------------------------------------
-- 3. Who may use the admin writer
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"00000000-0000-4000-8000-0000000000ff","role":"authenticated"}';

select throws_ok(
  $$select public.admin_save_event(jsonb_build_object('title','Sneaky','starts_at',now()::text))$$,
  '42501',
  null,
  'a signed-in stranger cannot create an official event');

reset role;

-- An ordinary member, who is a real account rather than a made-up uuid -- "it refused a uuid that
-- does not exist" is a weaker statement than "it refused a member".
select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.a_member(), 'role', 'authenticated')::text, true);
set local role authenticated;

select throws_ok(
  $$select public.admin_save_event(jsonb_build_object('title','Sneaky','starts_at',now()::text))$$,
  '42501',
  null,
  'nor can an ordinary member');

reset role;

-- ---------------------------------------------------------------------------
-- 4. The admin writer, and what it does with targeting
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.an_admin(), 'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;

select is(
  public.admin_save_event(jsonb_build_object(
    'title', 'Winter recovery clinic',
    'starts_at', (now() + interval '20 days')::text,
    'event_type', 'training',
    'city', 'Cypress', 'state', 'tx', 'postal_code', '77429',
    'status', 'published',
    'organizer_name', 'Houston Area Off-Road Recovery',
    'registration_url', 'https://example.invalid/clinic',
    'targets', jsonb_build_array(
      jsonb_build_object('kind', 'postal_code', 'postal_code', '77429'),
      jsonb_build_object('kind', 'postal_code', 'postal_code', '77494'))
  )) ->> 'ok',
  'true',
  'an admin creates a targeted official event');

reset role;

create temp table ev as
  select id from public.events where title = 'Winter recovery clinic';
grant select on ev to public;

select ok(
  (select is_official from public.events where id = (select id from ev)),
  'is_official is set by the function, never taken from the payload');

select is(
  (select state from public.events where id = (select id from ev)),
  'TX',
  'the state is upper-cased on the way in, so a typist is not refused for being right');

select is(
  (select count(*)::int from public.target_locations
    where scope = 'event' and target_id = (select id from ev)),
  2,
  'and its two ZIP targets are stored as rows rather than a comma-separated string');

-- TARGETS ABSENT AND TARGETS EMPTY ARE DIFFERENT INTENTIONS.
select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.an_admin(), 'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;

select is(
  public.admin_save_event(jsonb_build_object(
    'id', (select id from ev), 'title', 'Winter recovery clinic',
    'starts_at', (now() + interval '21 days')::text, 'status', 'published')) ->> 'ok',
  'true',
  'an edit that does not mention targets is accepted');

reset role;

select is(
  (select count(*)::int from public.target_locations
    where scope = 'event' and target_id = (select id from ev)),
  2,
  'and leaves the targeting alone -- a status change must not widen an event to everybody');

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.an_admin(), 'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;

select is(
  public.admin_save_event(jsonb_build_object(
    'id', (select id from ev), 'title', 'Winter recovery clinic',
    'starts_at', (now() + interval '21 days')::text, 'status', 'published',
    'targets', '[]'::jsonb)) ->> 'ok',
  'true',
  'while an empty array is accepted too');

reset role;

select is(
  (select count(*)::int from public.target_locations
    where scope = 'event' and target_id = (select id from ev)),
  0,
  'and means this event is for everybody now');

-- ---------------------------------------------------------------------------
-- 5. Bad input comes back as a sentence, not an error code
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.an_admin(), 'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;

select is(
  public.admin_save_event(jsonb_build_object(
    'title', 'Bad link', 'starts_at', (now() + interval '3 days')::text,
    'website_url', 'javascript:alert(1)')) ->> 'error',
  'bad_url',
  'javascript: in a website is refused, by name');

select is(
  public.admin_save_event(jsonb_build_object(
    'title', 'Bad phone', 'starts_at', (now() + interval '3 days')::text,
    'contact_phone', '555-1234')) ->> 'error',
  'bad_contact',
  'and a phone that is not E.164');

select is(
  public.admin_save_event(jsonb_build_object(
    'title', 'Bad zip', 'starts_at', (now() + interval '3 days')::text,
    'postal_code', '774')) ->> 'error',
  'bad_postal_code',
  'and a three-digit ZIP, rather than storing something unmatchable');

select is(
  public.admin_save_event(jsonb_build_object('title', 'No date')) ->> 'error',
  'no_start',
  'an event with no start is refused');

reset role;

-- ---------------------------------------------------------------------------
-- 6. events_upcoming still returns everything it used to
-- ---------------------------------------------------------------------------
--
-- This function was REPLACED by a create-or-replace with a matching signature, which is how the real
-- events_upcoming was once silently clobbered -- caught then only by data_model_test failing on
-- going_count. Each field the old version returned is named here so the next replacement cannot drop
-- one quietly.

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.a_member(), 'role', 'authenticated')::text, true);
set local role authenticated;

select ok(
  (public.events_upcoming(50) -> 'events' -> 0) ? 'going_count',
  'going_count survives the replacement');

select ok(
  (public.events_upcoming(50) -> 'events' -> 0) ? 'my_response',
  'and my_response');

select ok(
  (public.events_upcoming(50) -> 'events' -> 0) ? 'group_name'
  and (public.events_upcoming(50) -> 'events' -> 0) ? 'trail_slug',
  'and the group and trail columns');

select ok(
  (public.events_upcoming(50) -> 'events' -> 0) ? 'event_type'
  and (public.events_upcoming(50) -> 'events' -> 0) ? 'matches_my_area',
  'and the new fields are there beside them');

-- The image fields are GONE, by the owner's decision on 2026-10-03. 20261003000600 built the
-- columns and nothing else -- no uploader, no renderer -- so they were schema nothing could fill,
-- which reads to the next person as "events have pictures". Asserted as an absence because the
-- three functions that used to SELECT them were recreated without them, and a dropped column still
-- named in a function body is an error on the next call that nothing else here would catch.
select ok(
  not ((public.events_upcoming(50) -> 'events' -> 0) ? 'cover_image_path')
  and not ((public.events_upcoming(50) -> 'events' -> 0) ? 'image_paths'),
  'and the image fields are not, because the columns were dropped');

reset role;

-- ---------------------------------------------------------------------------
-- 7. TARGETING DOES NOT HIDE AN EVENT
-- ---------------------------------------------------------------------------
--
-- The judgement recorded in 20261003000700, asserted so that making it hide events later is a
-- deliberate act that breaks a test with a reason attached. For an advert, "does not match" means do
-- not show it. For an event it would mean a member cannot see their own community's events, and
-- replacing a group where everybody sees every post is what this product is for.

insert into public.target_locations (scope, target_id, kind, postal_code)
values ('event', '11110000-0000-4000-8000-00000000002e', 'postal_code', '77429');

-- A member a long way from that ZIP.
update public.profiles
   set city = 'Dallas', state = 'TX', postal_code = '75201',
       postal_center = extensions.st_setsrid(extensions.st_point(-96.7970, 32.7831), 4326)::extensions.geography
 where user_id = pg_temp.a_member();

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.a_member(), 'role', 'authenticated')::text, true);
set local role authenticated;

select ok(
  exists (
    select 1 from jsonb_array_elements(public.events_upcoming(100) -> 'events') x
     where x ->> 'title' = 'Recovery clinic'),
  'a member outside the targeting still SEES the event -- it is never hidden from the directory');

select ok(
  not (select (x ->> 'matches_my_area')::boolean
         from jsonb_array_elements(public.events_upcoming(100) -> 'events') x
        where x ->> 'title' = 'Recovery clinic'),
  'but it is marked as not near them, which is what notifications key on');

select ok(
  (select (x ->> 'matches_my_area')::boolean
     from jsonb_array_elements(public.events_upcoming(100) -> 'events') x
    where x ->> 'title' = 'Saturday run at the pits'),
  'while an untargeted event matches everybody -- the control that proves the flag is computed');

reset role;

-- ---------------------------------------------------------------------------
-- 8. Deleting an event takes its targeting with it
-- ---------------------------------------------------------------------------

delete from public.events where id = '11110000-0000-4000-8000-00000000002e';

select is(
  (select count(*)::int from public.target_locations
    where scope = 'event' and target_id = '11110000-0000-4000-8000-00000000002e'),
  0,
  'the sweep trigger reaches event targeting too, not only campaigns');

-- ---------------------------------------------------------------------------
-- 9. One event, on its own page
-- ---------------------------------------------------------------------------
--
-- event_detail() exists so that record_event_view() has something that can call it. Three things
-- separate it from events_upcoming(), and each is asserted: it reads ONE event, it is NOT limited to
-- upcoming ones, and a draft is indistinguishable from a deleted event.

insert into public.events (id, title, starts_at, status, event_type, city, state)
values
  ('11140000-0000-4000-8000-00000000001e', 'Detail page event',
   now() + interval '5 days', 'published', 'meetup', 'Cypress', 'TX'),
  -- Finished a week ago. events_upcoming() drops anything more than six hours past, so this row is
  -- the one that proves the detail page is not just a filtered list.
  ('11150000-0000-4000-8000-00000000001e', 'Last weekend run',
   now() - interval '7 days', 'published', 'trail_ride', 'Katy', 'TX'),
  ('11160000-0000-4000-8000-00000000001e', 'Unfinished event',
   now() + interval '5 days', 'draft', 'meetup', 'Cypress', 'TX');

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.a_member(), 'role', 'authenticated')::text, true);
set local role authenticated;

select is(
  public.event_detail('11140000-0000-4000-8000-00000000001e') -> 'event' ->> 'title',
  'Detail page event',
  'a published event opens');

select ok(
  (public.event_detail('11140000-0000-4000-8000-00000000001e') -> 'event') ? 'going_count'
  and (public.event_detail('11140000-0000-4000-8000-00000000001e') -> 'event') ? 'matches_my_area'
  and (public.event_detail('11140000-0000-4000-8000-00000000001e') -> 'event') ? 'organizer_name',
  'carrying the fields the page renders');

-- THE ONE THAT MATTERS FOR A LINK SOMEBODY WAS SENT.
select is(
  public.event_detail('11150000-0000-4000-8000-00000000001e') -> 'event' ->> 'title',
  'Last weekend run',
  'an event that FINISHED still opens -- events_upcoming() would never return it');

select ok(
  not exists (
    select 1 from jsonb_array_elements(public.events_upcoming(100) -> 'events') x
     where x ->> 'title' = 'Last weekend run'),
  'and the list genuinely does not, which is what makes the row above a real difference');

-- A DRAFT ANSWERS LIKE A DELETED EVENT. Both not_found, so a guessed uuid cannot confirm that
-- somebody is drafting something.
select is(
  public.event_detail('11160000-0000-4000-8000-00000000001e') ->> 'error',
  'not_found',
  'a draft is not readable, even with its exact id');

select is(
  public.event_detail('99999999-0000-4000-8000-00000000009e') ->> 'error',
  'not_found',
  'and an id that never existed answers identically -- the control that makes the refusal silent');

reset role;

-- Signed out, nothing -- and the refusal is HARDER than the function's own not_signed_in branch.
-- anon has no execute grant, so the call is refused before any of the body runs. Asserted as the
-- throw it actually is rather than as the friendly error it would give a role that could call it.
set local role anon;
select throws_ok(
  $$select public.event_detail('11140000-0000-4000-8000-00000000001e')$$,
  '42501',
  null,
  'a signed-out reader cannot call it at all: events are members-only');
reset role;

select ok(
  not has_function_privilege('anon', 'public.event_detail(uuid)', 'execute'),
  'which is a missing grant rather than a check inside the function');

-- ---------------------------------------------------------------------------
-- 10. The view counter now has something that can call it
-- ---------------------------------------------------------------------------
--
-- 20261003001000 shipped record_event_view() with no caller and said so. This is the loop closing:
-- a page exists, so a view is countable, so admin_event_report stops being a column of zeros.

select is(
  public.record_event_view('11140000-0000-4000-8000-00000000001e') ->> 'ok', 'true',
  'a view of the event behind the page is counted');

select is(
  (select views from public.event_daily_stats
    where event_id = '11140000-0000-4000-8000-00000000001e'),
  1,
  'and lands');

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.an_admin(), 'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;

select ok(
  (select (x ->> 'views')::int = 1
     from jsonb_array_elements(public.admin_event_report() -> 'events') x
    where x ->> 'title' = 'Detail page event'),
  'and the admin report shows it -- the number can move now, which it could not before');

reset role;

select * from finish();
rollback;
