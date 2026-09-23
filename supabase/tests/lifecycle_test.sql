-- Winch Up :: one recovery, all the way through
--
-- Run with:  supabase test db
--
-- Every other suite in this directory tests one thing in isolation: can a stranger read the
-- thread, does the enum refuse this value, does the index stop that race. This one does the
-- opposite. It walks a single recovery from an account that does not exist yet to a thank-you
-- note, in order, through the same functions the app calls, and checks the state after each
-- step.
--
-- That is the gap CLAUDE.md has admitted since Phase 15 was first written down: unit coverage,
-- component coverage and browser coverage all existed, and nothing joined them up. A suite that
-- proves each transition works says nothing about whether they work in sequence -- and in a
-- dispatcher, sequence is the entire product.
--
-- The sixteen steps below are the ones the phase asks for, in its order, with its names.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- A known starting point, as in the other suites that count things.
delete from sms_messages;
delete from notification_deliveries;
delete from notifications;

-- ---------------------------------------------------------------------------
-- 1. Register account
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, phone, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
)
select '00000000-0000-0000-0000-000000000000', v.id, 'authenticated', 'authenticated',
       v.email, v.phone, 'x', null, '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
from (values
  ('11110000-0000-4000-8000-00000000cafe'::uuid, 'lc-driver@example.invalid', '+15125557801'),
  ('22220000-0000-4000-8000-00000000cafe'::uuid, 'lc-volunteer@example.invalid', '+15125557802'),
  ('33330000-0000-4000-8000-00000000cafe'::uuid, 'lc-admin@example.invalid', '+15125557803')
) as v(id, email, phone);

select ok(
  exists (select 1 from profiles where user_id = '11110000-0000-4000-8000-00000000cafe'),
  'step 1: registering an account creates the profile that hangs off it'
);

insert into user_roles (user_id, role)
values ('33330000-0000-4000-8000-00000000cafe', 'admin') on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 2. Verify account
-- ---------------------------------------------------------------------------

-- The phone half matters as much as the email half: upsert_responder_profile reads the number
-- off the verified account rather than off the form, and refuses with no_verified_phone if it
-- has not been confirmed. Somebody cannot become a volunteer on a number they do not hold.
update auth.users
   set email_confirmed_at = now(), phone_confirmed_at = now()
 where id in ('11110000-0000-4000-8000-00000000cafe', '22220000-0000-4000-8000-00000000cafe');

select is(
  (select count(*)::integer from auth.users
    where id in ('11110000-0000-4000-8000-00000000cafe', '22220000-0000-4000-8000-00000000cafe')
      and email_confirmed_at is not null and phone_confirmed_at is not null),
  2,
  'step 2: both accounts are verified, by email and by phone'
);

-- ---------------------------------------------------------------------------
-- 3 and 4. Create a vehicle, and put recovery equipment on it
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"22220000-0000-4000-8000-00000000cafe","role":"authenticated","phone":"15125557802"}';

insert into vehicles (user_id, make, model, year, vehicle_class, drivetrain,
                      has_winch, equipment, is_primary)
values ('22220000-0000-4000-8000-00000000cafe', 'Ford', 'F-250', 2019, 'truck', '4wd',
        true, '{winch,kinetic_rope,traction_boards}', true);

select is(
  (select make || ' ' || model from vehicles
    where user_id = '22220000-0000-4000-8000-00000000cafe'),
  'Ford F-250',
  'step 3: a volunteer registers their rig, through row level security as themselves'
);

select ok(
  (select equipment @> '{winch}'::equipment_type[] from vehicles
    where user_id = '22220000-0000-4000-8000-00000000cafe'),
  'step 4: with the recovery equipment it actually carries'
);

-- ---------------------------------------------------------------------------
-- 5. Enable volunteer availability
--
-- There is no volunteer registration any more and no approval to wait for. A member fills in
-- where they are and what they carry, turns on Available to Help, and from that moment the
-- dispatcher can reach them. `approval` still exists and is still 'pending' below -- it is the
-- verification badge now, not a gate -- and the assertions here exist to prove it does not block
-- anything.
--
-- The number on the profile comes from the verified OTP claim in the session, never from the
-- form -- otherwise anybody could claim anybody's number. That is why the JWT above carries a
-- phone claim, and why this step fails with no_verified_phone without one.
-- ---------------------------------------------------------------------------

select is(
  public.upsert_responder_profile(jsonb_build_object(
    'first_name', 'Mike',
    'lat', 30.2700, 'lng', -97.7400,
    'radius_miles', 30,
    'equipment', jsonb_build_array('winch', 'kinetic_rope'),
    'sms_opt_in', true)) ->> 'ok',
  'true',
  'step 5: the volunteer fills in their profile'
);

select is(
  (select approval::text from responders where user_id = '22220000-0000-4000-8000-00000000cafe'),
  'pending',
  'and is still unverified, which no longer stops them helping anybody'
);

-- The switch that replaced the approval gate. It is the member's own decision and it defaults
-- off, so this line is what makes them reachable -- not an admin, and not signing up.
select is(
  public.set_available_to_help(true) ->> 'ok',
  'true',
  'they turn on Available to Help'
);

reset role;
create temp table lc as
  select (select id from responders where user_id = '22220000-0000-4000-8000-00000000cafe') as responder_id;
grant select on lc to public;

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"33330000-0000-4000-8000-00000000cafe","role":"authenticated","aal":"aal2"}';

-- An admin verifies them. This is deliberately NOT on the critical path any more: everything
-- below would work identically without it, and the test would still pass. It stays because the
-- badge it sets is the only remaining signal separating a checked volunteer from an account
-- created five minutes ago, and a verification nobody exercises is a verification that quietly
-- rots.
select is(
  public.admin_set_responder_approval((select responder_id from lc), 'approved', null) ->> 'ok',
  'true',
  'an admin verifies them -- a badge now, not a gate'
);

set local request.jwt.claims =
  '{"sub":"22220000-0000-4000-8000-00000000cafe","role":"authenticated","phone":"15125557802"}';

select is(public.set_my_availability('active') ->> 'ok', 'true',
  'and the volunteer marks themselves available');

-- ---------------------------------------------------------------------------
-- 6 and 7. Create a recovery request, and check it persisted
-- ---------------------------------------------------------------------------

reset role;

select ok(
  (public.create_request(jsonb_build_object(
     'name', 'Dana', 'phone', '+15125557801',
     'lat', 30.2750, 'lng', -97.7450,
     'vehicle_class', 'truck', 'stuck_type', 'mud', 'stuck_depth', 'frame',
     'land_type', 'public', 'locale', 'en',
     'requester_user_id', '11110000-0000-4000-8000-00000000cafe',
     'equipment', jsonb_build_array('winch')),
     'https://www.winch-up.com') ->> 'ok')::boolean,
  'step 6: somebody files a recovery request about half a mile from the volunteer'
);

reset role;
drop table lc;
create temp table lc as
  select r.id as request_id, r.public_token, r.short_code,
         (select id from responders where user_id = '22220000-0000-4000-8000-00000000cafe') as responder_id
    from requests r
   where r.requester_user_id = '11110000-0000-4000-8000-00000000cafe';
grant select on lc to public;

select is(
  (select status::text from requests where id = (select request_id from lc)),
  'submitted',
  'step 7: it persisted, and starts submitted'
);

select ok(
  (select length(public_token) > 10 and short_code is not null from lc),
  'with the unguessable link and the short code the texts quote'
);

-- ---------------------------------------------------------------------------
-- 8. Match nearby eligible volunteers
-- ---------------------------------------------------------------------------

select ok(
  (public.advance_dispatch(50) ->> 'processed')::integer >= 1,
  'step 8: the tick runs and picks the request up'
);

select is(
  (select count(*)::integer from dispatches where request_id = (select request_id from lc)),
  1,
  'and matches the one volunteer who is close enough, approved, active and carrying a winch'
);

select is(
  (select status::text from requests where id = (select request_id from lc)),
  'dispatching',
  'the request moves to dispatching'
);

-- ---------------------------------------------------------------------------
-- 9. Send notifications
-- ---------------------------------------------------------------------------

select ok(
  exists (select 1 from sms_messages where request_id = (select request_id from lc)
           and template_key like 'responder%'),
  'step 9: a text is queued for the volunteer'
);

select ok(
  exists (select 1 from sms_messages where request_id = (select request_id from lc)
           and template_key like 'requester%'),
  'and one for the person who is stuck, with their status link'
);

select ok(
  exists (select 1 from notifications
           where user_id = '22220000-0000-4000-8000-00000000cafe'
             and kind = 'recovery_request'),
  'and the volunteer has it in the app as well, without being texted twice'
);

-- ---------------------------------------------------------------------------
-- 10 and 11. Submit a volunteer offer, and the requester accepts it
--
-- This is the step the phase changed. The volunteer used to take the job -- first reply won.
-- Now they offer, and the person who is stuck decides who comes out. Two actors, two calls, and
-- a state in between where somebody has volunteered and nobody is committed.
-- ---------------------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"22220000-0000-4000-8000-00000000cafe","role":"authenticated","phone":"15125557802"}';

select is(
  public.offer_assistance((select request_id from lc), 'Winch and straps aboard', 40, true) ->> 'state',
  'offered',
  'step 10: the volunteer offers, and says forty minutes'
);

-- Nothing is settled yet. If this ever comes back non-null, something is assigning people again
-- without asking the requester.
select is(
  (select accepted_responder_id from requests where id = (select request_id from lc)),
  null,
  'and nobody is assigned by offering'
);

-- The requester decides. Service-role, because the real caller is a server action holding the
-- token -- the same path every other by_token write takes.
reset role;

select is(
  public.accept_offer_by_token(
    (select public_token from lc),
    (select id from dispatches
      where request_id = (select request_id from lc)
        and responder_id = (select responder_id from lc))
  ) ->> 'ok',
  'true',
  'step 11: the person who is stuck picks them'
);

select is(
  (select status::text from requests where id = (select request_id from lc)),
  'accepted',
  'the request is accepted'
);

select is(
  (select accepted_responder_id from requests where id = (select request_id from lc)),
  (select responder_id from lc),
  'by that volunteer and nobody else'
);

select is(
  (select eta_minutes::integer from requests where id = (select request_id from lc)),
  40,
  'and the ETA they gave is what the requester will see'
);

-- ---------------------------------------------------------------------------
-- 12. Open the recovery conversation
-- ---------------------------------------------------------------------------

select is(
  public.send_request_message(jsonb_build_object(
    'request_id', (select request_id from lc),
    'body', 'On my way. White F-250, about forty minutes.')) ->> 'ok',
  'true',
  'step 12: the volunteer opens the conversation'
);

set local request.jwt.claims =
  '{"sub":"11110000-0000-4000-8000-00000000cafe","role":"authenticated"}';

select is(
  jsonb_array_length(public.request_thread((select request_id from lc)) -> 'messages'),
  1,
  'and the person who is stuck can read it'
);

select is(
  public.send_request_message(jsonb_build_object(
    'request_id', (select request_id from lc),
    'body', 'Second gate past the cattle guard. Blue Tacoma.')) ->> 'ok',
  'true',
  'and answer'
);

-- Nobody else can, at any point in this.
set local request.jwt.claims =
  '{"sub":"33330000-0000-4000-8000-00000000cafe","role":"authenticated","aal":"aal2"}';

select is(
  public.request_thread((select request_id from lc)) ->> 'error',
  'not_found',
  'while an admin -- an admin -- still cannot read two people private conversation'
);

-- ---------------------------------------------------------------------------
-- 13. Update recovery status
-- ---------------------------------------------------------------------------

set local request.jwt.claims =
  '{"sub":"22220000-0000-4000-8000-00000000cafe","role":"authenticated","phone":"15125557802"}';

select is(
  public.report_on_site((select request_id from lc)) ->> 'ok',
  'true',
  'step 13: the volunteer says they have arrived'
);

select is(
  (select status::text from requests where id = (select request_id from lc)),
  'on_site',
  'and the status follows'
);

-- ---------------------------------------------------------------------------
-- 14. Complete the request
-- ---------------------------------------------------------------------------

select is(
  public.report_complete((select request_id from lc)) ->> 'ok',
  'true',
  'step 14: they pull the truck out and mark it done'
);

select is(
  (select status::text from requests where id = (select request_id from lc)),
  'recovered',
  'the recovery is finished'
);

-- ---------------------------------------------------------------------------
-- 15. Submit feedback
--
-- Through the token, not an account: by now the person may be on somebody else phone.
-- ---------------------------------------------------------------------------

reset role;

select is(
  public.thank_responder_by_token(
    (select public_token from lc),
    'Thank you, you saved my weekend.') ->> 'ok',
  'true',
  'step 15: the thank-you goes through the status link, not a sign-in'
);

select ok(
  exists (select 1 from sms_messages where request_id = (select request_id from lc)
           and template_key like '%thank%'),
  'and reaches the volunteer as a text'
);

-- ---------------------------------------------------------------------------
-- 16. Verify recovery history
-- ---------------------------------------------------------------------------

select ok(
  (select count(*) from request_events where request_id = (select request_id from lc)) >= 5,
  'step 16: the whole thing is written down as events, in order'
);

select bag_has(
  $$select event_type::text from request_events
     where request_id = (select request_id from lc)$$,
  $$values ('created'), ('accepted'), ('on_site'), ('recovered'), ('thanked')$$,
  'including every step somebody would want to see afterwards'
);

select is(
  (select status::text from requests where id = (select request_id from lc)),
  'recovered',
  'and the recovery stands in the volunteer history as finished'
);

-- ---------------------------------------------------------------------------
-- The error conditions that belong to the lifecycle rather than to one function
-- ---------------------------------------------------------------------------

-- Unauthorized access to a recovery. The token is the key; a wrong one is not a near miss.
select ok(
  public.get_request_by_token('not-a-real-token-at-all') is null,
  'error: a made-up status token opens nothing at all, with no error to probe'
);

select ok(
  public.get_request_by_token((select public_token from lc)) ->> 'id'
    = (select request_id::text from lc),
  'while the real one still opens the right recovery after the job is done'
);

-- Duplicate submission. The person is stuck and unsure the first one went through.
select ok(
  (public.create_request(jsonb_build_object(
     'name', 'Dana', 'phone', '+15125557801', 'lat', 30.2750, 'lng', -97.7450,
     'vehicle_class', 'truck', 'stuck_type', 'mud', 'land_type', 'public', 'locale', 'en',
     'requester_user_id', '11110000-0000-4000-8000-00000000cafe'),
     'https://www.winch-up.com') ->> 'ok')::boolean,
  'error: filing again after a finished recovery is allowed -- stuck twice is a real thing'
);

-- Requester cancels, mid-flight.
reset role;
create temp table lc2 as
  select r.id as request_id, r.public_token from requests r
   where r.requester_user_id = '11110000-0000-4000-8000-00000000cafe'
     and r.status not in ('recovered');
grant select on lc2 to public;

select is(
  public.cancel_request_by_token((select public_token from lc2), 'Got out on my own') ->> 'ok',
  'true',
  'error: the person who is stuck can cancel, and does not need an account to do it'
);

select is(
  (select status::text from requests where id = (select request_id from lc2)),
  'cancelled',
  'which stops the dispatcher working it'
);

-- No nearby volunteers: the same request, somewhere nobody covers.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
) values (
  '00000000-0000-0000-0000-000000000000', '44440000-0000-4000-8000-00000000cafe',
  'authenticated', 'authenticated', 'lc-remote@example.invalid', 'x', now(),
  '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
);

select ok(
  (public.create_request(jsonb_build_object(
     'name', 'Remote', 'phone', '+15125557804',
     'lat', 31.9000, 'lng', -102.3000,
     'vehicle_class', 'truck', 'stuck_type', 'sand', 'land_type', 'public', 'locale', 'en',
     'requester_user_id', '44440000-0000-4000-8000-00000000cafe'),
     'https://www.winch-up.com') ->> 'ok')::boolean,
  'error: a request comes in from four hundred miles away, where nobody has signed up'
);

select ok(
  (public.advance_dispatch(50) ->> 'processed')::integer >= 1,
  'the tick runs against it'
);

select is(
  (select count(*)::integer from dispatches d
     join requests r on r.id = d.request_id
    where r.requester_user_id = '44440000-0000-4000-8000-00000000cafe'),
  0,
  'and matches nobody, rather than texting somebody four hundred miles away'
);

select * from finish();
rollback;
