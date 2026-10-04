-- Winch Up :: which "no" is it
--
-- Run with:  supabase test db
--
-- `app.require_admin()` raises, which is right for an RPC and useless for a page deciding what to
-- render. The admin layout therefore asked only "is this person an admin", and on 2026-10-03 the
-- owner found the consequence: with security.require_admin_mfa on and a session at aal1, a real
-- admin passed the gate, got the whole console, and every screen showed an empty list -- each RPC
-- behind them raising `mfa_required`, which nothing in the app rendered.
--
-- `admin_session_state()` is the one function in the admin surface that answers a refusal with
-- DATA. The property that matters is therefore not what it returns but that it NEVER RAISES -- a
-- throw here puts the layout back to guessing, and the empty-console bug comes back wearing a
-- stack trace.

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

-- Enforcement off for the first half, which is how the local stack and a fresh project ship.
insert into public.app_settings (key, value) values ('security.require_admin_mfa', 'false'::jsonb)
on conflict (key) do update set value = 'false'::jsonb;

-- ---------------------------------------------------------------------------
-- 1. It never raises, whoever asks
-- ---------------------------------------------------------------------------
--
-- lives_ok rather than is(): the point is the absence of an exception. Asserted for every caller
-- the layout can have, because the one that throws is the one that breaks the page.

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"00000000-0000-4000-8000-0000000000aa","role":"authenticated"}';

select lives_ok(
  $$select public.admin_session_state()$$,
  'a signed-in stranger gets an answer, not an exception');

select is(
  public.admin_session_state() ->> 'reason',
  'not_admin',
  'and the answer names which refusal it is');

select is(
  (public.admin_session_state() ->> 'ok')::boolean,
  false,
  'with ok false, so a page cannot mistake the shape for permission');

reset role;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.a_member(), 'role', 'authenticated')::text, true);
set local role authenticated;

select is(
  public.admin_session_state() ->> 'reason',
  'not_admin',
  'an ordinary member, likewise');

reset role;

-- ---------------------------------------------------------------------------
-- 2. An admin, with enforcement off
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.an_admin(), 'role', 'authenticated')::text, true);
set local role authenticated;

select ok(
  (public.admin_session_state() ->> 'ok')::boolean,
  'an admin is let through when the site does not require a second factor');

select is(
  public.admin_session_state() ->> 'reason', 'ok',
  'and says so');

reset role;

-- ---------------------------------------------------------------------------
-- 3. THE CASE THE OWNER HIT
-- ---------------------------------------------------------------------------
--
-- Enforcement on, session at aal1. This is the state that produced a console full of empty lists,
-- and the whole reason this function exists.

insert into public.app_settings (key, value) values ('security.require_admin_mfa', 'true'::jsonb)
on conflict (key) do update set value = 'true'::jsonb;

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.an_admin(), 'role', 'authenticated')::text, true);
set local role authenticated;

select is(
  public.admin_session_state() ->> 'reason',
  'mfa_required',
  'an admin on an unchallenged session is told it is the FACTOR, not their account');

select is(
  (public.admin_session_state() ->> 'ok')::boolean, false,
  'and is not let through');

-- The same session, against a real admin RPC: this is what the screens were doing silently.
select throws_ok(
  $$select public.admin_announcements()$$,
  '42501',
  null,
  'while the RPCs themselves still refuse -- the page gate is presentation, not enforcement');

reset role;

-- ---------------------------------------------------------------------------
-- 4. Enforcement on, session challenged
-- ---------------------------------------------------------------------------
--
-- The control. Without it, every assertion above would also pass against a function that returned
-- mfa_required to everybody for ever.

select set_config('request.jwt.claims',
  json_build_object('sub', pg_temp.an_admin(), 'role', 'authenticated', 'aal', 'aal2')::text, true);
set local role authenticated;

select ok(
  (public.admin_session_state() ->> 'ok')::boolean,
  'the SAME admin at aal2 is let through, which is what makes the refusal above mean something');

select is(
  public.admin_session_state() ->> 'aal', 'aal2',
  'and the level is reported, so a screen can say what changed');

select is(
  public.admin_announcements() ->> 'ok', 'true',
  'and the RPCs accept the challenged session too');

reset role;

-- ---------------------------------------------------------------------------
-- 5. It tells a stranger nothing about who is an admin
-- ---------------------------------------------------------------------------

select ok(
  not has_function_privilege('anon', 'public.admin_session_state()', 'execute'),
  'a signed-out caller cannot ask at all');

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"00000000-0000-4000-8000-0000000000ab","role":"authenticated"}';

select ok(
  not (public.admin_session_state() ? 'admins')
  and not (public.admin_session_state() ? 'user_id'),
  'and the answer names nobody -- it is about THIS session and the site policy, not about who');

reset role;

-- Put the setting back the way the local stack ships.
insert into public.app_settings (key, value) values ('security.require_admin_mfa', 'false'::jsonb)
on conflict (key) do update set value = 'false'::jsonb;

select * from finish();
rollback;
