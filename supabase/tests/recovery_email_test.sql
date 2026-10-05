-- Winch Up :: a call-out goes out by email as well as by text
--
-- The owner, 2026-10-05: "we need to send an email and sms when someone is asking for help."
--
-- THE ASSERTION THIS FILE EXISTS FOR is that the two channels are INDEPENDENT. sms_opt_in is
-- consent to be texted -- metered, interrupting, default false. Email is neither, and
-- app.candidates() already enforces notify_recovery, so a volunteer who declined texts has not
-- declined email. Gate the email behind the SMS switch and almost nobody hears anything, which is
-- the failure the whole feature exists to remove. So: a volunteer with no SMS consent must still
-- get an email, and that is checked beside the volunteer who gets both.
--
-- And the privacy rule: email_deliveries stores IDs, never content. The facts come back from
-- claim_email_deliveries at send time, so nothing durable records who is stuck where.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- Count only what this file creates. The demo seed shares this database.
delete from email_deliveries;
delete from sms_messages;
delete from dispatches;

create temporary table t (name text primary key, id uuid not null);
insert into t (name, id) values
  ('req', gen_random_uuid()),
  ('texter', gen_random_uuid()), ('emailer', gen_random_uuid()), ('legacy', gen_random_uuid()),
  ('u_texter', gen_random_uuid()), ('u_emailer', gen_random_uuid());

update responders set availability = 'paused';

create temporary table spot as
  select extensions.st_setsrid(extensions.st_point(-95.3698, 29.7604), 4326)::extensions.geography as g;

insert into auth.users (id, email, created_at) values
  ((select id from t where name = 'u_texter'),  'texter@winchup.test',  now()),
  ((select id from t where name = 'u_emailer'), 'emailer@winchup.test', now());

insert into profiles (user_id, display_name, available_to_help) values
  ((select id from t where name = 'u_texter'),  'Tess Texter',  true),
  ((select id from t where name = 'u_emailer'), 'Ed Emailer',   true)
on conflict (user_id) do update set available_to_help = true;

-- Three volunteers, two miles out, differing only in how they can be reached.
--   texter  -- account + phone + SMS consent   -> text AND email
--   emailer -- account + phone, NO SMS consent -> email only
--   legacy  -- no account at all               -> text only, nothing to email
insert into responders (
  id, user_id, phone, first_name, home_location, radius_miles, equipment,
  vehicle_class, drivetrain, approval, availability, night_ok, is_test, sms_opt_in, locale
)
select v.id, v.uid, v.phone, v.nm,
       extensions.st_project((select g from spot), 2 * 1609.344, 0)::extensions.geography,
       60, '{winch}'::equipment_type[], 'truck', '4wd', 'approved', 'active', true, true,
       v.sms, 'en'
from (values
  ((select id from t where name = 'texter'),  (select id from t where name = 'u_texter'),
   '+15125559101', 'Tess',  true),
  ((select id from t where name = 'emailer'), (select id from t where name = 'u_emailer'),
   '+15125559102', 'Ed',    false),
  ((select id from t where name = 'legacy'),  null::uuid,
   '+15125559103', 'Lenny', true)
) as v(id, uid, phone, nm, sms);

insert into requests (
  id, requester_name, requester_phone, location, vehicle_class, stuck_type, land_type,
  status, emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at
) values (
  (select id from t where name = 'req'), 'Stuck Sam', '+15125557991',
  (select g from spot), 'jeep', 'mud', 'public', 'submitted', now(), true,
  (select id from waivers where slug = 'requester_waiver' and is_current), now()
);

-- ---------------------------------------------------------------------------
-- Open the wave
-- ---------------------------------------------------------------------------

select lives_ok(
  'select app.notify_ring((select id from t where name = ''req''), 1)',
  'the wave opens'
);

select is(
  (select count(*)::int from dispatches where request_id = (select id from t where name = 'req')),
  3,
  'all three volunteers are alerted -- the dispatch row is the alert, whatever the channel'
);

-- ---------------------------------------------------------------------------
-- Email, and who gets it
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int from email_deliveries
    where request_id = (select id from t where name = 'req')
      and template_key = 'recovery.offer'),
  2,
  'the two volunteers with accounts are emailed'
);

-- THE POINT OF THE WHOLE FILE.
select is(
  (select count(*)::int from email_deliveries e
    where e.request_id = (select id from t where name = 'req')
      and e.user_id = (select id from t where name = 'u_emailer')),
  1,
  'the volunteer who declined TEXTS still gets the EMAIL -- the channels are separate consents'
);

select is(
  (select count(*)::int from sms_messages m
    where m.request_id = (select id from t where name = 'req')
      and m.to_phone = '+15125559102'),
  0,
  'and is NOT texted, so declining texts still means something'
);

-- The pairing: somebody who consented to both gets both.
select is(
  (select count(*)::int from email_deliveries
    where request_id = (select id from t where name = 'req')
      and user_id = (select id from t where name = 'u_texter')),
  1,
  'the volunteer who consented to both is emailed'
);

select is(
  (select count(*)::int from sms_messages
    where request_id = (select id from t where name = 'req')
      and to_phone = '+15125559101'),
  1,
  'and texted -- so the email did not replace the text, it joined it'
);

-- A volunteer with no account has no address. Still dispatched, still texted.
select is(
  (select count(*)::int from sms_messages
    where request_id = (select id from t where name = 'req')
      and to_phone = '+15125559103'),
  1,
  'the accountless volunteer is still texted'
);

-- ---------------------------------------------------------------------------
-- The row stores IDs, never content
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::int from information_schema.columns
    where table_schema = 'public' and table_name = 'email_deliveries'
      and column_name in ('params', 'body', 'subject', 'to_email', 'action_url')),
  0,
  'email_deliveries still holds no params, body, subject, address or action URL'
);

select isnt(
  (select dispatch_id from email_deliveries
    where request_id = (select id from t where name = 'req')
      and user_id = (select id from t where name = 'u_texter')),
  null,
  'but it does point at the dispatch, which is how the facts are found again at send time'
);

-- ---------------------------------------------------------------------------
-- The claim hands the sender the facts
-- ---------------------------------------------------------------------------

create temporary table claimed as
  select * from public.claim_email_deliveries(50);

select cmp_ok(
  (select count(*)::int from claimed where template_key = 'recovery.offer'),
  '>=', 2,
  'the drain claims both call-out emails'
);

select is(
  (select (params ->> 'short_code') from claimed where template_key = 'recovery.offer' limit 1),
  (select short_code from requests where id = (select id from t where name = 'req')),
  'and is handed the short code, so the button can point at this recovery'
);

select is(
  (select round((params ->> 'miles')::numeric) from claimed
    where template_key = 'recovery.offer' limit 1),
  2::numeric,
  'and the distance, which is the fact that decides whether somebody goes'
);

select is(
  (select (params ->> 'vehicle_class') from claimed where template_key = 'recovery.offer' limit 1),
  'jeep',
  'and the vehicle'
);

-- Nothing that identifies the person who is stuck.
select ok(
  not (select bool_or(params::text ilike '%15125557991%') from claimed),
  'the requester''s phone number is NOT in what the sender is handed'
);

select ok(
  not (select bool_or(params ? 'lat' or params ? 'lng' or params ? 'location') from claimed),
  'and neither are their coordinates'
);

-- ---------------------------------------------------------------------------
-- Idempotence: a re-run cannot email anybody twice
-- ---------------------------------------------------------------------------

select lives_ok(
  'select app.notify_ring((select id from t where name = ''req''), 2)',
  'a second wave opens over the same people'
);

select is(
  (select count(*)::int from email_deliveries
    where request_id = (select id from t where name = 'req')),
  2,
  'and still only two emails exist -- one per helper per recovery, like the dispatch row'
);

select finish();
rollback;
