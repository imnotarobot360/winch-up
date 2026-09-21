-- Winch Up M1 :: enums
--
-- Every enum value that reaches a screen has a matching i18n key in messages/{en,es}.json
-- under `enum.<type>.<value>`. Adding a value here means adding both translations.

set search_path = public, extensions;

-- Lifecycle of a recovery request.
--   submitted   just created, dispatch has not started
--   dispatching rings are being worked
--   unmatched   no volunteer after the full escalation window; admins alerted, pro options shown
--   accepted    a responder took it
--   on_site     responder reported arrival
--   recovered   done
--   cancelled   requester or admin closed it
--   expired     auto-closed after inactivity
create type request_status as enum (
  'submitted', 'dispatching', 'unmatched', 'accepted', 'on_site', 'recovered', 'cancelled', 'expired'
);

create type location_source as enum (
  'gps', 'map_pin', 'coordinates', 'google_maps_link', 'what3words', 'admin_intake'
);

create type stuck_type as enum (
  'mud', 'sand', 'water', 'ditch', 'rollover', 'mechanical', 'other'
);

create type stuck_depth as enum ('hubs', 'frame', 'buried');

create type drivetrain as enum ('2wd', '4wd', 'awd', 'unknown');

create type land_type as enum ('public', 'offroad_park', 'private_permission');

create type vehicle_class as enum (
  'car', 'suv', 'truck', 'jeep', 'van', 'utv_atv', 'motorcycle', 'rv_trailer', 'semi', 'other'
);

-- Matches the /join checkboxes one-for-one.
create type equipment_type as enum (
  'winch', 'kinetic_rope', 'traction_boards', 'tractor', 'second_truck', 'trailer',
  'lifted_4x4', 'night_lights'
);

create type responder_approval as enum ('pending', 'approved', 'rejected', 'banned');

create type availability_state as enum ('active', 'paused');

-- One row per (request, responder) offer.
create type dispatch_state as enum (
  'queued', 'sent', 'delivered', 'failed', 'accepted', 'declined', 'expired', 'superseded'
);

create type sms_direction as enum ('inbound', 'outbound');

create type sms_state as enum ('queued', 'sent', 'delivered', 'failed', 'received');

create type app_role as enum ('admin', 'responder');

create type request_event_type as enum (
  'created', 'dispatch_started', 'ring_escalated', 'responder_notified', 'accepted', 'declined',
  'on_site', 'recovered', 'cancelled', 'expired', 'unmatched', 'reassigned', 'thanked', 'admin_note'
);

create type actor_kind as enum ('requester', 'responder', 'admin', 'system');
