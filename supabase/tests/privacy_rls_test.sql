-- Winch Up :: proof that phones and exact pins stay private
--
-- Run with:  supabase test db
-- Depends on supabase/seeds/demo.sql having been loaded (supabase db reset does this).
--
-- The rule these tests defend: a requester's phone number and exact location are visible to
-- nobody except the volunteer who actually accepted the job, and to admins through an explicit
-- admin RPC. If any of these fail, do not deploy.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- ---------------------------------------------------------------------------
-- 0. Fixtures are present
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int from requests where id::text like '22222222%'), 5,
  'demo requests are loaded (run: supabase db reset)'
);

-- ---------------------------------------------------------------------------
-- 1. RLS is on for every table in public
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int
     from pg_tables t
     join pg_class c on c.relname = t.tablename and c.relnamespace = 'public'::regnamespace
    where t.schemaname = 'public' and not c.relrowsecurity),
  0,
  'every table in public has row level security enabled'
);

-- ---------------------------------------------------------------------------
-- 2. Table-level privileges: anon touches almost nothing
-- ---------------------------------------------------------------------------

select ok(not has_table_privilege('anon', 'requests', 'SELECT'),
  'anon has no SELECT on requests');
select ok(not has_table_privilege('anon', 'responders', 'SELECT'),
  'anon has no SELECT on responders');
select ok(not has_table_privilege('anon', 'dispatches', 'SELECT'),
  'anon has no SELECT on dispatches');
select ok(not has_table_privilege('anon', 'sms_messages', 'SELECT'),
  'anon has no SELECT on sms_messages');
select ok(not has_table_privilege('anon', 'audit_log', 'SELECT'),
  'anon has no SELECT on audit_log');
select ok(not has_table_privilege('anon', 'blocklist', 'SELECT'),
  'anon has no SELECT on blocklist');
select ok(not has_table_privilege('authenticated', 'blocklist', 'SELECT'),
  'authenticated has no SELECT on blocklist');
select ok(not has_table_privilege('authenticated', 'rate_limit_hits', 'SELECT'),
  'authenticated has no SELECT on rate_limit_hits');
select ok(has_table_privilege('anon', 'pro_options', 'SELECT'),
  'anon can read the paid-options list');

-- ---------------------------------------------------------------------------
-- 3. Column-level privileges: the private columns do not exist for the app roles
--    (defence in depth: even a wrong RLS policy cannot leak these)
-- ---------------------------------------------------------------------------

select ok(not has_column_privilege('authenticated', 'requests', 'requester_phone', 'SELECT'),
  'authenticated cannot select requests.requester_phone');
select ok(not has_column_privilege('authenticated', 'requests', 'requester_name', 'SELECT'),
  'authenticated cannot select requests.requester_name');
select ok(not has_column_privilege('authenticated', 'requests', 'location', 'SELECT'),
  'authenticated cannot select the exact pin');
select ok(not has_column_privilege('authenticated', 'requests', 'public_token', 'SELECT'),
  'authenticated cannot select the requester status-page token');
select ok(not has_column_privilege('authenticated', 'requests', 'created_ip', 'SELECT'),
  'authenticated cannot select requester IP addresses');
select ok(has_column_privilege('authenticated', 'requests', 'approx_location', 'SELECT'),
  'authenticated can select the blurred pin');

-- A volunteer must not be able to approve themselves.
select ok(not has_column_privilege('authenticated', 'responders', 'approval', 'UPDATE'),
  'a responder cannot update their own approval state');
select ok(not has_column_privilege('authenticated', 'responders', 'recoveries_count', 'UPDATE'),
  'a responder cannot inflate their own recovery count');
select ok(has_column_privilege('authenticated', 'responders', 'availability', 'UPDATE'),
  'a responder can pause themselves');

-- ---------------------------------------------------------------------------
-- 4. The blurred pin really is blurred, and stable
-- ---------------------------------------------------------------------------

select ok(
  (select min(st_distance(location, approx_location)) from requests where id::text like '22222222%') > 700,
  'every demo request is blurred by at least 700 m'
);

select ok(
  (select max(st_distance(location, approx_location)) from requests where id::text like '22222222%') < 1800,
  'the blur stays inside roughly one mile, so the board is still useful'
);

select is(
  (select count(*)::int from requests
    where id::text like '22222222%'
      and st_distance(approx_location, app.blur_point(location, id)) > 0.01),
  0,
  'the blurred pin is deterministic: it does not move between page loads'
);

-- ---------------------------------------------------------------------------
-- 5. Anonymous: the public board leaks nothing
-- ---------------------------------------------------------------------------

set local role anon;

select ok(
  (select count(*) from board_requests(100)) > 0,
  'anon can read the public board'
);

select is(
  (select count(*)::int from board_requests(100) where not is_approximate),
  0,
  'every pin on the public board is flagged approximate by default'
);

select throws_ok(
  'select requester_phone from public.requests limit 1',
  '42501',
  null,
  'anon selecting requester_phone is refused outright'
);

select throws_ok(
  'select * from public.responders limit 1',
  '42501',
  null,
  'anon cannot read the volunteer roster'
);

reset role;

-- The board coordinates are not the real ones.
select is(
  (select count(*)::int
     from board_requests(100) b
     join requests r on r.short_code = b.short_code
    where abs(b.lat - st_y(r.location::geometry)) < 0.0001
      and abs(b.lng - st_x(r.location::geometry)) < 0.0001),
  0,
  'no board row exposes the real coordinates'
);

-- ---------------------------------------------------------------------------
-- 6. Requester status page: the responder phone appears only after acceptance
-- ---------------------------------------------------------------------------

set local role anon;

select is(
  get_request_by_token('demo-ring2-token-bbbbbb') -> 'responder',
  'null'::jsonb,
  'while volunteers are still being notified, no responder details are exposed'
);

select isnt(
  get_request_by_token('demo-accepted-token-cccccc') #> '{responder,phone}',
  null::jsonb,
  'once a volunteer accepts, the requester gets their phone number'
);

select is(
  get_request_by_token('demo-accepted-token-cccccc') #>> '{responder,first_name}',
  'Bobby',
  'the requester sees the responder first name'
);

select is(
  get_request_by_token('demo-accepted-token-cccccc') #> '{responder,last_name}',
  null::jsonb,
  'the responder surname is never sent to the requester'
);

select is(
  get_request_by_token('not-a-real-token-at-all'),
  null::jsonb,
  'a bad token returns nothing rather than an error that confirms existence'
);

select isnt(
  get_request_by_token('demo-unmatched-token-dddddd') -> 'pro_options',
  null::jsonb,
  'an unmatched request offers paid recovery options'
);

reset role;

-- ---------------------------------------------------------------------------
-- 7. Volunteers see only what they have been offered
-- ---------------------------------------------------------------------------

-- Mike: approved, was dispatched to demo request 2, never offered request 1.
set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated"}';

select is(
  (select count(*)::int from requests where id = '22222222-2222-4222-8222-000000000001'),
  0,
  'a volunteer cannot see a request they were never dispatched to'
);

select is(
  (select count(*)::int from requests where id = '22222222-2222-4222-8222-000000000002'),
  1,
  'a volunteer can see a request they were dispatched to'
);

select is(
  (select count(*)::int from responders),
  1,
  'a volunteer sees only their own responder row, not the roster'
);

select is(
  (select count(*)::int from dispatches where responder_id <> app.current_responder_id()),
  0,
  'a volunteer cannot see other volunteers dispatch rows'
);

select is(
  (select count(*)::int from sms_messages),
  0,
  'a volunteer cannot read the SMS log'
);

-- Dispatched, but not the accepted responder: no contact details.
select is(
  get_job_contact('22222222-2222-4222-8222-000000000002'),
  null::jsonb,
  'being notified about a job does not release the requester phone'
);

select is(
  get_job_contact('22222222-2222-4222-8222-000000000003'),
  null::jsonb,
  'a volunteer cannot pull contact details for someone else accepted job'
);

-- Their own feed shows the blurred pin for jobs that are not theirs.
select is(
  (select count(*)::int from responder_feed() where not is_approximate and not is_mine),
  0,
  'the volunteer feed only sharpens the pin on jobs the volunteer actually took'
);

reset role;

-- Bobby accepted demo request 3. He is the one person who gets the phone.
-- (Bobby has no auth user in the demo seed, so assert through the responder id directly.)
select is(
  (select r.requester_phone from requests r where r.id = '22222222-2222-4222-8222-000000000003'),
  '+14095550203',
  'the phone is on the row for the service role, which is what the SMS sender uses'
);

select is(
  (select r.accepted_responder_id from requests r where r.id = '22222222-2222-4222-8222-000000000003'),
  '11111111-1111-4111-8111-000000000007'::uuid,
  'demo request 3 is accepted by Bobby'
);

-- ---------------------------------------------------------------------------
-- 8. Pending volunteers are inert
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000000004","role":"authenticated"}';

select is(
  (select count(*)::int from requests),
  0,
  'a volunteer awaiting approval sees no requests at all'
);

select is(
  (select count(*)::int from responder_feed()),
  0,
  'a volunteer awaiting approval has an empty feed'
);

reset role;

-- ---------------------------------------------------------------------------
-- 9. Admin RPC is gated on the admin role, not just on being logged in
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated"}';

select throws_ok(
  $$select public.admin_request_detail('22222222-2222-4222-8222-000000000003')$$,
  '42501',
  null,
  'a non-admin calling the admin detail RPC is refused'
);

set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}';

select isnt(
  admin_request_detail('22222222-2222-4222-8222-000000000003') ->> 'requester_phone',
  null::text,
  'an admin can retrieve the requester phone through the admin RPC'
);

select is(
  admin_request_detail('22222222-2222-4222-8222-000000000003') -> 'location',
  null::jsonb,
  'the admin RPC returns lat/lng, not a raw geography blob'
);

reset role;

-- ---------------------------------------------------------------------------
-- 10. Public free-text fields reject phone numbers and links
-- ---------------------------------------------------------------------------

select ok(contains_contact_info('call me at 281-555-0123'),
  'a dashed phone number is caught');
select ok(contains_contact_info('713.555.0199'),
  'a dotted phone number is caught');
select ok(contains_contact_info('(936) 555 0188'),
  'a parenthesised phone number is caught');
select ok(contains_contact_info('see texasrecovery.com/help'),
  'a bare domain is caught');
select ok(contains_contact_info('https://example.org/x'),
  'an explicit URL is caught');
select ok(not contains_contact_info('stuck past the FM 1097 bridge, 200 yards in'),
  'ordinary road directions are not false positives');

select throws_ok(
  $$update public.requests
       set notes = 'call 281-555-0170'
     where id = '22222222-2222-4222-8222-000000000001'$$,
  '23514',
  null,
  'a phone number cannot be smuggled into the public notes field'
);

-- ---------------------------------------------------------------------------
-- 11. Identifiers handed out over SMS are immutable
-- ---------------------------------------------------------------------------

select throws_ok(
  $$update public.requests
       set public_token = 'something-else-entirely'
     where id = '22222222-2222-4222-8222-000000000001'$$,
  'P0001',
  'requests.public_token is immutable',
  'the status-page token cannot be changed after it has been texted out'
);

-- ---------------------------------------------------------------------------
-- 12. Blocked numbers cannot open new requests
-- ---------------------------------------------------------------------------

insert into blocklist (phone, reason) values ('+17135559999', 'test');

select throws_ok(
  $$insert into public.requests (
      requester_name, requester_phone, location, vehicle_class, stuck_type, land_type,
      emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at
    ) values (
      'Blocked Person', '+17135559999',
      extensions.st_setsrid(extensions.st_point(-95.4, 30.5), 4326)::extensions.geography,
      'truck', 'mud', 'public', now(), true,
      (select id from public.waivers where slug = 'requester_waiver' and is_current), now()
    )$$,
  '23514',
  null,
  'a blocked phone number cannot create a request'
);

select * from finish();

rollback;
