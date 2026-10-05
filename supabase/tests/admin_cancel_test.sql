-- Winch Up :: an admin can close a request, and the requester's path still works
--
-- Until 2026-10-05 `cancel_request_by_token` was the only way to cancel anything, so a request
-- filed and abandoned sat on the public board until the 24-hour expiry with nobody able to clear
-- it. This covers the new admin path AND re-covers the old one, because that function was rewired
-- to call the same shared core and "the admin button works" would be poor consolation for having
-- quietly broken the button a stranded driver uses.
--
-- The four things cancelling has to do: close the request, stand down the outstanding dispatches,
-- tell a volunteer who is already driving, and leave an audit trail. Each is asserted, because
-- each is a thing a second copy of this logic would have been free to forget.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

create temporary table t (name text primary key, id uuid not null);
insert into t (name, id) values
  ('admin', gen_random_uuid()), ('member', gen_random_uuid()),
  ('r_admin', gen_random_uuid()), ('r_token', gen_random_uuid()), ('r_closed', gen_random_uuid()),
  ('helper', gen_random_uuid());

insert into auth.users (id, email, created_at) values
  ((select id from t where name = 'admin'),  'cancel-admin@winchup.test',  now()),
  ((select id from t where name = 'member'), 'cancel-member@winchup.test', now());

insert into profiles (user_id, display_name) values
  ((select id from t where name = 'admin'),  'Cancel Admin'),
  ((select id from t where name = 'member'), 'Cancel Member')
on conflict (user_id) do nothing;

insert into user_roles (user_id, role)
values ((select id from t where name = 'admin'), 'admin')
on conflict do nothing;

-- A volunteer who will be mid-job on one of the requests.
insert into responders (
  id, phone, first_name, home_location, radius_miles, equipment,
  vehicle_class, drivetrain, approval, availability, is_test, sms_opt_in
) values (
  (select id from t where name = 'helper'), '+15125559201', 'Hal',
  extensions.st_setsrid(extensions.st_point(-95.37, 29.76), 4326)::extensions.geography,
  30, '{winch}'::equipment_type[], 'truck', '4wd', 'approved', 'active', true, true
);

insert into requests (
  id, requester_name, requester_phone, location, vehicle_class, stuck_type, land_type,
  status, emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at
)
select v.id, v.nm, v.phone,
       extensions.st_setsrid(extensions.st_point(-95.37, 29.76), 4326)::extensions.geography,
       'truck', 'mud', 'public', 'dispatching', now(), true,
       (select id from waivers where slug = 'requester_waiver' and is_current), now()
from (values
  ((select id from t where name = 'r_admin'),  'Admin Cancels', '+15125557201'),
  ((select id from t where name = 'r_token'),  'Token Cancels', '+15125557202'),
  ((select id from t where name = 'r_closed'), 'Already Done',  '+15125557203')
) as v(id, nm, phone);

-- An outstanding offer on the admin-cancelled one, and a volunteer already accepted.
insert into dispatches (request_id, responder_id, ring, distance_miles, state)
values ((select id from t where name = 'r_admin'), (select id from t where name = 'helper'),
        1, 2.0, 'sent');

update requests
   set accepted_responder_id = (select id from t where name = 'helper'), status = 'accepted'
 where id = (select id from t where name = 'r_admin');

-- ---------------------------------------------------------------------------
-- Who may do it
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims',
  json_build_object('sub', (select id from t where name = 'member'), 'role', 'authenticated')::text,
  true);

select throws_ok(
  format('select public.admin_cancel_request(%L)', (select id from t where name = 'r_admin')),
  null, null,
  'an ordinary member cannot cancel somebody else''s recovery'
);

select is(
  (select status::text from requests where id = (select id from t where name = 'r_admin')),
  'accepted',
  'and the refusal left it alone, rather than failing after the write'
);

select set_config('request.jwt.claims',
  json_build_object('sub', (select id from t where name = 'admin'), 'role', 'authenticated')::text,
  true);

select is(
  (public.admin_cancel_request((select id from t where name = 'r_admin'), 'test recovery') ->> 'ok')::boolean,
  true,
  'an admin can -- the inclusion that makes the refusal above mean something'
);

-- ---------------------------------------------------------------------------
-- The four things cancelling has to do
-- ---------------------------------------------------------------------------

select is(
  (select status::text from requests where id = (select id from t where name = 'r_admin')),
  'cancelled',
  '1. the request is closed'
);

select is(
  (select cancel_reason from requests where id = (select id from t where name = 'r_admin')),
  'test recovery',
  'with the reason recorded, so "why did this vanish from the board" has an answer'
);

select is(
  (select next_action_at from requests where id = (select id from t where name = 'r_admin')),
  null,
  'and the tick will not look at it again'
);

select is(
  (select count(*)::int from dispatches
    where request_id = (select id from t where name = 'r_admin')
      and state in ('queued', 'sent', 'delivered')),
  0,
  '2. the outstanding offers are stood down'
);

select is(
  (select count(*)::int from sms_messages
    where request_id = (select id from t where name = 'r_admin')
      and template_key = 'responder.job_cancelled'),
  1,
  '3. the volunteer who was already driving is told'
);

select is(
  (select count(*)::int from audit_log
    where action = 'request.cancelled'
      and entity_id = (select id::text from t where name = 'r_admin')),
  1,
  '4. an audit row is written, like every other mutating admin action'
);

-- ---------------------------------------------------------------------------
-- A refusal is not an administrative act
-- ---------------------------------------------------------------------------

select is(
  public.admin_cancel_request((select id from t where name = 'r_admin')) ->> 'error',
  'already_closed',
  'cancelling a closed request is refused rather than silently repeated'
);

select is(
  (select count(*)::int from audit_log
    where action = 'request.cancelled'
      and entity_id = (select id::text from t where name = 'r_admin')),
  1,
  'and the refusal writes NO second audit row -- logging those would bury the real ones'
);

select is(
  public.admin_cancel_request('00000000-0000-0000-0000-000000000000'::uuid) ->> 'error',
  'not_found',
  'a request that does not exist is named as such'
);

-- ---------------------------------------------------------------------------
-- THE REGRESSION GUARD. The requester's own path was rewired through the same core.
-- ---------------------------------------------------------------------------

select is(
  (public.cancel_request_by_token(
     (select public_token from requests where id = (select id from t where name = 'r_token')),
     'changed my mind') ->> 'ok')::boolean,
  true,
  'the requester can still cancel with their token'
);

select is(
  (select status::text from requests where id = (select id from t where name = 'r_token')),
  'cancelled',
  'and it really closes -- the path everybody already uses still works'
);

select is(
  (select cancel_reason from requests where id = (select id from t where name = 'r_token')),
  'changed my mind',
  'with their reason, not an admin''s'
);

select is(
  public.cancel_request_by_token('no-such-token-at-all') ->> 'error',
  'not_found',
  'and a bad token is still refused'
);

select is(
  (select count(*)::int from audit_log
    where action = 'request.cancelled'
      and entity_id = (select id::text from t where name = 'r_token')),
  0,
  'a requester cancelling their own recovery is not an ADMIN action and writes no audit row'
);

select finish();
rollback;
