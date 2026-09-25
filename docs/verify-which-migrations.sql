-- Winch Up :: which migration files still need running?
--
-- The companion to verify-universal-membership.sql, for when the answer is "a lot". That one
-- lists every object; this one collapses to one row per file, so the output is the paste list.
--
-- One statement, one result set -- same reason as the other file.

with expected(kind, name, detail, migration, file) as (
  values
    ('column',   'profiles.available_to_help',            '', '000100', '20260923000100_universal_membership.sql'),
    ('nullable', 'responders.phone',                      '', '000100', '20260923000100_universal_membership.sql'),
    ('nullable', 'responders.home_location',              '', '000100', '20260923000100_universal_membership.sql'),
    ('function', 'ensure_recovery_profile',               '', '000100', '20260923000100_universal_membership.sql'),
    ('function', 'set_available_to_help',                 '', '000100', '20260923000100_universal_membership.sql'),
    ('nogate',   'candidates',                      'approval', '000100', '20260923000100_universal_membership.sql'),
    ('enum',     'dispatch_state.offered',                '', '000150', '20260923000150_offer_states.sql'),
    ('enum',     'dispatch_state.passed_over',            '', '000150', '20260923000150_offer_states.sql'),
    ('enum',     'request_event_type.responder_offered',  '', '000150', '20260923000150_offer_states.sql'),
    ('enum',     'request_event_type.responder_withdrew', '', '000150', '20260923000150_offer_states.sql'),
    ('enum',     'request_event_type.offer_declined',     '', '000150', '20260923000150_offer_states.sql'),
    ('type',     'offer_origin',                          '', '000200', '20260923000200_assistance_offers.sql'),
    ('column',   'dispatches.offer_note',                 '', '000200', '20260923000200_assistance_offers.sql'),
    ('column',   'dispatches.offer_eta_minutes',          '', '000200', '20260923000200_assistance_offers.sql'),
    ('column',   'dispatches.equipment_ack',              '', '000200', '20260923000200_assistance_offers.sql'),
    ('function', 'offer_assistance',                      '', '000200', '20260923000200_assistance_offers.sql'),
    ('function', 'accept_offer_by_token',                 '', '000200', '20260923000200_assistance_offers.sql'),
    ('function', 'decline_offer_by_token',                '', '000200', '20260923000200_assistance_offers.sql'),
    ('function', 'withdraw_my_offer',                     '', '000200', '20260923000200_assistance_offers.sql'),
    ('function', 'assign_responder',                      '', '000200', '20260923000200_assistance_offers.sql'),
    ('hasref',   'handle_inbound_sms',        'record_offer', '000250', '20260923000250_inbound_offer.sql'),
    ('function', 'nearby_requests',                       '', '000300', '20260923000300_help_feed.sql'),
    ('hasref',   'nearby_requests',               'r.notes', '000500', '20260923000500_help_feed_notes.sql'),
    ('table',    'push_subscriptions',                    '', '000400', '20260923000400_push.sql'),
    ('function', 'save_push_subscription',                '', '000400', '20260923000400_push.sql'),
    ('function', 'delete_push_subscription',              '', '000400', '20260923000400_push.sql'),
    ('function', 'claim_push_deliveries',                 '', '000400', '20260923000400_push.sql'),
    ('function', 'record_push_result',                    '', '000400', '20260923000400_push.sql'),
    ('function', 'my_requests',                           '', '000600', '20260923000600_my_requests.sql'),
    ('hasref',   'system_health_summary', 'reachable_volunteers', '000700', '20260923000700_health_reachable.sql'),
    ('enum',     'request_event_type.helper_joined',      '', '001000', '20260923001000_team_chat_enums.sql'),
    ('enum',     'request_event_type.helper_withdrew',    '', '001000', '20260923001000_team_chat_enums.sql'),
    ('enum',     'request_event_type.helper_status',      '', '001000', '20260923001000_team_chat_enums.sql'),
    ('enum',     'notification_kind.helper_joined',       '', '001000', '20260923001000_team_chat_enums.sql'),
    ('enum',     'notification_kind.helper_status',       '', '001000', '20260923001000_team_chat_enums.sql'),
    ('table',    'recovery_participants',                 '', '001100', '20260923001100_recovery_participants.sql'),
    ('type',     'participant_role',                      '', '001100', '20260923001100_recovery_participants.sql'),
    ('type',     'participant_status',                    '', '001100', '20260923001100_recovery_participants.sql'),
    ('function', 'sync_recovery_lead',                    '', '001100', '20260923001100_recovery_participants.sql'),
    ('function', 'request_thread',                        '', '001200', '20260923001200_thread_access.sql'),
    ('function', 'my_unread_counts',                      '', '001200', '20260923001200_thread_access.sql'),
    ('hasref',   'is_request_participant', 'recovery_participants', '001200', '20260923001200_thread_access.sql'),
    ('trigger',  'requests_add_requester_participant',    '', '001200', '20260923001200_thread_access.sql'),
    ('function', 'sync_lead_participant',                 '', '001300', '20260923001300_team_membership_sync.sql'),
    ('trigger',  'requests_sync_lead_participant',        '', '001300', '20260923001300_team_membership_sync.sql'),
    ('hasref',   'sync_lead_participant', 'accepted_responder_id', '001300', '20260923001300_team_membership_sync.sql'),
    ('function', 'set_my_participant_status',             '', '001400', '20260923001400_participant_actions.sql'),
    ('function', 'withdraw_from_recovery',                '', '001400', '20260923001400_participant_actions.sql'),
    ('function', 'set_recovery_mute',                     '', '001400', '20260923001400_participant_actions.sql'),
    ('policyref','recovery_participants', 'is_request_participant', '001500', '20260923001500_participants_policy_fix.sql'),
    ('hasref',   'get_request_by_token',            'team', '001600', '20260923001600_status_team.sql'),
    ('column',   'profiles.notify_chat',                  '', '001700', '20260923001700_chat_notifications.sql'),
    ('column',   'profiles.notify_recovery_status',       '', '001700', '20260923001700_chat_notifications.sql'),
    ('function', 'notify_on_recovery_message',            '', '001700', '20260923001700_chat_notifications.sql'),
    ('function', 'recovery_link',                         '', '001700', '20260923001700_chat_notifications.sql'),
    ('trigger',  'request_messages_notify',               '', '001700', '20260923001700_chat_notifications.sql'),
    ('hasref',   'claim_push_deliveries',          'n.url', '002600', '20260923002600_claim_push_url.sql'),
    ('colgrant', 'profiles.notify_chat',           'SELECT', '001800', '20260923001800_notify_column_grants.sql'),
    ('colgrant', 'profiles.notify_chat',           'UPDATE', '001800', '20260923001800_notify_column_grants.sql'),
    ('colgrant', 'profiles.notify_recovery_status','SELECT', '001800', '20260923001800_notify_column_grants.sql'),
    ('colgrant', 'profiles.notify_recovery_status','UPDATE', '001800', '20260923001800_notify_column_grants.sql'),
    ('colgrant', 'profiles.available_to_help',     'SELECT', '001800', '20260923001800_notify_column_grants.sql'),
    ('enum',     'sms_state.suppressed',                  '', '001900', '20260923001900_sms_suppressed.sql'),
    ('setting',  'sms.outbound_enabled',                  '', '002000', '20260923002000_sms_off.sql'),
    ('hasref',   'queue_sms',         'sms.outbound_enabled', '002000', '20260923002000_sms_off.sql'),
    ('hasref',   'scrub_request',                  'params', '002000', '20260923002000_sms_off.sql'),
    ('hasref',   'scrub_responder',          'sms_messages', '002000', '20260923002000_sms_off.sql'),
    ('column',   'request_messages.client_id',            '', '002100', '20260923002100_message_client_id.sql'),
    ('hasref',   'send_request_message',        'client_id', '002100', '20260923002100_message_client_id.sql'),
    ('hasref',   'request_thread',              'client_id', '002100', '20260923002100_message_client_id.sql'),
    ('function', 'broadcast_recovery_change',             '', '002200', '20260923002200_realtime_broadcast.sql'),
    ('trigger',  'request_messages_broadcast',            '', '002200', '20260923002200_realtime_broadcast.sql'),
    ('trigger',  'recovery_participants_broadcast',       '', '002200', '20260923002200_realtime_broadcast.sql'),
    ('hasref',   'assign_responder',            'v_is_lead', '002300', '20260923002300_second_helper.sql'),
    ('function', 'stand_down_open_offers',                '', '002300', '20260923002300_second_helper.sql'),
    ('trigger',  'requests_stand_down_offers',            '', '002300', '20260923002300_second_helper.sql'),
    ('hasref',   'accept_offer_by_token', 'assign_responder', '002300', '20260923002300_second_helper.sql'),
    ('hasref',   'get_request_by_token', '''unmatched'', ''accepted'', ''on_site'')', '002400', '20260923002400_offers_after_accept.sql'),
    ('hasref',   'my_responder_profile', 'recovery_participants', '002500', '20260923002500_second_helper_dashboard.sql'),
    ('hasref',   'request_thread',        'location_source', '002700', '20260923002700_thread_location.sql'),
    ('function', 'nearby_members',                        '', '000100', '20260924000100_nearby_members.sql'),
    ('function', 'member_profile',                        '', '000100', '20260924000100_nearby_members.sql'),
    ('function', 'coarse_miles',                          '', '000100', '20260924000100_nearby_members.sql'),
    ('hasref',   'nearby_members',        'profile_public', '000100', '20260924000100_nearby_members.sql'),
    ('hasref',   'nearby_members',      'available_to_help', '000100', '20260924000100_nearby_members.sql'),
    ('table',    'email_deliveries',                      '', '000200', '20260924000200_email_deliveries.sql'),
    ('function', 'admin_email_deliveries',                '', '000200', '20260924000200_email_deliveries.sql'),
    ('index',    'email_deliveries_idempotency_idx',      '', '000200', '20260924000200_email_deliveries.sql'),
    ('function', 'queue_welcome_email',                   '', '000300', '20260924000300_welcome_email.sql'),
    ('function', 'claim_email_deliveries',                '', '000300', '20260924000300_welcome_email.sql'),
    ('function', 'record_email_result',                   '', '000300', '20260924000300_welcome_email.sql'),
    ('trigger',  'on_email_confirmed',                    '', '000300', '20260924000300_welcome_email.sql'),
    ('trigger',  'on_user_created_confirmed',             '', '000300', '20260924000300_welcome_email.sql')
),
checked as (
  select
    e.*,
    case e.kind
      when 'table' then exists (
        select 1 from information_schema.tables
         where table_schema = 'public' and table_name = e.name)
      when 'column' then exists (
        select 1 from information_schema.columns
         where table_schema = 'public'
           and table_name = split_part(e.name, '.', 1)
           and column_name = split_part(e.name, '.', 2))
      when 'nullable' then exists (
        select 1 from information_schema.columns
         where table_schema = 'public'
           and table_name = split_part(e.name, '.', 1)
           and column_name = split_part(e.name, '.', 2)
           and is_nullable = 'YES')
      when 'function' then exists (
        select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname in ('public', 'app') and p.proname = e.name)
      -- An index can BE the feature rather than decorate it: email_deliveries_idempotency_idx is
      -- what makes "the welcome email goes once" true. Without this kind the verifier would call
      -- the file done with the guarantee missing.
      -- Triggers, because 20260924000300 IS a trigger: its functions can all exist while nothing
      -- is wired to fire them, which looks identical to a working feature until nobody gets a
      -- welcome email. tgisinternal excludes the ones Postgres makes for foreign keys.
      when 'trigger' then exists (
        select 1 from pg_trigger where tgname = e.name and not tgisinternal)
      when 'index' then exists (
        select 1 from pg_indexes where schemaname = 'public' and indexname = e.name)
      when 'type' then exists (select 1 from pg_type where typname = e.name)
      when 'enum' then exists (
        select 1 from pg_type t join pg_enum x on x.enumtypid = t.oid
         where t.typname = split_part(e.name, '.', 1)
           and x.enumlabel = split_part(e.name, '.', 2))
      when 'hasref' then exists (
        select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname in ('public', 'app') and p.proname = e.name
           and pg_get_functiondef(p.oid) like '%' || e.detail || '%')
      when 'nogate' then exists (
        select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'app' and p.proname = e.name
           and pg_get_functiondef(p.oid) not like '%' || e.detail || '%')
      -- A trigger is the half of a producer that is easy to lose: the function survives a
      -- re-run of the file, and the CREATE TRIGGER is what a truncated paste drops.
      when 'trigger' then exists (
        select 1 from pg_trigger where not tgisinternal and tgname = e.name)
      -- 001500 replaces a policy of the same name, so existence proves nothing. Only the
      -- expression does: recursion into its own table is what the old one did.
      when 'policyref' then exists (
        select 1 from pg_policies
         where schemaname = 'public' and tablename = e.name
           and qual like '%' || e.detail || '%')
      -- profiles is column-granted in BOTH directions. A column with no SELECT grant does not
      -- error -- PostgREST 403s the whole row, the screen falls back to defaults, and every
      -- switch renders in a plausible-looking off state. That is how the availability toggle
      -- shipped broken and looked fine.
      --
      -- Read from pg_attribute.attacl rather than information_schema.column_privileges. That view
      -- shows only privileges granted TO or BY a currently enabled role, so connecting as a role
      -- that neither granted them nor is a member of the grantee sees nothing and the check
      -- reports a grant missing that is plainly there. Locally, where the connection owns
      -- everything, the two agree exactly -- which is precisely why the difference does not show
      -- up until it matters, against a pooled production connection.
      --
      -- A column-level grant can also be implied by a table-wide one, so both are counted.
      when 'colgrant' then (
        exists (
          select 1
            from pg_attribute a
            join pg_class c     on c.oid = a.attrelid
            join pg_namespace n on n.oid = c.relnamespace
           cross join lateral aclexplode(a.attacl) x
            join pg_roles gr    on gr.oid = x.grantee
           where n.nspname = 'public'
             and c.relname = split_part(e.name, '.', 1)
             and a.attname = split_part(e.name, '.', 2)
             and gr.rolname = 'authenticated'
             and x.privilege_type = e.detail)
        or exists (
          select 1
            from pg_class c
            join pg_namespace n on n.oid = c.relnamespace
           cross join lateral aclexplode(c.relacl) x
            join pg_roles gr    on gr.oid = x.grantee
           where n.nspname = 'public'
             and c.relname = split_part(e.name, '.', 1)
             and gr.rolname = 'authenticated'
             and x.privilege_type = e.detail))
      -- A settings row is the whole of a feature flag. Missing, app.setting_bool falls back to
      -- its default -- which for sms.outbound_enabled happens to be the same answer, so the
      -- absence would never show up as a behaviour change, only as a switch the owner cannot find.
      when 'setting' then exists (
        select 1 from public.app_settings where key = e.name)
    end as found
  from expected e
)
select
  case when count(*) filter (where not found) = 0 then 'done' else '>>> RE-RUN' end as action,
  file,
  count(*) filter (where not found) || ' of ' || count(*) || ' missing' as state,
  -- "1 of 6 missing" tells you to re-run a 465-line file and nothing about why. Naming the object
  -- is the difference between fixing it and guessing at it, and on the run that prompted this it
  -- was the last object in three separate files -- a pattern that is invisible from a count.
  coalesce(
    string_agg(
      kind || ' ' || name || coalesce(' ~ ' || nullif(detail, ''), '')
      , E'\n  ' order by name) filter (where not found),
    '') as missing
from checked
group by file
order by (count(*) filter (where not found) = 0), file;
