-- TxRecover M1 :: row level security
--
-- Three layers, on purpose:
--   1. RLS policies decide which ROWS a role can see.
--   2. Column-level GRANTs decide which COLUMNS exist for that role at all, so a future policy
--      mistake still cannot leak a phone number or an exact pin.
--   3. Requesters are anonymous and touch nothing directly; they go through token-scoped
--      `security definer` RPCs (next migration).
--
-- Admin *writes* run server-side with the service-role key after the server verifies the caller
-- is an admin. Admin *reads* of private columns go through `admin_*` RPCs. That is why there are
-- no admin column grants for requests.requester_phone here.

set search_path = public, extensions;

-- Supabase grants ALL on new public tables to anon/authenticated by default. Take it all back
-- first and hand out only what each screen needs.
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

alter table app_settings     enable row level security;
alter table waivers          enable row level security;
alter table user_roles       enable row level security;
alter table pro_options      enable row level security;
alter table blocklist        enable row level security;
alter table rate_limit_hits  enable row level security;
alter table responders       enable row level security;
alter table requests         enable row level security;
alter table request_photos   enable row level security;
alter table dispatches       enable row level security;
alter table request_events   enable row level security;
alter table sms_messages     enable row level security;
alter table audit_log        enable row level security;

-- ===========================================================================
-- Public reference data
-- ===========================================================================

grant select on pro_options to anon, authenticated;
create policy pro_options_read_active on pro_options
  for select to anon, authenticated
  using (is_active or app.is_admin());
create policy pro_options_admin_write on pro_options
  for all to authenticated
  using (app.is_admin()) with check (app.is_admin());

grant select on waivers to anon, authenticated;
create policy waivers_read_current on waivers
  for select to anon, authenticated
  using (is_current or app.is_admin());

grant select on app_settings to authenticated;
create policy app_settings_admin_read on app_settings
  for select to authenticated
  using (app.is_admin());
-- Public settings reach anon through public.get_public_settings(), never through this table.

grant select on user_roles to authenticated;
create policy user_roles_self_read on user_roles
  for select to authenticated
  using (user_id = auth.uid() or app.is_admin());

-- blocklist and rate_limit_hits: service role only. No grants, no policies.

-- ===========================================================================
-- Responders
-- ===========================================================================

grant select on responders to authenticated;

-- A volunteer sees their own row. Admins see everyone. Volunteers never see each other:
-- the public board and the requester status page only ever get a first name, via an RPC.
create policy responders_self_read on responders
  for select to authenticated
  using (user_id = auth.uid() or app.is_admin());

-- Signup: the row must belong to the caller and must start life as `pending`.
grant insert (
  user_id, phone, first_name, last_name, locale, home_location, home_address_text,
  radius_miles, equipment, vehicle_class, vehicle_desc, drivetrain,
  always_available, availability_hours, night_ok, availability, sms_opt_in
) on responders to authenticated;

create policy responders_self_insert on responders
  for insert to authenticated
  with check (user_id = auth.uid());

-- Self-service edits. `approval`, `approved_by`, `recoveries_count`, `admin_notes` and friends are
-- deliberately absent from this grant, so a volunteer cannot approve themselves.
grant update (
  first_name, last_name, locale, home_location, home_address_text, radius_miles,
  equipment, vehicle_class, vehicle_desc, drivetrain,
  always_available, availability_hours, night_ok, availability, paused_until, sms_opt_in
) on responders to authenticated;

create policy responders_self_update on responders
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ===========================================================================
-- Requests
-- ===========================================================================
--
-- anon gets nothing at all. authenticated gets the operational columns only.
-- Missing on purpose: public_token, requester_name, requester_phone, location,
-- waiver_ip, waiver_user_agent, created_ip, created_user_agent.

grant select (
  id, short_code, status, locale,
  approx_location, location_accuracy_m, location_source, location_note, county, state,
  vehicle_class, vehicle_make, vehicle_model, vehicle_year, drivetrain,
  stuck_type, stuck_depth, needs_tractor, needs_second_truck, required_equipment,
  land_type, land_permission_note, notes,
  emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at,
  dispatch_started_at, current_ring, ring_started_at, next_action_at, notified_count,
  unmatched_at, admin_alerted_at,
  accepted_responder_id, accepted_at, eta_minutes, on_site_at, recovered_at,
  cancelled_at, cancel_reason, thank_you_note,
  created_by, is_test, created_at, updated_at
) on requests to authenticated;

-- A volunteer sees a request only once they have actually been offered it.
create policy requests_responder_read on requests
  for select to authenticated
  using (
    exists (
      select 1 from dispatches d
       where d.request_id = requests.id
         and d.responder_id = app.current_responder_id()
    )
  );

create policy requests_admin_read on requests
  for select to authenticated
  using (app.is_admin());

-- ===========================================================================
-- Photos
-- ===========================================================================
--
-- The path alone is useless without a signed URL, but treat it as sensitive anyway: a photo of a
-- truck buried to the frame, plus a timestamp, is location data.

grant select on request_photos to authenticated;

create policy request_photos_assigned_read on request_photos
  for select to authenticated
  using (
    app.is_admin()
    or exists (
      select 1 from requests r
       where r.id = request_photos.request_id
         and r.accepted_responder_id = app.current_responder_id()
    )
  );

-- ===========================================================================
-- Dispatch offers
-- ===========================================================================

grant select on dispatches to authenticated;

create policy dispatches_own_read on dispatches
  for select to authenticated
  using (responder_id = app.current_responder_id() or app.is_admin());

-- ===========================================================================
-- Timeline
-- ===========================================================================

grant select on request_events to authenticated;

create policy request_events_read on request_events
  for select to authenticated
  using (
    app.is_admin()
    or (
      is_public
      and exists (
        select 1 from dispatches d
         where d.request_id = request_events.request_id
           and d.responder_id = app.current_responder_id()
      )
    )
  );

-- ===========================================================================
-- SMS log and audit log: admins only, and read-only even for them
-- ===========================================================================

grant select on sms_messages to authenticated;
create policy sms_messages_admin_read on sms_messages
  for select to authenticated
  using (app.is_admin());

grant select on audit_log to authenticated;
create policy audit_log_admin_read on audit_log
  for select to authenticated
  using (app.is_admin());
