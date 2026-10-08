-- Winch Up :: group B -- the migrations object presence cannot verify
--
-- READ ONLY. No writes, no DDL. Safe on production.
--
-- 42 of the 68 migrations missing from production's ledger create no unique object, so
-- docs/verify-every-migration.sql can only say "inconclusive" about them. This looks for evidence
-- of a different kind, as the owner asked: specific markers inside the function bodies, plus
-- constraints, grants and policies where the migration has any.
--
-- WHY A BODY MARKER IS EVIDENCE AT ALL. Postgres stores a function body verbatim in pg_proc.prosrc
-- -- comments, indentation and all, confirmed against a local database. So a line written in a
-- migration file can be looked for in production's pg_get_functiondef, and finding it means the
-- body installed there is that migration's.
--
-- THE LIMIT, WHICH IS THE WHOLE DESIGN. Several migrations redefine the same function, and two of
-- them rewrite it through pg_get_functiondef without declaring it. A marker from an earlier
-- migration is therefore legitimately absent once a later one has rewritten the body, and its
-- absence would prove nothing. So markers are extracted ONLY for functions where the migration
-- under test is the LAST thing to touch them -- counting both declarations and pg_get_functiondef
-- patches as touches. 11 of the 42 end up with nothing checkable for exactly that reason
-- and stay pending, which is the instruction: no evidence, no record.
--
-- A marker found is strong evidence. A marker MISSING is stronger still, in the other direction: it
-- means the installed body is not this migration's, so do not record it and find out why.

set search_path = public, extensions;

with expected(version, kind, label, present) as (values
  ('20260923000250', 'function marker', 'public.handle_inbound_sms: values (''inbound'', ''received'', coalesce(p_to, ''u', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.handle_inbound_sms'
                        and strpos(p.prosrc, 'values (''inbound'', ''received'', coalesce(p_to, ''unknown''), p_from, p_body, p_twilio_sid)') > 0)),
  ('20260923000250', 'function marker', 'public.handle_inbound_sms: eta  := nullif(regexp_replace(coalesce(split_par', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.handle_inbound_sms'
                        and strpos(p.prosrc, 'eta  := nullif(regexp_replace(coalesce(split_part(body, '' '', 2), ''''), ''[^0-9]'', '''', ''g''), '''')::integer;') > 0)),
  ('20260923000250', 'function marker', 'public.handle_inbound_sms: if word in (''STOP'', ''STOPALL'', ''UNSUBSCRIBE'', ''C', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.handle_inbound_sms'
                        and strpos(p.prosrc, 'if word in (''STOP'', ''STOPALL'', ''UNSUBSCRIBE'', ''CANCEL'', ''END'', ''QUIT'', ''BAJA'') then') > 0)),
  ('20260923000250', 'grant', 'public.handle_inbound_sms execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.handle_inbound_sms'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260923000300', 'grant', 'public.nearby_requests execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_requests'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260923000300', 'grant', 'public.nearby_requests execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_requests'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260923000500', 'function marker', 'public.nearby_requests: mins => app.setting_int(''dispatch.location_fresh', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_requests'
                        and strpos(p.prosrc, 'mins => app.setting_int(''dispatch.location_freshness_minutes'', 120))') > 0)),
  ('20260923000500', 'function marker', 'public.nearby_requests: d.state = ''offered''', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_requests'
                        and strpos(p.prosrc, 'd.state = ''offered''') > 0)),
  ('20260923000500', 'function marker', 'public.nearby_requests: where r.status in (''submitted'', ''dispatching'', ''', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_requests'
                        and strpos(p.prosrc, 'where r.status in (''submitted'', ''dispatching'', ''unmatched'')') > 0)),
  ('20260923000500', 'grant', 'public.nearby_requests execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_requests'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260923000500', 'grant', 'public.nearby_requests execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_requests'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260923000600', 'function marker', 'public.my_requests: r.status in (''submitted'', ''dispatching'', ''unmatc', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_requests'
                        and strpos(p.prosrc, 'r.status in (''submitted'', ''dispatching'', ''unmatched'', ''accepted'', ''on_site''),') > 0)),
  ('20260923000600', 'function marker', 'public.my_requests: where d.request_id = r.id and d.state = ''offered', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_requests'
                        and strpos(p.prosrc, 'where d.request_id = r.id and d.state = ''offered'')') > 0)),
  ('20260923000600', 'function marker', 'public.my_requests: (r.status in (''submitted'', ''dispatching'', ''unmat', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_requests'
                        and strpos(p.prosrc, '(r.status in (''submitted'', ''dispatching'', ''unmatched'', ''accepted'', ''on_site'')) desc,') > 0)),
  ('20260923000600', 'grant', 'public.my_requests execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_requests'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260923000600', 'grant', 'public.my_requests execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_requests'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260923000700', 'function marker', 'public.system_health_summary: ''scheduler_age_seconds'',', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.system_health_summary'
                        and strpos(p.prosrc, '''scheduler_age_seconds'',') > 0)),
  ('20260923000700', 'function marker', 'public.system_health_summary: ''sms_queued'', (select count(*) from sms_messages', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.system_health_summary'
                        and strpos(p.prosrc, '''sms_queued'', (select count(*) from sms_messages where state = ''queued''),') > 0)),
  ('20260923000700', 'function marker', 'public.system_health_summary: ''sms_failed_24h'', (select count(*) from sms_mess', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.system_health_summary'
                        and strpos(p.prosrc, '''sms_failed_24h'', (select count(*) from sms_messages') > 0)),
  ('20260923000700', 'grant', 'public.system_health_summary execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.system_health_summary'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260923001400', 'function marker', 'public.set_recovery_mute: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.set_recovery_mute'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_signed_in'');') > 0)),
  ('20260923001400', 'function marker', 'public.set_recovery_mute: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.set_recovery_mute'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_found'');') > 0)),
  ('20260923001400', 'function marker', 'public.set_recovery_mute: return jsonb_build_object(''ok'', true, ''muted'', c', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.set_recovery_mute'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', true, ''muted'', coalesce(p_muted, false));') > 0)),
  ('20260923001400', 'grant', 'public.set_my_participant_status execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.set_my_participant_status'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260923001400', 'grant', 'public.set_my_participant_status execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.set_my_participant_status'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260923001400', 'grant', 'public.withdraw_from_recovery execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.withdraw_from_recovery'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260923001400', 'grant', 'public.withdraw_from_recovery execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.withdraw_from_recovery'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260923001400', 'grant', 'public.set_recovery_mute execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.set_recovery_mute'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260923001400', 'grant', 'public.set_recovery_mute execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.set_recovery_mute'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260923001500', 'grant', 'app.is_request_participant execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.is_request_participant'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260923001500', 'policy', 'recovery_participants_read_own_team', exists (select 1 from pg_policies where policyname = 'recovery_participants_read_own_team')),
  ('20260923002000', 'function marker', 'app.scrub_request: requester_name  = ''Removed'',', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.scrub_request'
                        and strpos(p.prosrc, 'requester_name  = ''Removed'',') > 0)),
  ('20260923002000', 'function marker', 'app.scrub_responder: first_name    = ''Removed'',', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.scrub_responder'
                        and strpos(p.prosrc, 'first_name    = ''Removed'',') > 0)),
  ('20260923002000', 'function marker', 'app.scrub_responder: availability  = ''paused'',', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.scrub_responder'
                        and strpos(p.prosrc, 'availability  = ''paused'',') > 0)),
  ('20260923002000', 'function marker', 'app.scrub_responder: approval      = ''rejected'',', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.scrub_responder'
                        and strpos(p.prosrc, 'approval      = ''rejected'',') > 0)),
  ('20260923002400', 'function marker', 'public.get_request_by_token: and r.status in (''accepted'', ''on_site'', ''recover', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.get_request_by_token'
                        and strpos(p.prosrc, 'and r.status in (''accepted'', ''on_site'', ''recovered'');') > 0)),
  ('20260923002400', 'function marker', 'public.get_request_by_token: select value into radii from public.app_settings', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.get_request_by_token'
                        and strpos(p.prosrc, 'select value into radii from public.app_settings where key = ''dispatch.ring_radii_miles'';') > 0)),
  ('20260923002400', 'function marker', 'public.get_request_by_token: ''short_code'',      r.short_code,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.get_request_by_token'
                        and strpos(p.prosrc, '''short_code'',      r.short_code,') > 0)),
  ('20260923002500', 'function marker', 'public.my_responder_profile: ''first_name'', me.first_name,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_responder_profile'
                        and strpos(p.prosrc, '''first_name'', me.first_name,') > 0)),
  ('20260923002500', 'function marker', 'public.my_responder_profile: ''last_name'', me.last_name,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_responder_profile'
                        and strpos(p.prosrc, '''last_name'', me.last_name,') > 0)),
  ('20260923002500', 'function marker', 'public.my_responder_profile: ''phone'', me.phone,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_responder_profile'
                        and strpos(p.prosrc, '''phone'', me.phone,') > 0)),
  ('20260923002500', 'grant', 'public.my_responder_profile execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_responder_profile'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260923002500', 'grant', 'public.my_responder_profile execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_responder_profile'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260923002600', 'function marker', 'public.claim_push_deliveries: where d.channel = ''push''', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.claim_push_deliveries'
                        and strpos(p.prosrc, 'where d.channel = ''push''') > 0)),
  ('20260923002600', 'function marker', 'public.claim_push_deliveries: and d.state in (''queued'', ''failed'')', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.claim_push_deliveries'
                        and strpos(p.prosrc, 'and d.state in (''queued'', ''failed'')') > 0)),
  ('20260923002600', 'grant', 'public.claim_push_deliveries execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.claim_push_deliveries'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260923002700', 'function marker', 'public.request_thread: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.request_thread'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_found'');') > 0)),
  ('20260923002700', 'function marker', 'public.request_thread: select r.status in (''recovered'', ''cancelled'', ''e', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.request_thread'
                        and strpos(p.prosrc, 'select r.status in (''recovered'', ''cancelled'', ''expired'') into v_closed') > 0)),
  ('20260923002700', 'function marker', 'public.request_thread: ''lat'',        round(extensions.st_y(r.location::', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.request_thread'
                        and strpos(p.prosrc, '''lat'',        round(extensions.st_y(r.location::extensions.geometry)::numeric, 6),') > 0)),
  ('20260924000100', 'grant', 'public.nearby_members execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_members'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260924000100', 'grant', 'public.nearby_members execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_members'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260924000100', 'grant', 'public.member_profile execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.member_profile'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260924000100', 'grant', 'public.member_profile execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.member_profile'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260925000100', 'function marker', 'app.queue_sms: v_master  boolean := app.setting_bool(''sms.outbo', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.queue_sms'
                        and strpos(p.prosrc, 'v_master  boolean := app.setting_bool(''sms.outbound_enabled'', false);') > 0)),
  ('20260925000100', 'function marker', 'app.queue_sms: (select value from public.app_settings where key', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.queue_sms'
                        and strpos(p.prosrc, '(select value from public.app_settings where key = ''sms.enabled_templates'')') > 0)),
  ('20260925000100', 'function marker', 'app.queue_sms: v_reason := ''sms.outbound_enabled is off; sent b', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.queue_sms'
                        and strpos(p.prosrc, 'v_reason := ''sms.outbound_enabled is off; sent by push and in-app instead'';') > 0)),
  ('20260927000100', 'function marker', 'app.handle_new_user: v_name := btrim(coalesce(new.raw_user_meta_data ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.handle_new_user'
                        and strpos(p.prosrc, 'v_name := btrim(coalesce(new.raw_user_meta_data ->> ''full_name'', ''''));') > 0)),
  ('20260927000100', 'function marker', 'app.handle_new_user: insert into user_roles (user_id, role) values (n', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.handle_new_user'
                        and strpos(p.prosrc, 'insert into user_roles (user_id, role) values (new.id, ''member'')') > 0)),
  ('20260928000300', 'function marker', 'app.membership_state: ''has_agreement'', a.id is not null,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.membership_state'
                        and strpos(p.prosrc, '''has_agreement'', a.id is not null,') > 0)),
  ('20260928000300', 'function marker', 'app.membership_state: ''version'',       a.version,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.membership_state'
                        and strpos(p.prosrc, '''version'',       a.version,') > 0)),
  ('20260928000300', 'function marker', 'app.membership_state: ''signed'',        v_signed_at is not null,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.membership_state'
                        and strpos(p.prosrc, '''signed'',        v_signed_at is not null,') > 0)),
  ('20260928000300', 'function marker', 'app.membership_gate_blocks: from public.app_settings where key = ''membership', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.membership_gate_blocks'
                        and strpos(p.prosrc, 'from public.app_settings where key = ''membership.required'';') > 0)),
  ('20260928000300', 'function marker', 'app.membership_gate_blocks: return (v_state ->> ''has_agreement'')::boolean', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.membership_gate_blocks'
                        and strpos(p.prosrc, 'return (v_state ->> ''has_agreement'')::boolean') > 0)),
  ('20260928000300', 'function marker', 'app.membership_gate_blocks: and not (v_state ->> ''signed'')::boolean;', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.membership_gate_blocks'
                        and strpos(p.prosrc, 'and not (v_state ->> ''signed'')::boolean;') > 0)),
  ('20260928000300', 'function marker', 'public.membership_agreement: from public.app_settings where key = ''membership', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.membership_agreement'
                        and strpos(p.prosrc, 'from public.app_settings where key = ''membership.required'';') > 0)),
  ('20260928000300', 'function marker', 'public.membership_agreement: ''required'', coalesce(v_required, false),', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.membership_agreement'
                        and strpos(p.prosrc, '''required'', coalesce(v_required, false),') > 0)),
  ('20260928000300', 'function marker', 'public.membership_agreement: ''agreement'', case when a.id is null then null el', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.membership_agreement'
                        and strpos(p.prosrc, '''agreement'', case when a.id is null then null else jsonb_build_object(') > 0)),
  ('20260928000300', 'function marker', 'public.sign_membership_agreement: v_user      uuid := nullif(p_payload ->> ''user_i', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.sign_membership_agreement'
                        and strpos(p.prosrc, 'v_user      uuid := nullif(p_payload ->> ''user_id'', '''')::uuid;') > 0)),
  ('20260928000300', 'function marker', 'public.sign_membership_agreement: v_legal     text := nullif(btrim(coalesce(p_payl', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.sign_membership_agreement'
                        and strpos(p.prosrc, 'v_legal     text := nullif(btrim(coalesce(p_payload ->> ''legal_name'', '''')), '''');') > 0)),
  ('20260928000300', 'function marker', 'public.sign_membership_agreement: v_signature text := nullif(btrim(coalesce(p_payl', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.sign_membership_agreement'
                        and strpos(p.prosrc, 'v_signature text := nullif(btrim(coalesce(p_payload ->> ''signature_text'', '''')), '''');') > 0)),
  ('20260928000300', 'grant', 'public.membership_agreement execute to anon', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.membership_agreement'
                        and has_function_privilege('anon', p.oid, 'execute'))),
  ('20260928000300', 'grant', 'public.membership_agreement execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.membership_agreement'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260928000300', 'grant', 'public.membership_agreement execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.membership_agreement'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260928000300', 'grant', 'public.sign_membership_agreement execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.sign_membership_agreement'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260928000400', 'function marker', 'public.admin_publish_membership_agreement: if length(btrim(coalesce(p_body_en, ''''))) < 20 o', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_publish_membership_agreement'
                        and strpos(p.prosrc, 'if length(btrim(coalesce(p_body_en, ''''))) < 20 or length(btrim(coalesce(p_body_es, ''''))) < 20 then') > 0)),
  ('20260928000400', 'function marker', 'public.admin_publish_membership_agreement: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_publish_membership_agreement'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''both_languages_required'');') > 0)),
  ('20260928000400', 'function marker', 'public.admin_publish_membership_agreement: perform app.audit(''membership_agreement.publish''', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_publish_membership_agreement'
                        and strpos(p.prosrc, 'perform app.audit(''membership_agreement.publish'', ''membership_agreements'', v_id::text,') > 0)),
  ('20260928000400', 'function marker', 'public.admin_membership_agreements: ''version'', a.version,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_membership_agreements'
                        and strpos(p.prosrc, '''version'', a.version,') > 0)),
  ('20260928000400', 'function marker', 'public.admin_membership_agreements: ''is_current'', a.is_current,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_membership_agreements'
                        and strpos(p.prosrc, '''is_current'', a.is_current,') > 0)),
  ('20260928000400', 'function marker', 'public.admin_membership_agreements: ''effective_at'', a.effective_at,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_membership_agreements'
                        and strpos(p.prosrc, '''effective_at'', a.effective_at,') > 0)),
  ('20260928000400', 'function marker', 'public.admin_membership_signatures: v_q     text    := nullif(btrim(coalesce(p_searc', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_membership_signatures'
                        and strpos(p.prosrc, 'v_q     text    := nullif(btrim(coalesce(p_search, '''')), '''');') > 0)),
  ('20260928000400', 'function marker', 'public.admin_membership_signatures: and (v_q is null or s.legal_name ilike ''%'' || v_', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_membership_signatures'
                        and strpos(p.prosrc, 'and (v_q is null or s.legal_name ilike ''%'' || v_q || ''%'');') > 0)),
  ('20260928000400', 'function marker', 'public.admin_membership_signatures: ''user_id'', s.user_id,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_membership_signatures'
                        and strpos(p.prosrc, '''user_id'', s.user_id,') > 0)),
  ('20260928000400', 'grant', 'public.admin_publish_membership_agreement execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_publish_membership_agreement'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260928000400', 'grant', 'public.admin_publish_membership_agreement execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_publish_membership_agreement'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260928000400', 'grant', 'public.admin_membership_agreements execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_membership_agreements'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260928000400', 'grant', 'public.admin_membership_agreements execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_membership_agreements'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260928000400', 'grant', 'public.admin_membership_signatures execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_membership_signatures'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260928000400', 'grant', 'public.admin_membership_signatures execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_membership_signatures'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260928000600', 'function marker', 'public.create_request: v_submission_id uuid   := nullif(p_payload ->> ''', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.create_request'
                        and strpos(p.prosrc, 'v_submission_id uuid   := nullif(p_payload ->> ''submission_id'', '''')::uuid;') > 0)),
  ('20260928000600', 'function marker', 'public.create_request: v_phone         text   := btrim(p_payload ->> ''p', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.create_request'
                        and strpos(p.prosrc, 'v_phone         text   := btrim(p_payload ->> ''phone'');') > 0)),
  ('20260928000600', 'function marker', 'public.create_request: v_locale        text   := coalesce(nullif(p_payl', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.create_request'
                        and strpos(p.prosrc, 'v_locale        text   := coalesce(nullif(p_payload ->> ''locale'', ''''), ''en'');') > 0)),
  ('20260928000600', 'function marker', 'public.offer_assistance: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.offer_assistance'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_signed_in'');') > 0)),
  ('20260928000600', 'function marker', 'public.offer_assistance: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.offer_assistance'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''membership_agreement_required'');') > 0)),
  ('20260928000600', 'function marker', 'public.offer_assistance: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.offer_assistance'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''equipment_not_acknowledged'');') > 0)),
  ('20260928000600', 'grant', 'public.create_request execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.create_request'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260928000600', 'grant', 'public.offer_assistance execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.offer_assistance'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260928000600', 'grant', 'public.offer_assistance execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.offer_assistance'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260928000800', 'grant', 'public.upsert_responder_profile execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.upsert_responder_profile'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260928000800', 'grant', 'public.upsert_responder_profile execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.upsert_responder_profile'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260928001000', 'grant', 'public.member_profile execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.member_profile'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260928001000', 'grant', 'public.member_profile execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.member_profile'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260930000100', 'function marker', 'public.my_security_state: raise exception ''not signed in'' using errcode = ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_security_state'
                        and strpos(p.prosrc, 'raise exception ''not signed in'' using errcode = ''42501'';') > 0)),
  ('20260930000100', 'function marker', 'public.my_security_state: coalesce(encrypted_password, '''') <> ''''   as has_', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_security_state'
                        and strpos(p.prosrc, 'coalesce(encrypted_password, '''') <> ''''   as has_password,') > 0)),
  ('20260930000100', 'function marker', 'public.my_security_state: and provider not in (''email'', ''phone'');', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_security_state'
                        and strpos(p.prosrc, 'and provider not in (''email'', ''phone'');') > 0)),
  ('20260930000100', 'grant', 'public.my_security_state execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_security_state'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001000100', 'function marker', 'app.ad_slot_allowed: when p_surface = ''resources'' and coalesce(p_slug', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.ad_slot_allowed'
                        and strpos(p.prosrc, 'when p_surface = ''resources'' and coalesce(p_slug, '''') in (''stuck'', ''safety'', ''emergency'')') > 0)),
  ('20261001000700', 'function marker', 'app.may_see_request_photos: where key = ''dispatch.ring_radii_miles''', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.may_see_request_photos'
                        and strpos(p.prosrc, 'where key = ''dispatch.ring_radii_miles''') > 0)),
  ('20261001000700', 'function marker', 'app.may_see_request_photos: where req.status in (''submitted'', ''dispatching'',', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.may_see_request_photos'
                        and strpos(p.prosrc, 'where req.status in (''submitted'', ''dispatching'', ''unmatched'')') > 0)),
  ('20261001000700', 'function marker', 'app.may_see_request_photos: and resp.availability = ''active''', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.may_see_request_photos'
                        and strpos(p.prosrc, 'and resp.availability = ''active''') > 0)),
  ('20261001000700', 'function marker', 'public.request_photos_for_helper: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.request_photos_for_helper'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_signed_in'');') > 0)),
  ('20261001000700', 'function marker', 'public.request_photos_for_helper: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.request_photos_for_helper'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_found'');') > 0)),
  ('20261001000700', 'function marker', 'public.request_photos_for_helper: return jsonb_build_object(''ok'', true, ''paths'', v', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.request_photos_for_helper'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', true, ''paths'', v_paths);') > 0)),
  ('20261001000700', 'grant', 'public.request_photos_for_helper execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.request_photos_for_helper'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001000700', 'grant', 'public.request_photos_for_helper execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.request_photos_for_helper'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001001100', 'function marker', 'public.nearby_members: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_members'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_signed_in'');') > 0)),
  ('20261001001100', 'function marker', 'public.nearby_members: (p.available_to_help and coalesce(r.availability', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_members'
                        and strpos(p.prosrc, '(p.available_to_help and coalesce(r.availability, ''paused'') = ''active'') as available,') > 0)),
  ('20261001001100', 'function marker', 'public.nearby_members: coalesce(r.approval = ''approved'', false) as veri', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_members'
                        and strpos(p.prosrc, 'coalesce(r.approval = ''approved'', false) as verified,') > 0)),
  ('20261001001100', 'grant', 'public.nearby_members execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_members'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001001100', 'grant', 'public.nearby_members execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_members'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001001100', 'grant', 'public.member_profile execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.member_profile'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001001100', 'grant', 'public.member_profile execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.member_profile'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001001400', 'function marker', 'public.admin_suspend_member: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_suspend_member'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''cannot_suspend_self'');') > 0)),
  ('20261001001400', 'function marker', 'public.admin_suspend_member: if nullif(btrim(coalesce(p_reason, '''')), '''') is ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_suspend_member'
                        and strpos(p.prosrc, 'if nullif(btrim(coalesce(p_reason, '''')), '''') is null then') > 0)),
  ('20261001001400', 'function marker', 'public.admin_suspend_member: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_suspend_member'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''reason_required'');') > 0)),
  ('20261001001400', 'function marker', 'public.admin_restore_member: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_restore_member'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_found'');') > 0)),
  ('20261001001400', 'function marker', 'public.admin_restore_member: perform app.audit(''member.restore'', ''profile'', p', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_restore_member'
                        and strpos(p.prosrc, 'perform app.audit(''member.restore'', ''profile'', p_user_id::text, ''{}''::jsonb);') > 0)),
  ('20261001001400', 'function marker', 'public.admin_restore_member: return jsonb_build_object(''ok'', true, ''suspended', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_restore_member'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', true, ''suspended'', false);') > 0)),
  ('20261001001400', 'constraint', 'content_reports_target_kind_check', exists (select 1 from pg_constraint where conname = 'content_reports_target_kind_check')),
  ('20261001001400', 'grant', 'public.report_member execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.report_member'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001001400', 'grant', 'public.report_member execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.report_member'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001001400', 'grant', 'public.admin_suspend_member execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_suspend_member'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001001400', 'grant', 'public.admin_suspend_member execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_suspend_member'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001001400', 'grant', 'public.admin_restore_member execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_restore_member'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001001400', 'grant', 'public.admin_restore_member execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_restore_member'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001001400', 'grant', 'public.moderation_reported_members execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_reported_members'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001001400', 'grant', 'public.moderation_reported_members execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_reported_members'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001001500', 'function marker', 'public.moderation_queue: raise exception ''forbidden'' using errcode = ''ins', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_queue'
                        and strpos(p.prosrc, 'raise exception ''forbidden'' using errcode = ''insufficient_privilege'';') > 0)),
  ('20261001001500', 'function marker', 'public.moderation_queue: left join community_posts p on cr.target_kind = ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_queue'
                        and strpos(p.prosrc, 'left join community_posts p on cr.target_kind = ''post'' and p.id = cr.target_id') > 0)),
  ('20261001001500', 'function marker', 'public.moderation_queue: left join community_comments c on cr.target_kind', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_queue'
                        and strpos(p.prosrc, 'left join community_comments c on cr.target_kind = ''comment'' and c.id = cr.target_id') > 0)),
  ('20261001001500', 'grant', 'public.moderation_queue execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_queue'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001001500', 'grant', 'public.moderation_queue execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_queue'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001001600', 'function marker', 'public.moderation_reported_members: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_reported_members'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_allowed'');') > 0)),
  ('20261001001600', 'function marker', 'public.moderation_reported_members: count(cr.id) filter (where cr.status in (''new'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_reported_members'
                        and strpos(p.prosrc, 'count(cr.id) filter (where cr.status in (''new'', ''reviewing'')) as reports_open') > 0)),
  ('20261001001600', 'function marker', 'public.moderation_reported_members: on cr.target_kind = ''member'' and cr.target_id = ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_reported_members'
                        and strpos(p.prosrc, 'on cr.target_kind = ''member'' and cr.target_id = p.user_id') > 0)),
  ('20261001001600', 'grant', 'public.moderation_reported_members execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_reported_members'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001001600', 'grant', 'public.moderation_reported_members execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_reported_members'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001001800', 'function marker', 'public.community_report: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.community_report'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_signed_in'');') > 0)),
  ('20261001001800', 'function marker', 'public.community_report: if p_kind = ''post'' then', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.community_report'
                        and strpos(p.prosrc, 'if p_kind = ''post'' then') > 0)),
  ('20261001001800', 'function marker', 'public.community_report: elsif p_kind = ''comment'' then', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.community_report'
                        and strpos(p.prosrc, 'elsif p_kind = ''comment'' then') > 0)),
  ('20261001001800', 'grant', 'public.community_report execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.community_report'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001001800', 'grant', 'public.community_report execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.community_report'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001002200', 'function marker', 'app.notify: foreach v_channel in array coalesce(p_channels, ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.notify'
                        and strpos(p.prosrc, 'foreach v_channel in array coalesce(p_channels, array[''in_app'']::notification_channel[])') > 0)),
  ('20261001002200', 'function marker', 'app.notify: when p_kind = ''marketing'' then coalesce(v_profil', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.notify'
                        and strpos(p.prosrc, 'when p_kind = ''marketing'' then coalesce(v_profile.notify_marketing, false)') > 0)),
  ('20261001002200', 'function marker', 'app.notify: when p_kind = ''community'' or p_kind = ''event_rem', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.notify'
                        and strpos(p.prosrc, 'when p_kind = ''community'' or p_kind = ''event_reminder''') > 0)),
  ('20261001002300', 'function marker', 'app.dm_members_ok: where p.user_id = p_other', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.dm_members_ok'
                        and strpos(p.prosrc, 'where p.user_id = p_other') > 0)),
  ('20261001002300', 'function marker', 'app.dm_members_ok: where me.user_id = p_me', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.dm_members_ok'
                        and strpos(p.prosrc, 'where me.user_id = p_me') > 0)),
  ('20261001002300', 'function marker', 'public.dm_can_message: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_can_message'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_signed_in'');') > 0)),
  ('20261001002300', 'function marker', 'public.dm_can_message: return jsonb_build_object(''ok'', true, ''can_messa', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_can_message'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', true, ''can_message'', false, ''reason'', ''not_found'');') > 0)),
  ('20261001002300', 'function marker', 'public.dm_can_message: return jsonb_build_object(''ok'', true, ''can_messa', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_can_message'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', true, ''can_message'', true, ''thread_id'', v_thread);') > 0)),
  ('20261001002300', 'function marker', 'public.dm_send: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_send'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_signed_in'');') > 0)),
  ('20261001002300', 'function marker', 'public.dm_send: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_send'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''bad_client_id'');') > 0)),
  ('20261001002300', 'function marker', 'public.dm_send: return jsonb_build_object(''ok'', true, ''thread_id', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_send'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', true, ''thread_id'', v_thread, ''message_id'', v_id,') > 0)),
  ('20261001002300', 'grant', 'public.dm_can_message execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_can_message'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001002300', 'grant', 'public.dm_can_message execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_can_message'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001002300', 'grant', 'public.dm_send execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_send'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001002300', 'grant', 'public.dm_send execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_send'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001002400', 'function marker', 'app.dm_other_member: where t.id = p_thread_id', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.dm_other_member'
                        and strpos(p.prosrc, 'where t.id = p_thread_id') > 0)),
  ('20261001002400', 'function marker', 'public.dm_inbox: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_inbox'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_signed_in'');') > 0)),
  ('20261001002400', 'function marker', 'public.dm_inbox: return jsonb_build_object(''ok'', true, ''threads'',', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_inbox'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', true, ''threads'', v_rows);') > 0)),
  ('20261001002400', 'function marker', 'public.dm_thread: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_thread'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_signed_in'');') > 0)),
  ('20261001002400', 'function marker', 'public.dm_thread: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_thread'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_found'');') > 0)),
  ('20261001002400', 'function marker', 'public.dm_thread: ''user_id'',      op.user_id,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_thread'
                        and strpos(p.prosrc, '''user_id'',      op.user_id,') > 0)),
  ('20261001002400', 'function marker', 'public.dm_mark_read: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_mark_read'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_signed_in'');') > 0)),
  ('20261001002400', 'function marker', 'public.dm_mark_read: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_mark_read'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_found'');') > 0)),
  ('20261001002400', 'function marker', 'public.dm_mark_read: return jsonb_build_object(''ok'', true, ''marked'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_mark_read'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', true, ''marked'', v_count);') > 0)),
  ('20261001002400', 'grant', 'public.dm_inbox execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_inbox'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001002400', 'grant', 'public.dm_inbox execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_inbox'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001002400', 'grant', 'public.dm_thread execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_thread'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001002400', 'grant', 'public.dm_thread execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_thread'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001002400', 'grant', 'public.dm_mark_read execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_mark_read'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001002400', 'grant', 'public.dm_mark_read execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_mark_read'
                        and has_function_privilege('service_role', p.oid, 'execute')))
),
per_version as (
  select version,
         count(*)::int                        as checks,
         count(*) filter (where present)::int as passed
    from expected group by version
)
select
  version,
  checks,
  passed,
  case
    when passed = checks then 'EVIDENCE: every marker, constraint, grant and policy it defines is present'
    when passed = 0      then 'NO EVIDENCE: nothing it defines is present -- do not record'
    else                      'PARTIAL: inspect before recording'
  end as verdict,
  case when passed = checks
       then 'supabase migration repair --status applied ' || version
       else '-- withhold ' || version || ' (' || (checks - passed) || ' check(s) failed)'
  end as command
from per_version
order by version;

-- Which individual check failed, for anything above that is not clean.
with expected(version, kind, label, present) as (values
  ('20260923000250', 'function marker', 'public.handle_inbound_sms: values (''inbound'', ''received'', coalesce(p_to, ''u', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.handle_inbound_sms'
                        and strpos(p.prosrc, 'values (''inbound'', ''received'', coalesce(p_to, ''unknown''), p_from, p_body, p_twilio_sid)') > 0)),
  ('20260923000250', 'function marker', 'public.handle_inbound_sms: eta  := nullif(regexp_replace(coalesce(split_par', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.handle_inbound_sms'
                        and strpos(p.prosrc, 'eta  := nullif(regexp_replace(coalesce(split_part(body, '' '', 2), ''''), ''[^0-9]'', '''', ''g''), '''')::integer;') > 0)),
  ('20260923000250', 'function marker', 'public.handle_inbound_sms: if word in (''STOP'', ''STOPALL'', ''UNSUBSCRIBE'', ''C', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.handle_inbound_sms'
                        and strpos(p.prosrc, 'if word in (''STOP'', ''STOPALL'', ''UNSUBSCRIBE'', ''CANCEL'', ''END'', ''QUIT'', ''BAJA'') then') > 0)),
  ('20260923000250', 'grant', 'public.handle_inbound_sms execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.handle_inbound_sms'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260923000300', 'grant', 'public.nearby_requests execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_requests'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260923000300', 'grant', 'public.nearby_requests execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_requests'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260923000500', 'function marker', 'public.nearby_requests: mins => app.setting_int(''dispatch.location_fresh', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_requests'
                        and strpos(p.prosrc, 'mins => app.setting_int(''dispatch.location_freshness_minutes'', 120))') > 0)),
  ('20260923000500', 'function marker', 'public.nearby_requests: d.state = ''offered''', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_requests'
                        and strpos(p.prosrc, 'd.state = ''offered''') > 0)),
  ('20260923000500', 'function marker', 'public.nearby_requests: where r.status in (''submitted'', ''dispatching'', ''', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_requests'
                        and strpos(p.prosrc, 'where r.status in (''submitted'', ''dispatching'', ''unmatched'')') > 0)),
  ('20260923000500', 'grant', 'public.nearby_requests execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_requests'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260923000500', 'grant', 'public.nearby_requests execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_requests'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260923000600', 'function marker', 'public.my_requests: r.status in (''submitted'', ''dispatching'', ''unmatc', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_requests'
                        and strpos(p.prosrc, 'r.status in (''submitted'', ''dispatching'', ''unmatched'', ''accepted'', ''on_site''),') > 0)),
  ('20260923000600', 'function marker', 'public.my_requests: where d.request_id = r.id and d.state = ''offered', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_requests'
                        and strpos(p.prosrc, 'where d.request_id = r.id and d.state = ''offered'')') > 0)),
  ('20260923000600', 'function marker', 'public.my_requests: (r.status in (''submitted'', ''dispatching'', ''unmat', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_requests'
                        and strpos(p.prosrc, '(r.status in (''submitted'', ''dispatching'', ''unmatched'', ''accepted'', ''on_site'')) desc,') > 0)),
  ('20260923000600', 'grant', 'public.my_requests execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_requests'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260923000600', 'grant', 'public.my_requests execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_requests'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260923000700', 'function marker', 'public.system_health_summary: ''scheduler_age_seconds'',', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.system_health_summary'
                        and strpos(p.prosrc, '''scheduler_age_seconds'',') > 0)),
  ('20260923000700', 'function marker', 'public.system_health_summary: ''sms_queued'', (select count(*) from sms_messages', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.system_health_summary'
                        and strpos(p.prosrc, '''sms_queued'', (select count(*) from sms_messages where state = ''queued''),') > 0)),
  ('20260923000700', 'function marker', 'public.system_health_summary: ''sms_failed_24h'', (select count(*) from sms_mess', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.system_health_summary'
                        and strpos(p.prosrc, '''sms_failed_24h'', (select count(*) from sms_messages') > 0)),
  ('20260923000700', 'grant', 'public.system_health_summary execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.system_health_summary'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260923001400', 'function marker', 'public.set_recovery_mute: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.set_recovery_mute'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_signed_in'');') > 0)),
  ('20260923001400', 'function marker', 'public.set_recovery_mute: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.set_recovery_mute'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_found'');') > 0)),
  ('20260923001400', 'function marker', 'public.set_recovery_mute: return jsonb_build_object(''ok'', true, ''muted'', c', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.set_recovery_mute'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', true, ''muted'', coalesce(p_muted, false));') > 0)),
  ('20260923001400', 'grant', 'public.set_my_participant_status execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.set_my_participant_status'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260923001400', 'grant', 'public.set_my_participant_status execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.set_my_participant_status'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260923001400', 'grant', 'public.withdraw_from_recovery execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.withdraw_from_recovery'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260923001400', 'grant', 'public.withdraw_from_recovery execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.withdraw_from_recovery'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260923001400', 'grant', 'public.set_recovery_mute execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.set_recovery_mute'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260923001400', 'grant', 'public.set_recovery_mute execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.set_recovery_mute'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260923001500', 'grant', 'app.is_request_participant execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.is_request_participant'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260923001500', 'policy', 'recovery_participants_read_own_team', exists (select 1 from pg_policies where policyname = 'recovery_participants_read_own_team')),
  ('20260923002000', 'function marker', 'app.scrub_request: requester_name  = ''Removed'',', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.scrub_request'
                        and strpos(p.prosrc, 'requester_name  = ''Removed'',') > 0)),
  ('20260923002000', 'function marker', 'app.scrub_responder: first_name    = ''Removed'',', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.scrub_responder'
                        and strpos(p.prosrc, 'first_name    = ''Removed'',') > 0)),
  ('20260923002000', 'function marker', 'app.scrub_responder: availability  = ''paused'',', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.scrub_responder'
                        and strpos(p.prosrc, 'availability  = ''paused'',') > 0)),
  ('20260923002000', 'function marker', 'app.scrub_responder: approval      = ''rejected'',', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.scrub_responder'
                        and strpos(p.prosrc, 'approval      = ''rejected'',') > 0)),
  ('20260923002400', 'function marker', 'public.get_request_by_token: and r.status in (''accepted'', ''on_site'', ''recover', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.get_request_by_token'
                        and strpos(p.prosrc, 'and r.status in (''accepted'', ''on_site'', ''recovered'');') > 0)),
  ('20260923002400', 'function marker', 'public.get_request_by_token: select value into radii from public.app_settings', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.get_request_by_token'
                        and strpos(p.prosrc, 'select value into radii from public.app_settings where key = ''dispatch.ring_radii_miles'';') > 0)),
  ('20260923002400', 'function marker', 'public.get_request_by_token: ''short_code'',      r.short_code,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.get_request_by_token'
                        and strpos(p.prosrc, '''short_code'',      r.short_code,') > 0)),
  ('20260923002500', 'function marker', 'public.my_responder_profile: ''first_name'', me.first_name,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_responder_profile'
                        and strpos(p.prosrc, '''first_name'', me.first_name,') > 0)),
  ('20260923002500', 'function marker', 'public.my_responder_profile: ''last_name'', me.last_name,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_responder_profile'
                        and strpos(p.prosrc, '''last_name'', me.last_name,') > 0)),
  ('20260923002500', 'function marker', 'public.my_responder_profile: ''phone'', me.phone,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_responder_profile'
                        and strpos(p.prosrc, '''phone'', me.phone,') > 0)),
  ('20260923002500', 'grant', 'public.my_responder_profile execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_responder_profile'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260923002500', 'grant', 'public.my_responder_profile execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_responder_profile'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260923002600', 'function marker', 'public.claim_push_deliveries: where d.channel = ''push''', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.claim_push_deliveries'
                        and strpos(p.prosrc, 'where d.channel = ''push''') > 0)),
  ('20260923002600', 'function marker', 'public.claim_push_deliveries: and d.state in (''queued'', ''failed'')', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.claim_push_deliveries'
                        and strpos(p.prosrc, 'and d.state in (''queued'', ''failed'')') > 0)),
  ('20260923002600', 'grant', 'public.claim_push_deliveries execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.claim_push_deliveries'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260923002700', 'function marker', 'public.request_thread: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.request_thread'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_found'');') > 0)),
  ('20260923002700', 'function marker', 'public.request_thread: select r.status in (''recovered'', ''cancelled'', ''e', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.request_thread'
                        and strpos(p.prosrc, 'select r.status in (''recovered'', ''cancelled'', ''expired'') into v_closed') > 0)),
  ('20260923002700', 'function marker', 'public.request_thread: ''lat'',        round(extensions.st_y(r.location::', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.request_thread'
                        and strpos(p.prosrc, '''lat'',        round(extensions.st_y(r.location::extensions.geometry)::numeric, 6),') > 0)),
  ('20260924000100', 'grant', 'public.nearby_members execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_members'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260924000100', 'grant', 'public.nearby_members execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_members'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260924000100', 'grant', 'public.member_profile execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.member_profile'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260924000100', 'grant', 'public.member_profile execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.member_profile'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260925000100', 'function marker', 'app.queue_sms: v_master  boolean := app.setting_bool(''sms.outbo', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.queue_sms'
                        and strpos(p.prosrc, 'v_master  boolean := app.setting_bool(''sms.outbound_enabled'', false);') > 0)),
  ('20260925000100', 'function marker', 'app.queue_sms: (select value from public.app_settings where key', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.queue_sms'
                        and strpos(p.prosrc, '(select value from public.app_settings where key = ''sms.enabled_templates'')') > 0)),
  ('20260925000100', 'function marker', 'app.queue_sms: v_reason := ''sms.outbound_enabled is off; sent b', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.queue_sms'
                        and strpos(p.prosrc, 'v_reason := ''sms.outbound_enabled is off; sent by push and in-app instead'';') > 0)),
  ('20260927000100', 'function marker', 'app.handle_new_user: v_name := btrim(coalesce(new.raw_user_meta_data ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.handle_new_user'
                        and strpos(p.prosrc, 'v_name := btrim(coalesce(new.raw_user_meta_data ->> ''full_name'', ''''));') > 0)),
  ('20260927000100', 'function marker', 'app.handle_new_user: insert into user_roles (user_id, role) values (n', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.handle_new_user'
                        and strpos(p.prosrc, 'insert into user_roles (user_id, role) values (new.id, ''member'')') > 0)),
  ('20260928000300', 'function marker', 'app.membership_state: ''has_agreement'', a.id is not null,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.membership_state'
                        and strpos(p.prosrc, '''has_agreement'', a.id is not null,') > 0)),
  ('20260928000300', 'function marker', 'app.membership_state: ''version'',       a.version,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.membership_state'
                        and strpos(p.prosrc, '''version'',       a.version,') > 0)),
  ('20260928000300', 'function marker', 'app.membership_state: ''signed'',        v_signed_at is not null,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.membership_state'
                        and strpos(p.prosrc, '''signed'',        v_signed_at is not null,') > 0)),
  ('20260928000300', 'function marker', 'app.membership_gate_blocks: from public.app_settings where key = ''membership', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.membership_gate_blocks'
                        and strpos(p.prosrc, 'from public.app_settings where key = ''membership.required'';') > 0)),
  ('20260928000300', 'function marker', 'app.membership_gate_blocks: return (v_state ->> ''has_agreement'')::boolean', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.membership_gate_blocks'
                        and strpos(p.prosrc, 'return (v_state ->> ''has_agreement'')::boolean') > 0)),
  ('20260928000300', 'function marker', 'app.membership_gate_blocks: and not (v_state ->> ''signed'')::boolean;', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.membership_gate_blocks'
                        and strpos(p.prosrc, 'and not (v_state ->> ''signed'')::boolean;') > 0)),
  ('20260928000300', 'function marker', 'public.membership_agreement: from public.app_settings where key = ''membership', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.membership_agreement'
                        and strpos(p.prosrc, 'from public.app_settings where key = ''membership.required'';') > 0)),
  ('20260928000300', 'function marker', 'public.membership_agreement: ''required'', coalesce(v_required, false),', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.membership_agreement'
                        and strpos(p.prosrc, '''required'', coalesce(v_required, false),') > 0)),
  ('20260928000300', 'function marker', 'public.membership_agreement: ''agreement'', case when a.id is null then null el', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.membership_agreement'
                        and strpos(p.prosrc, '''agreement'', case when a.id is null then null else jsonb_build_object(') > 0)),
  ('20260928000300', 'function marker', 'public.sign_membership_agreement: v_user      uuid := nullif(p_payload ->> ''user_i', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.sign_membership_agreement'
                        and strpos(p.prosrc, 'v_user      uuid := nullif(p_payload ->> ''user_id'', '''')::uuid;') > 0)),
  ('20260928000300', 'function marker', 'public.sign_membership_agreement: v_legal     text := nullif(btrim(coalesce(p_payl', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.sign_membership_agreement'
                        and strpos(p.prosrc, 'v_legal     text := nullif(btrim(coalesce(p_payload ->> ''legal_name'', '''')), '''');') > 0)),
  ('20260928000300', 'function marker', 'public.sign_membership_agreement: v_signature text := nullif(btrim(coalesce(p_payl', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.sign_membership_agreement'
                        and strpos(p.prosrc, 'v_signature text := nullif(btrim(coalesce(p_payload ->> ''signature_text'', '''')), '''');') > 0)),
  ('20260928000300', 'grant', 'public.membership_agreement execute to anon', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.membership_agreement'
                        and has_function_privilege('anon', p.oid, 'execute'))),
  ('20260928000300', 'grant', 'public.membership_agreement execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.membership_agreement'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260928000300', 'grant', 'public.membership_agreement execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.membership_agreement'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260928000300', 'grant', 'public.sign_membership_agreement execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.sign_membership_agreement'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260928000400', 'function marker', 'public.admin_publish_membership_agreement: if length(btrim(coalesce(p_body_en, ''''))) < 20 o', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_publish_membership_agreement'
                        and strpos(p.prosrc, 'if length(btrim(coalesce(p_body_en, ''''))) < 20 or length(btrim(coalesce(p_body_es, ''''))) < 20 then') > 0)),
  ('20260928000400', 'function marker', 'public.admin_publish_membership_agreement: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_publish_membership_agreement'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''both_languages_required'');') > 0)),
  ('20260928000400', 'function marker', 'public.admin_publish_membership_agreement: perform app.audit(''membership_agreement.publish''', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_publish_membership_agreement'
                        and strpos(p.prosrc, 'perform app.audit(''membership_agreement.publish'', ''membership_agreements'', v_id::text,') > 0)),
  ('20260928000400', 'function marker', 'public.admin_membership_agreements: ''version'', a.version,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_membership_agreements'
                        and strpos(p.prosrc, '''version'', a.version,') > 0)),
  ('20260928000400', 'function marker', 'public.admin_membership_agreements: ''is_current'', a.is_current,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_membership_agreements'
                        and strpos(p.prosrc, '''is_current'', a.is_current,') > 0)),
  ('20260928000400', 'function marker', 'public.admin_membership_agreements: ''effective_at'', a.effective_at,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_membership_agreements'
                        and strpos(p.prosrc, '''effective_at'', a.effective_at,') > 0)),
  ('20260928000400', 'function marker', 'public.admin_membership_signatures: v_q     text    := nullif(btrim(coalesce(p_searc', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_membership_signatures'
                        and strpos(p.prosrc, 'v_q     text    := nullif(btrim(coalesce(p_search, '''')), '''');') > 0)),
  ('20260928000400', 'function marker', 'public.admin_membership_signatures: and (v_q is null or s.legal_name ilike ''%'' || v_', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_membership_signatures'
                        and strpos(p.prosrc, 'and (v_q is null or s.legal_name ilike ''%'' || v_q || ''%'');') > 0)),
  ('20260928000400', 'function marker', 'public.admin_membership_signatures: ''user_id'', s.user_id,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_membership_signatures'
                        and strpos(p.prosrc, '''user_id'', s.user_id,') > 0)),
  ('20260928000400', 'grant', 'public.admin_publish_membership_agreement execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_publish_membership_agreement'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260928000400', 'grant', 'public.admin_publish_membership_agreement execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_publish_membership_agreement'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260928000400', 'grant', 'public.admin_membership_agreements execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_membership_agreements'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260928000400', 'grant', 'public.admin_membership_agreements execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_membership_agreements'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260928000400', 'grant', 'public.admin_membership_signatures execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_membership_signatures'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260928000400', 'grant', 'public.admin_membership_signatures execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_membership_signatures'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260928000600', 'function marker', 'public.create_request: v_submission_id uuid   := nullif(p_payload ->> ''', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.create_request'
                        and strpos(p.prosrc, 'v_submission_id uuid   := nullif(p_payload ->> ''submission_id'', '''')::uuid;') > 0)),
  ('20260928000600', 'function marker', 'public.create_request: v_phone         text   := btrim(p_payload ->> ''p', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.create_request'
                        and strpos(p.prosrc, 'v_phone         text   := btrim(p_payload ->> ''phone'');') > 0)),
  ('20260928000600', 'function marker', 'public.create_request: v_locale        text   := coalesce(nullif(p_payl', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.create_request'
                        and strpos(p.prosrc, 'v_locale        text   := coalesce(nullif(p_payload ->> ''locale'', ''''), ''en'');') > 0)),
  ('20260928000600', 'function marker', 'public.offer_assistance: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.offer_assistance'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_signed_in'');') > 0)),
  ('20260928000600', 'function marker', 'public.offer_assistance: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.offer_assistance'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''membership_agreement_required'');') > 0)),
  ('20260928000600', 'function marker', 'public.offer_assistance: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.offer_assistance'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''equipment_not_acknowledged'');') > 0)),
  ('20260928000600', 'grant', 'public.create_request execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.create_request'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260928000600', 'grant', 'public.offer_assistance execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.offer_assistance'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260928000600', 'grant', 'public.offer_assistance execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.offer_assistance'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260928000800', 'grant', 'public.upsert_responder_profile execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.upsert_responder_profile'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260928000800', 'grant', 'public.upsert_responder_profile execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.upsert_responder_profile'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260928001000', 'grant', 'public.member_profile execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.member_profile'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20260928001000', 'grant', 'public.member_profile execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.member_profile'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20260930000100', 'function marker', 'public.my_security_state: raise exception ''not signed in'' using errcode = ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_security_state'
                        and strpos(p.prosrc, 'raise exception ''not signed in'' using errcode = ''42501'';') > 0)),
  ('20260930000100', 'function marker', 'public.my_security_state: coalesce(encrypted_password, '''') <> ''''   as has_', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_security_state'
                        and strpos(p.prosrc, 'coalesce(encrypted_password, '''') <> ''''   as has_password,') > 0)),
  ('20260930000100', 'function marker', 'public.my_security_state: and provider not in (''email'', ''phone'');', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_security_state'
                        and strpos(p.prosrc, 'and provider not in (''email'', ''phone'');') > 0)),
  ('20260930000100', 'grant', 'public.my_security_state execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.my_security_state'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001000100', 'function marker', 'app.ad_slot_allowed: when p_surface = ''resources'' and coalesce(p_slug', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.ad_slot_allowed'
                        and strpos(p.prosrc, 'when p_surface = ''resources'' and coalesce(p_slug, '''') in (''stuck'', ''safety'', ''emergency'')') > 0)),
  ('20261001000700', 'function marker', 'app.may_see_request_photos: where key = ''dispatch.ring_radii_miles''', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.may_see_request_photos'
                        and strpos(p.prosrc, 'where key = ''dispatch.ring_radii_miles''') > 0)),
  ('20261001000700', 'function marker', 'app.may_see_request_photos: where req.status in (''submitted'', ''dispatching'',', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.may_see_request_photos'
                        and strpos(p.prosrc, 'where req.status in (''submitted'', ''dispatching'', ''unmatched'')') > 0)),
  ('20261001000700', 'function marker', 'app.may_see_request_photos: and resp.availability = ''active''', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.may_see_request_photos'
                        and strpos(p.prosrc, 'and resp.availability = ''active''') > 0)),
  ('20261001000700', 'function marker', 'public.request_photos_for_helper: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.request_photos_for_helper'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_signed_in'');') > 0)),
  ('20261001000700', 'function marker', 'public.request_photos_for_helper: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.request_photos_for_helper'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_found'');') > 0)),
  ('20261001000700', 'function marker', 'public.request_photos_for_helper: return jsonb_build_object(''ok'', true, ''paths'', v', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.request_photos_for_helper'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', true, ''paths'', v_paths);') > 0)),
  ('20261001000700', 'grant', 'public.request_photos_for_helper execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.request_photos_for_helper'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001000700', 'grant', 'public.request_photos_for_helper execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.request_photos_for_helper'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001001100', 'function marker', 'public.nearby_members: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_members'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_signed_in'');') > 0)),
  ('20261001001100', 'function marker', 'public.nearby_members: (p.available_to_help and coalesce(r.availability', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_members'
                        and strpos(p.prosrc, '(p.available_to_help and coalesce(r.availability, ''paused'') = ''active'') as available,') > 0)),
  ('20261001001100', 'function marker', 'public.nearby_members: coalesce(r.approval = ''approved'', false) as veri', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_members'
                        and strpos(p.prosrc, 'coalesce(r.approval = ''approved'', false) as verified,') > 0)),
  ('20261001001100', 'grant', 'public.nearby_members execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_members'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001001100', 'grant', 'public.nearby_members execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.nearby_members'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001001100', 'grant', 'public.member_profile execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.member_profile'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001001100', 'grant', 'public.member_profile execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.member_profile'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001001400', 'function marker', 'public.admin_suspend_member: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_suspend_member'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''cannot_suspend_self'');') > 0)),
  ('20261001001400', 'function marker', 'public.admin_suspend_member: if nullif(btrim(coalesce(p_reason, '''')), '''') is ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_suspend_member'
                        and strpos(p.prosrc, 'if nullif(btrim(coalesce(p_reason, '''')), '''') is null then') > 0)),
  ('20261001001400', 'function marker', 'public.admin_suspend_member: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_suspend_member'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''reason_required'');') > 0)),
  ('20261001001400', 'function marker', 'public.admin_restore_member: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_restore_member'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_found'');') > 0)),
  ('20261001001400', 'function marker', 'public.admin_restore_member: perform app.audit(''member.restore'', ''profile'', p', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_restore_member'
                        and strpos(p.prosrc, 'perform app.audit(''member.restore'', ''profile'', p_user_id::text, ''{}''::jsonb);') > 0)),
  ('20261001001400', 'function marker', 'public.admin_restore_member: return jsonb_build_object(''ok'', true, ''suspended', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_restore_member'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', true, ''suspended'', false);') > 0)),
  ('20261001001400', 'constraint', 'content_reports_target_kind_check', exists (select 1 from pg_constraint where conname = 'content_reports_target_kind_check')),
  ('20261001001400', 'grant', 'public.report_member execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.report_member'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001001400', 'grant', 'public.report_member execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.report_member'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001001400', 'grant', 'public.admin_suspend_member execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_suspend_member'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001001400', 'grant', 'public.admin_suspend_member execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_suspend_member'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001001400', 'grant', 'public.admin_restore_member execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_restore_member'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001001400', 'grant', 'public.admin_restore_member execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.admin_restore_member'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001001400', 'grant', 'public.moderation_reported_members execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_reported_members'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001001400', 'grant', 'public.moderation_reported_members execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_reported_members'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001001500', 'function marker', 'public.moderation_queue: raise exception ''forbidden'' using errcode = ''ins', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_queue'
                        and strpos(p.prosrc, 'raise exception ''forbidden'' using errcode = ''insufficient_privilege'';') > 0)),
  ('20261001001500', 'function marker', 'public.moderation_queue: left join community_posts p on cr.target_kind = ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_queue'
                        and strpos(p.prosrc, 'left join community_posts p on cr.target_kind = ''post'' and p.id = cr.target_id') > 0)),
  ('20261001001500', 'function marker', 'public.moderation_queue: left join community_comments c on cr.target_kind', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_queue'
                        and strpos(p.prosrc, 'left join community_comments c on cr.target_kind = ''comment'' and c.id = cr.target_id') > 0)),
  ('20261001001500', 'grant', 'public.moderation_queue execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_queue'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001001500', 'grant', 'public.moderation_queue execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_queue'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001001600', 'function marker', 'public.moderation_reported_members: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_reported_members'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_allowed'');') > 0)),
  ('20261001001600', 'function marker', 'public.moderation_reported_members: count(cr.id) filter (where cr.status in (''new'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_reported_members'
                        and strpos(p.prosrc, 'count(cr.id) filter (where cr.status in (''new'', ''reviewing'')) as reports_open') > 0)),
  ('20261001001600', 'function marker', 'public.moderation_reported_members: on cr.target_kind = ''member'' and cr.target_id = ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_reported_members'
                        and strpos(p.prosrc, 'on cr.target_kind = ''member'' and cr.target_id = p.user_id') > 0)),
  ('20261001001600', 'grant', 'public.moderation_reported_members execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_reported_members'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001001600', 'grant', 'public.moderation_reported_members execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.moderation_reported_members'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001001800', 'function marker', 'public.community_report: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.community_report'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_signed_in'');') > 0)),
  ('20261001001800', 'function marker', 'public.community_report: if p_kind = ''post'' then', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.community_report'
                        and strpos(p.prosrc, 'if p_kind = ''post'' then') > 0)),
  ('20261001001800', 'function marker', 'public.community_report: elsif p_kind = ''comment'' then', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.community_report'
                        and strpos(p.prosrc, 'elsif p_kind = ''comment'' then') > 0)),
  ('20261001001800', 'grant', 'public.community_report execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.community_report'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001001800', 'grant', 'public.community_report execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.community_report'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001002200', 'function marker', 'app.notify: foreach v_channel in array coalesce(p_channels, ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.notify'
                        and strpos(p.prosrc, 'foreach v_channel in array coalesce(p_channels, array[''in_app'']::notification_channel[])') > 0)),
  ('20261001002200', 'function marker', 'app.notify: when p_kind = ''marketing'' then coalesce(v_profil', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.notify'
                        and strpos(p.prosrc, 'when p_kind = ''marketing'' then coalesce(v_profile.notify_marketing, false)') > 0)),
  ('20261001002200', 'function marker', 'app.notify: when p_kind = ''community'' or p_kind = ''event_rem', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.notify'
                        and strpos(p.prosrc, 'when p_kind = ''community'' or p_kind = ''event_reminder''') > 0)),
  ('20261001002300', 'function marker', 'app.dm_members_ok: where p.user_id = p_other', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.dm_members_ok'
                        and strpos(p.prosrc, 'where p.user_id = p_other') > 0)),
  ('20261001002300', 'function marker', 'app.dm_members_ok: where me.user_id = p_me', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.dm_members_ok'
                        and strpos(p.prosrc, 'where me.user_id = p_me') > 0)),
  ('20261001002300', 'function marker', 'public.dm_can_message: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_can_message'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_signed_in'');') > 0)),
  ('20261001002300', 'function marker', 'public.dm_can_message: return jsonb_build_object(''ok'', true, ''can_messa', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_can_message'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', true, ''can_message'', false, ''reason'', ''not_found'');') > 0)),
  ('20261001002300', 'function marker', 'public.dm_can_message: return jsonb_build_object(''ok'', true, ''can_messa', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_can_message'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', true, ''can_message'', true, ''thread_id'', v_thread);') > 0)),
  ('20261001002300', 'function marker', 'public.dm_send: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_send'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_signed_in'');') > 0)),
  ('20261001002300', 'function marker', 'public.dm_send: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_send'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''bad_client_id'');') > 0)),
  ('20261001002300', 'function marker', 'public.dm_send: return jsonb_build_object(''ok'', true, ''thread_id', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_send'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', true, ''thread_id'', v_thread, ''message_id'', v_id,') > 0)),
  ('20261001002300', 'grant', 'public.dm_can_message execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_can_message'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001002300', 'grant', 'public.dm_can_message execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_can_message'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001002300', 'grant', 'public.dm_send execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_send'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001002300', 'grant', 'public.dm_send execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_send'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001002400', 'function marker', 'app.dm_other_member: where t.id = p_thread_id', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'app.dm_other_member'
                        and strpos(p.prosrc, 'where t.id = p_thread_id') > 0)),
  ('20261001002400', 'function marker', 'public.dm_inbox: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_inbox'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_signed_in'');') > 0)),
  ('20261001002400', 'function marker', 'public.dm_inbox: return jsonb_build_object(''ok'', true, ''threads'',', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_inbox'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', true, ''threads'', v_rows);') > 0)),
  ('20261001002400', 'function marker', 'public.dm_thread: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_thread'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_signed_in'');') > 0)),
  ('20261001002400', 'function marker', 'public.dm_thread: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_thread'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_found'');') > 0)),
  ('20261001002400', 'function marker', 'public.dm_thread: ''user_id'',      op.user_id,', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_thread'
                        and strpos(p.prosrc, '''user_id'',      op.user_id,') > 0)),
  ('20261001002400', 'function marker', 'public.dm_mark_read: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_mark_read'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_signed_in'');') > 0)),
  ('20261001002400', 'function marker', 'public.dm_mark_read: return jsonb_build_object(''ok'', false, ''error'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_mark_read'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', false, ''error'', ''not_found'');') > 0)),
  ('20261001002400', 'function marker', 'public.dm_mark_read: return jsonb_build_object(''ok'', true, ''marked'', ', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_mark_read'
                        and strpos(p.prosrc, 'return jsonb_build_object(''ok'', true, ''marked'', v_count);') > 0)),
  ('20261001002400', 'grant', 'public.dm_inbox execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_inbox'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001002400', 'grant', 'public.dm_inbox execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_inbox'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001002400', 'grant', 'public.dm_thread execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_thread'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001002400', 'grant', 'public.dm_thread execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_thread'
                        and has_function_privilege('service_role', p.oid, 'execute'))),
  ('20261001002400', 'grant', 'public.dm_mark_read execute to authenticated', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_mark_read'
                        and has_function_privilege('authenticated', p.oid, 'execute'))),
  ('20261001002400', 'grant', 'public.dm_mark_read execute to service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname || '.' || p.proname = 'public.dm_mark_read'
                        and has_function_privilege('service_role', p.oid, 'execute')))
)
select version, kind, label
  from expected
 where not present
 order by version, kind, label;

-- Still unverifiable, and therefore still pending by the owner's rule:
--   20260923001600
--   20260923001800
--   20260928000100
--   20260928000700
--   20261001000500
--   20261001000600
--   20261001001200
--   20261001001900
--   20261001002500
--   20261005001000
--   20261005001100
