-- Winch Up :: completing the volunteer form is what makes somebody dispatchable
--
-- `profiles.available_to_help` is what app.candidates() matches on. It is `not null default false`,
-- and until 2026-10-05 the volunteer form did not set it: upsert_responder_profile never mentioned
-- the column in any of the five migrations that define it. A member filled in /join -- home
-- location, radius, equipment, a verified phone -- was returned to the home page, and was silently
-- not in the candidate set. Three real members sat 0, 15 and 28 miles from the owner that way.
--
-- THE PAIRING THAT MATTERS MOST is assertion 2. An unconditional `update profiles set
-- available_to_help = ...` passes assertion 1 and is wrong: this same function is how a member
-- edits their radius months later, so a caller that does not mention the key must not change the
-- answer. Otherwise changing your radius silently puts you back on call at 2am after you had
-- deliberately turned it off -- and nothing on any screen would say so.
--
-- Assertion 3 is the other half of the same coin: naming the key with false IS the member
-- unticking the box, and must take effect. A guard written as "only ever set it to true" would
-- pass 1 and 2 and make the checkbox one-way.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

create temporary table t (name text primary key, id uuid not null);
insert into t (name, id) values
  ('joiner', gen_random_uuid()),
  ('editor', gen_random_uuid());

insert into auth.users (id, email, phone, phone_confirmed_at, created_at) values
  ((select id from t where name = 'joiner'), 'joiner@winchup.test', '+15125554001', now(), now()),
  ((select id from t where name = 'editor'), 'editor@winchup.test', '+15125554002', now(), now());

insert into profiles (user_id, display_name)
select id, name from t
on conflict (user_id) do nothing;

-- ---------------------------------------------------------------------------
-- 1. Ticking the box on /join makes you dispatchable
-- ---------------------------------------------------------------------------

select is(
  (select available_to_help from profiles where user_id = (select id from t where name = 'joiner')),
  false,
  'a new member starts not available to help -- the column default, and the right default'
);

select set_config('request.jwt.claims',
  json_build_object('sub', (select id from t where name = 'joiner'), 'role', 'authenticated')::text,
  true);

select is(
  (public.upsert_responder_profile(jsonb_build_object(
     'first_name', 'Joiner',
     'lat', 29.76, 'lng', -95.37,
     'equipment', jsonb_build_array('winch'),
     'available_to_help', true
   )) ->> 'ok')::boolean,
  true,
  'the volunteer form saves'
);

select is(
  (select available_to_help from profiles where user_id = (select id from t where name = 'joiner')),
  true,
  'and the member is now available to help -- the form no longer produces volunteers nobody rings'
);

-- The flag is useless without the row the ring matches against, so assert both. Marking somebody
-- willing with nothing to match through is available, never rung, and no error anywhere.
select isnt_empty(
  format('select 1 from responders where user_id = %L and home_location is not null',
         (select id from t where name = 'joiner')),
  'and they have a capability row with a home point for the ring to match'
);

-- ---------------------------------------------------------------------------
-- 2. THE PAIRING. Editing a profile without mentioning the key changes nothing.
-- ---------------------------------------------------------------------------
--
-- This is somebody changing their radius a month later from a client that predates the checkbox.

select is(
  (public.upsert_responder_profile(jsonb_build_object(
     'first_name', 'Joiner',
     'lat', 29.76, 'lng', -95.37,
     'equipment', jsonb_build_array('winch'),
     'radius_miles', 60
   )) ->> 'ok')::boolean,
  true,
  'editing the profile without naming the key succeeds'
);

select is(
  (select available_to_help from profiles where user_id = (select id from t where name = 'joiner')),
  true,
  'and leaves them available -- a payload that is silent about consent must not change it'
);

-- Now the same silence over an answer of FALSE, which is the direction that actually hurts.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from t where name = 'editor'), 'role', 'authenticated')::text,
  true);

select public.upsert_responder_profile(jsonb_build_object(
  'first_name', 'Editor',
  'lat', 29.76, 'lng', -95.37,
  'equipment', jsonb_build_array('winch'),
  'available_to_help', false
));

select is(
  (public.upsert_responder_profile(jsonb_build_object(
     'first_name', 'Editor',
     'lat', 29.76, 'lng', -95.37,
     'equipment', jsonb_build_array('winch'),
     'radius_miles', 15
   )) ->> 'ok')::boolean,
  true,
  'somebody who declined call-outs can still edit their radius'
);

select is(
  (select available_to_help from profiles where user_id = (select id from t where name = 'editor')),
  false,
  'and is NOT put back on call by it -- the failure this guard exists to prevent'
);

-- ---------------------------------------------------------------------------
-- 3. The checkbox works in both directions
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  json_build_object('sub', (select id from t where name = 'joiner'), 'role', 'authenticated')::text,
  true);

select public.upsert_responder_profile(jsonb_build_object(
  'first_name', 'Joiner',
  'lat', 29.76, 'lng', -95.37,
  'equipment', jsonb_build_array('winch'),
  'available_to_help', false
));

select is(
  (select available_to_help from profiles where user_id = (select id from t where name = 'joiner')),
  false,
  'unticking the box takes effect -- a guard that only ever set true would make it one-way'
);

select finish();
rollback;
