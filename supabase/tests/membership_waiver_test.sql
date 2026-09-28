-- Winch Up :: proof that the membership agreement records what it claims to record
--
-- Run with:  supabase test db
--
-- A signature is a legal record. Almost everything worth checking here is a way that record
-- could quietly become false, in rough order of how badly it would go:
--
--   1. Somebody edits the text after people have signed it. The signature would then attest to
--      words its signer never read. The immutability trigger is the only thing preventing this,
--      so it is the first thing checked.
--
--   2. A member signs text they were never shown, because an admin published a new version
--      while their form sat open. The hash round trip is what catches that.
--
--   3. The gate locks every member out of the product. `membership.required` can be switched on
--      by an admin at any time, and with no published agreement there would be no way for
--      anybody to satisfy it. Checked before anything else about the gate.
--
--   4. A double submit records two signatures, or moves the timestamp on the first.
--
--   5. Signatures are readable from a browser. They carry legal names and IP addresses and must
--      never be, from any role but service_role.
--
--   6. A cosmetic re-publish nags every member into re-signing, training them to click through
--      the thing they are supposed to read.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

delete from public.membership_signatures;
delete from public.membership_agreements;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
)
select '00000000-0000-0000-0000-000000000000', v.id, 'authenticated', 'authenticated',
       v.email, 'x', now(), '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
from (values
  ('a1111111-0000-4000-8000-00000000000a'::uuid, 'waiver-signer@example.invalid'),
  ('a2222222-0000-4000-8000-00000000000a'::uuid, 'waiver-holdout@example.invalid')
) as v(id, email)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 3 first: the gate cannot lock the product
-- ---------------------------------------------------------------------------

update public.app_settings set value = 'true'::jsonb where key = 'membership.required';

select ok(
  not app.membership_gate_blocks('a1111111-0000-4000-8000-00000000000a'),
  'the setting alone does not gate: with no published agreement there would be nothing anybody '
  'could sign to get back in'
);

select ok(
  not (app.membership_state('a1111111-0000-4000-8000-00000000000a') ->> 'needs_signature')::boolean,
  'and nobody is prompted to sign an agreement that does not exist'
);

-- ---------------------------------------------------------------------------
-- Publish v1
-- ---------------------------------------------------------------------------

insert into public.membership_agreements (version, body_en, body_es, is_current, effective_at)
values (1, 'Agreement text, version one.', 'Texto del acuerdo, version uno.', true, now());

select ok(
  app.membership_gate_blocks('a1111111-0000-4000-8000-00000000000a'),
  'with a published agreement and the setting on, an unsigned member is gated'
);

select is(
  (select body_hash from public.membership_agreements where version = 1),
  encode(extensions.digest(
    'Agreement text, version one.' || E'\n--\n' || 'Texto del acuerdo, version uno.', 'sha256'
  ), 'hex'),
  'the hash covers both languages: a member signs the document, not one translation of it'
);

select ok(
  (public.membership_agreement() -> 'agreement' ->> 'body_en') is not null,
  'the full text is returned for display rather than a link to it'
);

-- ---------------------------------------------------------------------------
-- 2. A member cannot sign text they were not shown
-- ---------------------------------------------------------------------------

select is(
  public.sign_membership_agreement(jsonb_build_object(
    'user_id', 'a1111111-0000-4000-8000-00000000000a',
    'legal_name', 'Jane Doe', 'signature_text', 'Jane Doe',
    'body_hash', 'a-hash-from-a-version-that-is-no-longer-current'
  )) ->> 'error',
  'agreement_changed',
  'a stale hash is refused: the version on screen is no longer the version in force'
);

select is(
  public.sign_membership_agreement(jsonb_build_object(
    'user_id', 'a1111111-0000-4000-8000-00000000000a',
    'legal_name', 'Jane Doe', 'signature_text', 'JD',
    'body_hash', (select body_hash from public.membership_agreements where version = 1)
  )) ->> 'error',
  'signature_mismatch',
  'initials are not a signature: the typed name has to be the legal name'
);

select is(
  public.sign_membership_agreement(jsonb_build_object(
    'user_id', 'a1111111-0000-4000-8000-00000000000a',
    'legal_name', '', 'signature_text', '',
    'body_hash', (select body_hash from public.membership_agreements where version = 1)
  )) ->> 'error',
  'legal_name_required',
  'an empty name is refused rather than stored as a signature'
);

select is((select count(*)::integer from public.membership_signatures), 0,
  'none of those wrote a row');

-- ---------------------------------------------------------------------------
-- A real signature
-- ---------------------------------------------------------------------------

select ok(
  (public.sign_membership_agreement(jsonb_build_object(
    'user_id', 'a1111111-0000-4000-8000-00000000000a',
    'legal_name', 'Jane Doe', 'signature_text', '  jane   DOE  ',
    'body_hash', (select body_hash from public.membership_agreements where version = 1),
    'ip', '203.0.113.7', 'user_agent', 'Mozilla/5.0 (test)', 'locale', 'es'
  )) ->> 'ok')::boolean,
  'sloppy case and spacing still signs: that is the same person being imprecise, not a different name'
);

select results_eq(
  $$ select legal_name, signature_text, agreement_version, locale, signed_via,
            signed_ip, signed_user_agent
       from public.membership_signatures
      where user_id = 'a1111111-0000-4000-8000-00000000000a' $$,
  $$ values ('Jane Doe', 'jane   DOE', 1, 'es', 'web',
             '203.0.113.7'::inet, 'Mozilla/5.0 (test)') $$,
  'the record keeps what was typed verbatim alongside the audit trail -- requirement 6'
);

select is(
  (select s.body_hash from public.membership_signatures s
    where s.user_id = 'a1111111-0000-4000-8000-00000000000a'),
  (select a.body_hash from public.membership_agreements a where a.version = 1),
  'the signature carries its own copy of the hash, so a later mismatch is detectable'
);

select ok(
  not app.membership_gate_blocks('a1111111-0000-4000-8000-00000000000a'),
  'and the gate opens for them'
);

select ok(
  app.membership_gate_blocks('a2222222-0000-4000-8000-00000000000a'),
  'but not for the member who has not signed'
);

-- ---------------------------------------------------------------------------
-- 4. Double submit
-- ---------------------------------------------------------------------------

select ok(
  (public.sign_membership_agreement(jsonb_build_object(
    'user_id', 'a1111111-0000-4000-8000-00000000000a',
    'legal_name', 'Jane Doe', 'signature_text', 'Jane Doe',
    'body_hash', (select body_hash from public.membership_agreements where version = 1)
  )) ->> 'replayed')::boolean,
  'a second submit reports itself as a replay rather than signing again'
);

select is((select count(*)::integer from public.membership_signatures), 1,
  'and there is still exactly one signature');

select throws_ok(
  $$ insert into public.membership_signatures
       (user_id, agreement_id, agreement_version, body_hash, legal_name, signature_text)
     select 'a1111111-0000-4000-8000-00000000000a', id, version, body_hash, 'Jane Doe', 'Jane Doe'
       from public.membership_agreements where version = 1 $$,
  '23505',
  null,
  'and the table refuses a duplicate directly, not only through the RPC'
);

-- ---------------------------------------------------------------------------
-- 1. The signed text is frozen
-- ---------------------------------------------------------------------------

select throws_ok(
  $$ update public.membership_agreements set body_en = 'quietly different' where version = 1 $$,
  null, null,
  'the text of a signed agreement cannot be edited: the signature would attest to words its '
  'signer never read'
);

select throws_ok(
  $$ delete from public.membership_agreements where version = 1 $$,
  null, null,
  'nor deleted -- requirement 13 keeps historical versions for the members who signed them'
);

select lives_ok(
  $$ update public.membership_agreements set is_current = false where version = 1 $$,
  'but it can be retired, which is how a new version supersedes it'
);

-- ---------------------------------------------------------------------------
-- 6. Re-signature only on material change
-- ---------------------------------------------------------------------------

insert into public.membership_agreements
  (version, body_en, body_es, is_current, effective_at, requires_resignature)
values (2, 'Agreement text, version one (typo).', 'Texto del acuerdo, version uno.',
        true, now(), false);

select ok(
  not (app.membership_state('a1111111-0000-4000-8000-00000000000a') ->> 'needs_signature')::boolean,
  'a cosmetic re-publish does not nag an existing signer: training people to click through the '
  'document is how it stops being read'
);

select ok(
  (app.membership_state('a2222222-0000-4000-8000-00000000000a') ->> 'needs_signature')::boolean,
  'but somebody who never signed anything still has to'
);

update public.membership_agreements set is_current = false where version = 2;
insert into public.membership_agreements
  (version, body_en, body_es, is_current, effective_at, requires_resignature)
values (3, 'Agreement text, version three. Materially different.', 'Texto tres.',
        true, now(), true);

select ok(
  (app.membership_state('a1111111-0000-4000-8000-00000000000a') ->> 'needs_signature')::boolean,
  'a material change re-prompts a member who had signed -- requirement 14'
);

select is(
  (select count(*)::integer from public.membership_agreements),
  3,
  'and every historical version is still on file'
);

-- ---------------------------------------------------------------------------
-- Effective dating
-- ---------------------------------------------------------------------------

update public.membership_agreements set effective_at = now() + interval '1 day' where version = 3;

select ok(
  not (app.membership_state('a2222222-0000-4000-8000-00000000000a') ->> 'has_agreement')::boolean,
  'an agreement dated in the future is not yet in force'
);

select ok(
  not app.membership_gate_blocks('a2222222-0000-4000-8000-00000000000a'),
  'so it gates nobody until it takes effect'
);

-- ---------------------------------------------------------------------------
-- 5. Nobody reads signatures from a browser
-- ---------------------------------------------------------------------------

select ok(
  (select relrowsecurity from pg_class where oid = 'public.membership_signatures'::regclass),
  'membership_signatures has RLS enabled'
);

select is(
  (select count(*)::integer from pg_policies
    where schemaname = 'public' and tablename = 'membership_signatures'),
  0,
  'with no policy at all: deny by default, because these rows carry legal names and IP addresses'
);

select ok(
  not has_table_privilege('authenticated', 'public.membership_signatures', 'select'),
  'a signed-in member cannot select signatures'
);

select ok(
  not has_table_privilege('anon', 'public.membership_signatures', 'select'),
  'and neither can anon'
);

select ok(
  not has_function_privilege('authenticated', 'public.sign_membership_agreement(jsonb)', 'execute'),
  'signing is not reachable from the browser: the IP and user agent on a signature are audit '
  'evidence, and evidence the signer supplies about themselves is not evidence'
);

select ok(
  has_function_privilege('anon', 'public.membership_agreement()', 'execute'),
  'but reading the agreement is open to anon, because registration must show it before an '
  'account exists'
);

-- ---------------------------------------------------------------------------
-- The shipped default
-- ---------------------------------------------------------------------------

select is(
  (select value from public.app_settings where key = 'membership.required'),
  'true'::jsonb,
  'this suite turned the gate on (the migration ships it off)'
);

select * from finish();
rollback;
