-- Winch Up :: dispatch state machine
--
-- Run with:  supabase test db
--
-- These are the transitions that decide whether a stranded driver gets help, so they are tested
-- against real rows rather than mocked. Time is moved by rewinding `dispatch_started_at` and
-- `next_action_at`, not by waiting.
--
-- Fixtures are built here rather than taken from the demo seed: a test that fails because
-- somebody edited seed data is a test nobody trusts.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- ---------------------------------------------------------------------------
-- Fixtures
--
-- One spot in Houston, and volunteers at known distances due north of it.
--   R1   5 mi   winch                      -> ring 1
--   R2  20 mi   winch                      -> ring 2
--   R3  45 mi   winch                      -> ring 3
--   R4   8 mi   winch + tractor            -> ring 1, and the only one for tractor jobs
--   R5  40 mi   winch, but only drives 15  -> never, their own radius rules them out
--   R6   6 mi   winch, awaiting approval   -> never
--   R7   6 mi   winch, paused              -> never
-- ---------------------------------------------------------------------------

create temporary table t_ids (name text primary key, id uuid not null);

-- Park everybody else first.
--
-- `supabase db reset` loads the demo seed into the same database, and one of those volunteers
-- lives at exactly the coordinates these fixtures use. Without this, ring counts depend on the
-- demo data — and on the time of day, since that volunteer has night calls switched off. The
-- rollback at the end puts them all back.
update responders set availability = 'paused'
 where id::text not like 'aaaa0001%';

insert into responders (
  id, phone, first_name, home_location, radius_miles, equipment,
  vehicle_class, drivetrain, approval, approved_at, availability, night_ok, is_test
) values
  ('aaaa0001-0000-4000-8000-000000000001', '+12813330001', 'Ringone',
   st_setsrid(st_point(-95.3698, 29.8329), 4326)::geography, 60, '{winch}',
   'truck', '4wd', 'approved', now(), 'active', true, true),
  ('aaaa0001-0000-4000-8000-000000000002', '+12813330002', 'Ringtwo',
   st_setsrid(st_point(-95.3698, 30.0504), 4326)::geography, 60, '{winch}',
   'truck', '4wd', 'approved', now(), 'active', true, true),
  ('aaaa0001-0000-4000-8000-000000000003', '+12813330003', 'Ringthree',
   st_setsrid(st_point(-95.3698, 30.4124), 4326)::geography, 60, '{winch}',
   'truck', '4wd', 'approved', now(), 'active', true, true),
  ('aaaa0001-0000-4000-8000-000000000004', '+12813330004', 'Tractorguy',
   st_setsrid(st_point(-95.3698, 29.8764), 4326)::geography, 60, '{winch,tractor}',
   'truck', '4wd', 'approved', now(), 'active', true, true),
  ('aaaa0001-0000-4000-8000-000000000005', '+12813330005', 'Homebody',
   st_setsrid(st_point(-95.3698, 30.3400), 4326)::geography, 15, '{winch}',
   'truck', '4wd', 'approved', now(), 'active', true, true),
  ('aaaa0001-0000-4000-8000-000000000006', '+12813330006', 'Waiting',
   st_setsrid(st_point(-95.3698, 29.8474), 4326)::geography, 60, '{winch}',
   'truck', '4wd', 'pending', null, 'active', true, true),
  ('aaaa0001-0000-4000-8000-000000000007', '+12813330007', 'Onbreak',
   st_setsrid(st_point(-95.3698, 29.8474), 4326)::geography, 60, '{winch}',
   'truck', '4wd', 'approved', now(), 'paused', true, true);

-- A request maker, so each scenario gets its own clean row.
create or replace function pg_temp.make_request(
  p_token text,
  p_needs_tractor boolean default false
)
returns uuid
language plpgsql
as $$
declare
  new_id uuid;
begin
  insert into public.requests (
    public_token, requester_name, requester_phone,
    location, location_source, vehicle_class, stuck_type, stuck_depth,
    needs_tractor, land_type, emergency_ack_at, rules_accepted,
    waiver_id, waiver_accepted_at, next_action_at, is_test
  ) values (
    p_token, 'Test Driver', '+17130000001',
    extensions.st_setsrid(extensions.st_point(-95.3698, 29.7604), 4326)::extensions.geography,
    'gps', 'truck', 'mud', 'frame',
    p_needs_tractor, 'public', now(), true,
    (select id from public.waivers where slug = 'requester_waiver' and is_current),
    now(), now(), true
  )
  returning id into new_id;

  return new_id;
end;
$$;

-- Wind a request back in time by the given number of minutes.
create or replace function pg_temp.rewind(p_request_id uuid, p_minutes integer)
returns void
language sql
as $$
  update public.requests
     set dispatch_started_at = dispatch_started_at - make_interval(mins => p_minutes),
         ring_started_at     = ring_started_at - make_interval(mins => p_minutes),
         next_action_at      = next_action_at - make_interval(mins => p_minutes)
   where id = p_request_id;
$$;

-- ---------------------------------------------------------------------------
-- 1. Ring 1
-- ---------------------------------------------------------------------------

insert into t_ids values ('r1', pg_temp.make_request('test-token-ring-escalation-1'));

select is(
  (select app.advance_one(id) ->> 'action' from t_ids where name = 'r1'),
  'ring_1',
  'the first tick opens ring 1'
);

select is(
  (select status::text from requests where id = (select id from t_ids where name = 'r1')),
  'dispatching',
  'the request moves to dispatching'
);

-- Three, not two. 'Waiting' is approval = 'pending' and under the old model was invisible to the
-- dispatcher; universal membership means there is no approval gate, so a member who is nearby,
-- willing and carrying the right kit is rung whether or not an admin has ever looked at them.
-- This assertion is the gate's headstone: if it ever reads 2 again, the gate is back.
select is(
  (select count(*)::int from dispatches
    where request_id = (select id from t_ids where name = 'r1') and ring = 1),
  3,
  'ring 1 reaches all three willing volunteers inside 15 miles, approved or not'
);

select is(
  (select count(*)::int from dispatches d
     join responders r on r.id = d.responder_id
    where d.request_id = (select id from t_ids where name = 'r1')
      and r.first_name = 'Waiting'),
  1,
  'a volunteer nobody has approved is now reached -- that is the point of this phase'
);

-- What did NOT change. Paused still means paused: it is the member saying "not right now", and
-- removing the approval gate must not quietly remove that one too.
select is(
  (select count(*)::int from dispatches d
     join responders r on r.id = d.responder_id
    where d.request_id = (select id from t_ids where name = 'r1')
      and r.first_name = 'Onbreak'),
  0,
  'a paused volunteer is still never dispatched to'
);

select is(
  (select count(*)::int from sms_messages
    where request_id = (select id from t_ids where name = 'r1')
      and template_key = 'responder.offer'),
  3,
  'each dispatched volunteer has an invitation queued'
);

select is(
  (select count(*)::int from request_events
    where request_id = (select id from t_ids where name = 'r1')
      and event_type = 'ring_escalated'),
  0,
  'opening ring 1 is not reported to the requester as widening the search'
);

-- ---------------------------------------------------------------------------
-- 2. Ring escalation
-- ---------------------------------------------------------------------------

select is(
  (select app.advance_one(id) ->> 'action' from t_ids where name = 'r1'),
  'not_due',
  'nothing escalates before the ring has had its seven minutes'
);

do $$ begin perform pg_temp.rewind((select id from t_ids where name = 'r1'), 8); end $$;

select is(
  (select app.advance_one(id) ->> 'action' from t_ids where name = 'r1'),
  'ring_2',
  'after the wait, the search widens to ring 2'
);

select is(
  (select count(*)::int from dispatches
    where request_id = (select id from t_ids where name = 'r1') and ring = 2),
  1,
  'ring 2 picks up the volunteer 20 miles out'
);

select is(
  (select count(*)::int from dispatches d
     join responders r on r.id = d.responder_id
    where d.request_id = (select id from t_ids where name = 'r1')
      and r.first_name = 'Ringone'),
  1,
  'a volunteer already texted in ring 1 is not texted again in ring 2'
);

do $$ begin perform pg_temp.rewind((select id from t_ids where name = 'r1'), 8); end $$;

select is(
  (select app.advance_one(id) ->> 'action' from t_ids where name = 'r1'),
  'ring_3',
  'and again to ring 3'
);

select is(
  (select count(*)::int from dispatches d
     join responders r on r.id = d.responder_id
    where d.request_id = (select id from t_ids where name = 'r1')
      and r.first_name = 'Homebody'),
  0,
  'a volunteer inside our ring but outside their own radius is left alone'
);

select is(
  (select count(*)::int from dispatches d
     join responders r on r.id = d.responder_id
    where d.request_id = (select id from t_ids where name = 'r1')
      and r.first_name = 'Ringthree'),
  1,
  'ring 3 reaches the volunteer 45 miles out'
);

-- ---------------------------------------------------------------------------
-- 3. Equipment matching
-- ---------------------------------------------------------------------------

insert into t_ids values ('tractor', pg_temp.make_request('test-token-needs-tractor-1', true));

select is(
  (select required_equipment::text from requests where id = (select id from t_ids where name = 'tractor')),
  '{tractor}',
  'asking for a tractor is turned into a hard equipment requirement'
);

select lives_ok(
  $$select app.advance_one((select id from t_ids where name = 'tractor'))$$,
  'the tractor job dispatches'
);

select is(
  (select count(*)::int from dispatches d
     join responders r on r.id = d.responder_id
    where d.request_id = (select id from t_ids where name = 'tractor')
      and not (r.equipment @> '{tractor}'::equipment_type[])),
  0,
  'nobody without a tractor is texted about a job that needs one'
);

select ok(
  (select count(*) from dispatches d
     join responders r on r.id = d.responder_id
    where d.request_id = (select id from t_ids where name = 'tractor')
      and r.first_name = 'Tractorguy') = 1,
  'the volunteer with a tractor is texted'
);

-- ---------------------------------------------------------------------------
-- 4. Double accept — the one that must never happen
-- ---------------------------------------------------------------------------

insert into t_ids values ('race', pg_temp.make_request('test-token-double-accept-1'));
do $$ begin perform app.advance_one((select id from t_ids where name = 'race')); end $$;

select is(
  app.accept_request(
    (select id from t_ids where name = 'race'),
    'aaaa0001-0000-4000-8000-000000000001',
    30
  ) ->> 'ok',
  'true',
  'the first volunteer to answer gets the job'
);

select is(
  app.accept_request(
    (select id from t_ids where name = 'race'),
    'aaaa0001-0000-4000-8000-000000000004',
    20
  ) ->> 'error',
  'already_covered',
  'the second volunteer to answer is told it is already covered'
);

select is(
  (select accepted_responder_id from requests where id = (select id from t_ids where name = 'race')),
  'aaaa0001-0000-4000-8000-000000000001'::uuid,
  'the winner is still the first one in'
);

select is(
  (select count(*)::int from requests
    where id = (select id from t_ids where name = 'race') and status = 'accepted'),
  1,
  'the request lands in exactly one accepted state'
);

select is(
  (select count(*)::int from dispatches
    where request_id = (select id from t_ids where name = 'race') and state = 'accepted'),
  1,
  'exactly one dispatch row is marked accepted'
);

select is(
  (select count(*)::int from dispatches
    where request_id = (select id from t_ids where name = 'race')
      and state in ('queued', 'sent', 'delivered')),
  0,
  'every other offer is closed out'
);

select is(
  (select count(*)::int from sms_messages
    where request_id = (select id from t_ids where name = 'race')
      and template_key = 'responder.assigned'),
  1,
  'only the winner is sent the assignment, which carries the phone and the pin'
);

select is(
  (select count(*)::int from sms_messages
    where request_id = (select id from t_ids where name = 'race')
      and template_key = 'requester.accepted'),
  1,
  'the requester is told who is coming'
);

select is(
  (select next_action_at from requests where id = (select id from t_ids where name = 'race')),
  null::timestamptz,
  'an accepted request drops out of the tick'
);

-- A request that is already taken is not re-opened by the scheduler.
select is(
  app.advance_one((select id from t_ids where name = 'race')) ->> 'action',
  'none',
  'the tick leaves an accepted request alone'
);

-- ---------------------------------------------------------------------------
-- 5. Cancel mid-dispatch
-- ---------------------------------------------------------------------------

insert into t_ids values ('cancel', pg_temp.make_request('test-token-cancel-midway-1'));
do $$ begin perform app.advance_one((select id from t_ids where name = 'cancel')); end $$;

-- Pretend the offers actually went out, so the "stand down" texts are exercised.
update dispatches set state = 'sent', sent_at = now()
 where request_id = (select id from t_ids where name = 'cancel');

select is(
  cancel_request_by_token('test-token-cancel-midway-1', 'got pulled out by a friend') ->> 'ok',
  'true',
  'a requester can cancel while volunteers are being notified'
);

select is(
  (select status::text from requests where id = (select id from t_ids where name = 'cancel')),
  'cancelled',
  'the request is cancelled'
);

select is(
  (select count(*)::int from dispatches
    where request_id = (select id from t_ids where name = 'cancel')
      and state in ('queued', 'sent', 'delivered')),
  0,
  'nobody is left holding an open offer for a cancelled job'
);

select is(
  cancel_request_by_token('test-token-cancel-midway-1') ->> 'error',
  'already_closed',
  'cancelling twice is refused rather than silently repeated'
);

-- ---------------------------------------------------------------------------
-- 6. Nobody takes it
-- ---------------------------------------------------------------------------

insert into t_ids values ('nobody', pg_temp.make_request('test-token-unmatched-flow-1'));
do $$ begin perform app.advance_one((select id from t_ids where name = 'nobody')); end $$;
do $$ begin perform pg_temp.rewind((select id from t_ids where name = 'nobody'), 30); end $$;

select is(
  app.advance_one((select id from t_ids where name = 'nobody')) ->> 'action',
  'unmatched',
  'after the full escalation window the request goes unmatched'
);

select isnt(
  (select unmatched_at from requests where id = (select id from t_ids where name = 'nobody')),
  null::timestamptz,
  'the unmatched time is recorded'
);

select isnt(
  (select admin_alerted_at from requests where id = (select id from t_ids where name = 'nobody')),
  null::timestamptz,
  'the admins are marked as alerted'
);

select is(
  (select count(*)::int from sms_messages
    where request_id = (select id from t_ids where name = 'nobody')
      and template_key = 'requester.unmatched'),
  1,
  'the requester is told nobody has taken it'
);

select isnt(
  get_request_by_token('test-token-unmatched-flow-1') -> 'pro_options',
  null::jsonb,
  'and the status page starts offering paid options'
);

-- ---------------------------------------------------------------------------
-- 7. Expiry
-- ---------------------------------------------------------------------------

select is(
  app.advance_one((select id from t_ids where name = 'nobody')) ->> 'action',
  'not_due',
  'an unmatched request is not expired immediately'
);

update requests set next_action_at = now() - interval '1 minute'
 where id = (select id from t_ids where name = 'nobody');

select is(
  app.advance_one((select id from t_ids where name = 'nobody')) ->> 'action',
  'expired',
  'once the expiry window passes, the request is closed'
);

select is(
  (select count(*)::int from dispatches
    where request_id = (select id from t_ids where name = 'nobody')
      and state in ('queued', 'sent', 'delivered')),
  0,
  'expiring a request closes any offer still open'
);

-- ---------------------------------------------------------------------------
-- 8. The tick itself
-- ---------------------------------------------------------------------------

insert into t_ids values ('tick', pg_temp.make_request('test-token-tick-driven-01'));

select ok(
  (advance_dispatch(50) ->> 'processed')::int >= 1,
  'advance_dispatch picks up everything that is due'
);

select is(
  (select current_ring from requests where id = (select id from t_ids where name = 'tick')),
  1::smallint,
  'and it opened ring 1 for the request that was waiting'
);

-- ---------------------------------------------------------------------------
-- 9. Inbound SMS
-- ---------------------------------------------------------------------------

insert into t_ids values ('sms', pg_temp.make_request('test-token-inbound-sms-01'));
do $$ begin perform app.advance_one((select id from t_ids where name = 'sms')); end $$;

-- Ringone is holding the 'race' job, so the offer here went to Tractorguy.
select is(
  handle_inbound_sms('+12813330004', '2') ->> 'action',
  'declined',
  'replying 2 passes on the job'
);

select is(
  (select state::text from dispatches
    where request_id = (select id from t_ids where name = 'sms')
      and responder_id = 'aaaa0001-0000-4000-8000-000000000004'),
  'declined',
  'the offer is recorded as declined'
);

select is(
  handle_inbound_sms('+12813330004', 'wat') ->> 'reply_template',
  'responder.help',
  'anything we cannot parse gets the help text, not silence'
);

select is(
  handle_inbound_sms('+15550009999', '1') ->> 'reply_template',
  'unknown.no_account',
  'a number we do not know is told it is not registered'
);

select is(
  handle_inbound_sms('+12813330002', 'STOP') ->> 'action',
  'stop',
  'STOP is honoured'
);

select is(
  (select sms_opt_in from responders where phone = '+12813330002'),
  false,
  'and it actually opts the volunteer out'
);

select is(
  (select availability::text from responders where phone = '+12813330002'),
  'paused',
  'a volunteer who texts STOP is also taken off the call list'
);

select is(
  handle_inbound_sms('+12813330002', 'START') ->> 'action',
  'start',
  'START puts them back'
);

select is(
  (select sms_opt_in from responders where phone = '+12813330002'),
  true,
  'and opts them back in'
);

-- Accepting by text, including the optional ETA.
insert into t_ids values ('sms2', pg_temp.make_request('test-token-inbound-accept-1'));
do $$ begin perform app.advance_one((select id from t_ids where name = 'sms2')); end $$;

-- Replying `1` used to win the job outright. Now it is an offer and the requester chooses, so
-- these assertions describe a two-step handshake where there used to be one step.
select is(
  handle_inbound_sms('+12813330004', '1 45') ->> 'action',
  'offered',
  'replying 1 puts their hand up'
);

select is(
  (select accepted_responder_id from requests where id = (select id from t_ids where name = 'sms2')),
  null,
  'and nobody is assigned by it -- the driver has not chosen yet'
);

-- The ETA now rides on the offer until somebody is chosen. Putting it straight onto the request
-- would be claiming an arrival time from a volunteer who may never be picked.
select is(
  (select offer_eta_minutes from dispatches
    where request_id = (select id from t_ids where name = 'sms2')
      and responder_id = 'aaaa0001-0000-4000-8000-000000000004'),
  45,
  'a number after the 1 is read as the ETA and held on the offer'
);

select is(
  (select state::text from dispatches
    where request_id = (select id from t_ids where name = 'sms2')
      and responder_id = 'aaaa0001-0000-4000-8000-000000000004'),
  'offered',
  'and the invitation becomes an offer'
);

-- The requester picks them, which is the step that did not exist before.
select is(
  (select accept_offer_by_token(
            (select public_token from requests where id = (select id from t_ids where name = 'sms2')),
            (select id from dispatches
              where request_id = (select id from t_ids where name = 'sms2')
                and responder_id = 'aaaa0001-0000-4000-8000-000000000004')
          ) ->> 'ok'),
  'true',
  'the requester accepts the offer'
);

select is(
  (select eta_minutes from requests where id = (select id from t_ids where name = 'sms2')),
  45::smallint,
  'and the ETA they gave carries onto the request'
);

select is(
  handle_inbound_sms('+12813330004', 'HERE') ->> 'action',
  'on_site',
  'HERE reports arrival'
);

select is(
  (select status::text from requests where id = (select id from t_ids where name = 'sms2')),
  'on_site',
  'and the request says so'
);

select is(
  handle_inbound_sms('+12813330004', 'DONE') ->> 'action',
  'complete',
  'DONE closes the job'
);

select is(
  (select status::text from requests where id = (select id from t_ids where name = 'sms2')),
  'recovered',
  'and the request is recovered'
);

select is(
  handle_inbound_sms('+12813330004', 'DONE') ->> 'action',
  'no_job',
  'a second DONE has nothing to close'
);

-- ---------------------------------------------------------------------------
-- 10. A volunteer cannot accept something they were never offered
-- ---------------------------------------------------------------------------

insert into t_ids values ('unoffered', pg_temp.make_request('test-token-not-offered-01'));

select is(
  app.accept_request(
    (select id from t_ids where name = 'unoffered'),
    'aaaa0001-0000-4000-8000-000000000003'
  ) ->> 'error',
  'not_offered',
  'accepting a job you were never texted about is refused'
);

-- This used to read 'not_approved'. There is no approval gate any more, so an unapproved member
-- reaches the same refusal as everybody else: you cannot be assigned to a recovery you never
-- offered on. The protection that matters here was never the approval -- it was the offer.
select is(
  app.accept_request(
    (select id from t_ids where name = 'unoffered'),
    'aaaa0001-0000-4000-8000-000000000006'
  ) ->> 'error',
  'not_offered',
  'an unapproved member is refused for the same reason as anyone else: no offer'
);

-- ---------------------------------------------------------------------------
-- Matching counts equipment on a member's rigs, not only their declared list
--
-- Phase 4 gave members vehicles with their own equipment. Before this change a winch added to
-- the Jeep did nothing for matching and the volunteer would never have been texted.
--
-- This section builds its own volunteer, account and request rather than borrowing the demo
-- fixtures. Fifty assertions above it have already accepted jobs, written dispatch rows and
-- moved people around; a test that reuses those rows passes or fails on what ran before it.
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
) values (
  '00000000-0000-0000-0000-000000000000',
  'aaaaaaaa-0000-4000-8000-00000000000a', 'authenticated', 'authenticated',
  'rig-match-test@example.invalid', 'x', now(),
  '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
);

insert into responders (
  id, user_id, phone, first_name, home_location, radius_miles,
  equipment, approval, availability, night_ok, sms_opt_in, max_active_jobs
) values (
  'aaaaaaaa-1111-4111-8111-00000000000a',
  'aaaaaaaa-0000-4000-8000-00000000000a',
  '+15125559001', 'RigTest',
  extensions.st_setsrid(extensions.st_point(-97.7431, 30.2672), 4326)::extensions.geography,
  60, '{kinetic_rope}', 'approved', 'active', true, true, 1
);

-- Every fixture below that belongs to a real account has to opt in, because willingness is now a
-- thing a member chooses rather than something an admin confers. profiles.available_to_help
-- defaults to false on purpose: being listed as willing to drive out to a stranger at 2am should
-- never be a thing that happens to somebody by default. The volunteers higher up this file have
-- no user_id at all -- they are the legacy SMS-only kind -- and are matched as before.
update profiles set available_to_help = true
 where user_id = 'aaaaaaaa-0000-4000-8000-00000000000a';

insert into requests (
  requester_name, requester_phone, location, vehicle_class, stuck_type, land_type,
  needs_tractor, status, emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at
) values (
  'Rig Match', '+15125559002',
  extensions.st_setsrid(extensions.st_point(-97.7431, 30.2672), 4326)::extensions.geography,
  'truck', 'mud', 'public', true, 'dispatching', now(), true,
  (select id from waivers where slug = 'requester_waiver' and is_current), now()
);

-- required_equipment is derived by a trigger from the situation, so it is read, not set.
select is(
  (select required_equipment::text from requests where requester_phone = '+15125559002'),
  '{tractor}',
  'needs_tractor derives a tractor requirement'
);

select is(
  (select count(*)::int
     from app.candidates((select id from requests where requester_phone = '+15125559002'), 60, 50) c
    where c.responder_id = 'aaaaaaaa-1111-4111-8111-00000000000a'),
  0,
  'a volunteer whose declared list lacks the gear does not match'
);

insert into vehicles (user_id, make, equipment)
values ('aaaaaaaa-0000-4000-8000-00000000000a', 'Kubota', '{tractor}'::equipment_type[]);

select is(
  (select count(*)::int
     from app.candidates((select id from requests where requester_phone = '+15125559002'), 60, 50) c
    where c.responder_id = 'aaaaaaaa-1111-4111-8111-00000000000a'),
  1,
  'and matches once a rig of theirs carries it'
);

delete from vehicles where user_id = 'aaaaaaaa-0000-4000-8000-00000000000a';

select is(
  (select count(*)::int
     from app.candidates((select id from requests where requester_phone = '+15125559002'), 60, 50) c
    where c.responder_id = 'aaaaaaaa-1111-4111-8111-00000000000a'),
  0,
  'and stops matching when that rig is removed'
);

-- Most volunteers have no account, and their declared list has to keep working on its own.
update responders set user_id = null, equipment = '{tractor}'
 where id = 'aaaaaaaa-1111-4111-8111-00000000000a';

select is(
  (select count(*)::int
     from app.candidates((select id from requests where requester_phone = '+15125559002'), 60, 50) c
    where c.responder_id = 'aaaaaaaa-1111-4111-8111-00000000000a'),
  1,
  'a volunteer with no account still matches on their declared list alone'
);

-- ---------------------------------------------------------------------------
-- Matching measures from where a volunteer is, not only where they live
--
-- Phase 6: recent permissioned location beats an assumption about home. Own fixtures, because
-- everything above has already moved people around.
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
) values (
  '00000000-0000-0000-0000-000000000000', 'dddddddd-0000-4000-8000-00000000000d',
  'authenticated', 'authenticated', 'loc-test@example.invalid', 'x', now(),
  '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
);

-- Lives 185 miles away, has the gear, 60 mile radius.
insert into responders (
  id, user_id, phone, first_name, home_location, radius_miles,
  equipment, approval, availability, night_ok, sms_opt_in, max_active_jobs
) values (
  'dddddddd-1111-4111-8111-00000000000d', 'dddddddd-0000-4000-8000-00000000000d',
  '+15125559101', 'LocTest',
  extensions.st_setsrid(extensions.st_point(-100.5, 31.5), 4326)::extensions.geography,
  60, '{tractor}', 'approved', 'active', true, true, 1
);

-- Willing to be called out; see the note on the first account-backed fixture above.
update profiles set available_to_help = true
 where user_id = 'dddddddd-0000-4000-8000-00000000000d';

insert into requests (
  requester_name, requester_phone, location, vehicle_class, stuck_type, land_type,
  needs_tractor, status, emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at
) values (
  'Loc Match', '+15125559102',
  extensions.st_setsrid(extensions.st_point(-97.7431, 30.2672), 4326)::extensions.geography,
  'truck', 'mud', 'public', true, 'dispatching', now(), true,
  (select id from waivers where slug = 'requester_waiver' and is_current), now()
);

select is(
  (select count(*)::int
     from app.candidates((select id from requests where requester_phone = '+15125559102'), 60, 50) c
    where c.responder_id = 'dddddddd-1111-4111-8111-00000000000d'),
  0,
  'a volunteer whose home is 185 miles away does not match'
);

-- Out on the trail, two miles from the stuck truck, shared just now.
update responders
   set share_location = true,
       last_location = extensions.st_setsrid(extensions.st_point(-97.71, 30.29), 4326)::extensions.geography,
       last_location_at = now()
 where id = 'dddddddd-1111-4111-8111-00000000000d';

select is(
  (select count(*)::int
     from app.candidates((select id from requests where requester_phone = '+15125559102'), 60, 50) c
    where c.responder_id = 'dddddddd-1111-4111-8111-00000000000d'),
  1,
  'and does match once they share where they actually are'
);

select cmp_ok(
  (select distance_miles
     from app.candidates((select id from requests where requester_phone = '+15125559102'), 60, 50) c
    where c.responder_id = 'dddddddd-1111-4111-8111-00000000000d'),
  '<', 10::numeric,
  'the distance reported is the real one, not the distance from home'
);

-- Same point, shared three days ago.
update responders set last_location_at = now() - interval '3 days'
 where id = 'dddddddd-1111-4111-8111-00000000000d';

select is(
  (select count(*)::int
     from app.candidates((select id from requests where requester_phone = '+15125559102'), 60, 50) c
    where c.responder_id = 'dddddddd-1111-4111-8111-00000000000d'),
  0,
  'a stale position is ignored and matching falls back to home: stale beats wrong'
);

-- Sharing turned off entirely, with a fresh point still on the row.
update responders set share_location = false, last_location_at = now()
 where id = 'dddddddd-1111-4111-8111-00000000000d';

select is(
  (select count(*)::int
     from app.candidates((select id from requests where requester_phone = '+15125559102'), 60, 50) c
    where c.responder_id = 'dddddddd-1111-4111-8111-00000000000d'),
  0,
  'and a volunteer who turned sharing off is matched from home even if a point remains'
);

-- forget_my_location() removes it rather than merely ignoring it.
set local role authenticated;
set local request.jwt.claims = '{"sub":"dddddddd-0000-4000-8000-00000000000d","role":"authenticated"}';
select is(public.forget_my_location() ->> 'ok', 'true', 'a volunteer can forget their position');
reset role;

select is(
  (select last_location is null and share_location = false
     from responders where id = 'dddddddd-1111-4111-8111-00000000000d'),
  true,
  'and the point is actually gone, not just switched off'
);

-- ---------------------------------------------------------------------------
-- Notification preference, and knowing whether the tick is alive
--
-- Phase 13: profiles.notify_recovery had been writable since Phase 3 and read by nothing, so a
-- volunteer could switch off recovery alerts, watch it save, and still be texted at 2am.
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
) values (
  '00000000-0000-0000-0000-000000000000', 'eeeeeeee-0000-4000-8000-00000000000e',
  'authenticated', 'authenticated', 'pref-test@example.invalid', 'x', now(),
  '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
);

insert into responders (
  id, user_id, phone, first_name, home_location, radius_miles,
  equipment, approval, availability, night_ok, sms_opt_in, max_active_jobs
) values (
  'eeeeeeee-1111-4111-8111-00000000000e', 'eeeeeeee-0000-4000-8000-00000000000e',
  '+15125559201', 'PrefTest',
  extensions.st_setsrid(extensions.st_point(-97.7431, 30.2672), 4326)::extensions.geography,
  60, '{tractor}', 'approved', 'active', true, true, 1
);

-- Willing to be called out. This section then switches notify_recovery off to prove the
-- preference is honoured, so the two switches have to be independent: available_to_help stays on
-- throughout, or the test would pass for the wrong reason.
update profiles set available_to_help = true
 where user_id = 'eeeeeeee-0000-4000-8000-00000000000e';

insert into requests (
  requester_name, requester_phone, location, vehicle_class, stuck_type, land_type,
  needs_tractor, status, emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at
) values (
  'Pref Match', '+15125559202',
  extensions.st_setsrid(extensions.st_point(-97.7431, 30.2672), 4326)::extensions.geography,
  'truck', 'mud', 'public', true, 'dispatching', now(), true,
  (select id from waivers where slug = 'requester_waiver' and is_current), now()
);

select is(
  (select count(*)::int
     from app.candidates((select id from requests where requester_phone = '+15125559202'), 60, 50) c
    where c.responder_id = 'eeeeeeee-1111-4111-8111-00000000000e'),
  1,
  'a volunteer with recovery alerts on is matched'
);

update profiles set notify_recovery = false
 where user_id = 'eeeeeeee-0000-4000-8000-00000000000e';

select is(
  (select count(*)::int
     from app.candidates((select id from requests where requester_phone = '+15125559202'), 60, 50) c
    where c.responder_id = 'eeeeeeee-1111-4111-8111-00000000000e'),
  0,
  'and is not matched once they switch recovery alerts off'
);

-- A volunteer with no account never had the chance to express a preference. Silently dropping
-- them would be worse than texting them, and nearly every volunteer today has no account.
update responders set user_id = null where id = 'eeeeeeee-1111-4111-8111-00000000000e';

select is(
  (select count(*)::int
     from app.candidates((select id from requests where requester_phone = '+15125559202'), 60, 50) c
    where c.responder_id = 'eeeeeeee-1111-4111-8111-00000000000e'),
  1,
  'a volunteer with no account keeps being matched'
);

-- ---------------------------------------------------------------------------
-- The heartbeat: telling a quiet afternoon from a dead scheduler
-- ---------------------------------------------------------------------------

delete from system_heartbeats where key = 'dispatch_tick';

select ok(
  public.advance_dispatch(5) is not null,
  'a tick runs'
);

select is(
  (select count(*)::int from system_heartbeats where key = 'dispatch_tick'),
  1,
  'and writes a heartbeat, whether or not it had anything to do'
);

update system_heartbeats set beat_at = now() - interval '20 minutes'
 where key = 'dispatch_tick';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}';

select is(
  public.admin_system_health() -> 'dispatch' ->> 'stalled',
  'true',
  'a heartbeat 20 minutes old is reported as stalled'
);

reset role;
update system_heartbeats set beat_at = now() where key = 'dispatch_tick';

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}';

select is(
  public.admin_system_health() -> 'dispatch' ->> 'stalled',
  'false',
  'and a fresh one is not'
);

reset role;

select * from finish();
rollback;
