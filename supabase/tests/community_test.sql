-- Winch Up :: proof that the community feed keeps people apart when they ask it to
--
-- Run with:  supabase test db
--
-- Three things are worth proving here and the rest is detail:
--
--   1. Blocking works in BOTH directions. If either person blocked the other, neither of them
--      sees the other's posts, comments on them, or reacts to them. A one-way block leaves the
--      person who was frightened enough to use it still visible to the person they blocked.
--
--   2. A moderator can hide content and can do nothing else. They cannot list volunteers, which
--      is the screen that carries phone numbers. That separation is the entire reason the
--      moderator role exists.
--
--   3. Hidden content is gone from every surface -- the feed, the thread, the counts -- not just
--      dimmed in the one place somebody remembered to filter.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- ---------------------------------------------------------------------------
-- Fixtures: three ordinary members and one moderator.
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
)
select '00000000-0000-0000-0000-000000000000', v.id, 'authenticated', 'authenticated',
       v.email, 'x', now(), '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
from (values
  ('c1111111-0000-4000-8000-00000000000c'::uuid, 'com-amy@example.invalid'),
  ('c2222222-0000-4000-8000-00000000000c'::uuid, 'com-ben@example.invalid'),
  ('c3333333-0000-4000-8000-00000000000c'::uuid, 'com-cal@example.invalid'),
  ('c4444444-0000-4000-8000-00000000000c'::uuid, 'com-mod@example.invalid')
) as v(id, email);

insert into profiles (user_id, display_name)
select v.id, v.name
from (values
  ('c1111111-0000-4000-8000-00000000000c'::uuid, 'Amy'),
  ('c2222222-0000-4000-8000-00000000000c'::uuid, 'Ben'),
  ('c3333333-0000-4000-8000-00000000000c'::uuid, 'Cal'),
  ('c4444444-0000-4000-8000-00000000000c'::uuid, 'Mod')
) as v(id, name)
on conflict (user_id) do update set display_name = excluded.display_name;

insert into user_roles (user_id, role)
values ('c4444444-0000-4000-8000-00000000000c', 'moderator')
on conflict do nothing;


-- ---------------------------------------------------------------------------
-- A known starting point.
--
-- This file's counts are only meaningful if the feed starts empty. Run against a
-- database somebody has been clicking around in, they were not: two posts left over from a
-- browser session made "all three posts" read four, and a `like` lookup match two rows. Rolled
-- back with everything else, so nothing here touches real data.
-- ---------------------------------------------------------------------------

delete from content_reports;
delete from community_posts;

-- ---------------------------------------------------------------------------
-- 1. Nothing is reachable except through the functions
-- ---------------------------------------------------------------------------

select ok(not has_table_privilege('anon', 'community_posts', 'SELECT'),
  'anon cannot read community_posts');
select ok(not has_table_privilege('authenticated', 'community_posts', 'SELECT'),
  'a signed-in member cannot read community_posts directly either');
select ok(not has_table_privilege('authenticated', 'community_posts', 'INSERT'),
  'nor insert into it directly, so the contact-info and rate-limit checks cannot be skipped');
select ok(not has_table_privilege('authenticated', 'user_blocks', 'SELECT'),
  'nobody can read user_blocks directly: who blocked whom is not browsable');
select ok(not has_table_privilege('authenticated', 'content_reports', 'SELECT'),
  'nor content_reports, so a reporter cannot be identified by the person they reported');

select ok(not has_function_privilege('anon', 'public.community_feed(timestamptz, integer)', 'EXECUTE'),
  'the feed is not public: anon cannot call community_feed');
select ok(not has_function_privilege('anon', 'public.community_post(text, text)', 'EXECUTE'),
  'nor post to it');
select ok(has_function_privilege('authenticated', 'public.community_feed(timestamptz, integer)', 'EXECUTE'),
  'a signed-in member can call community_feed');

-- ---------------------------------------------------------------------------
-- 2. Posting, and what is refused
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"c1111111-0000-4000-8000-00000000000c","role":"authenticated"}';

select is(public.community_post('Aired down at the park all weekend, great conditions.') ->> 'ok',
  'true', 'a member can post');

select is(public.community_post('   ') ->> 'error', 'empty',
  'an empty post is refused');

-- The rule everybody accepts already says no phone numbers. This is the surface where a tow
-- company would post one.
select is(public.community_post('Cheap recovery, call me at 512-555-0134') ->> 'error',
  'contact_info',
  'a post carrying a phone number is refused before it reaches the table');

select is(public.community_post('Best rates, see https://example.com/tow') ->> 'error',
  'contact_info',
  'and so is one carrying a link');

set local request.jwt.claims =
  '{"sub":"c2222222-0000-4000-8000-00000000000c","role":"authenticated"}';
select is(public.community_post('Anyone running 37s on a stock axle?') ->> 'ok', 'true',
  'Ben posts');

set local request.jwt.claims =
  '{"sub":"c3333333-0000-4000-8000-00000000000c","role":"authenticated"}';
select is(public.community_post('Gate on the north trail is locked again.') ->> 'ok', 'true',
  'Cal posts');

-- ---------------------------------------------------------------------------
-- 3. The feed shows the right things to the right person
-- ---------------------------------------------------------------------------

set local request.jwt.claims =
  '{"sub":"c2222222-0000-4000-8000-00000000000c","role":"authenticated"}';

select is(
  jsonb_array_length(public.community_feed() -> 'posts'), 3,
  'the feed carries all three posts'
);

select ok(
  public.community_feed() -> 'posts' @> '[{"author_name":"Amy","mine":false}]'::jsonb,
  'somebody else''s post shows their display name and is not marked mine'
);

select ok(
  public.community_feed() -> 'posts'
    @> '[{"body":"Anyone running 37s on a stock axle?","mine":true}]'::jsonb,
  'and your own post is marked mine, which is how the delete control knows to appear'
);

reset role;
create temp table cposts as
  select body, id from community_posts;
-- The assertions below look ids up by body text while acting as a member, so the lookup table
-- has to be readable by that role. It holds nothing but ids and bodies they can already see.
grant select on cposts to public;

-- ---------------------------------------------------------------------------
-- 4. Comments and reactions, and the counters that follow them
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"c2222222-0000-4000-8000-00000000000c","role":"authenticated"}';

select is(
  public.community_comment(
    (select id from cposts where body like 'Aired down%'),
    'Which loop were you on?') ->> 'ok',
  'true',
  'a member can comment on somebody else''s post'
);

select is(
  public.community_comment(
    (select id from cposts where body like 'Aired down%'),
    'text me on 512-555-0134') ->> 'error',
  'contact_info',
  'a comment carrying a phone number is refused too'
);

select is(
  public.community_react((select id from cposts where body like 'Aired down%'), true) ->> 'ok',
  'true',
  'and can react'
);

reset role;
select is(
  (select comment_count from community_posts where body like 'Aired down%'), 1,
  'the comment counter on the post follows the insert'
);
select is(
  (select reaction_count from community_posts where body like 'Aired down%'), 1,
  'and so does the reaction counter'
);

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"c2222222-0000-4000-8000-00000000000c","role":"authenticated"}';

select ok(
  public.community_feed() -> 'posts'
    @> '[{"body":"Aired down at the park all weekend, great conditions.","reacted":true}]'::jsonb,
  'the feed reports back that you reacted, so the button renders in the right state'
);

select is(
  public.community_react((select id from cposts where body like 'Aired down%'), false) ->> 'ok',
  'true', 'reacting is a toggle');

reset role;
select is(
  (select reaction_count from community_posts where body like 'Aired down%'), 0,
  'and un-reacting takes the count back down'
);

-- ---------------------------------------------------------------------------
-- 5. Blocking, in both directions
--
-- Ben blocks Cal. Cal is never told. What matters is that neither of them sees the other.
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"c2222222-0000-4000-8000-00000000000c","role":"authenticated"}';

select is(public.community_block('c3333333-0000-4000-8000-00000000000c', true) ->> 'ok', 'true',
  'Ben blocks Cal');

select is(public.community_block('c2222222-0000-4000-8000-00000000000c', true) ->> 'error',
  'bad_target', 'blocking yourself is refused');

select is(
  jsonb_array_length(public.community_feed() -> 'posts'), 2,
  'Cal''s post is gone from Ben''s feed'
);

select ok(
  not (public.community_feed() -> 'posts' @> '[{"author_name":"Cal"}]'::jsonb),
  'specifically: nothing of Cal''s remains in it'
);

-- The half that is easy to get wrong.
set local request.jwt.claims =
  '{"sub":"c3333333-0000-4000-8000-00000000000c","role":"authenticated"}';

select is(
  jsonb_array_length(public.community_feed() -> 'posts'), 2,
  'and Ben''s post is gone from Cal''s feed, although Cal blocked nobody'
);

select ok(
  not (public.community_feed() -> 'posts' @> '[{"author_name":"Ben"}]'::jsonb),
  'a block is symmetric in effect: the person who was blocked stops seeing the blocker too'
);

select is(
  public.community_post_thread((select id from cposts where body like 'Anyone running 37s%'))
    ->> 'error',
  'not_found',
  'Cal cannot open the thread on Ben''s post'
);

select is(
  public.community_comment(
    (select id from cposts where body like 'Anyone running 37s%'), 'hey') ->> 'error',
  'not_found',
  'nor comment on it'
);

select is(
  public.community_react((select id from cposts where body like 'Anyone running 37s%'), true)
    ->> 'error',
  'not_found',
  'nor react to it -- a block that only hid the post would still let a notification through'
);

-- Amy blocked nobody and is unaffected by any of it.
set local request.jwt.claims =
  '{"sub":"c1111111-0000-4000-8000-00000000000c","role":"authenticated"}';
select is(
  jsonb_array_length(public.community_feed() -> 'posts'), 3,
  'a block between two other people changes nothing for anyone else'
);

-- The list is one-sided on purpose: you can see who you blocked, never who blocked you.
set local request.jwt.claims =
  '{"sub":"c2222222-0000-4000-8000-00000000000c","role":"authenticated"}';
select ok(
  public.community_blocked_list() -> 'blocked' @> '[{"display_name":"Cal"}]'::jsonb,
  'Ben can see who he blocked, so he can undo it'
);

set local request.jwt.claims =
  '{"sub":"c3333333-0000-4000-8000-00000000000c","role":"authenticated"}';
select is(
  jsonb_array_length(public.community_blocked_list() -> 'blocked'), 0,
  'and Cal is not told that he was blocked'
);

set local request.jwt.claims =
  '{"sub":"c2222222-0000-4000-8000-00000000000c","role":"authenticated"}';
select is(public.community_block('c3333333-0000-4000-8000-00000000000c', false) ->> 'ok', 'true',
  'Ben unblocks Cal');

set local request.jwt.claims =
  '{"sub":"c3333333-0000-4000-8000-00000000000c","role":"authenticated"}';
select is(
  jsonb_array_length(public.community_feed() -> 'posts'), 3,
  'and both feeds come back'
);

-- ---------------------------------------------------------------------------
-- 6. Reporting
-- ---------------------------------------------------------------------------

set local request.jwt.claims =
  '{"sub":"c2222222-0000-4000-8000-00000000000c","role":"authenticated"}';

select is(
  public.community_report('post', (select id from cposts where body like 'Gate on the north%'),
                          'spam') ->> 'ok',
  'true', 'a member can report a post');

select is(
  public.community_report('post', (select id from cposts where body like 'Gate on the north%'),
                          'spam') ->> 'ok',
  'true', 'pressing report twice answers ok rather than erroring at them');

select is(
  public.community_report('post', (select id from cposts where body like 'Gate on the north%'),
                          'not_a_reason') ->> 'error',
  'bad_reason', 'an unknown reason is refused');

select is(
  public.community_report('post', 'c9999999-9999-4999-8999-00000000000c', 'spam') ->> 'error',
  'not_found', 'reporting something that does not exist is refused');

reset role;
select is(
  (select count(*)::integer from content_reports
    where target_id = (select id from cposts where body like 'Gate on the north%')),
  1,
  'and the second press did not create a second report, so the queue counts people not clicks'
);

-- ---------------------------------------------------------------------------
-- 7. Who may moderate
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"c2222222-0000-4000-8000-00000000000c","role":"authenticated"}';

select throws_ok(
  $$select public.moderation_queue('new')$$,
  '42501', null,
  'an ordinary member cannot read the moderation queue'
);

select throws_ok(
  $$select public.moderate_content('post', 'c9999999-9999-4999-8999-00000000000c', 'hide')$$,
  '42501', null,
  'nor hide anything'
);

set local request.jwt.claims =
  '{"sub":"c4444444-0000-4000-8000-00000000000c","role":"authenticated"}';

select is(
  jsonb_array_length(public.moderation_queue('new') -> 'items'), 1,
  'a moderator sees the reported item'
);

select ok(
  public.moderation_queue('new') -> 'items'
    @> '[{"content":"Gate on the north trail is locked again.","author_name":"Cal"}]'::jsonb,
  'with the content and the author, which is what a decision needs'
);

-- The point of the role. A moderator hides posts; the volunteer roster carries phone numbers and
-- is none of their business.
select throws_ok(
  $$select public.admin_list_responders()$$,
  '42501', null,
  'a moderator cannot list volunteers: hiding a post is not a key to contact details'
);

select throws_ok(
  $$select public.admin_dashboard()$$,
  '42501', null,
  'nor open the admin dashboard'
);

-- ---------------------------------------------------------------------------
-- 8. Hiding, and what it takes with it
-- ---------------------------------------------------------------------------

select is(
  public.moderate_content('post', (select id from cposts where body like 'Gate on the north%'),
                          'hide', 'Reported as spam by two members') ->> 'ok',
  'true', 'the moderator hides it');

set local request.jwt.claims =
  '{"sub":"c2222222-0000-4000-8000-00000000000c","role":"authenticated"}';

select is(
  jsonb_array_length(public.community_feed() -> 'posts'), 2,
  'and it leaves the feed'
);

select is(
  public.community_post_thread((select id from cposts where body like 'Gate on the north%'))
    ->> 'error',
  'not_found',
  'and its thread stops answering, so a saved link does not still open it'
);

-- Even for the person who wrote it. Silently leaving it visible to its author is how a hidden
-- post keeps getting replies nobody can see.
set local request.jwt.claims =
  '{"sub":"c3333333-0000-4000-8000-00000000000c","role":"authenticated"}';
select ok(
  not (public.community_feed() -> 'posts' @> '[{"body":"Gate on the north trail is locked again."}]'::jsonb),
  'including for its own author'
);

set local request.jwt.claims =
  '{"sub":"c4444444-0000-4000-8000-00000000000c","role":"authenticated"}';

select is(
  jsonb_array_length(public.moderation_queue('new') -> 'items'), 0,
  'the queue empties, because acting on the content closes every report against it'
);

reset role;
-- Scoped to this post, not a count of every hide the database has ever seen: the audit log is
-- append-only and real moderation lands in it, so a global count is a test that breaks the first
-- time somebody actually moderates something.
select is(
  (select count(*)::integer from audit_log
    where action = 'content.hide'
      and entity_id = (select id::text from cposts where body like 'Gate on the north%')), 1,
  'and the moderator''s action is in the audit log: hiding is reversible, doing it unaccountably is not'
);

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"c4444444-0000-4000-8000-00000000000c","role":"authenticated"}';

select is(
  public.moderate_content('post', (select id from cposts where body like 'Gate on the north%'),
                          'restore') ->> 'ok',
  'true', 'a moderator can undo it');

set local request.jwt.claims =
  '{"sub":"c3333333-0000-4000-8000-00000000000c","role":"authenticated"}';
select is(
  jsonb_array_length(public.community_feed() -> 'posts'), 3,
  'and the post comes back'
);

-- ---------------------------------------------------------------------------
-- 9. Your own content is yours
-- ---------------------------------------------------------------------------

select is(
  public.community_delete_own('post', (select id from cposts where body like 'Anyone running 37s%'))
    ->> 'error',
  'not_found',
  'you cannot delete somebody else''s post'
);

set local request.jwt.claims =
  '{"sub":"c2222222-0000-4000-8000-00000000000c","role":"authenticated"}';

select is(
  public.community_delete_own('post', (select id from cposts where body like 'Anyone running 37s%'))
    ->> 'ok',
  'true',
  'you can delete your own'
);

select is(
  jsonb_array_length(public.community_feed() -> 'posts'), 2,
  'and it goes'
);

reset role;

select * from finish();
rollback;
