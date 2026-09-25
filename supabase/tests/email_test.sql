-- Winch Up :: the account-email delivery log
--
-- Run with:  supabase test db
--
-- Two things are being proved here, and only one of them is about logging.
--
-- The first is that "send the welcome email once" is true because the database makes it true,
-- not because the caller remembered to check. §5 of the email brief says once per verified
-- account; a read-then-write cannot promise that under a double webhook or two tabs, so the
-- promise lives in a unique index and these assertions are what say so.
--
-- The second is about what a delivery log is allowed to know. An action URL in a verification
-- email is a credential -- somebody who can read it can take over the account -- so a table of
-- emails must not become a more valuable target than the mail it records. The column list is
-- pinned for the same reason ad_daily_stats's is: the safe version of this table is the one
-- that cannot identify anybody, and that only stays true if a test fails when it changes.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- ---------------------------------------------------------------------------
-- Two members: one whose account survives, one who deletes theirs
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
)
select '00000000-0000-0000-0000-000000000000', v.id, 'authenticated', 'authenticated',
       v.email, 'x', now(), '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
from (values
  ('e1000000-0000-4000-8000-00000000000e'::uuid, 'mail-stays@example.invalid'),
  ('e2000000-0000-4000-8000-00000000000e'::uuid, 'mail-goes@example.invalid')
) as v(id, email)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Shape
-- ---------------------------------------------------------------------------

select has_table('public', 'email_deliveries', 'the delivery log exists');

select ok(
  (select relrowsecurity from pg_class where oid = 'public.email_deliveries'::regclass),
  'row level security is on'
);

-- Nobody reads this from a browser. It is written by the service role and read through an admin
-- RPC, so a policy mistake cannot expose which addresses have accounts.
select is(
  (select count(*)::int
     from information_schema.role_table_grants
    where table_schema = 'public'
      and table_name = 'email_deliveries'
      and grantee in ('anon', 'authenticated')),
  0,
  'neither anon nor a signed-in member has any grant on the table'
);

-- ---------------------------------------------------------------------------
-- What a row is NOT allowed to carry
--
-- Named individually rather than as a set difference, so a failure says which column appeared.
-- ---------------------------------------------------------------------------

select hasnt_column('public', 'email_deliveries', 'to_email',
  'no recipient address: it is on auth.users already, and a second copy is a second thing '
  'account deletion has to remember');

select hasnt_column('public', 'email_deliveries', 'subject', 'no subject line');
select hasnt_column('public', 'email_deliveries', 'body', 'no body');
select hasnt_column('public', 'email_deliveries', 'html', 'no rendered HTML');

select hasnt_column('public', 'email_deliveries', 'action_url',
  'and above all no action URL -- that is a single-use credential, and storing it would make '
  'this table worth attacking');

-- The whole column list, so a new column has to be thought about rather than just added.
select set_eq(
  $$select column_name::text from information_schema.columns
     where table_schema = 'public' and table_name = 'email_deliveries'$$,
  array[
    'id', 'user_id', 'template_key', 'locale', 'status', 'provider', 'provider_message_id',
    'idempotency_key', 'failure_reason', 'attempts', 'created_at', 'completed_at'
  ],
  'the column list is exactly what was reasoned about'
);

-- ---------------------------------------------------------------------------
-- Idempotency: the reason the table has an index at all
-- ---------------------------------------------------------------------------

insert into public.email_deliveries (user_id, template_key, idempotency_key, status)
values ('e1000000-0000-4000-8000-00000000000e', 'auth.welcome', 'welcome:e1', 'sent');

select throws_ok(
  $$insert into public.email_deliveries (user_id, template_key, idempotency_key, status)
    values ('e1000000-0000-4000-8000-00000000000e', 'auth.welcome', 'welcome:e1', 'sent')$$,
  '23505',
  null,
  'the same welcome email cannot be recorded twice'
);

-- A security notice legitimately repeats: two password changes are two emails. Those carry no
-- key, and nulls must not collide with each other or the second one would be swallowed.
insert into public.email_deliveries (user_id, template_key, status)
values ('e1000000-0000-4000-8000-00000000000e', 'security.password_changed', 'sent');

insert into public.email_deliveries (user_id, template_key, status)
values ('e1000000-0000-4000-8000-00000000000e', 'security.password_changed', 'sent');

select is(
  (select count(*)::int from public.email_deliveries
    where user_id = 'e1000000-0000-4000-8000-00000000000e'
      and template_key = 'security.password_changed'),
  2,
  'two password-change notices both record, because neither claims to be unique'
);

-- ---------------------------------------------------------------------------
-- Constraints
-- ---------------------------------------------------------------------------

select throws_ok(
  $$insert into public.email_deliveries (template_key, status) values ('auth.welcome', 'posted')$$,
  '23514',
  null,
  'an invented status is refused'
);

select throws_ok(
  $$insert into public.email_deliveries (template_key, locale) values ('auth.welcome', 'fr')$$,
  '23514',
  null,
  'a language with no templates is refused'
);

-- ---------------------------------------------------------------------------
-- Account deletion
--
-- The log must not block a deletion, and must not be a way to erase evidence either. SET NULL
-- is the middle: the row survives, and it identifies nobody because the table holds no address.
-- ---------------------------------------------------------------------------

insert into public.email_deliveries (user_id, template_key, idempotency_key, status)
values ('e2000000-0000-4000-8000-00000000000e', 'auth.welcome', 'welcome:e2', 'sent');

delete from auth.users where id = 'e2000000-0000-4000-8000-00000000000e';

select is(
  (select user_id from public.email_deliveries where idempotency_key = 'welcome:e2'),
  null,
  'deleting the account detaches the row instead of blocking the delete'
);

select is(
  (select count(*)::int from public.email_deliveries where idempotency_key = 'welcome:e2'),
  1,
  'and the row survives, so deleting an account cannot erase the record that mail went out'
);

-- ---------------------------------------------------------------------------
-- The admin read path
-- ---------------------------------------------------------------------------

select has_function('public', 'admin_email_deliveries', 'the admin read RPC exists');

select is(
  (select count(*)::int from information_schema.role_routine_grants
    where routine_name = 'admin_email_deliveries' and grantee = 'anon'),
  0,
  'anon cannot execute it'
);

select ok(
  (select prosecdef from pg_proc where proname = 'admin_email_deliveries'),
  'it is security definer'
);

select ok(
  (select array_to_string(proconfig, ',') like '%search_path%'
     from pg_proc where proname = 'admin_email_deliveries'),
  'and pins its search_path'
);

-- A member is not an admin, and the gate is the function''s own, not a grant.
set local role authenticated;
set local request.jwt.claim.sub = 'e1000000-0000-4000-8000-00000000000e';

select throws_ok(
  $$select * from public.admin_email_deliveries(10)$$,
  null,
  null,
  'a signed-in member who is not an admin is refused'
);

reset role;

-- ---------------------------------------------------------------------------
-- The welcome trigger
--
-- The event being tested is the transition, not the value: email_confirmed_at going from null to
-- a timestamp is the one thing that happens exactly once per verified account and cannot be
-- skipped by a browser that never came back from the redirect.
-- ---------------------------------------------------------------------------

-- Unconfirmed at creation, with a language recorded by the signup form.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
) values (
  '00000000-0000-0000-0000-000000000000', 'e3000000-0000-4000-8000-00000000000e',
  'authenticated', 'authenticated', 'mail-verifies@example.invalid', 'x', null,
  '{}'::jsonb, '{"locale":"es"}'::jsonb, now(), now(), '', '', '', ''
);

select is(
  (select count(*)::int from public.email_deliveries
    where user_id = 'e3000000-0000-4000-8000-00000000000e' and template_key = 'auth.welcome'),
  0,
  'signing up does not send a welcome email -- an unverified address has not been shown to belong to anybody'
);

update auth.users set email_confirmed_at = now()
 where id = 'e3000000-0000-4000-8000-00000000000e';

select is(
  (select count(*)::int from public.email_deliveries
    where user_id = 'e3000000-0000-4000-8000-00000000000e' and template_key = 'auth.welcome'),
  1,
  'confirming the address queues exactly one welcome email'
);

select is(
  (select locale from public.email_deliveries
    where user_id = 'e3000000-0000-4000-8000-00000000000e' and template_key = 'auth.welcome'),
  'es',
  'in the language the signup form recorded, because nothing else remembers it'
);

-- Supabase can touch this row again -- a password change, a metadata edit, an admin action.
-- None of those is a second verification.
update auth.users set email_confirmed_at = now() + interval '1 minute'
 where id = 'e3000000-0000-4000-8000-00000000000e';

update auth.users set raw_user_meta_data = '{"locale":"en"}'::jsonb
 where id = 'e3000000-0000-4000-8000-00000000000e';

select is(
  (select count(*)::int from public.email_deliveries
    where user_id = 'e3000000-0000-4000-8000-00000000000e' and template_key = 'auth.welcome'),
  1,
  'and touching the row again never produces a second one'
);

-- Confirmed at creation: confirmations switched off, an admin-created account, a seed. Without
-- the insert trigger these are silently never welcomed, and that is the configuration the local
-- stack runs in -- so the gap would only ever show up in the other environment.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
) values (
  '00000000-0000-0000-0000-000000000000', 'e4000000-0000-4000-8000-00000000000e',
  'authenticated', 'authenticated', 'mail-preconfirmed@example.invalid', 'x', now(),
  '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
);

select is(
  (select count(*)::int from public.email_deliveries
    where user_id = 'e4000000-0000-4000-8000-00000000000e' and template_key = 'auth.welcome'),
  1,
  'an account created already-confirmed is welcomed too'
);

select is(
  (select locale from public.email_deliveries
    where user_id = 'e4000000-0000-4000-8000-00000000000e' and template_key = 'auth.welcome'),
  'en',
  'and falls back to English when the form recorded no language'
);

-- Phone OTP is a different signup path entirely and has no address to send to.
insert into auth.users (
  instance_id, id, aud, role, email, phone, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
) values (
  '00000000-0000-0000-0000-000000000000', 'e5000000-0000-4000-8000-00000000000e',
  'authenticated', 'authenticated', null, '+15125550000', 'x', now(),
  '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
);

select is(
  (select count(*)::int from public.email_deliveries
    where user_id = 'e5000000-0000-4000-8000-00000000000e'),
  0,
  'a phone-only account queues nothing rather than a row that can never be sent'
);

-- ---------------------------------------------------------------------------
-- Claiming
-- ---------------------------------------------------------------------------

select is(
  (select to_email from public.claim_email_deliveries(10)
    where user_id = 'e3000000-0000-4000-8000-00000000000e'),
  'mail-verifies@example.invalid',
  'the claim joins the address at send time rather than the table storing it'
);

select is(
  (select status from public.email_deliveries
    where user_id = 'e3000000-0000-4000-8000-00000000000e' and template_key = 'auth.welcome'),
  'sending',
  'and marks what it handed out, so a second drain cannot take the same row'
);

select is(
  (select count(*)::int from public.claim_email_deliveries(10)),
  0,
  'a second claim finds nothing left to send'
);

-- ---------------------------------------------------------------------------
-- Recording the outcome
--
-- Putting a row back to queued is what happens when no provider is configured. It must not look
-- like a completed send, or the retry would read as a duplicate.
-- ---------------------------------------------------------------------------

select public.record_email_result(
  (select id from public.email_deliveries
    where user_id = 'e4000000-0000-4000-8000-00000000000e' and template_key = 'auth.welcome'),
  'queued', null, null, 'no email provider configured'
);

select is(
  (select completed_at from public.email_deliveries
    where user_id = 'e4000000-0000-4000-8000-00000000000e' and template_key = 'auth.welcome'),
  null,
  'a requeued row has no completion time, so a later send is not read as a second one'
);

select is(
  (select status from public.email_deliveries
    where user_id = 'e4000000-0000-4000-8000-00000000000e' and template_key = 'auth.welcome'),
  'queued',
  'and it goes back in the queue rather than being burned when email is unconfigured'
);

select throws_ok(
  $$select public.record_email_result(gen_random_uuid(), 'posted')$$,
  null, null,
  'an invented status is refused rather than written'
);

select * from finish();
rollback;
