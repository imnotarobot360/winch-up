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
    ('hasref',   'system_health_summary', 'reachable_volunteers', '000700', '20260923000700_health_reachable.sql')
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
    end as found
  from expected e
)
select
  case when count(*) filter (where not found) = 0 then 'done' else '>>> RE-RUN' end as action,
  file,
  count(*) filter (where not found) || ' of ' || count(*) || ' missing' as state
from checked
group by file
order by (count(*) filter (where not found) = 0), file;
