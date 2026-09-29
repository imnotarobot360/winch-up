-- Winch Up :: are there already duplicate accounts?
--
--   psql "<uri>" -f docs/find-duplicate-accounts.sql
--
-- READ-ONLY. It changes nothing; it answers whether the linking fix is only prevention, or
-- whether there is also a cleanup to do.
--
-- The bug: /join used to call signInWithOtp({phone}) + verifyOtp({type:'sms'}) even when
-- somebody was already signed in. Those authenticate the PHONE IDENTITY, so a member who
-- joined with email or Google and then verified their number was handed a SECOND account.
-- Their responder profile attached to the phone account; their waiver signature, vehicles and
-- requests stayed on whichever account was current when each was made.
--
-- Fixed forward by 2026-09-29. Anything below predates that.

\echo ''
\echo '=== 1. Phone-only accounts: no email at all ==='
\echo '    The clearest symptom. A member who joined by email and then verified a phone would'
\echo '    leave one of these behind, holding their responder profile.'

select u.id,
       u.phone,
       u.created_at,
       (select count(*) from public.responders r where r.user_id = u.id)  as responders,
       (select count(*) from public.requests q where q.requester_user_id = u.id) as requests,
       (select count(*) from public.vehicles v where v.user_id = u.id)    as vehicles
  from auth.users u
 where (u.email is null or u.email = '')
   and u.phone is not null and u.phone <> ''
 order by u.created_at;

\echo ''
\echo '=== 2. The same phone on more than one account ==='

select u.phone, count(*) as accounts, string_agg(u.id::text, ', ' order by u.created_at) as ids
  from auth.users u
 where u.phone is not null and u.phone <> ''
 group by u.phone
having count(*) > 1;

\echo ''
\echo '=== 3. The same email on more than one account ==='
\echo '    Should be impossible -- Supabase enforces it -- but worth proving rather than assuming.'

select lower(u.email) as email, count(*) as accounts, string_agg(u.id::text, ', ' order by u.created_at) as ids
  from auth.users u
 where u.email is not null and u.email <> ''
 group by lower(u.email)
having count(*) > 1;

\echo ''
\echo '=== 4. A responder profile whose phone is NOT on its own auth account ==='
\echo '    The fingerprint of a split: the profile says one number, the account it belongs to'
\echo '    does not carry it, because the verification landed on a different user.'

select r.id as responder_id,
       r.user_id,
       r.phone      as responder_phone,
       u.phone      as auth_phone,
       u.email,
       (select count(*) from auth.users o
         where o.phone = r.phone and o.id <> r.user_id) as other_accounts_with_that_number
  from public.responders r
  join auth.users u on u.id = r.user_id
 where r.phone is not null
   and coalesce(u.phone, '') <> r.phone;

\echo ''
\echo '=== SUMMARY ==='

select
  (select count(*) from auth.users) as total_accounts,
  (select count(*) from auth.users where (email is null or email = '') and phone is not null and phone <> '') as phone_only,
  (select count(*) from public.responders r join auth.users u on u.id = r.user_id
    where r.phone is not null and coalesce(u.phone,'') <> r.phone) as split_profiles;

\echo ''
\echo 'All zeros in the summary means prevention only -- nothing to merge.'
\echo 'Anything else: send the rows back before touching them. Merging accounts by hand is'
\echo 'how recovery history and signed waivers get detached from the member they belong to.'
\echo ''
