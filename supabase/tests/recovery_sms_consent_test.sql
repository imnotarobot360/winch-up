-- Winch Up :: consent to recovery call-out texts
--
-- The spec: "A verified phone number does NOT automatically mean the member has consented to
-- recovery SMS messages." The field enforcing that existed long before this suite -- what was
-- wrong was its DEFAULT (true, so a row was born consenting) and the absence of any way to say
-- otherwise. Both are fixed; these are the assertions that keep them fixed.
--
-- THE ASYMMETRY THAT MATTERS, and the reason most of this file exists: turning consent ON clears
-- the STOP stamp, because a trigger forbids a row holding both -- but it deliberately does NOT
-- restore availability. Replying STOP also paused the volunteer, and putting somebody back on call
-- because they ticked a box on a settings screen is not what they asked for. Both halves are
-- asserted, because getting either one wrong is silent.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

create temporary table t (name text primary key, id uuid not null);
insert into t (name, id) values
  ('member', gen_random_uuid()), ('nobody', gen_random_uuid());

insert into auth.users (id, email, created_at) values
  ((select id from t where name = 'member'), 'consent@winchup.test', now()),
  ((select id from t where name = 'nobody'),  'noprofile@winchup.test', now());

insert into profiles (user_id, display_name) values
  ((select id from t where name = 'member'), 'Consent Member'),
  ((select id from t where name = 'nobody'),  'No Profile')
on conflict (user_id) do nothing;

-- ---------------------------------------------------------------------------
-- 1. A row is born WITHOUT consent
-- ---------------------------------------------------------------------------

insert into responders (
  id, user_id, phone, first_name, home_location, radius_miles, equipment,
  vehicle_class, drivetrain, approval, availability, is_test
) values (
  gen_random_uuid(), (select id from t where name = 'member'), '+15125554001', 'Connie',
  extensions.st_setsrid(extensions.st_point(-95.37, 29.76), 4326)::extensions.geography,
  30, '{winch}'::equipment_type[], 'truck', '4wd', 'approved', 'active', true
);

-- sms_opt_in is deliberately NOT named above. That is the point: the column default decides, and
-- until 20261004000200 the default was true, so proving a phone number WAS consent.
select is(
  (select sms_opt_in from responders where user_id = (select id from t where name = 'member')),
  false,
  'a new volunteer is born opted OUT -- a verified phone is not consent'
);

-- ---------------------------------------------------------------------------
-- 2. The member can say yes, and the RPC is the only way they can
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  json_build_object('sub', (select id from t where name = 'member'), 'role', 'authenticated')::text,
  true);

select is(
  (public.set_my_recovery_sms(true) ->> 'ok')::boolean,
  true,
  'opting in reports success'
);

select is(
  (select sms_opt_in from responders where user_id = (select id from t where name = 'member')),
  true,
  'and the row says so'
);

select is(
  (public.set_my_recovery_sms(false) ->> 'ok')::boolean,
  true,
  'opting back out reports success'
);

select is(
  (select sms_opt_in from responders where user_id = (select id from t where name = 'member')),
  false,
  'and the row says that too -- the switch moves in both directions'
);

-- ---------------------------------------------------------------------------
-- 3. STOP, and coming back from it
-- ---------------------------------------------------------------------------

-- What the inbound webhook does on STOP: opted out, stamped, AND paused.
update responders
   set sms_opt_in = false, sms_opt_out_at = now(), availability = 'paused'
 where user_id = (select id from t where name = 'member');

select lives_ok(
  'select public.set_my_recovery_sms(true)',
  'opting in after a STOP is allowed rather than blocked by the trigger'
);

select is(
  (select sms_opt_out_at from responders where user_id = (select id from t where name = 'member')),
  null,
  'the STOP stamp is cleared, because a trigger forbids being opted in and opted out at once'
);

-- THE HALF THAT IS EASY TO GET WRONG, and silent when you do.
select is(
  (select availability::text from responders where user_id = (select id from t where name = 'member')),
  'paused',
  'but availability stays PAUSED -- ticking an SMS box does not put somebody back on call'
);

-- ---------------------------------------------------------------------------
-- 4. Refusals, each paired with the acceptance that makes it meaningful
-- ---------------------------------------------------------------------------

select is(
  (public.set_my_recovery_sms(true) ->> 'ok')::boolean,
  true,
  'a member with a recovery profile is served'
);

select set_config('request.jwt.claims',
  json_build_object('sub', (select id from t where name = 'nobody'), 'role', 'authenticated')::text,
  true);

select is(
  public.set_my_recovery_sms(true) ->> 'error',
  'no_recovery_profile',
  'somebody who has never volunteered is told there is nothing to consent to, not "saved"'
);

select set_config('request.jwt.claims', '', true);

select is(
  public.set_my_recovery_sms(true) ->> 'error',
  'signed_out',
  'and a caller with no session is refused by name'
);

-- ---------------------------------------------------------------------------
-- 5. The way IN: upsert_responder_profile honours the field it used to drop
-- ---------------------------------------------------------------------------
--
-- lifecycle_test has passed 'sms_opt_in', true in this payload since it was written, and the
-- function never read it -- the assertion passed because the COLUMN defaulted to true. With the
-- default false that silence would have meant nobody could ever opt in at signup.

select set_config('request.jwt.claims',
  json_build_object('sub', (select id from t where name = 'member'), 'role', 'authenticated')::text,
  true);

update responders set sms_opt_in = false
 where user_id = (select id from t where name = 'member');

select lives_ok(
  $$select public.upsert_responder_profile(jsonb_build_object(
      'first_name', 'Connie', 'lat', 29.76, 'lng', -95.37,
      'equipment', jsonb_build_array('winch'), 'sms_opt_in', true))$$,
  'editing the profile with consent in the payload is accepted'
);

select is(
  (select sms_opt_in from responders where user_id = (select id from t where name = 'member')),
  true,
  'and the payload field is HONOURED rather than silently dropped'
);

-- UPDATE treats an absent field as UNCHANGED. Editing a radius must not withdraw consent -- the
-- same reasoning as the phone coalesce this function already carried.
select lives_ok(
  $$select public.upsert_responder_profile(jsonb_build_object(
      'first_name', 'Connie', 'lat', 29.76, 'lng', -95.37,
      'equipment', jsonb_build_array('winch'), 'radius_miles', 60))$$,
  'editing something unrelated is accepted'
);

select is(
  (select sms_opt_in from responders where user_id = (select id from t where name = 'member')),
  true,
  'and consent survives it -- an omitted field is not a withdrawal'
);

select finish();
rollback;
