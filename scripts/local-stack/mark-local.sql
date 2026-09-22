-- Mark this database as NOT production.
--
-- Run once per local rebuild, after the migrations and before the demo seed. Without it,
-- supabase/seeds/demo.sql refuses to run -- deliberately, because demo data creates accounts
-- with known passwords and recovery requests that would text real volunteers if it ever landed
-- on the wrong database.
--
-- There is no equivalent for production and there should never be one: production is the
-- default, and the only way to leave it is this file.

update app_settings
   set value = '"local"'::jsonb,
       updated_at = now()
 where key = 'deploy.environment';

insert into app_settings (key, value, description)
select 'deploy.environment', '"local"'::jsonb, 'Marked local by scripts/local-stack/mark-local.sql'
 where not exists (select 1 from app_settings where key = 'deploy.environment');

select 'this database is now marked: ' || (value #>> '{}') as marked
  from app_settings where key = 'deploy.environment';
