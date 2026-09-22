-- Winch Up :: which database is this, actually
--
-- Phase 15: "Never send test recovery alerts to real community members."
--
-- The protection for that was a comment at the top of supabase/seeds/demo.sql saying not to run
-- it against production. That is a rule, and this project's habit is to turn rules into things
-- that cannot be broken -- a trail cannot claim to be open without a source, two submits cannot
-- both become open requests, an ad cannot be served on the request wizard.
--
-- So: the database says what it is, and it says `production` unless somebody has deliberately
-- said otherwise. Fail closed. A fresh database that nobody has marked is treated as production
-- and refuses the demo seed, which is the right way round -- the failure mode of being wrong is
-- somebody's phone ringing at midnight about a recovery that does not exist.
--
-- Marking a database as local is one statement, in scripts/local-stack/mark-local.sql, run as
-- part of the documented rebuild. It is deliberately not in seed.sql, because seed.sql is the
-- reference data that runs everywhere including production.

set search_path = public, extensions;

insert into app_settings (key, value, description)
values (
  'deploy.environment',
  '"production"'::jsonb,
  'What this database is: production, staging or local. Defaults to production so that an '
  'unmarked database refuses anything that would text a real person. Set by '
  'scripts/local-stack/mark-local.sql during a local rebuild.'
)
on conflict (key) do nothing;

create or replace function app.is_production()
returns boolean
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  -- Anything other than an explicit non-production marker counts as production, including a
  -- missing row and a value nobody recognises.
  select coalesce(
    (select value #>> '{}' from public.app_settings where key = 'deploy.environment'),
    'production'
  ) not in ('local', 'staging', 'test');
$$;

comment on function app.is_production() is
  'True unless the database has been explicitly marked local, staging or test. Used to refuse '
  'anything that could text a real community member from a test.';

-- ---------------------------------------------------------------------------
-- The guard itself
--
-- Callable, so the demo seed can use it and so a test can prove it works. It raises rather than
-- returning false: a seed that carries on after a warning is a seed that ran.
-- ---------------------------------------------------------------------------

create or replace function app.refuse_if_production(p_what text)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if app.is_production() then
    raise exception
      '% refuses to run: this database is marked %. Demo data creates accounts with known '
      'passwords and recovery requests that would text real volunteers. If this really is a '
      'local database, run scripts/local-stack/mark-local.sql first.',
      p_what,
      coalesce((select value #>> '{}' from public.app_settings where key = 'deploy.environment'),
               'production (no marker)')
      using errcode = 'insufficient_privilege';
  end if;
end;
$$;
