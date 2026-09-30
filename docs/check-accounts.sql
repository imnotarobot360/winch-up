-- Winch Up :: one member, one account -- the standing check
--
-- PASTE INTO THE SUPABASE SQL EDITOR (Dashboard -> SQL Editor -> New query).
--
-- Written for the editor rather than psql, deliberately: the owner's psql access fails on
-- password auth, and the dashboard is the path that actually works. That constrains the style,
-- because the editor does not understand \echo or \gexec and SHOWS ONLY THE LAST RESULT SET of
-- a multi-statement run. A file of four queries would therefore display one and hide three --
-- a careful script rendered misleading. So each section below is ONE statement returning ONE
-- result. Run them one at a time.
--
-- WHAT THIS IS LOOKING FOR
--
-- /join used to call signInWithOtp({phone}) + verifyOtp({type:'sms'}) even when somebody was
-- already signed in. Those AUTHENTICATE THE PHONE IDENTITY, so a member who joined by email or
-- Google and then verified their number was handed a SECOND account: the responder profile
-- attached to the phone account while the waiver signature, vehicles and requests stayed on the
-- first. Fixed forward on 2026-09-29 (updateUser + type 'phone_change' when a session exists,
-- guarded by scripts/check-account-linking.mjs). Three accounts left over from before that fix
-- were deleted on 2026-09-30. Anything this finds now is new, so read it before acting on it.


-- ============================================================================
-- 1. THE SUMMARY, AND ANY PHONE-ONLY ACCOUNT  (read-only)
-- ============================================================================
--
-- A phone-only account is the clearest symptom: a member who joined by email and then verified
-- a phone leaves one behind, holding their responder profile. "holds" says whether it is an
-- empty shell or somebody's real data.

select
  'summary'                                              as row_kind,
  (select count(*) from auth.users)::text                as total_accounts,
  (select count(*) from auth.users
    where (email is null or email = '')
      and phone is not null and phone <> '')::text       as phone_only,
  (select count(*) from public.responders r
     join auth.users u on u.id = r.user_id
    where r.phone is not null
      -- ltrim the '+': auth.users.phone stores it WITHOUT, responders.phone WITH. A raw compare
      -- reports every healthy profile as split; the first run of this reported exactly that.
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

-- All zeros in the summary means prevention is holding and there is nothing to merge.


-- ============================================================================
-- 2. THE SAME PHONE ON MORE THAN ONE ACCOUNT
-- ============================================================================

select ltrim(u.phone, '+') as phone,
       count(*)            as accounts,
       string_agg(u.id::text, ', ' order by u.created_at) as ids
  from auth.users u
 where u.phone is not null and u.phone <> ''
 group by ltrim(u.phone, '+')
having count(*) > 1;


-- ============================================================================
-- 3. THE SAME EMAIL ON MORE THAN ONE ACCOUNT
-- ============================================================================
-- Should be impossible -- Supabase enforces it -- which is a reason to prove it, not to skip it.

select lower(u.email) as email,
       count(*)       as accounts,
       string_agg(u.id::text, ', ' order by u.created_at) as ids
  from auth.users u
 where u.email is not null and u.email <> ''
 group by lower(u.email)
having count(*) > 1;


-- ============================================================================
-- 4. A RESPONDER PROFILE WHOSE PHONE IS NOT ON ITS OWN AUTH ACCOUNT
-- ============================================================================
-- The fingerprint of a split: the profile says one number, the account it belongs to does not
-- carry it, because the verification landed on a different user.

select r.id      as responder_id,
       r.user_id,
       r.phone   as responder_phone,
       u.phone   as auth_phone,
       u.email,
       (select count(*) from auth.users o
         where ltrim(o.phone, '+') = ltrim(r.phone, '+') and o.id <> r.user_id)
         as other_accounts_with_that_number
  from public.responders r
  join auth.users u on u.id = r.user_id
 where r.phone is not null
   and ltrim(coalesce(u.phone, ''), '+') <> ltrim(r.phone, '+');


-- ============================================================================
-- IF YOU FIND SOMETHING, AND HOW TO DELETE SAFELY
-- ============================================================================
--
-- Send the rows back before touching them. Merging accounts by hand is how recovery history and
-- signed waivers get detached from the member they belong to.
--
-- When a delete is genuinely right, write it SELF-GUARDING, as the 2026-09-30 cleanup did.
-- There is no visible transaction in the editor and no ROLLBACK to watch scroll past, so safety
-- cannot depend on an abort: the DELETE must only MATCH rows that are still safe to remove.
--
--   with targets as (
--     select u.id from auth.users u
--      where u.id in ( ...the ids you read above... )
--        and (u.email is null or u.email = '')
--        and not exists (select 1 from public.requests q where q.requester_user_id = u.id)
--        and not exists (select 1 from public.membership_signatures s where s.user_id = u.id)
--        and not exists (select 1 from public.vehicles v where v.user_id = u.id)
--   ),
--   gone as (delete from auth.users where id in (select id from targets) returning id)
--   select (select count(*) from gone) as deleted;
--
-- An account that became real between the report and the delete is simply not matched, the
-- others still go, and the count tells you. Running it twice is a no-op.
--
-- DO NOT ADD "AFTER" COUNTS TO THAT STATEMENT. The first version of the 2026-09-30 script also
-- selected count(*) from auth.users, and when tested it deleted all three correctly and then
-- reported 29 accounts and 3 phone-only -- the BEFORE numbers wearing the wrong label. A
-- statement's sub-selects read the snapshot from when the statement began, so the CTE's own
-- DELETE is invisible to them. In production that reads exactly like a failed cleanup and
-- invites a second run. Re-run section 1 instead; it is a separate statement and sees the truth.
--
-- WHAT DELETING AN ACCOUNT DOES TO THE RESPONDER PROFILE: it survives, scrubbed.
-- responders.user_id is ON DELETE SET NULL and a BEFORE DELETE trigger blanks the identity --
-- user_id null, phone +10000000000, name "Removed", approval rejected, availability paused.
-- Verified on a local copy of the real shape. That is safe: app.candidates() matches on approval
-- and availability, so a rejected, paused row is never dispatched to. What happened stays on the
-- record; who it was does not.
