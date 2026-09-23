-- Winch Up :: the security and privacy review, kept
--
-- Run with:  supabase test db
--
-- Phase 14 asks for a complete security review. Most of what a review produces is a document,
-- and a document goes stale the day after it is written. These are the parts of it that can be
-- asserted, so that the next migration has to keep them true.
--
-- The finding this file exists for: deleting an account did not delete the account. The foreign
-- keys were doing what Phase 3 set them up to do, and the identifying data was never in the
-- foreign key -- it was in the columns beside it. A phone number, a name, and the exact
-- coordinates of somewhere a person got stuck at night, all still there after the delete.

begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select no_plan();

-- ---------------------------------------------------------------------------
-- Fixtures: somebody with a volunteer profile, a finished recovery, a
-- conversation on it, and a post other people replied to.
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, phone, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
)
select '00000000-0000-0000-0000-000000000000', v.id, 'authenticated', 'authenticated',
       v.email, v.phone, 'x', now(), '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
from (values
  ('a0000000-0000-4000-8000-0000000000aa'::uuid, 'sec-leaving@example.invalid', '+15125559601'),
  ('a0000001-0000-4000-8000-0000000000aa'::uuid, 'sec-staying@example.invalid', '+15125559602')
) as v(id, email, phone);

insert into responders (
  id, user_id, phone, first_name, last_name, home_location, radius_miles,
  equipment, approval, availability, sms_opt_in, share_location
) values (
  'a0000000-1111-4111-8111-0000000000aa', 'a0000000-0000-4000-8000-0000000000aa',
  '+15125559601', 'Leaving', 'Person',
  extensions.st_setsrid(extensions.st_point(-97.7400, 30.2700), 4326)::extensions.geography,
  60, '{winch}', 'approved', 'active', true, true
);

insert into requests (
  id, requester_name, requester_phone, requester_user_id, location, vehicle_class, stuck_type,
  land_type, status, emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at, notes
) values (
  'a0000000-2222-4222-8222-0000000000aa',
  'Leaving Person', '+15125559601', 'a0000000-0000-4000-8000-0000000000aa',
  extensions.st_setsrid(extensions.st_point(-97.7400, 30.2700), 4326)::extensions.geography,
  'truck', 'mud', 'public', 'recovered', now(), true,
  (select id from waivers where slug = 'requester_waiver' and is_current), now(),
  'Blue Tacoma, past the second cattle guard'
);

insert into community_posts (id, author_user_id, body)
values ('a0000000-3333-4333-8333-0000000000aa', 'a0000000-0000-4000-8000-0000000000aa',
        'Anybody running the north loop?');

insert into community_comments (post_id, author_user_id, body)
values ('a0000000-3333-4333-8333-0000000000aa', 'a0000001-0000-4000-8000-0000000000aa',
        'I am, Saturday.');

-- What the exact pin was, so it can be shown to be gone rather than merely different.
create temp table before_delete as
  select location as exact_pin from requests where id = 'a0000000-2222-4222-8222-0000000000aa';

-- ---------------------------------------------------------------------------
-- 1. Deletion deletes the person
-- ---------------------------------------------------------------------------

delete from auth.users where id = 'a0000000-0000-4000-8000-0000000000aa';

select is(
  (select requester_phone from requests where id = 'a0000000-2222-4222-8222-0000000000aa'),
  '+10000000000',
  'the phone number on a finished recovery is gone after the account is deleted'
);

select is(
  (select requester_name from requests where id = 'a0000000-2222-4222-8222-0000000000aa'),
  'Removed',
  'and so is the name'
);

select is(
  (select notes from requests where id = 'a0000000-2222-4222-8222-0000000000aa'),
  null,
  'and the free text they typed, which described their truck'
);

-- The one that matters most. Not "different from before" -- far enough away to be no use.
select ok(
  (select extensions.st_distance(r.location, b.exact_pin)
     from requests r, before_delete b
    where r.id = 'a0000000-2222-4222-8222-0000000000aa') > 500,
  'the exact pin is destroyed: what is stored is now half a kilometre or more from where they were'
);

select is(
  (select phone from responders where id = 'a0000000-1111-4111-8111-0000000000aa'),
  '+10000000000',
  'the volunteer profile loses its mobile number too'
);

select is(
  (select first_name from responders where id = 'a0000000-1111-4111-8111-0000000000aa'),
  'Removed',
  'and its name'
);

select ok(
  (select extensions.st_distance(
            home_location,
            extensions.st_setsrid(extensions.st_point(-97.74, 30.27), 4326)::extensions.geography)
     from responders where id = 'a0000000-1111-4111-8111-0000000000aa') > 100000,
  'and their home location, which is the most sensitive column in the schema'
);

select is(
  (select approval::text from responders where id = 'a0000000-1111-4111-8111-0000000000aa'),
  'rejected',
  'a deleted volunteer can never be matched to a job again'
);

select ok(
  (select redacted_at is not null from responders where id = 'a0000000-1111-4111-8111-0000000000aa'),
  'and the row records that it has been through this, so it is not scrubbed twice'
);

-- ---------------------------------------------------------------------------
-- 2. And keeps what belongs to other people
-- ---------------------------------------------------------------------------

select ok(
  exists (select 1 from requests where id = 'a0000000-2222-4222-8222-0000000000aa'
           and status = 'recovered'),
  'the recovery still happened: the row, its status and its timings survive'
);

select ok(
  exists (select 1 from community_posts where id = 'a0000000-3333-4333-8333-0000000000aa'),
  'a post somebody replied to does not vanish and take the replies with it'
);

select is(
  (select author_user_id from community_posts where id = 'a0000000-3333-4333-8333-0000000000aa'),
  null,
  'but it is no longer attributed to anybody'
);

-- ---------------------------------------------------------------------------
-- 3. An open recovery cannot be left running with nobody to call
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, phone, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
) values (
  '00000000-0000-0000-0000-000000000000', 'a0000002-0000-4000-8000-0000000000aa',
  'authenticated', 'authenticated', 'sec-open@example.invalid', '+15125559603', 'x', now(),
  '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
);

insert into requests (
  id, requester_name, requester_phone, requester_user_id, location, vehicle_class, stuck_type,
  land_type, status, emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at
) values (
  'a0000002-2222-4222-8222-0000000000aa',
  'Open Person', '+15125559603', 'a0000002-0000-4000-8000-0000000000aa',
  extensions.st_setsrid(extensions.st_point(-97.74, 30.27), 4326)::extensions.geography,
  'truck', 'mud', 'public', 'dispatching', now(), true,
  (select id from waivers where slug = 'requester_waiver' and is_current), now()
);

delete from auth.users where id = 'a0000002-0000-4000-8000-0000000000aa';

select is(
  (select status::text from requests where id = 'a0000002-2222-4222-8222-0000000000aa'),
  'cancelled',
  'deleting an account with a live recovery cancels it rather than leaving volunteers driving to it'
);

select is(
  (select requester_phone from requests where id = 'a0000002-2222-4222-8222-0000000000aa'),
  '+10000000000',
  'and scrubs it like any other'
);

-- ---------------------------------------------------------------------------
-- 4. Time deletes too
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id, id, aud, role, email, phone, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change, email_change_token_new
) values (
  '00000000-0000-0000-0000-000000000000', 'a0000003-0000-4000-8000-0000000000aa',
  'authenticated', 'authenticated', 'sec-old@example.invalid', '+15125559604', 'x', now(),
  '{}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', ''
);

insert into requests (
  id, requester_name, requester_phone, requester_user_id, location, vehicle_class, stuck_type,
  land_type, status, emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at
) values (
  'a0000003-2222-4222-8222-0000000000aa',
  'Old Recovery', '+15125559604', 'a0000003-0000-4000-8000-0000000000aa',
  extensions.st_setsrid(extensions.st_point(-97.74, 30.27), 4326)::extensions.geography,
  'truck', 'mud', 'public', 'recovered', now(), true,
  (select id from waivers where slug = 'requester_waiver' and is_current), now()
);

-- A year ago, with the trigger out of the way so the timestamp sticks.
alter table requests disable trigger requests_set_updated_at;
update requests set updated_at = now() - interval '400 days', created_at = now() - interval '400 days'
 where id = 'a0000003-2222-4222-8222-0000000000aa';
alter table requests enable trigger requests_set_updated_at;

select is(app.apply_retention(), 1, 'retention scrubs a recovery that closed over the limit ago');

select is(
  (select requester_phone from requests where id = 'a0000003-2222-4222-8222-0000000000aa'),
  '+10000000000',
  'the number on a year-old recovery is gone, without anybody asking'
);

select is(app.apply_retention(), 0, 'and running it again finds nothing to do');

-- A setting of zero turns it off rather than scrubbing everything, which is the safer way round
-- for a number somebody might clear by accident.
update app_settings set value = '0'::jsonb where key = 'privacy.request_retention_days';

insert into requests (
  id, requester_name, requester_phone, requester_user_id, location, vehicle_class, stuck_type,
  land_type, status, emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at
) values (
  'a0000004-2222-4222-8222-0000000000aa',
  'Another Old', '+15125559605', null,
  extensions.st_setsrid(extensions.st_point(-97.74, 30.27), 4326)::extensions.geography,
  'truck', 'mud', 'public', 'recovered', now(), true,
  (select id from waivers where slug = 'requester_waiver' and is_current), now()
);

alter table requests disable trigger requests_set_updated_at;
update requests set updated_at = now() - interval '400 days'
 where id = 'a0000004-2222-4222-8222-0000000000aa';
alter table requests enable trigger requests_set_updated_at;

select is(app.apply_retention(), 0, 'zero days turns retention off rather than scrubbing everything');

select is(
  (select requester_phone from requests where id = 'a0000004-2222-4222-8222-0000000000aa'),
  '+15125559605',
  'so nothing is touched'
);

-- ---------------------------------------------------------------------------
-- 5. Advertising cannot see where anybody was
--
-- The spec forbids using private recovery location information for behavioural advertising.
-- Checked structurally rather than promised: the functions cannot read it and the serving
-- function cannot write anything at all.
-- ---------------------------------------------------------------------------

select is(
  (select count(*)::integer
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'app')
      and p.proname in ('ads_for', 'ad_record_event', 'advertiser_overview', 'admin_ad_queue',
                        'admin_review_ad', 'save_campaign', 'save_creative', 'save_business')
      and (p.prosrc ~* '\mrequests\M' or p.prosrc ~* '\mlast_location\M'
           or p.prosrc ~* '\mhome_location\M' or p.prosrc ~* '\mapprox_location\M')),
  0,
  'no function in the advertising path reads a recovery location or a volunteer position'
);

select is(
  (select provolatile::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'ads_for'),
  's',
  'ads_for is stable, so the coordinates a reader passes it cannot be written down anywhere'
);

select is(
  (select count(*)::integer from pg_attribute a
     join pg_class c on c.oid = a.attrelid
     join pg_namespace n on n.oid = c.relnamespace
     join pg_type t on t.oid = a.atttypid
    where n.nspname = 'public' and t.typname = 'geography'
      and a.attnum > 0 and not a.attisdropped
      and c.relname in ('ad_creatives', 'ad_daily_stats')),
  0,
  'and neither creatives nor the counts have anywhere to put a location'
);

-- ---------------------------------------------------------------------------
-- 6. The redaction value itself
-- ---------------------------------------------------------------------------

select matches(app.redacted_phone(), '^\+1[0-9]{10}$',
  'the redacted number is a valid E.164 shape, so every constraint and code path still works');

select ok(app.redacted_phone() !~ '^\+1[2-9]',
  'and starts with an unassignable area code, so nobody can dial it by accident');

-- ---------------------------------------------------------------------------
-- 7. A test can never text a real community member
--
-- Phase 15's one safety rule. It used to be a comment at the top of the demo seed; it is now
-- the database refusing, and it fails closed -- an unmarked database calls itself production.
-- ---------------------------------------------------------------------------

update app_settings set value = '"production"'::jsonb where key = 'deploy.environment';

select ok(app.is_production(), 'a database marked production knows it');

select throws_ok(
  $q$select app.refuse_if_production('the demo seed')$q$,
  '42501', null,
  'and refuses anything that would create accounts and text real volunteers'
);

delete from app_settings where key = 'deploy.environment';

select ok(
  app.is_production(),
  'a database with no marker at all is treated as production, which is the safe way round'
);

insert into app_settings (key, value) values ('deploy.environment', '"nonsense"'::jsonb);

select ok(
  app.is_production(),
  'and so is one marked with something nobody recognises'
);

update app_settings set value = '"local"'::jsonb where key = 'deploy.environment';

select ok(not app.is_production(), 'only an explicit local marker unlocks it');

select lives_ok(
  $q$select app.refuse_if_production('the demo seed')$q$,
  'at which point the demo seed is allowed to run'
);

-- ---------------------------------------------------------------------------
-- 8. The health endpoint cannot become a leak
--
-- /api/health is unauthenticated on purpose: an uptime checker has no session and cannot hold a
-- secret. That only stays safe while the function behind it returns counts and ages. Somebody
-- adding "and the most recent request" to make a dashboard nicer would turn a status page into
-- a feed of who is stuck and where.
-- ---------------------------------------------------------------------------

select ok(
  not has_function_privilege('anon', 'public.system_health_summary()', 'EXECUTE'),
  'the health summary is not callable from a browser'
);
select ok(
  not has_function_privilege('authenticated', 'public.system_health_summary()', 'EXECUTE'),
  'nor by a signed-in member -- the route holds the service key'
);

select bag_eq(
  $q$select jsonb_object_keys(public.system_health_summary())$q$,
  $q$values ('ok'), ('scheduler_age_seconds'), ('sms_queued'), ('sms_failed_24h'),
           ('notifications_queued'), ('open_requests'), ('reachable_volunteers')$q$,
  'and it returns exactly these keys: every one a count or an age, none of them about a person'
);

select ok(
  (select bool_and(jsonb_typeof(public.system_health_summary() -> k) in ('number', 'boolean', 'null'))
     from jsonb_object_keys(public.system_health_summary()) k),
  'all of them numbers -- a string here would be the first place a name could hide'
);

select * from finish();
rollback;
