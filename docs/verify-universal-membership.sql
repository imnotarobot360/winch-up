-- Winch Up :: did the universal-membership migrations land?
--
-- Paste into the Supabase SQL editor. Read-only: it creates nothing and changes nothing.
--
-- ONE STATEMENT, ON PURPOSE.
--
-- The first version of this file was four statements. The Supabase editor shows the result of the
-- LAST one, so the eighteen-row table of findings was never displayed -- only a trailing "PRESENT"
-- from an unrelated check. It was read, reasonably, as everything being fine, while
-- profiles.available_to_help was in fact missing in production. That took app.candidates() down
-- with it, which meant no recovery request could reach anybody, and the only visible symptom was
-- /api/health saying "database unreachable".
--
-- A verification tool that hides its own findings is worse than no tool. Hence: one query, one
-- result set, failures sorted to the top, and a summary row that states the verdict outright.

with expected(sort, kind, name, detail, migration) as (
  values
    -- 20260923000100_universal_membership.sql
    (1, 'column',   'profiles.available_to_help',            '', '000100 universal_membership'),
    (1, 'nullable', 'responders.phone',                      '', '000100 universal_membership'),
    (1, 'nullable', 'responders.home_location',              '', '000100 universal_membership'),
    (1, 'function', 'ensure_recovery_profile',               '', '000100 universal_membership'),
    (1, 'function', 'set_available_to_help',                 '', '000100 universal_membership'),
    (1, 'nogate',   'candidates',                            'approval', '000100 universal_membership'),
    -- 20260923000150_offer_states.sql
    (2, 'enum',     'dispatch_state.offered',                '', '000150 offer_states'),
    (2, 'enum',     'dispatch_state.passed_over',            '', '000150 offer_states'),
    (2, 'enum',     'request_event_type.responder_offered',  '', '000150 offer_states'),
    (2, 'enum',     'request_event_type.responder_withdrew', '', '000150 offer_states'),
    (2, 'enum',     'request_event_type.offer_declined',     '', '000150 offer_states'),
    -- 20260923000200_assistance_offers.sql
    (3, 'type',     'offer_origin',                          '', '000200 assistance_offers'),
    (3, 'column',   'dispatches.offer_note',                 '', '000200 assistance_offers'),
    (3, 'column',   'dispatches.offer_eta_minutes',          '', '000200 assistance_offers'),
    (3, 'column',   'dispatches.equipment_ack',              '', '000200 assistance_offers'),
    (3, 'function', 'offer_assistance',                      '', '000200 assistance_offers'),
    (3, 'function', 'accept_offer_by_token',                 '', '000200 assistance_offers'),
    (3, 'function', 'decline_offer_by_token',                '', '000200 assistance_offers'),
    (3, 'function', 'withdraw_my_offer',                     '', '000200 assistance_offers'),
    (3, 'function', 'assign_responder',                      '', '000200 assistance_offers'),
    -- 20260923000250_inbound_offer.sql
    (4, 'hasref',   'handle_inbound_sms',                    'record_offer', '000250 inbound_offer'),
    -- 20260923000300 + 000500
    (5, 'function', 'nearby_requests',                       '', '000300 + 000500 help feed'),
    (5, 'hasref',   'nearby_requests',                       'r.notes',  '000500 help feed notes'),
    -- 20260923000400_push.sql
    (6, 'table',    'push_subscriptions',                    '', '000400 push'),
    (6, 'function', 'save_push_subscription',                '', '000400 push'),
    (6, 'function', 'delete_push_subscription',              '', '000400 push'),
    (6, 'function', 'claim_push_deliveries',                 '', '000400 push'),
    (6, 'function', 'record_push_result',                    '', '000400 push'),
    -- 20260923000600_my_requests.sql
    (7, 'function', 'my_requests',                           '', '000600 my_requests'),
    -- 20260923000700_health_reachable.sql
    (8, 'hasref',   'system_health_summary',                 'reachable_volunteers', '000700 health')
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
      -- The column must exist AND accept nulls. ensure_recovery_profile inserts a responders row
      -- with no phone and no home location for a member who joined with an email address; if
      -- these are still NOT NULL, turning on Available to Help fails.
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
      -- The function's source must MENTION something: proves the new body is installed, not just
      -- that a function of that name exists.
      when 'hasref' then exists (
        select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname in ('public', 'app') and p.proname = e.name
           and pg_get_functiondef(p.oid) like '%' || e.detail || '%')
      -- The reverse: the source must NOT mention it any more.
      when 'nogate' then exists (
        select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'app' and p.proname = e.name
           and pg_get_functiondef(p.oid) not like '%' || e.detail || '%')
    end as found
  from expected e
)
select * from (
  -- The verdict, first, so it is visible without scrolling and cannot be missed.
  select
    0 as ord,
    case when count(*) filter (where not found) = 0
         then 'ALL ' || count(*) || ' CHECKS PASSED'
         else '>>> ' || count(*) filter (where not found) || ' OF ' || count(*)
              || ' MISSING -- see the rows below'
    end as result,
    '' as migration,
    '' as what
  from checked

  union all

  select
    case when found then 2 else 1 end,
    case when found then 'ok' else '>>> MISSING' end,
    migration,
    kind || ' ' || name || case when detail <> '' then ' (' || detail || ')' else '' end
  from checked
) rows
order by ord, migration, what;
