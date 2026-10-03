-- Winch Up :: announcements, and who they reach
--
-- Run with:  supabase test db
--
-- Section 1 of the owner's spec. Two properties carry most of the weight here:
--
--   TARGETING FILTERS AN ANNOUNCEMENT, unlike an event. The asymmetry is argued in
--   20261003001300 -- an announcement is pushed at somebody who did not ask for it and there is no
--   directory of them to browse -- and both halves are asserted, because a filter that hides
--   everything passes every "does not see it" test on its own.
--
--   A DRAFT IS NOBODY'S BUSINESS. There is no table access, so a member cannot read unfinished words
--   about a gate closure that has not been confirmed.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

create or replace function pg_temp.an_admin() returns uuid language sql stable as $$
  select user_id from public.user_roles where role = 'admin' order by user_id limit 1;
$$;

create or replace function pg_temp.a_member() returns uuid language sql stable as $$
  select p.user_id from public.profiles p
   where p.suspended_at is null
     and exists (select 1 from public.user_roles r
                  where r.user_id = p.user_id and r.role = 'member')
     and not exists (select 1 from public.user_roles r
                      where r.user_id = p.user_id and r.role in ('admin', 'moderator'))
   order by p.user_id limit 1;
$$;

select isnt(pg_temp.an_admin(), null, 'the seed has an admin');
select isnt(pg_temp.a_member(), null, 'and an ordinary member');

-- The member is in Cypress for the whole of this suite.
update public.profiles
   set city = 'Cypress', state = 'TX', postal_code = '77429',
       postal_center = extensions.st_setsrid(extensions.st_point(-95.6972, 29.9691), 4326)::extensions.geography
 where user_id = pg_temp.a_member();

-- ---------------------------------------------------------------------------
-- 1. Nobody reads the tables
-- ---------------------------------------------------------------------------

select ok(not has_table_privilege('authenticated', 'announcements', 'SELECT'),
  'a member has no direct read on announcements, so a draft is unreachable');
select ok(not has_table_privilege('authenticated', 'announcements', 'INSERT'),
  'and cannot write one');
select ok(not has_table_privilege('authenticated', 'announcement_dismissals', 'SELECT'),
  'nor read who dismissed what');
select ok(
  (select relrowsecurity from pg_class where relname = 'announcements')
  and (select relrowsecurity from pg_class where relname = 'announcement_dismissals'),
  'and RLS is on both, so a future grant cannot quietly open them');

-- ---------------------------------------------------------------------------
-- 2. Only an admin writes one
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.a_member(), 'role', 'authenticated')::text, true);
set local role authenticated;

select throws_ok(
  $$select public.admin_save_announcement(jsonb_build_object('title','Mine','body','Hello'))$$,
  '42501',
  null,
  'a member cannot write an announcement to the whole membership');

select throws_ok(
  $$select public.admin_announcements()$$,
  '42501',
  null,
  'nor read the admin list');

reset role;

-- ---------------------------------------------------------------------------
-- 3. An admin writes one, untargeted
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.an_admin(), 'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;

select is(
  public.admin_save_announcement(jsonb_build_object(
    'title', 'App maintenance Sunday',
    'body', 'The app will be slow for about an hour on Sunday morning.',
    'status', 'published')) ->> 'ok',
  'true',
  'an admin publishes an untargeted announcement');

select is(
  public.admin_save_announcement(jsonb_build_object(
    'title', 'Unfinished thought',
    'body', 'Still checking whether the gate is actually locked.')) ->> 'ok',
  'true',
  'and saves a draft -- the default status, so forgetting the field cannot publish something');

reset role;

create temp table ann as select id, title, status::text as status from public.announcements;
grant select on ann to public;

select is(
  (select status from ann where title = 'Unfinished thought'),
  'draft',
  'which really is a draft');

-- ---------------------------------------------------------------------------
-- 4. What the member sees
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.a_member(), 'role', 'authenticated')::text, true);
set local role authenticated;

select ok(
  exists (select 1 from jsonb_array_elements(public.my_announcements() -> 'announcements') x
           where x ->> 'title' = 'App maintenance Sunday'),
  'the published announcement reaches them');

select ok(
  not exists (select 1 from jsonb_array_elements(public.my_announcements() -> 'announcements') x
               where x ->> 'title' = 'Unfinished thought'),
  'and the draft does not -- somebody is still checking whether that gate is locked');

reset role;

-- ---------------------------------------------------------------------------
-- 5. TARGETING FILTERS, AND BOTH DIRECTIONS ARE ASSERTED
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.an_admin(), 'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;

select is(
  public.admin_save_announcement(jsonb_build_object(
    'title', 'Gate locked at the pits',
    'body', 'The north gate is chained. Do not drive out expecting to get in.',
    'status', 'published',
    'targets', jsonb_build_array(
      jsonb_build_object('kind', 'postal_code', 'postal_code', '77429')))) ->> 'ok',
  'true',
  'an admin publishes one aimed at a single ZIP');

select is(
  public.admin_save_announcement(jsonb_build_object(
    'title', 'Dallas meet moved',
    'body', 'The Dallas meet has moved to the other car park.',
    'status', 'published',
    'targets', jsonb_build_array(
      jsonb_build_object('kind', 'postal_code', 'postal_code', '75201')))) ->> 'ok',
  'true',
  'and another aimed somewhere else entirely');

reset role;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.a_member(), 'role', 'authenticated')::text, true);
set local role authenticated;

select ok(
  exists (select 1 from jsonb_array_elements(public.my_announcements() -> 'announcements') x
           where x ->> 'title' = 'Gate locked at the pits'),
  'the member in 77429 gets the one about their own gate');

select ok(
  not exists (select 1 from jsonb_array_elements(public.my_announcements() -> 'announcements') x
               where x ->> 'title' = 'Dallas meet moved'),
  'and NOT the one about a car park four hundred miles away');

select ok(
  exists (select 1 from jsonb_array_elements(public.my_announcements() -> 'announcements') x
           where x ->> 'title' = 'App maintenance Sunday'),
  'while an untargeted one still reaches everybody -- the control proving the filter is a filter');

reset role;

-- A member with no stated area. For an advert, unknown is a miss; for an announcement it is the same
-- rule, and the cost is bounded because untargeted announcements -- which is what anything genuinely
-- for everybody is -- still arrive.
update public.profiles
   set city = null, state = null, postal_code = null, postal_center = null
 where user_id = pg_temp.a_member();

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.a_member(), 'role', 'authenticated')::text, true);
set local role authenticated;

select ok(
  not exists (select 1 from jsonb_array_elements(public.my_announcements() -> 'announcements') x
               where x ->> 'title' = 'Gate locked at the pits'),
  'a member who has not said where they are does not get a targeted announcement');

select ok(
  exists (select 1 from jsonb_array_elements(public.my_announcements() -> 'announcements') x
           where x ->> 'title' = 'App maintenance Sunday'),
  'but still gets everything meant for everybody');

reset role;

-- Put the shared demo member back where this suite found them.
update public.profiles
   set city = 'Cypress', state = 'TX', postal_code = '77429',
       postal_center = extensions.st_setsrid(extensions.st_point(-95.6972, 29.9691), 4326)::extensions.geography
 where user_id = pg_temp.a_member();

-- ---------------------------------------------------------------------------
-- 6. The time window
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.an_admin(), 'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;

select is(
  public.admin_save_announcement(jsonb_build_object(
    'title', 'Starts next week', 'body', 'Not yet.', 'status', 'published',
    'starts_at', (now() + interval '7 days')::text)) ->> 'ok',
  'true', 'an announcement can be scheduled');

select is(
  public.admin_save_announcement(jsonb_build_object(
    'title', 'Finished last week', 'body', 'Over.', 'status', 'published',
    'ends_at', (now() - interval '7 days')::text)) ->> 'ok',
  'true', 'and can have an end date in the past');

select is(
  public.admin_save_announcement(jsonb_build_object(
    'title', 'Backwards', 'body', 'No.', 'status', 'published',
    'starts_at', (now() + interval '7 days')::text,
    'ends_at', (now() + interval '1 day')::text)) ->> 'error',
  'bad_window',
  'while a window that ends before it starts is refused by name');

reset role;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.a_member(), 'role', 'authenticated')::text, true);
set local role authenticated;

select ok(
  not exists (select 1 from jsonb_array_elements(public.my_announcements(50) -> 'announcements') x
               where x ->> 'title' = 'Starts next week'),
  'one that has not started is not shown');

select ok(
  not exists (select 1 from jsonb_array_elements(public.my_announcements(50) -> 'announcements') x
               where x ->> 'title' = 'Finished last week'),
  'nor one that has finished');

reset role;

-- ---------------------------------------------------------------------------
-- 7. Dismissal
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.a_member(), 'role', 'authenticated')::text, true);
set local role authenticated;

create or replace function pg_temp.sees_maintenance() returns boolean language sql stable as $$
  select exists (select 1 from jsonb_array_elements(public.my_announcements(50) -> 'announcements') x
                  where x ->> 'title' = 'App maintenance Sunday');
$$;

select ok(pg_temp.sees_maintenance(), 'before dismissing, the member sees it');

select is(
  public.dismiss_announcement((select id from ann where title = 'App maintenance Sunday')) ->> 'ok',
  'true', 'they close it');

select ok(not pg_temp.sees_maintenance(), 'and it is gone');

-- Idempotent: this is exactly the kind of button that gets double-tapped on one bar of signal.
select is(
  public.dismiss_announcement((select id from ann where title = 'App maintenance Sunday')) ->> 'ok',
  'true', 'closing it twice is not an error');

-- A draft id tells a caller nothing, which is also how it stays unannounced.
select is(
  public.dismiss_announcement((select id from ann where title = 'Unfinished thought')) ->> 'error',
  'not_found',
  'and a draft cannot be dismissed, so its id is not confirmed to exist');

reset role;

-- One member closing it does not close it for anybody else.
select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.an_admin(), 'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;

select ok(
  exists (select 1 from jsonb_array_elements(public.my_announcements(50) -> 'announcements') x
           where x ->> 'title' = 'App maintenance Sunday'),
  'another member still sees it -- dismissal is per person, not a delete');

select is(
  (select (x ->> 'dismissed_count')::int
     from jsonb_array_elements(public.admin_announcements() -> 'announcements') x
    where x ->> 'title' = 'App maintenance Sunday'),
  1,
  'and the admin list counts the dismissal, which is the only feedback this feature has');

-- Section 14's number.
select ok(
  (select (x ->> 'audience')::int >= 0
     from jsonb_array_elements(public.admin_announcements() -> 'announcements') x
    where x ->> 'title' = 'Gate locked at the pits'),
  'every row carries its estimated audience, before anybody publishes');

select ok(
  (select jsonb_array_length(x -> 'targets') = 1
     from jsonb_array_elements(public.admin_announcements() -> 'announcements') x
    where x ->> 'title' = 'Gate locked at the pits'),
  'and its targeting as places rather than a string to parse');

reset role;

-- ---------------------------------------------------------------------------
-- 8. Bad input, by name
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.an_admin(), 'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;

select is(
  public.admin_save_announcement(jsonb_build_object(
    'title', 'Bad link', 'body', 'Body', 'link_url', 'javascript:alert(1)')) ->> 'error',
  'bad_url',
  'javascript: in a link is refused');

select is(
  public.admin_save_announcement(jsonb_build_object(
    'title', 'Label only', 'body', 'Body', 'link_label', 'Read more')) ->> 'error',
  'label_without_link',
  'and a button label with nothing behind it, which would render a control that does nothing');

select is(
  public.admin_save_announcement(jsonb_build_object('title', 'x', 'body', 'Body')) ->> 'error',
  'bad_title',
  'and a one-character title');

-- A LINK IS ALLOWED HERE, unlike in community text, because an admin wrote it. The control for the
-- refusals above.
select is(
  public.admin_save_announcement(jsonb_build_object(
    'title', 'Sponsor week', 'body', 'Our sponsor is running an offer.',
    'category', 'marketing', 'status', 'published',
    'link_url', 'https://example.invalid/offer', 'link_label', 'See the offer')) ->> 'ok',
  'true',
  'while a real https link with a label is accepted');

reset role;

-- ---------------------------------------------------------------------------
-- 9. The category is recorded even though nothing sends anything yet
-- ---------------------------------------------------------------------------
--
-- Nothing in this phase notifies. The column exists from the first row so that the day notifications
-- are wired, nobody has to guess retrospectively which of a hundred announcements somebody had
-- consented to receive. `notify_marketing` is the only consent flag in this app that ships false.

select is(
  (select category::text from public.announcements where title = 'Sponsor week'),
  'marketing',
  'a marketing announcement says so on the row');

select is(
  (select category::text from public.announcements where title = 'Gate locked at the pits'),
  'operational',
  'and a gate closure defaults to operational -- the safe direction for a field somebody forgets');

-- ---------------------------------------------------------------------------
-- 10. Deleting one takes its targeting with it
-- ---------------------------------------------------------------------------

-- READ FROM THE LIVE TABLE, NOT FROM `ann`.
--
-- `ann` is a snapshot taken in section 3, before this announcement was created, so looking its id up
-- there returns NULL -- and then the "after" assertion compares 0 to 0 and passes while proving
-- absolutely nothing about the trigger. The first assertion failing is the only reason that was
-- noticed: a sweep test whose subject does not exist is green in exactly the same way a working one is.
create temp table gate as
  select id from public.announcements where title = 'Gate locked at the pits';
grant select on gate to public;

select is((select count(*)::int from gate), 1,
  'the announcement this section is about actually exists');

select is(
  (select count(*)::int from public.target_locations
    where scope = 'announcement' and target_id = (select id from gate)),
  1,
  'and has its targeting row');

delete from public.announcements where id = (select id from gate);

select is(
  (select count(*)::int from public.target_locations
    where scope = 'announcement' and target_id = (select id from gate)),
  0,
  'deleting it sweeps the targeting, like campaigns and events');

select * from finish();
rollback;
