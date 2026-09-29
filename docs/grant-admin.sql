-- Winch Up :: make an account an admin, and show its state before and after
--
--   psql "<uri>" -v email=someone@example.com -f docs/grant-admin.sql
--
-- Idempotent: granting admin twice is a no-op, not an error.
--
-- WHY A FILE RATHER THAN psql -c
--
-- The same reason every other operational step here is a file: a one-liner with quotes in it
-- gets mangled differently by PowerShell, Git Bash and whatever pasted it, and the failures are
-- confusing rather than obvious. Run it with -f and there is nothing to quote.
--
-- WHY IT PRINTS BEFORE AND AFTER
--
-- "make me an admin" is usually really "why am I not an admin", and the two useful answers are
-- invisible from the app: the account may already HAVE the role (so the problem is the session,
-- not the grant), or there may be TWO accounts on that address (so the grant landed on the one
-- you are not signed into). Both show up below.

\set ON_ERROR_STOP on

\echo ''
\echo '=== BEFORE: every account on this address, and its roles ==='

select u.id,
       u.email,
       u.email_confirmed_at is not null as confirmed,
       u.created_at,
       coalesce(
         (select string_agg(r.role::text, ', ' order by r.role)
            from public.user_roles r where r.user_id = u.id),
         '(none)'
       ) as roles
  from auth.users u
 where lower(u.email) = lower(:'email')
 order by u.created_at;

-- Which sign-in methods are attached to each account. More than one provider on ONE id is a
-- linked account, which is what you want; two separate ids sharing the email is not.
--
-- Generated and run only if the table is there. auth.identities exists on hosted Supabase and
-- NOT in this project's local stub, so referencing it directly makes the whole file fail to
-- parse locally -- which would mean the script could only ever be tested in production, on the
-- one run where it matters. Same shape as the storage.foldername trap in 20260928000900.
select format(
  'select u.email, i.provider, i.user_id from auth.identities i '
  'join auth.users u on u.id = i.user_id '
  'where lower(u.email) = lower(%L) order by i.provider', :'email')
 where to_regclass('auth.identities') is not null
\gexec

\echo ''
\echo '=== GRANTING admin ==='

insert into public.user_roles (user_id, role)
select u.id, 'admin'::app_role
  from auth.users u
 where lower(u.email) = lower(:'email')
on conflict (user_id, role) do nothing;

\echo ''
\echo '=== AFTER ==='

select u.email,
       (select string_agg(r.role::text, ', ' order by r.role)
          from public.user_roles r where r.user_id = u.id) as roles
  from auth.users u
 where lower(u.email) = lower(:'email');

\echo ''
\echo 'If roles now includes admin but /admin still refuses: sign out and back in.'
\echo 'The admin check reads auth.uid() from the session, and an existing session'
\echo 'is not re-evaluated until it is renewed.'
\echo ''
