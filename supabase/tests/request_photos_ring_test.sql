-- Winch Up :: who may see a request's photographs
--
-- Run with:  supabase test db
--
-- A photograph of a stuck vehicle shows where it is and often whose it is. Until 2026-10-01 it
-- reached the requester and the ACCEPTED helper and nobody else; the owner's decision was to
-- widen that to members in the ring -- the people the dispatcher would call out anyway.
--
-- The authorisation rule IS the feature here, so every assertion below is about who is refused.
-- The near member proves it is not simply off; everybody else proves it is not simply on.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- ---------------------------------------------------------------------------
-- One request, and four members at carefully chosen distances
-- ---------------------------------------------------------------------------
--
-- Austin, and points roughly 5 and 40 miles away. The first ring is 10 miles.

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
)
select '00000000-0000-0000-0000-000000000000', v.id, 'authenticated', 'authenticated',
       v.email, 'x', now(), '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
from (values
  ('9000000a-0000-4000-8000-00000000000a'::uuid, 'ph-stuck@example.invalid'),
  ('9000000b-0000-4000-8000-00000000000a'::uuid, 'ph-near@example.invalid'),
  ('9000000c-0000-4000-8000-00000000000a'::uuid, 'ph-far@example.invalid'),
  ('9000000d-0000-4000-8000-00000000000a'::uuid, 'ph-unavailable@example.invalid'),
  ('9000000e-0000-4000-8000-00000000000a'::uuid, 'ph-stale@example.invalid')
) as v(id, email)
on conflict (id) do nothing;

update profiles set available_to_help = true
 where user_id in ('9000000b-0000-4000-8000-00000000000a',
                   '9000000c-0000-4000-8000-00000000000a',
                   '9000000e-0000-4000-8000-00000000000a');

-- Deliberately NOT available: the member who has said they are not up for a call-out.
update profiles set available_to_help = false
 where user_id = '9000000d-0000-4000-8000-00000000000a';

insert into responders (
  id, user_id, phone, first_name, home_location, last_location, last_location_at,
  radius_miles, equipment, approval, availability, recoveries_count
)
values
  -- ~5 miles from the request: inside the 10-mile first ring.
  ('a100000b-0000-4000-8000-00000000000b', '9000000b-0000-4000-8000-00000000000a', '+15125550301', 'Near',
   extensions.st_setsrid(extensions.st_point(-97.7431, 30.2672), 4326)::extensions.geography,
   extensions.st_setsrid(extensions.st_point(-97.8300, 30.3100), 4326)::extensions.geography,
   now(), 60, '{winch}', 'approved', 'active', 0),
  -- ~40 miles away: outside it.
  ('a100000c-0000-4000-8000-00000000000b', '9000000c-0000-4000-8000-00000000000a', '+15125550302', 'Far',
   extensions.st_setsrid(extensions.st_point(-98.2000, 30.2672), 4326)::extensions.geography,
   extensions.st_setsrid(extensions.st_point(-98.2000, 30.2672), 4326)::extensions.geography,
   now(), 60, '{winch}', 'approved', 'active', 0),
  -- Near, but not available to help.
  ('a100000d-0000-4000-8000-00000000000b', '9000000d-0000-4000-8000-00000000000a', '+15125550303', 'Unavailable',
   extensions.st_setsrid(extensions.st_point(-97.8300, 30.3100), 4326)::extensions.geography,
   extensions.st_setsrid(extensions.st_point(-97.8300, 30.3100), 4326)::extensions.geography,
   now(), 60, '{winch}', 'approved', 'active', 0),
  -- Near, available, but the position is older than the freshness window and HOME is far.
  ('a100000e-0000-4000-8000-00000000000b', '9000000e-0000-4000-8000-00000000000a', '+15125550304', 'Stale',
   extensions.st_setsrid(extensions.st_point(-98.2000, 30.2672), 4326)::extensions.geography,
   extensions.st_setsrid(extensions.st_point(-97.8300, 30.3100), 4326)::extensions.geography,
   now() - interval '10 hours', 60, '{winch}', 'approved', 'active', 0)
on conflict (id) do nothing;

insert into requests (
  id, requester_user_id, requester_name, requester_phone, location, vehicle_class, stuck_type,
  land_type, needs_tractor, status, current_ring, emergency_ack_at, rules_accepted,
  waiver_id, waiver_accepted_at
) values (
  'c1000001-0000-4000-8000-00000000000c', '9000000a-0000-4000-8000-00000000000a', 'Stuck', '+15125550300',
  extensions.st_setsrid(extensions.st_point(-97.7431, 30.2672), 4326)::extensions.geography,
  'truck', 'mud', 'public', false, 'dispatching', 1, now(), true,
  (select id from waivers where slug = 'requester_waiver' and is_current), now()
);

insert into request_photos (request_id, storage_path, content_type, bytes, width, height, sort_order)
values ('c1000001-0000-4000-8000-00000000000c', 'requests/c1000001/1.jpg', 'image/jpeg', 1000, 800, 600, 1);

-- ---------------------------------------------------------------------------
-- Who may, and who may not
-- ---------------------------------------------------------------------------

select ok(
  app.may_see_request_photos('c1000001-0000-4000-8000-00000000000c', '9000000b-0000-4000-8000-00000000000a'),
  'a member five miles away, available, with a fresh position: yes'
);

select ok(
  not app.may_see_request_photos('c1000001-0000-4000-8000-00000000000c', '9000000c-0000-4000-8000-00000000000a'),
  'forty miles away, outside the ten-mile ring: no'
);

select ok(
  app.may_see_request_photos('c1000001-0000-4000-8000-00000000000c', '9000000d-0000-4000-8000-00000000000a'),
  'close by and active: yes under universal membership'
);

select ok(
  not app.may_see_request_photos('c1000001-0000-4000-8000-00000000000c', '9000000e-0000-4000-8000-00000000000a'),
  'a stale position does not count as being nearby, and home is far'
);

select ok(
  not app.may_see_request_photos('c1000001-0000-4000-8000-00000000000c', '9000000a-0000-4000-8000-00000000000a'),
  'the requester does not read their own photographs through this door'
);

-- A MEMBER OWN RADIUS BINDS, not just the ring. The rule is least(ring, their own choice),
-- which is the same one the matcher uses -- somebody who said they will drive fifteen miles is
-- not called out to a recovery forty miles away just because the ring widened to sixty.
--
-- radius_miles is CHECKed to 15, 30 or 60, so this moves the ring out rather than the radius
-- in: ring 3 is sixty miles, the far member is about forty away, and their own fifteen is what
-- keeps them out.
update requests set current_ring = 3
 where id = 'c1000001-0000-4000-8000-00000000000c';

update responders set radius_miles = 15
 where id = 'a100000c-0000-4000-8000-00000000000b';

select ok(
  not app.may_see_request_photos('c1000001-0000-4000-8000-00000000000c', '9000000c-0000-4000-8000-00000000000a'),
  'the ring reaches sixty miles but the member chose fifteen, so forty miles away is still no'
);

-- Control: the same member, same distance, once they say they will travel sixty.
update responders set radius_miles = 60
 where id = 'a100000c-0000-4000-8000-00000000000b';

select ok(
  app.may_see_request_photos('c1000001-0000-4000-8000-00000000000c', '9000000c-0000-4000-8000-00000000000a'),
  'and yes once they do -- so it is their radius doing the work, not distance alone'
);

update requests set current_ring = 1
 where id = 'c1000001-0000-4000-8000-00000000000c';

-- A closed recovery stops being anybody's business.
update requests set status = 'recovered'
 where id = 'c1000001-0000-4000-8000-00000000000c';

select ok(
  not app.may_see_request_photos('c1000001-0000-4000-8000-00000000000c', '9000000b-0000-4000-8000-00000000000a'),
  'once the recovery is over, the photographs close with it'
);

update requests set status = 'dispatching'
 where id = 'c1000001-0000-4000-8000-00000000000c';

-- ---------------------------------------------------------------------------
-- The RPC on top of it
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims = '{"sub":"9000000b-0000-4000-8000-00000000000a","role":"authenticated"}';

select is(
  jsonb_array_length(public.request_photos_for_helper('c1000001-0000-4000-8000-00000000000c') -> 'paths'),
  1,
  'the near member gets the path'
);

set local request.jwt.claims = '{"sub":"9000000c-0000-4000-8000-00000000000a","role":"authenticated"}';

select is(
  public.request_photos_for_helper('c1000001-0000-4000-8000-00000000000c') ->> 'error',
  'not_found',
  'the far member is told not_found -- the same answer as a request that does not exist'
);

-- Which is the point: a refusal must not confirm that the id is a live recovery.
select is(
  public.request_photos_for_helper('c1000001-0000-4000-8000-0000000000ff') ->> 'error',
  'not_found',
  'and an invented id gets exactly the same answer'
);

set local request.jwt.claims = '';

select is(
  public.request_photos_for_helper('c1000001-0000-4000-8000-00000000000c') ->> 'error',
  'not_signed_in',
  'signed out gets nothing'
);

reset role;

select is(
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'request_photos_for_helper'
      and has_function_privilege('anon', p.oid, 'execute')),
  0::bigint,
  'anon cannot execute it'
);

select * from finish();
rollback;
