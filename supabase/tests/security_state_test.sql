-- Winch Up :: my_security_state(), the thing the Account & Security screen believes
--
-- Run with:  supabase test db
--
-- This RPC decides whether a member is allowed to disconnect a sign-in method, so the failure
-- mode it guards is somebody locking themselves out of an account they cannot get back into --
-- with no support desk behind it. Every assertion below is aimed at one of the two ways that
-- happens: the count being too high, or the screen being told about an account that is not the
-- caller's.
--
-- The awkward truth about testing a security definer function in pgTAP is that it runs as the
-- OWNER, so a missing grant does not show up by calling it. The grant is therefore asserted
-- against the catalogue instead, which is also the only way to catch the trap that bit
-- sign_membership_agreement: a new function is born executable by anon (Supabase's default
-- privileges) AND by PUBLIC (vanilla Postgres), and it takes revoking all three to close it.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- ---------------------------------------------------------------------------
-- Four members, one per shape the screen has to render.
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, phone, encrypted_password,
  email_confirmed_at, phone_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
)
select '00000000-0000-0000-0000-000000000000', v.id, 'authenticated', 'authenticated',
       v.email, v.phone, v.pw,
       case when v.email is null then null else now() end,
       case when v.phone is null then null else now() end,
       '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
from (values
  -- password + confirmed phone: two ways in
  ('50000001-0000-4000-8000-000000000001'::uuid, 'sec-both@example.invalid',   '+15125550001', 'hashed'),
  -- password only
  ('50000002-0000-4000-8000-000000000002'::uuid, 'sec-pw@example.invalid',     null,           'hashed'),
  -- Google only: an email on the account, but NO password and no phone. The one that must not
  -- be allowed to disconnect Google.
  ('50000003-0000-4000-8000-000000000003'::uuid, 'sec-google@example.invalid', null,           ''),
  -- phone only, the volunteer who joined by SMS
  ('50000004-0000-4000-8000-000000000004'::uuid, null,                         '+15125550004', '')
) as v(id, email, phone, pw)
on conflict (id) do nothing;

insert into auth.identities (provider_id, user_id, provider, identity_data)
values
  ('google-sub-3', '50000003-0000-4000-8000-000000000003', 'google',
   '{"sub":"google-sub-3","email":"sec-google@example.invalid"}'::jsonb),
  -- GoTrue writes an 'email' identity for a password account too. It must NOT be counted or
  -- listed: it is not a "connected account" and counting it would double up with has_password.
  ('sec-both@example.invalid', '50000001-0000-4000-8000-000000000001', 'email',
   '{"sub":"50000001-0000-4000-8000-000000000001","email":"sec-both@example.invalid"}'::jsonb),
  ('+15125550004', '50000004-0000-4000-8000-000000000004', 'phone',
   '{"sub":"50000004-0000-4000-8000-000000000004","phone":"+15125550004"}'::jsonb)
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- The shapes
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims = '{"sub":"50000001-0000-4000-8000-000000000001","role":"authenticated"}';

select is(
  (public.my_security_state() ->> 'has_password')::boolean, true,
  'a member with a password is told so'
);

select is(
  (public.my_security_state() ->> 'phone_confirmed')::boolean, true,
  'a confirmed phone reads as confirmed'
);

select is(
  (public.my_security_state() ->> 'methods')::integer, 2,
  'password + phone counts as two ways in'
);

-- The email identity must not leak into the connected-accounts list.
select is(
  public.my_security_state() -> 'providers', '[]'::jsonb,
  'the internal email identity is not a connected account'
);

set local request.jwt.claims = '{"sub":"50000002-0000-4000-8000-000000000002","role":"authenticated"}';

select is(
  (public.my_security_state() ->> 'methods')::integer, 1,
  'a password alone is one way in'
);

set local request.jwt.claims = '{"sub":"50000003-0000-4000-8000-000000000003","role":"authenticated"}';

select is(
  (public.my_security_state() ->> 'has_password')::boolean, false,
  'a Google-only account has no password, and an empty hash is not a password'
);

select is(
  public.my_security_state() -> 'providers', '["google"]'::jsonb,
  'Google is listed as the connected account'
);

-- THE ASSERTION THIS FILE EXISTS FOR.
--
-- A confirmed email looks like a way back in -- send yourself a reset link -- but a reset link
-- sets a PASSWORD, and this account has no password and no way to prove the address once
-- Google is gone. If this ever returns 2, the screen will happily offer to disconnect the only
-- thing holding the account open.
select is(
  (public.my_security_state() ->> 'methods')::integer, 1,
  'a confirmed email does NOT count as a way in for a Google-only account'
);

set local request.jwt.claims = '{"sub":"50000004-0000-4000-8000-000000000004","role":"authenticated"}';

select is(
  (public.my_security_state() ->> 'methods')::integer, 1,
  'phone only is one way in'
);

select is(
  public.my_security_state() -> 'providers', '[]'::jsonb,
  'the internal phone identity is not a connected account either'
);

-- ---------------------------------------------------------------------------
-- It answers for the CALLER, and for nobody else
-- ---------------------------------------------------------------------------

select is(
  public.my_security_state() ->> 'email', '',
  'a phone-only caller is not handed some other account''s email'
);

set local request.jwt.claims = '{"sub":"50000002-0000-4000-8000-000000000002","role":"authenticated"}';

select is(
  public.my_security_state() ->> 'email', 'sec-pw@example.invalid',
  'switching the claim switches the answer -- it reads auth.uid(), not a fixed row'
);

-- No session at all. The function raises rather than returning a shape that a screen would
-- happily render as "no methods, everything removable".
set local request.jwt.claims = '';

select throws_ok(
  'select public.my_security_state()',
  '42501',
  null,
  'signed out is refused, not answered with an empty account'
);

-- ---------------------------------------------------------------------------
-- What it must never return
-- ---------------------------------------------------------------------------

set local request.jwt.claims = '{"sub":"50000001-0000-4000-8000-000000000001","role":"authenticated"}';

-- The hash, obviously. Asserted by key rather than by value because the point is that no key
-- carries it, whatever it happens to contain.
select is(
  (select count(*) from jsonb_object_keys(public.my_security_state()) k
    where k in ('encrypted_password', 'password', 'hash', 'identity_data', 'token')),
  0::bigint,
  'no key carries the password hash, a token, or the provider payload'
);

-- identity_data holds the provider's raw profile -- name, avatar url, sub. The screen needs to
-- know Google is attached, not what Google said about the person.
select is(
  public.my_security_state()::text not like '%google-sub-3%', true,
  'the provider subject id is not returned'
);

reset role;

-- ---------------------------------------------------------------------------
-- The grant. Catalogue, not behaviour -- see the header.
-- ---------------------------------------------------------------------------

select is(
  (select count(*) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'my_security_state'
      and (has_function_privilege('anon', p.oid, 'execute'))),
  0::bigint,
  'anon cannot execute my_security_state -- new functions are born anon-executable, this one was un-born'
);

select is(
  (select count(*) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'my_security_state'
      and has_function_privilege('authenticated', p.oid, 'execute')),
  1::bigint,
  'authenticated can execute it'
);

select is(
  (select prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'my_security_state'),
  true,
  'it is security definer -- it reads auth.users, which the caller cannot'
);

select is(
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'my_security_state'
      and p.proconfig::text like '%search_path%'),
  1::bigint,
  'search_path is pinned'
);

select * from finish();
rollback;
