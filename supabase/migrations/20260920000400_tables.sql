-- TxRecover M1 :: tables + indexes
--
-- RLS is turned on for every table in 20260920000600_rls.sql. Nothing here grants access.

set search_path = public, extensions;

-- ===========================================================================
-- Settings, legal copy, roles
-- ===========================================================================

create table app_settings (
  key         text primary key,
  value       jsonb not null,
  description text,
  is_public   boolean not null default false,   -- readable by anon through get_public_settings()
  updated_at  timestamptz not null default now(),
  updated_by  uuid references auth.users (id)
);

comment on table app_settings is 'Admin-tunable dispatch and display knobs. Code reads these, never hard-codes them.';

-- Versioned legal copy. A request records WHICH version was accepted, so the exact text a person
-- agreed to can always be reproduced.
create table waivers (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null check (slug in ('requester_waiver', 'responder_waiver', 'rules')),
  version      integer not null check (version > 0),
  body_en      text not null,
  body_es      text not null,
  is_current   boolean not null default false,
  effective_at timestamptz not null default now(),
  created_at   timestamptz not null default now(),
  unique (slug, version)
);

create unique index waivers_one_current_per_slug on waivers (slug) where is_current;

create table user_roles (
  user_id    uuid not null references auth.users (id) on delete cascade,
  role       app_role not null,
  granted_at timestamptz not null default now(),
  granted_by uuid references auth.users (id),
  primary key (user_id, role)
);

-- Paid recovery / tow operators shown to the requester once nobody volunteers.
create table pro_options (
  id                   uuid primary key default gen_random_uuid(),
  name                 text not null check (length(btrim(name)) between 2 and 80),
  phone                text check (phone is null or phone ~ '^\+1[0-9]{10}$'),
  url                  text,
  blurb_en             text check (blurb_en is null or length(blurb_en) <= 240),
  blurb_es             text check (blurb_es is null or length(blurb_es) <= 240),
  counties             text[] not null default '{}',
  center               extensions.geography(Point, 4326),
  radius_miles         integer check (radius_miles is null or radius_miles between 1 and 500),
  is_active            boolean not null default true,
  sort_order           smallint not null default 100,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create index pro_options_active_idx on pro_options (is_active, sort_order);
create index pro_options_center_idx on pro_options using gist (center);

-- Phones / IPs that may not create requests or sign up.
create table blocklist (
  id         uuid primary key default gen_random_uuid(),
  phone      text unique check (phone is null or phone ~ '^\+1[0-9]{10}$'),
  ip         inet,
  reason     text,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  constraint blocklist_target_present check (phone is not null or ip is not null)
);

create index blocklist_ip_idx on blocklist (ip) where ip is not null;

create table rate_limit_hits (
  id         bigint generated always as identity primary key,
  bucket_key text not null,
  created_at timestamptz not null default now()
);

create index rate_limit_hits_key_idx on rate_limit_hits (bucket_key, created_at desc);

-- ===========================================================================
-- Responders
-- ===========================================================================

create table responders (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid unique references auth.users (id) on delete set null,
  phone              text not null unique check (phone ~ '^\+1[0-9]{10}$'),
  first_name         text not null check (length(btrim(first_name)) between 1 and 40),
  last_name          text check (last_name is null or length(btrim(last_name)) <= 40),
  locale             text not null default 'en' check (locale in ('en', 'es')),

  home_location      extensions.geography(Point, 4326) not null,
  home_address_text  text,
  radius_miles       integer not null default 30 check (radius_miles in (15, 30, 60)),

  equipment          equipment_type[] not null default '{}',
  vehicle_class      vehicle_class not null default 'truck',
  vehicle_desc       text check (
                       vehicle_desc is null
                       or (length(vehicle_desc) <= 120 and not public.contains_contact_info(vehicle_desc))
                     ),
  drivetrain         drivetrain not null default '4wd',

  always_available   boolean not null default true,
  -- {"mon":[["07:00","21:00"]], ...} in America/Chicago; empty when always_available
  availability_hours jsonb not null default '{}'::jsonb,
  night_ok           boolean not null default true,

  approval           responder_approval not null default 'pending',
  approved_by        uuid references auth.users (id),
  approved_at        timestamptz,
  review_reason      text,

  availability       availability_state not null default 'active',
  paused_until       timestamptz,

  sms_opt_in         boolean not null default true,
  sms_opt_out_at     timestamptz,

  max_active_jobs    smallint not null default 1 check (max_active_jobs between 1 and 5),
  recoveries_count   integer not null default 0,
  last_notified_at   timestamptz,
  last_accepted_at   timestamptz,

  admin_notes        text,
  is_test            boolean not null default false,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create index responders_home_idx on responders using gist (home_location);
create index responders_equipment_idx on responders using gin (equipment);
create index responders_dispatchable_idx on responders (approval, availability)
  where approval = 'approved' and availability = 'active';
create index responders_phone_idx on responders (phone);

comment on column responders.radius_miles is
  'How far this volunteer is willing to drive. A ring only reaches them if the request is also inside this radius.';

-- ===========================================================================
-- Requests
-- ===========================================================================

create table requests (
  id                   uuid primary key default gen_random_uuid(),
  public_token         text not null unique default app.gen_public_token(),
  short_code           text not null unique default app.gen_short_code(),
  status               request_status not null default 'submitted',
  locale               text not null default 'en' check (locale in ('en', 'es')),

  -- Private contact details. Column-level SELECT is revoked from anon/authenticated in the RLS
  -- migration; they are released to the accepting responder through an RPC and nowhere else.
  requester_name       text not null check (length(btrim(requester_name)) between 1 and 60),
  requester_phone      text not null check (requester_phone ~ '^\+1[0-9]{10}$'),

  location             extensions.geography(Point, 4326) not null,
  approx_location      extensions.geography(Point, 4326) not null,   -- set by trigger, ~1 mi off
  location_accuracy_m  numeric(8, 1) check (location_accuracy_m is null or location_accuracy_m >= 0),
  location_source      location_source not null default 'gps',
  location_note        text check (
                         location_note is null
                         or (length(location_note) <= 200 and not public.contains_contact_info(location_note))
                       ),
  county               text,
  state                text not null default 'TX',

  vehicle_class        vehicle_class not null,
  vehicle_make         text check (vehicle_make is null or length(vehicle_make) <= 40),
  vehicle_model        text check (vehicle_model is null or length(vehicle_model) <= 40),
  vehicle_year         smallint check (vehicle_year is null or vehicle_year between 1900 and 2100),
  drivetrain           drivetrain not null default 'unknown',

  stuck_type           stuck_type not null,
  stuck_depth          stuck_depth,
  needs_tractor        boolean not null default false,
  needs_second_truck   boolean not null default false,
  required_equipment   equipment_type[] not null default '{}',   -- derived by trigger
  land_type            land_type not null,
  land_permission_note text check (land_permission_note is null or length(land_permission_note) <= 200),
  notes                text check (
                         notes is null
                         or (length(notes) <= 500 and not public.contains_contact_info(notes))
                       ),

  -- Consent record. Keep every field: this is the paper trail if something goes wrong on a job.
  emergency_ack_at     timestamptz not null,
  rules_accepted       boolean not null default false check (rules_accepted),
  waiver_id            uuid not null references waivers (id),
  waiver_accepted_at   timestamptz not null,
  waiver_ip            inet,
  waiver_user_agent    text,

  -- Dispatch state machine. Only the dispatch function (M3) writes these.
  dispatch_started_at  timestamptz,
  current_ring         smallint not null default 0 check (current_ring between 0 and 3),
  ring_started_at      timestamptz,
  next_action_at       timestamptz,              -- the cron tick picks up rows due at or before now()
  notified_count       integer not null default 0,
  unmatched_at         timestamptz,
  admin_alerted_at     timestamptz,

  accepted_responder_id uuid references responders (id),
  accepted_at          timestamptz,
  eta_minutes          smallint check (eta_minutes is null or eta_minutes between 0 and 600),
  on_site_at           timestamptz,
  recovered_at         timestamptz,
  cancelled_at         timestamptz,
  cancel_reason        text check (cancel_reason is null or length(cancel_reason) <= 240),
  thank_you_note       text check (
                         thank_you_note is null
                         or (length(thank_you_note) <= 300 and not public.contains_contact_info(thank_you_note))
                       ),

  created_ip           inet,
  created_user_agent   text,
  created_by           uuid references auth.users (id),   -- set for admin intake from a FB post
  is_test              boolean not null default false,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),

  constraint requests_assigned_states_have_responder
    check (accepted_responder_id is not null or status not in ('accepted', 'on_site'))
);

create index requests_location_idx        on requests using gist (location);
create index requests_approx_location_idx on requests using gist (approx_location);
create index requests_status_idx          on requests (status, created_at desc);
create index requests_created_idx         on requests (created_at desc);
create index requests_accepted_by_idx     on requests (accepted_responder_id)
  where accepted_responder_id is not null;
-- The 60 s tick scans exactly this index.
create index requests_due_idx on requests (next_action_at)
  where status in ('submitted', 'dispatching');
create index requests_phone_idx on requests (requester_phone, created_at desc);

create table request_photos (
  id           uuid primary key default gen_random_uuid(),
  request_id   uuid not null references requests (id) on delete cascade,
  storage_path text not null unique,
  content_type text not null default 'image/jpeg'
                 check (content_type in ('image/jpeg', 'image/png', 'image/webp')),
  bytes        integer check (bytes is null or bytes between 1 and 5242880),
  width        integer,
  height       integer,
  sort_order   smallint not null default 0,
  created_at   timestamptz not null default now()
);

create index request_photos_request_idx on request_photos (request_id, sort_order);

-- ===========================================================================
-- Dispatch
-- ===========================================================================

-- One row per offer made to one responder. The unique constraint means a responder is never
-- texted twice about the same request, even as the rings widen.
create table dispatches (
  id             uuid primary key default gen_random_uuid(),
  request_id     uuid not null references requests (id) on delete cascade,
  responder_id   uuid not null references responders (id) on delete cascade,
  ring           smallint not null check (ring between 1 and 3),
  distance_miles numeric(6, 2) not null check (distance_miles >= 0),
  state          dispatch_state not null default 'queued',
  is_manual      boolean not null default false,   -- admin pushed this one
  queued_at      timestamptz not null default now(),
  sent_at        timestamptz,
  responded_at   timestamptz,
  response_text  text,
  twilio_sid     text,
  error_message  text,
  unique (request_id, responder_id)
);

create index dispatches_request_idx   on dispatches (request_id, ring);
create index dispatches_responder_idx on dispatches (responder_id, state, queued_at desc);
create index dispatches_queued_idx    on dispatches (queued_at) where state = 'queued';

-- Timeline. Public rows are what /r/[token] renders; private rows are admin-only detail.
create table request_events (
  id                 bigint generated always as identity primary key,
  request_id         uuid not null references requests (id) on delete cascade,
  event_type         request_event_type not null,
  actor_kind         actor_kind not null default 'system',
  actor_user_id      uuid references auth.users (id),
  actor_responder_id uuid references responders (id),
  data               jsonb not null default '{}'::jsonb,
  is_public          boolean not null default true,
  created_at         timestamptz not null default now()
);

create index request_events_request_idx on request_events (request_id, created_at);

-- Outbound outbox and inbound log in one place, so the whole SMS conversation is auditable.
-- The state machine writes `queued` rows with a template key; the Edge Function renders them in
-- the recipient's locale and sends them. SQL never builds message copy.
create table sms_messages (
  id            uuid primary key default gen_random_uuid(),
  direction     sms_direction not null,
  state         sms_state not null default 'queued',
  to_phone      text not null,
  from_phone    text,
  template_key  text,
  params        jsonb not null default '{}'::jsonb,
  locale        text not null default 'en' check (locale in ('en', 'es')),
  body          text,
  request_id    uuid references requests (id) on delete set null,
  responder_id  uuid references responders (id) on delete set null,
  dispatch_id   uuid references dispatches (id) on delete set null,
  twilio_sid    text unique,
  error_message text,
  attempts      smallint not null default 0,
  send_after    timestamptz not null default now(),
  sent_at       timestamptz,
  created_at    timestamptz not null default now()
);

create index sms_messages_outbox_idx on sms_messages (send_after)
  where direction = 'outbound' and state = 'queued';
create index sms_messages_phone_idx   on sms_messages (to_phone, created_at desc);
create index sms_messages_request_idx on sms_messages (request_id, created_at desc);

create table audit_log (
  id            bigint generated always as identity primary key,
  actor_kind    actor_kind not null default 'admin',
  actor_user_id uuid references auth.users (id),
  action        text not null,
  entity        text,
  entity_id     text,
  data          jsonb not null default '{}'::jsonb,
  ip            inet,
  user_agent    text,
  created_at    timestamptz not null default now()
);

create index audit_log_created_idx on audit_log (created_at desc);
create index audit_log_entity_idx  on audit_log (entity, entity_id);
