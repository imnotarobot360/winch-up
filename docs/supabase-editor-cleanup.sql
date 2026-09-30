-- Winch Up :: the stray-account cleanup, rewritten for the Supabase SQL editor
--
-- The psql versions of these (docs/find-duplicate-accounts.sql, docs/delete-stray-accounts.sql)
-- use \echo and \gexec, which the editor does not understand, and they print several result
-- sets, of which the editor shows only the LAST. Both of those turn a careful script into a
-- misleading one. So each block below is ONE statement returning ONE result.
--
-- Run block A, read it, then run block B. They are independent.

-- ============================================================================
-- A. WHAT IS THERE  (read-only, safe to run any time)
-- ============================================================================

select
  'summary'                                              as row_kind,
  (select count(*) from auth.users)::text                as total_accounts,
  (select count(*) from auth.users
    where (email is null or email = '')
      and phone is not null and phone <> '')::text       as phone_only,
  (select count(*) from public.responders r
     join auth.users u on u.id = r.user_id
    where r.phone is not null
      -- ltrim the '+': auth.users.phone stores it without, responders.phone with, and a raw
      -- compare reports every healthy profile as split.
      and ltrim(coalesce(u.phone, ''), '+') <> ltrim(r.phone, '+'))::text as split_profiles,
  null::text as id, null::text as phone, null::text as holds
union all
select
  'phone-only account',
  null, null, null,
  u.id::text,
  u.phone,
  concat(
    (select count(*) from public.responders r where r.user_id = u.id), ' responder, ',
    (select count(*) from public.requests q where q.requester_user_id = u.id), ' requests, ',
    (select count(*) from public.vehicles v where v.user_id = u.id), ' vehicles, ',
    (select count(*) from public.membership_signatures s where s.user_id = u.id), ' signatures'
  )
from auth.users u
where (u.email is null or u.email = '')
  and u.phone is not null and u.phone <> ''
order by 1 desc, 5;


-- ============================================================================
-- B. DELETE THE THREE STRAYS  (run this second)
-- ============================================================================
--
-- SELF-GUARDING, which matters more here than in psql. There is no visible transaction in the
-- editor and no way to watch a ROLLBACK scroll past, so safety cannot depend on an abort. The
-- DELETE instead only MATCHES rows that are still safe to remove: the three known ids, still
-- without an email, still holding no requests, signatures or vehicles.
--
-- If any of them has become a real account since the report, it simply is not matched, the
-- others still go, and the result tells you which. Nothing to interpret and nothing to undo.

with targets as (
  select u.id
    from auth.users u
   where u.id in (
     'a649f1df-e868-48fa-ab3c-c8588bb9dc35',
     'f99d0736-dd68-4a3a-8b72-c4b6a57d6f37',
     '3ee0028e-f19e-4c89-b934-6383f95b19fb'
   )
     and (u.email is null or u.email = '')
     and not exists (select 1 from public.requests q where q.requester_user_id = u.id)
     and not exists (select 1 from public.membership_signatures s where s.user_id = u.id)
     and not exists (select 1 from public.vehicles v where v.user_id = u.id)
),
gone as (
  delete from auth.users where id in (select id from targets) returning id
)
select
  (select count(*) from gone)      as deleted,
  3 - (select count(*) from gone)  as skipped_or_already_gone;

-- Expected: deleted 3, skipped 0.
--
-- NO "AFTER" COUNTS HERE, DELIBERATELY. The first version of this block also selected
-- count(*) from auth.users, and it reported 29 accounts and 3 phone-only immediately after
-- successfully deleting all three. Sub-selects in a statement read the snapshot from when the
-- statement began, so the CTE's own DELETE is invisible to them: the "after" numbers were the
-- BEFORE numbers wearing the wrong label, and read exactly like a failed cleanup.
--
-- To see the result, RUN BLOCK A AGAIN. It is a separate statement, so it sees the deletion.
-- Expected then: total_accounts 4, phone_only 0, and no phone-only rows listed.
--
-- If deleted is less than 3, run block A again -- an account that was skipped has gained an
-- email or some data and is no longer a stray. Do not force it.
--
-- The responder row on the first account does NOT disappear: responders.user_id is
-- ON DELETE SET NULL, so the row survives with its identity scrubbed by the BEFORE DELETE
-- trigger (user_id null, phone +10000000000, name "Removed", approval rejected, availability
-- paused). That is intended and safe -- app.candidates() never matches a rejected, paused row.
