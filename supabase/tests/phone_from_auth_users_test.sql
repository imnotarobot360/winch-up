-- Winch Up :: a phone verified after sign-in still reaches the volunteer profile
--
-- upsert_responder_profile read the number from `auth.jwt() ->> 'phone'`, and a JWT is a snapshot
-- taken when the session was issued. Verify a phone mid-session and the token carries no phone
-- claim until it refreshes -- so the claim was null, the coalesce kept the existing null, and the
-- save reported success having written nothing. The member is left believing they are reachable
-- while the dispatcher has nothing to text, with no error on any screen.
--
-- That happened to the owner's own account on 2026-10-05, while they were the single volunteer on
-- call in production: account phone verified, volunteer profile empty, and the only way to see it
-- was a database query.
--
-- THE PROPERTY THAT MUST NOT MOVE is that the number never comes from the form. A browser-supplied
-- one would let anyone sign up as somebody else and be sent their recoveries. Three assertions
-- below exist only to hold that line.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

create temporary table t (name text primary key, id uuid not null);
insert into t (name, id) values
  ('confirmed', gen_random_uuid()),
  ('unconfirmed', gen_random_uuid()),
  ('nophone', gen_random_uuid());

-- Three accounts differing only in what auth knows about their phone.
insert into auth.users (id, email, phone, phone_confirmed_at, created_at) values
  ((select id from t where name = 'confirmed'),   'conf@winchup.test',   '+15125553001', now(), now()),
  ((select id from t where name = 'unconfirmed'), 'unconf@winchup.test', '+15125553002', null,  now()),
  ((select id from t where name = 'nophone'),     'nophone@winchup.test', null,          null,  now());

insert into profiles (user_id, display_name)
select id, name from t
on conflict (user_id) do nothing;

create temporary table payload as
select jsonb_build_object(
         'first_name', 'Pat',
         'lat', 29.76, 'lng', -95.37,
         'equipment', jsonb_build_array('winch')
       ) as p;

-- ---------------------------------------------------------------------------
-- 1. The case that was broken: no claim in the token, a confirmed phone on the account
-- ---------------------------------------------------------------------------
--
-- claims carry `sub` and NO `phone`, which is exactly a session issued before the verification.

select set_config('request.jwt.claims',
  json_build_object('sub', (select id from t where name = 'confirmed'), 'role', 'authenticated')::text,
  true);

select is(
  (public.upsert_responder_profile((select p from payload)) ->> 'ok')::boolean,
  true,
  'saving the volunteer profile succeeds with a stale token'
);

select is(
  (select phone from responders where user_id = (select id from t where name = 'confirmed')),
  '+15125553001',
  'and the CONFIRMED phone from auth.users is written -- the save no longer silently writes nothing'
);

-- ---------------------------------------------------------------------------
-- 2. THE LINE THAT MUST NOT MOVE. An unconfirmed number is not a verified one.
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  json_build_object('sub', (select id from t where name = 'unconfirmed'), 'role', 'authenticated')::text,
  true);

select lives_ok(
  'select public.upsert_responder_profile((select p from payload))',
  'somebody with an unconfirmed number can still save a profile'
);

select is(
  (select phone from responders where user_id = (select id from t where name = 'unconfirmed')),
  null,
  'but NO phone is written -- an unverified number is worse than none, because a volunteer would be calling a stranger'
);

-- ---------------------------------------------------------------------------
-- 3. No phone anywhere: refused at the door, and that rule is older than this change
-- ---------------------------------------------------------------------------
--
-- 20260928000800 reinstated "a new volunteer must have a verified number to get through it",
-- after 20260928000100 had made the phone optional. Pinned here because this migration touches
-- the very lines that decide it, and quietly reopening that door while fixing a stale-claim bug
-- would be a much larger change than the one being made.

select set_config('request.jwt.claims',
  json_build_object('sub', (select id from t where name = 'nophone'), 'role', 'authenticated')::text,
  true);

select is(
  public.upsert_responder_profile((select p from payload)) ->> 'error',
  'phone_required',
  'a brand-new volunteer with no verified number anywhere is refused, as it was before this change'
);

select is(
  (select count(*)::int from responders where user_id = (select id from t where name = 'nophone')),
  0,
  'and no half-made profile is left behind'
);

-- ---------------------------------------------------------------------------
-- 4. The claim still wins when it is there, and editing never blanks a number
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  json_build_object('sub', (select id from t where name = 'confirmed'),
                    'role', 'authenticated', 'phone', '15125559999')::text,
  true);

select is(
  (public.upsert_responder_profile((select p from payload)) ->> 'ok')::boolean,
  true,
  'saving with a phone claim present succeeds'
);

select is(
  (select phone from responders where user_id = (select id from t where name = 'confirmed')),
  '+15125559999',
  'and the claim is used -- it stays the primary source, the fallback only covers a stale token'
);

-- Back to a stale token, and the number already stored must survive.
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from t where name = 'confirmed'), 'role', 'authenticated')::text,
  true);

select lives_ok(
  'select public.upsert_responder_profile((select p from payload))',
  'editing the profile again from a session with no claim'
);

select isnt(
  (select phone from responders where user_id = (select id from t where name = 'confirmed')),
  null,
  'does not blank the stored number -- changing a radius must never cost somebody their phone'
);

select finish();
rollback;
