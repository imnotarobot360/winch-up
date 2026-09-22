-- Winch Up :: demo data (LOCAL DEVELOPMENT ONLY)
--
-- Loaded automatically by `supabase db reset` via [db.seed].sql_paths in config.toml.
-- Never run this against production: it creates auth users with known credentials.
--
-- Phone numbers all use the 555-01xx range reserved for fiction.
-- Demo requests are flagged is_test = false on purpose so that /board and the admin map have
-- something to render locally.
-- ---------------------------------------------------------------------------
-- Refuse to run against production.
--
-- This used to be a comment. A comment does not stop a tired person pasting the wrong file into
-- the wrong SQL editor at eleven at night, and what follows creates accounts with known
-- passwords and recovery requests that would text real volunteers.
--
-- The database defaults to calling itself production, so an unmarked one refuses. Mark a local
-- database with scripts/local-stack/mark-local.sql.
-- ---------------------------------------------------------------------------

select app.refuse_if_production('supabase/seeds/demo.sql');


set search_path = public, extensions;

-- ===========================================================================
-- Auth users (local only)
--   admin@winchup.test   / +17135550100  -> admin
--   mike@winchup.test    / +12815550101  -> approved responder
--   rosa@winchup.test    / +19365550102  -> approved responder
--   pending@winchup.test / +14095550103  -> pending responder
-- Password for all of them: recovery-demo-2026
-- ===========================================================================

do $$
declare
  ids uuid[] := array[
    '00000000-0000-4000-8000-000000000001'::uuid,
    '00000000-0000-4000-8000-000000000002'::uuid,
    '00000000-0000-4000-8000-000000000003'::uuid,
    '00000000-0000-4000-8000-000000000004'::uuid
  ];
  emails text[] := array['admin@winchup.test','mike@winchup.test','rosa@winchup.test','pending@winchup.test'];
  phones text[] := array['+17135550100','+12815550101','+19365550102','+14095550103'];
  i integer;
begin
  for i in 1..4 loop
    begin
      insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        phone, phone_confirmed_at, raw_app_meta_data, raw_user_meta_data,
        created_at, updated_at, confirmation_token, recovery_token,
        email_change, email_change_token_new
      ) values (
        '00000000-0000-0000-0000-000000000000', ids[i], 'authenticated', 'authenticated',
        emails[i], extensions.crypt('recovery-demo-2026', extensions.gen_salt('bf')), now(),
        phones[i], now(),
        '{"provider":"phone","providers":["phone","email"]}'::jsonb, '{}'::jsonb,
        now(), now(), '', '', '', ''
      )
      on conflict (id) do nothing;
    exception when others then
      raise notice 'demo seed: could not create auth user % (%). Skipping.', emails[i], sqlerrm;
    end;
  end loop;
end
$$;

insert into user_roles (user_id, role)
values ('00000000-0000-4000-8000-000000000001', 'admin')
on conflict do nothing;

-- ===========================================================================
-- Volunteers around the Houston / Piney Woods area
-- ===========================================================================

insert into responders (
  id, user_id, phone, first_name, last_name, locale,
  home_location, home_address_text, radius_miles,
  equipment, vehicle_class, vehicle_desc, drivetrain,
  approval, approved_at, availability, night_ok, recoveries_count
) values
  ('11111111-1111-4111-8111-000000000001', '00000000-0000-4000-8000-000000000002',
   '+12815550101', 'Mike', 'Alvarez', 'en',
   extensions.st_setsrid(extensions.st_point(-95.0616, 29.9116), 4326)::extensions.geography, 'Crosby, TX', 30,
   '{winch,kinetic_rope,traction_boards,lifted_4x4,night_lights}', 'truck',
   'Lifted F-250, 12k winch', '4wd', 'approved', now() - interval '60 days', 'active', true, 14),

  ('11111111-1111-4111-8111-000000000002', '00000000-0000-4000-8000-000000000003',
   '+19365550102', 'Rosa', 'Mendez', 'es',
   extensions.st_setsrid(extensions.st_point(-95.4561, 30.3119), 4326)::extensions.geography, 'Conroe, TX', 60,
   '{winch,kinetic_rope,tractor,trailer,night_lights}', 'truck',
   'Ram 3500 dually, tractor on trailer', '4wd', 'approved', now() - interval '45 days', 'active', true, 31),

  ('11111111-1111-4111-8111-000000000003', null,
   '+12815550104', 'Dewayne', 'Fisher', 'en',
   extensions.st_setsrid(extensions.st_point(-95.6972, 29.9691), 4326)::extensions.geography, 'Cypress, TX', 30,
   '{winch,kinetic_rope,traction_boards}', 'jeep',
   'JK Rubicon on 37s', '4wd', 'approved', now() - interval '30 days', 'active', true, 8),

  ('11111111-1111-4111-8111-000000000004', null,
   '+17135550105', 'Tanya', 'Brooks', 'en',
   extensions.st_setsrid(extensions.st_point(-95.3698, 29.7604), 4326)::extensions.geography, 'Houston, TX', 15,
   '{kinetic_rope,traction_boards}', 'suv',
   '4Runner, straps only', '4wd', 'approved', now() - interval '20 days', 'active', false, 3),

  ('11111111-1111-4111-8111-000000000005', null,
   '+19365550106', 'Curtis', 'Ray', 'en',
   extensions.st_setsrid(extensions.st_point(-95.5508, 30.7235), 4326)::extensions.geography, 'Huntsville, TX', 60,
   '{winch,tractor,second_truck,trailer}', 'truck',
   'Farm truck plus a Kubota', '4wd', 'approved', now() - interval '90 days', 'active', true, 22),

  ('11111111-1111-4111-8111-000000000006', null,
   '+12815550107', 'Hector', 'Solis', 'es',
   extensions.st_setsrid(extensions.st_point(-95.8245, 29.7858), 4326)::extensions.geography, 'Katy, TX', 30,
   '{winch,kinetic_rope,traction_boards,night_lights}', 'truck',
   'Tacoma, winch bumper', '4wd', 'approved', now() - interval '15 days', 'active', true, 5),

  ('11111111-1111-4111-8111-000000000007', null,
   '+14095550108', 'Bobby', 'Lane', 'en',
   extensions.st_setsrid(extensions.st_point(-94.7977, 29.3013), 4326)::extensions.geography, 'Galveston, TX', 30,
   '{traction_boards,kinetic_rope}', 'truck',
   'Beach sand specialist', '4wd', 'approved', now() - interval '10 days', 'active', true, 11),

  ('11111111-1111-4111-8111-000000000008', null,
   '+12815550109', 'Jenna', 'Whitfield', 'en',
   extensions.st_setsrid(extensions.st_point(-95.6349, 29.6197), 4326)::extensions.geography, 'Sugar Land, TX', 15,
   '{winch,kinetic_rope}', 'suv',
   'Bronco Badlands', '4wd', 'approved', now() - interval '5 days', 'paused', true, 1),

  ('11111111-1111-4111-8111-000000000009', null,
   '+19365550110', 'Ollie', 'Nguyen', 'en',
   extensions.st_setsrid(extensions.st_point(-95.1616, 30.2352), 4326)::extensions.geography, 'Splendora, TX', 30,
   '{winch,kinetic_rope,traction_boards,second_truck,night_lights}', 'truck',
   'Two trucks, both winched', '4wd', 'approved', now() - interval '70 days', 'active', true, 19),

  ('11111111-1111-4111-8111-000000000010', null,
   '+12815550111', 'Marisol', 'Cantu', 'es',
   extensions.st_setsrid(extensions.st_point(-94.9774, 29.7355), 4326)::extensions.geography, 'Baytown, TX', 30,
   '{kinetic_rope,traction_boards,night_lights}', 'jeep',
   'Gladiator, recovery kit', '4wd', 'approved', now() - interval '25 days', 'active', true, 6),

  ('11111111-1111-4111-8111-000000000011', null,
   '+19795550112', 'Wade', 'Kirkpatrick', 'en',
   extensions.st_setsrid(extensions.st_point(-95.9463, 29.7855), 4326)::extensions.geography, 'Brookshire, TX', 60,
   '{tractor,second_truck,trailer,winch}', 'truck',
   'Ranch equipment, tractor available', '4wd', 'approved', now() - interval '80 days', 'active', true, 27),

  -- Not approved yet: must never receive a dispatch.
  ('11111111-1111-4111-8111-000000000012', '00000000-0000-4000-8000-000000000004',
   '+14095550103', 'Trey', 'Holloway', 'en',
   extensions.st_setsrid(extensions.st_point(-95.4546, 29.3541), 4326)::extensions.geography, 'Rosharon, TX', 30,
   '{winch,kinetic_rope}', 'truck',
   'Signed up last night', '4wd', 'pending', null, 'active', true, 0)
on conflict (id) do nothing;

-- ===========================================================================
-- Requests, one per interesting state
-- ===========================================================================

insert into requests (
  id, public_token, short_code, status, locale,
  requester_name, requester_phone,
  location, location_accuracy_m, location_source, location_note, county,
  vehicle_class, vehicle_make, vehicle_model, vehicle_year, drivetrain,
  stuck_type, stuck_depth, needs_tractor, needs_second_truck, land_type, notes,
  emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at, waiver_ip, waiver_user_agent,
  dispatch_started_at, current_ring, ring_started_at, next_action_at, notified_count,
  accepted_responder_id, accepted_at, eta_minutes, on_site_at, recovered_at,
  unmatched_at, thank_you_note, created_at
)
select * from (values
  -- 1. Just submitted, dispatch has not run yet
  ('22222222-2222-4222-8222-000000000001'::uuid, 'demo-fresh-token-aaaaaa', 'TX-DM01',
   'submitted'::request_status, 'en',
   'Carl Whitten', '+17135550201',
   extensions.st_setsrid(extensions.st_point(-95.4402, 30.5049), 4326)::extensions.geography, 12.0, 'gps'::location_source,
   'Forest road, past the second gate', 'Walker',
   'truck'::vehicle_class, 'Chevrolet', 'Silverado', 2014::smallint, '4wd'::drivetrain,
   'mud'::stuck_type, 'frame'::stuck_depth, false, false, 'public'::land_type,
   'Rear end sank in a rut after the rain. Tires spinning, no traction left.',
   now() - interval '2 minutes', true, (select id from public.waivers where slug = 'requester_waiver' and is_current), now() - interval '2 minutes',
   '203.0.113.10'::inet, 'Mozilla/5.0 (Android 11; Mobile)',
   null::timestamptz, 0::smallint, null::timestamptz, now() - interval '1 minute', 0,
   null::uuid, null::timestamptz, null::smallint, null::timestamptz, null::timestamptz,
   null::timestamptz, null::text, now() - interval '2 minutes'),

  -- 2. Ring 2 in progress, six volunteers texted, nobody has replied
  ('22222222-2222-4222-8222-000000000002'::uuid, 'demo-ring2-token-bbbbbb', 'TX-DM02',
   'dispatching'::request_status, 'en',
   'Priscilla Hoyt', '+12815550202',
   extensions.st_setsrid(extensions.st_point(-95.0881, 29.9271), 4326)::extensions.geography, 8.0, 'gps'::location_source,
   'River bottom below the sand pit', 'Harris',
   'jeep'::vehicle_class, 'Jeep', 'Wrangler', 2019::smallint, '4wd'::drivetrain,
   'mud'::stuck_type, 'buried'::stuck_depth, false, false, 'private_permission'::land_type,
   'Buried past the doors on the driver side. Winch or a long strap should do it.',
   now() - interval '11 minutes', true, (select id from public.waivers where slug = 'requester_waiver' and is_current), now() - interval '11 minutes',
   '203.0.113.11'::inet, 'Mozilla/5.0 (iPhone)',
   now() - interval '10 minutes', 2::smallint, now() - interval '3 minutes',
   now() + interval '4 minutes', 6,
   null::uuid, null::timestamptz, null::smallint, null::timestamptz, null::timestamptz,
   null::timestamptz, null::text, now() - interval '11 minutes'),

  -- 3. Accepted, volunteer on the way
  ('22222222-2222-4222-8222-000000000003'::uuid, 'demo-accepted-token-cccccc', 'TX-DM03',
   'accepted'::request_status, 'es',
   'Alma Rivas', '+14095550203',
   extensions.st_setsrid(extensions.st_point(-94.6469, 29.4497), 4326)::extensions.geography, 20.0, 'map_pin'::location_source,
   'Cerca del acceso a la playa', 'Galveston',
   'suv'::vehicle_class, 'Toyota', 'Highlander', 2017::smallint, '2wd'::drivetrain,
   'sand'::stuck_type, 'hubs'::stuck_depth, false, false, 'public'::land_type,
   'Bajamos a la arena blanda y ya no sale. Marea subiendo.',
   now() - interval '35 minutes', true, (select id from public.waivers where slug = 'requester_waiver' and is_current), now() - interval '35 minutes',
   '203.0.113.12'::inet, 'Mozilla/5.0 (Android 10; Mobile)',
   now() - interval '34 minutes', 1::smallint, now() - interval '34 minutes',
   null::timestamptz, 4,
   '11111111-1111-4111-8111-000000000007'::uuid, now() - interval '28 minutes', 40::smallint,
   null::timestamptz, null::timestamptz,
   null::timestamptz, null::text, now() - interval '35 minutes'),

  -- 4. Nobody took it: rings exhausted, admins alerted, paid options showing
  ('22222222-2222-4222-8222-000000000004'::uuid, 'demo-unmatched-token-dddddd', 'TX-DM04',
   'unmatched'::request_status, 'en',
   'Ronnie Pate', '+19795550204',
   extensions.st_setsrid(extensions.st_point(-95.9271, 29.6039), 4326)::extensions.geography, 30.0, 'coordinates'::location_source,
   'Rice field turn row', 'Austin',
   'truck'::vehicle_class, 'Ford', 'F-150', 2008::smallint, '2wd'::drivetrain,
   'ditch'::stuck_type, 'frame'::stuck_depth, true, false, 'private_permission'::land_type,
   'Slid off the turn row into the ditch. Landowner says a tractor is the only way out.',
   now() - interval '32 minutes', true, (select id from public.waivers where slug = 'requester_waiver' and is_current), now() - interval '32 minutes',
   '203.0.113.13'::inet, 'Mozilla/5.0 (Android 9; Mobile)',
   now() - interval '31 minutes', 3::smallint, now() - interval '14 minutes',
   null::timestamptz, 3,
   null::uuid, null::timestamptz, null::smallint, null::timestamptz, null::timestamptz,
   now() - interval '6 minutes', null::text, now() - interval '32 minutes'),

  -- 5. Closed out, with a thank-you note
  ('22222222-2222-4222-8222-000000000005'::uuid, 'demo-recovered-token-eeeeee', 'TX-DM05',
   'recovered'::request_status, 'en',
   'Dana Kessler', '+12815550205',
   extensions.st_setsrid(extensions.st_point(-95.1616, 30.2352), 4326)::extensions.geography, 10.0, 'gps'::location_source,
   'Mud hole off the pipeline cut', 'Montgomery',
   'truck'::vehicle_class, 'Toyota', 'Tundra', 2021::smallint, '4wd'::drivetrain,
   'mud'::stuck_type, 'hubs'::stuck_depth, false, false, 'public'::land_type,
   'Got sideways in the mud hole and could not back out.',
   now() - interval '3 hours', true, (select id from public.waivers where slug = 'requester_waiver' and is_current), now() - interval '3 hours',
   '203.0.113.14'::inet, 'Mozilla/5.0 (Android 12; Mobile)',
   now() - interval '3 hours', 1::smallint, now() - interval '3 hours',
   null::timestamptz, 5,
   '11111111-1111-4111-8111-000000000009'::uuid, now() - interval '2 hours 50 minutes', 25::smallint,
   now() - interval '2 hours 25 minutes', now() - interval '2 hours 10 minutes',
   null::timestamptz, 'Ollie had me out in ten minutes and would not take a dime. Good people.',
   now() - interval '3 hours')
) as v
on conflict (id) do nothing;

-- ===========================================================================
-- Dispatch offers
-- ===========================================================================

insert into dispatches (request_id, responder_id, ring, distance_miles, state, sent_at, responded_at, response_text)
values
  -- request 2: ring 1 then ring 2, nobody has answered
  ('22222222-2222-4222-8222-000000000002', '11111111-1111-4111-8111-000000000001', 1, 4.10,  'delivered', now() - interval '10 minutes', null, null),
  ('22222222-2222-4222-8222-000000000002', '11111111-1111-4111-8111-000000000010', 1, 11.60, 'delivered', now() - interval '10 minutes', null, null),
  ('22222222-2222-4222-8222-000000000002', '11111111-1111-4111-8111-000000000009', 1, 14.20, 'declined',  now() - interval '10 minutes', now() - interval '8 minutes', '2'),
  ('22222222-2222-4222-8222-000000000002', '11111111-1111-4111-8111-000000000003', 2, 23.40, 'delivered', now() - interval '3 minutes', null, null),
  ('22222222-2222-4222-8222-000000000002', '11111111-1111-4111-8111-000000000005', 2, 28.90, 'sent',      now() - interval '3 minutes', null, null),
  ('22222222-2222-4222-8222-000000000002', '11111111-1111-4111-8111-000000000002', 2, 29.70, 'sent',      now() - interval '3 minutes', null, null),

  -- request 3: Bobby took it, the rest were told it was covered
  ('22222222-2222-4222-8222-000000000003', '11111111-1111-4111-8111-000000000007', 1, 12.80, 'accepted',   now() - interval '34 minutes', now() - interval '28 minutes', '1'),
  ('22222222-2222-4222-8222-000000000003', '11111111-1111-4111-8111-000000000010', 1, 14.90, 'superseded', now() - interval '34 minutes', null, null),
  ('22222222-2222-4222-8222-000000000003', '11111111-1111-4111-8111-000000000006', 1, 14.95, 'superseded', now() - interval '34 minutes', null, null),
  ('22222222-2222-4222-8222-000000000003', '11111111-1111-4111-8111-000000000004', 1, 14.99, 'superseded', now() - interval '34 minutes', null, null),

  -- request 4: three tractor-capable volunteers, all passed or timed out
  ('22222222-2222-4222-8222-000000000004', '11111111-1111-4111-8111-000000000011', 1, 9.30,  'declined', now() - interval '31 minutes', now() - interval '27 minutes', '2'),
  ('22222222-2222-4222-8222-000000000004', '11111111-1111-4111-8111-000000000002', 3, 52.10, 'expired',  now() - interval '14 minutes', null, null),
  ('22222222-2222-4222-8222-000000000004', '11111111-1111-4111-8111-000000000005', 3, 58.40, 'expired',  now() - interval '14 minutes', null, null),

  -- request 5: closed out
  ('22222222-2222-4222-8222-000000000005', '11111111-1111-4111-8111-000000000009', 1, 2.40, 'accepted', now() - interval '3 hours', now() - interval '2 hours 50 minutes', '1')
on conflict (request_id, responder_id) do nothing;

-- ===========================================================================
-- Timeline rows the status-page trigger cannot infer for pre-built demo rows
-- ===========================================================================

insert into request_events (request_id, event_type, actor_kind, actor_responder_id, data, created_at)
values
  ('22222222-2222-4222-8222-000000000002', 'dispatch_started',   'system', null, '{"ring":1,"notified":3}', now() - interval '10 minutes'),
  ('22222222-2222-4222-8222-000000000002', 'ring_escalated',     'system', null, '{"ring":2,"notified_count":6}', now() - interval '3 minutes'),
  ('22222222-2222-4222-8222-000000000003', 'dispatch_started',   'system', null, '{"ring":1,"notified":4}', now() - interval '34 minutes'),
  ('22222222-2222-4222-8222-000000000003', 'accepted',           'responder', '11111111-1111-4111-8111-000000000007', '{"eta_minutes":40}', now() - interval '28 minutes'),
  ('22222222-2222-4222-8222-000000000004', 'dispatch_started',   'system', null, '{"ring":1,"notified":1}', now() - interval '31 minutes'),
  ('22222222-2222-4222-8222-000000000004', 'ring_escalated',     'system', null, '{"ring":3,"notified_count":3}', now() - interval '14 minutes'),
  ('22222222-2222-4222-8222-000000000004', 'unmatched',          'system', null, '{}', now() - interval '6 minutes'),
  ('22222222-2222-4222-8222-000000000005', 'dispatch_started',   'system', null, '{"ring":1,"notified":5}', now() - interval '3 hours'),
  ('22222222-2222-4222-8222-000000000005', 'accepted',           'responder', '11111111-1111-4111-8111-000000000009', '{"eta_minutes":25}', now() - interval '2 hours 50 minutes'),
  ('22222222-2222-4222-8222-000000000005', 'on_site',            'responder', '11111111-1111-4111-8111-000000000009', '{}', now() - interval '2 hours 25 minutes'),
  ('22222222-2222-4222-8222-000000000005', 'recovered',          'requester', '11111111-1111-4111-8111-000000000009', '{}', now() - interval '2 hours 10 minutes'),
  ('22222222-2222-4222-8222-000000000005', 'thanked',            'requester', '11111111-1111-4111-8111-000000000009', '{}', now() - interval '2 hours 5 minutes');
