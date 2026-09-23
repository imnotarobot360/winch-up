-- Winch Up :: did the universal-membership migrations land?
--
-- Paste into the Supabase SQL editor. Read-only: it creates nothing, changes nothing, and can be
-- run as many times as you like.
--
-- Every row should say PRESENT. A MISSING row names the migration that did not run, so you can
-- paste that one file again rather than guessing which of the eight is short.

with expected(kind, name, migration) as (
  values
    -- 20260923000100_universal_membership.sql
    ('column',   'profiles.available_to_help',        '000100 universal_membership'),
    ('function', 'ensure_recovery_profile',           '000100 universal_membership'),
    ('function', 'set_available_to_help',             '000100 universal_membership'),
    -- 20260923000150_offer_states.sql
    ('enum',     'dispatch_state.offered',            '000150 offer_states'),
    ('enum',     'dispatch_state.passed_over',        '000150 offer_states'),
    ('enum',     'request_event_type.responder_offered', '000150 offer_states'),
    -- 20260923000200_assistance_offers.sql
    ('type',     'offer_origin',                      '000200 assistance_offers'),
    ('column',   'dispatches.offer_note',             '000200 assistance_offers'),
    ('function', 'offer_assistance',                  '000200 assistance_offers'),
    ('function', 'accept_offer_by_token',             '000200 assistance_offers'),
    ('function', 'decline_offer_by_token',            '000200 assistance_offers'),
    ('function', 'withdraw_my_offer',                 '000200 assistance_offers'),
    -- 20260923000250_inbound_offer.sql  (redefines two functions; checked by behaviour below)
    -- 20260923000300 / 000500  the Help Someone feed
    ('function', 'nearby_requests',                   '000300 + 000500 help feed'),
    -- 20260923000400_push.sql
    ('table',    'push_subscriptions',                '000400 push'),
    ('function', 'save_push_subscription',            '000400 push'),
    ('function', 'claim_push_deliveries',             '000400 push'),
    ('function', 'record_push_result',                '000400 push'),
    -- 20260923000600_my_requests.sql
    ('function', 'my_requests',                       '000600 my_requests')
)
select
  case when found then 'PRESENT' else '>>> MISSING' end as state,
  migration,
  kind,
  name
from (
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
      when 'function' then exists (
        select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname in ('public', 'app') and p.proname = e.name)
      when 'type' then exists (select 1 from pg_type where typname = e.name)
      when 'enum' then exists (
        select 1 from pg_type t join pg_enum x on x.enumtypid = t.oid
         where t.typname = split_part(e.name, '.', 1)
           and x.enumlabel = split_part(e.name, '.', 2))
    end as found
  from expected e
) checked
order by (case when found then 1 else 0 end), migration, name;

-- The two behaviour changes that matter, confirmed rather than assumed.
select
  case
    when exists (
      select 1 from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'app' and p.proname = 'candidates'
         and pg_get_functiondef(p.oid) like '%approval%'
    )
    then '>>> THE APPROVAL GATE IS STILL IN app.candidates -- 000100 did not run'
    else 'PRESENT  the approval gate is gone from app.candidates'
  end as approval_gate;

select
  case
    when exists (
      select 1 from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'handle_inbound_sms'
         and pg_get_functiondef(p.oid) like '%record_offer%'
    )
    then 'PRESENT  replying 1 records an offer rather than taking the job'
    else '>>> REPLYING 1 STILL TAKES THE JOB -- 000250 did not run'
  end as inbound_reply;

-- And what the migration table thinks it has.
--
-- Guarded because that table is Supabase's own bookkeeping and does not exist on the local
-- no-Docker stack, where an unguarded reference ends this script on an error that looks like a
-- finding and is not.
do $do$
begin
  if to_regclass('supabase_migrations.schema_migrations') is null then
    raise notice 'no supabase_migrations table here (expected on the local stack)';
  else
    raise notice 'recorded migrations: %', (
      select coalesce(string_agg(version, ', ' order by version), '(none from this phase)')
        from supabase_migrations.schema_migrations
       where version like '2026092300%'
    );
  end if;
end
$do$;
