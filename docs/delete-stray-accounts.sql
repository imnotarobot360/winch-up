-- Winch Up :: delete the three phone-only accounts left by 2026-09-28 testing
--
--   psql "<uri>" -f docs/delete-stray-accounts.sql
--
-- ONE-OFF. This names three specific account ids and is not a template for anything. Delete
-- the file once it has run.
--
-- The accounts, from docs/find-duplicate-accounts.sql on 2026-09-29:
--
--   a649f1df-e868-48fa-ab3c-c8588bb9dc35  +18324923210  1 responder profile, 0 requests
--   f99d0736-dd68-4a3a-8b72-c4b6a57d6f37  +13468124492  nothing at all
--   3ee0028e-f19e-4c89-b934-6383f95b19fb  +16514276885  nothing at all
--
-- All three were created within 50 seconds during phone-verification testing, before the
-- linking fix. The third exists because of an OTP I sent while diagnosing. None belongs to a
-- real member.
--
-- WHY THIS REFUSES RATHER THAN PROCEEDS
--
-- The ids were read from a report taken minutes earlier, and a lot can be true between then
-- and now: somebody could have signed in on one of those numbers, or attached an email, or
-- filed a request. So every assumption behind "these are safe to delete" is re-checked here,
-- in the same transaction as the delete. If any of them is false the whole thing rolls back
-- and prints why, rather than deleting an account that has become somebody's.
--
-- Deleting auth.users runs the BEFORE DELETE scrub (see security_test.sql), which blanks the
-- phone, name and positions on anything referencing it and cancels a live recovery.
--
-- The responder row does NOT cascade -- responders.user_id is ON DELETE SET NULL, so the row
-- SURVIVES with its identity removed. Verified against a local copy of this exact shape:
--
--   user_id (null)   phone +10000000000   first_name Removed
--   approval rejected   availability paused   redacted_at set
--
-- That is deliberate, and it is safe: app.candidates() matches on approval and availability,
-- so a rejected and paused row is never dispatched to. What happened stays on the record;
-- who it was does not.

\set ON_ERROR_STOP on

begin;

\echo ''
\echo '=== BEFORE: the three accounts, and what they hold ==='

select u.id,
       coalesce(u.email, '(none)') as email,
       u.phone,
       u.created_at,
       (select count(*) from public.responders r where r.user_id = u.id) as responders,
       (select count(*) from public.requests q where q.requester_user_id = u.id) as requests,
       (select count(*) from public.vehicles v where v.user_id = u.id) as vehicles,
       (select count(*) from public.membership_signatures s where s.user_id = u.id) as signatures
  from auth.users u
 where u.id in (
   'a649f1df-e868-48fa-ab3c-c8588bb9dc35',
   'f99d0736-dd68-4a3a-8b72-c4b6a57d6f37',
   '3ee0028e-f19e-4c89-b934-6383f95b19fb'
 )
 order by u.created_at;

do $guard$
declare
  v_found      integer;
  v_with_email integer;
  v_requests   integer;
  v_signatures integer;
  v_vehicles   integer;
begin
  select count(*) into v_found
    from auth.users
   where id in (
     'a649f1df-e868-48fa-ab3c-c8588bb9dc35',
     'f99d0736-dd68-4a3a-8b72-c4b6a57d6f37',
     '3ee0028e-f19e-4c89-b934-6383f95b19fb'
   );

  -- Fewer than three means somebody already removed one and this file is out of date; more is
  -- impossible. Either way, stop and look rather than delete a partially-understood set.
  if v_found <> 3 then
    raise exception 'expected exactly 3 accounts, found %. Re-run find-duplicate-accounts.sql.', v_found;
  end if;

  -- An email means it stopped being a stray phone-only account and became somebody's login.
  select count(*) into v_with_email
    from auth.users
   where id in (
     'a649f1df-e868-48fa-ab3c-c8588bb9dc35',
     'f99d0736-dd68-4a3a-8b72-c4b6a57d6f37',
     '3ee0028e-f19e-4c89-b934-6383f95b19fb'
   ) and email is not null and email <> '';

  if v_with_email > 0 then
    raise exception '% of these now has an email address. That is a real account; refusing.', v_with_email;
  end if;

  -- Real activity. Any of these appearing means the account was used by somebody after the
  -- report, and the whole premise of "holds nothing" is gone.
  select count(*) into v_requests from public.requests
   where requester_user_id in (
     'a649f1df-e868-48fa-ab3c-c8588bb9dc35',
     'f99d0736-dd68-4a3a-8b72-c4b6a57d6f37',
     '3ee0028e-f19e-4c89-b934-6383f95b19fb'
   );

  select count(*) into v_signatures from public.membership_signatures
   where user_id in (
     'a649f1df-e868-48fa-ab3c-c8588bb9dc35',
     'f99d0736-dd68-4a3a-8b72-c4b6a57d6f37',
     '3ee0028e-f19e-4c89-b934-6383f95b19fb'
   );

  select count(*) into v_vehicles from public.vehicles
   where user_id in (
     'a649f1df-e868-48fa-ab3c-c8588bb9dc35',
     'f99d0736-dd68-4a3a-8b72-c4b6a57d6f37',
     '3ee0028e-f19e-4c89-b934-6383f95b19fb'
   );

  if v_requests > 0 or v_signatures > 0 or v_vehicles > 0 then
    raise exception
      'these accounts now hold real data (% requests, % signatures, % vehicles); refusing',
      v_requests, v_signatures, v_vehicles;
  end if;

  raise notice 'guards passed: 3 accounts, no email, no requests, no signatures, no vehicles';
end
$guard$;

\echo ''
\echo '=== DELETING ==='

delete from auth.users
 where id in (
   'a649f1df-e868-48fa-ab3c-c8588bb9dc35',
   'f99d0736-dd68-4a3a-8b72-c4b6a57d6f37',
   '3ee0028e-f19e-4c89-b934-6383f95b19fb'
 );

\echo ''
\echo '=== AFTER ==='

select
  (select count(*) from auth.users) as total_accounts,
  (select count(*) from auth.users
    where (email is null or email = '') and phone is not null and phone <> '') as phone_only_remaining,
  (select count(*) from auth.users
    where id in (
      'a649f1df-e868-48fa-ab3c-c8588bb9dc35',
      'f99d0736-dd68-4a3a-8b72-c4b6a57d6f37',
      '3ee0028e-f19e-4c89-b934-6383f95b19fb'
    )) as targets_remaining;

commit;

\echo ''
\echo 'Expected after: total 4, phone_only_remaining 0, targets_remaining 0.'
\echo 'If you see ROLLBACK above, nothing was deleted and the reason is printed with it.'
\echo ''
