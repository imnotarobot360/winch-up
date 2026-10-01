-- Winch Up :: the first ring is ten miles
--
-- The owner's location-alerts spec says "Start by searching within 10 miles, expanding the
-- search when appropriate". The rings have shipped as [15, 30, 60] since 20260921000100.
--
-- WHY A MIGRATION RATHER THAN THE SEED. app_settings rows are created by a migration, not by
-- supabase/seed.sql, and production already holds [15, 30, 60]. Editing the original file would
-- change nothing on any database that has already run it -- the usual trap with reference data
-- that lives in an applied migration.
--
-- GUARDED, so this can only ever perform the one change it describes. If the value is anything
-- other than the shipped default, somebody has tuned it -- quite possibly in the admin screen,
-- which can edit every setting -- and a migration that overwrote that would be taking a
-- decision away from the person who made it. The owner can still set it to anything from
-- /admin/settings afterwards; this moves the DEFAULT, once.
--
-- Only the first ring moves. The spec names 10 miles as the starting radius and says nothing
-- about the others, and 30/60 are what the escalation has always widened to.

set search_path = public, extensions;

do $$
declare
  v_current jsonb;
begin
  select value into v_current from public.app_settings where key = 'dispatch.ring_radii_miles';

  if v_current is null then
    raise notice 'dispatch.ring_radii_miles is absent; nothing to change';
  elsif v_current = '[15, 30, 60]'::jsonb then
    update public.app_settings
       set value = '[10, 30, 60]'::jsonb,
           updated_at = now()
     where key = 'dispatch.ring_radii_miles';
    raise notice 'first ring moved from 15 to 10 miles';
  else
    raise notice 'dispatch.ring_radii_miles is % -- already tuned, left alone', v_current;
  end if;
end
$$;
