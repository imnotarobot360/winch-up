-- Winch Up :: the nine migrations that block CI, checked by hand
--
-- READ ONLY. No writes, no DDL. Safe on production.
--
-- WHY THESE NINE AND NOT THE OTHER THIRTY-THREE. docs/verify-group-b.sql found evidence for 31 of
-- the 42 inconclusive migrations. Of the 11 it could not reach, the ledger guard -- dry-run with
-- REMOTE_VERSIONS -- says only NINE actually block CI: 20261005001000 and 20261005001100 are newer
-- than everything recorded, so they are a forward-only apply and db push re-applies them as a
-- no-op (proved: every guarded block reports "already", and their own verifications still read t).
--
-- The generic verifier cannot reach these nine because each declares a function that a LATER
-- migration rewrote, or changes no schema at all. So the checks below are hand-written against the
-- effect each one introduced rather than against the body it shipped. That is what "marcadores
-- específicos, además de permisos, políticas y restricciones" needs here.
--
-- COLUMN-LEVEL GRANTS were the gap in the generated file: it checked table and function privileges
-- and not column ones, and two of these nine do nothing else. profiles has an ENUMERATED column
-- grant list, so a preference column without its grant leaves the screen showing defaults with no
-- error -- which is how that class of bug has bitten this project before.

set search_path = public, extensions;

with checks(version, what, present) as (values

  -- 20260923001800_notify_column_grants.sql -- column grants, and nothing else.
  ('20260923001800', 'profiles.available_to_help readable by authenticated',
    has_column_privilege('authenticated', 'public.profiles', 'available_to_help', 'select')),
  ('20260923001800', 'profiles.notify_chat readable',
    has_column_privilege('authenticated', 'public.profiles', 'notify_chat', 'select')),
  ('20260923001800', 'profiles.notify_chat writable',
    has_column_privilege('authenticated', 'public.profiles', 'notify_chat', 'update')),
  ('20260923001800', 'profiles.notify_recovery_status readable',
    has_column_privilege('authenticated', 'public.profiles', 'notify_recovery_status', 'select')),
  ('20260923001800', 'profiles.notify_recovery_status writable',
    has_column_privilege('authenticated', 'public.profiles', 'notify_recovery_status', 'update')),

  -- 20261001002500_direct_message_column_grants.sql -- the same shape, for the DM preferences.
  ('20261001002500', 'profiles.allow_direct_messages readable',
    has_column_privilege('authenticated', 'public.profiles', 'allow_direct_messages', 'select')),
  ('20261001002500', 'profiles.allow_direct_messages writable',
    has_column_privilege('authenticated', 'public.profiles', 'allow_direct_messages', 'update')),
  ('20261001002500', 'profiles.notify_direct_messages readable',
    has_column_privilege('authenticated', 'public.profiles', 'notify_direct_messages', 'select')),
  ('20261001002500', 'profiles.notify_direct_messages writable',
    has_column_privilege('authenticated', 'public.profiles', 'notify_direct_messages', 'update')),

  -- 20261001001900_drop_profile_public.sql -- evidence is an ABSENCE. The generated verifier only
  -- ever looks for things that should exist, so a drop migration is invisible to it.
  ('20261001001900', 'profiles.profile_public is GONE',
    not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'profiles'
                   and column_name = 'profile_public')),

  -- 20260928000700_rules_v2.sql -- writes a new version of the ground rules into waivers. The
  -- phrase is from the v2 text itself, so finding it means v2 is the current row.
  ('20260928000700', 'the v2 ground rules are the current rules waiver',
    exists (select 1 from public.waivers
             where slug = 'rules' and is_current
               and strpos(body_en, 'not an emergency service and not a towing company') > 0)),

  -- 20261001000500_exclude_requester.sql -- rewrites app.candidates through pg_get_functiondef and
  -- declares nothing, so there is no shipped body to match. Its EFFECT is still in the live body,
  -- and later migrations preserved it: asserted again by 20261005000900's own verification.
  ('20261001000500', 'app.candidates excludes the requester',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'app' and p.proname = 'candidates'
               and strpos(p.prosrc, 'req.requester_user_id') > 0)),

  -- 20261001001200_dispatch_respects_suspension.sql -- same shape, same function, different effect.
  ('20261001001200', 'app.candidates skips suspended members',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'app' and p.proname = 'candidates'
               and strpos(p.prosrc, 'suspended_at') > 0))
),
per_version as (
  select version,
         count(*)::int                        as checks,
         count(*) filter (where present)::int as passed
    from checks group by version
)
select
  version,
  checks,
  passed,
  case when passed = checks then 'EVIDENCE: the effect this migration introduced is present'
       when passed = 0      then 'NO EVIDENCE: do not record, find out why'
       else                      'PARTIAL: inspect before recording'
  end as verdict,
  case when passed = checks
       then 'supabase migration repair --status applied ' || version
       else '-- withhold ' || version
  end as command
from per_version
order by version;

-- Which individual check failed, if any.
with checks(version, what, present) as (values
  ('20260923001800', 'available_to_help select',
    has_column_privilege('authenticated', 'public.profiles', 'available_to_help', 'select')),
  ('20260923001800', 'notify_chat select',
    has_column_privilege('authenticated', 'public.profiles', 'notify_chat', 'select')),
  ('20260923001800', 'notify_chat update',
    has_column_privilege('authenticated', 'public.profiles', 'notify_chat', 'update')),
  ('20260923001800', 'notify_recovery_status select',
    has_column_privilege('authenticated', 'public.profiles', 'notify_recovery_status', 'select')),
  ('20260923001800', 'notify_recovery_status update',
    has_column_privilege('authenticated', 'public.profiles', 'notify_recovery_status', 'update')),
  ('20261001002500', 'allow_direct_messages select',
    has_column_privilege('authenticated', 'public.profiles', 'allow_direct_messages', 'select')),
  ('20261001002500', 'allow_direct_messages update',
    has_column_privilege('authenticated', 'public.profiles', 'allow_direct_messages', 'update')),
  ('20261001002500', 'notify_direct_messages select',
    has_column_privilege('authenticated', 'public.profiles', 'notify_direct_messages', 'select')),
  ('20261001002500', 'notify_direct_messages update',
    has_column_privilege('authenticated', 'public.profiles', 'notify_direct_messages', 'update')),
  ('20261001001900', 'profile_public gone',
    not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'profiles'
                   and column_name = 'profile_public')),
  ('20260928000700', 'v2 rules current',
    exists (select 1 from public.waivers
             where slug = 'rules' and is_current
               and strpos(body_en, 'not an emergency service and not a towing company') > 0)),
  ('20261001000500', 'requester excluded',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'app' and p.proname = 'candidates'
               and strpos(p.prosrc, 'req.requester_user_id') > 0)),
  ('20261001001200', 'suspension respected',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'app' and p.proname = 'candidates'
               and strpos(p.prosrc, 'suspended_at') > 0))
)
select version, what from checks where not present order by version, what;

-- ---------------------------------------------------------------------------
-- THE THREE THAT CANNOT BE VERIFIED, AND WHY
-- ---------------------------------------------------------------------------
--
-- These need an explicit risk decision, which is the owner's. No query can settle them.
--
--   20261001000600_first_ring_ten_miles.sql
--     Changed dispatch.ring_radii_miles from [15,30,60] to [10,30,60]. The owner later chose the
--     15-mile first wave deliberately, so the current value is [15,30,60] and this migration's
--     effect is gone BY DECISION. No value can distinguish "never applied" from "applied and
--     reversed".
--     RECORDING IT IS THE SAFE CHOICE, and this is the one case where withholding is the risk: its
--     body acts only when the value is exactly [15,30,60], which is what it is now. Replayed, it
--     would silently narrow wave 1 back to 10 miles. The ledger guard is the only thing preventing
--     that today; recording it removes the possibility for good.
--
--   20260928000100_phone_optional.sql
--     Made responders.phone nullable. It IS nullable -- but 20260923000100_universal_membership had
--     already made it so, so the state cannot tell the two apart. Weak evidence, not no evidence:
--     nothing contradicts it.
--
--   20260923001600_status_team.sql
--     Rewrote get_request_by_token to carry the recovery team. Later migrations rewrote the same
--     function, so no marker from this one can be expected to survive, and the team-carrying
--     behaviour is asserted by the pgTAP suites rather than by anything visible in the catalogue.
