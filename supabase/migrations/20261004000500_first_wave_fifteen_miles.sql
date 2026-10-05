-- Winch Up :: the first wave goes back to fifteen miles
--
-- The owner's call, 2026-10-04, made with the history in front of them.
--
-- THE HISTORY, because this value has now moved three times and the reasons matter more than the
-- number. It shipped as [15, 30, 60] in 20260921000100. On 2026-10-01 the owner's location-alerts
-- spec said "start by searching within 10 miles" and 20261001000600 narrowed the first ring to 10.
-- Today's closest-helper spec asks for 5. The owner chose 15 -- wider than all three recent
-- proposals -- after being shown what was actually live.
--
-- (I told them it was 15 when it was 10: I read the original seed and missed the later migration.
-- They answered on that wrong figure, so they were asked again with the real one. Reference data
-- that lives in an applied migration is edited by LATER migrations, so the first file to mention a
-- key is rarely the one that decides it -- read forward before quoting a default.)
--
-- WHY WIDER IS THE SAFER DIRECTION HERE. A narrow first wave is cheaper and quieter, and its
-- failure mode is a stranded driver hearing nothing while the clock runs down the first wave's
-- wait. In rural Texas five miles can hold nobody at all. Widening costs messages; narrowing costs
-- minutes, and only one of those is being paid by the person in the ditch.
--
-- GUARDED, exactly as 20261001000600 was: this performs the one change it describes and nothing
-- else. If the value is anything other than the 10-mile default that migration set, somebody has
-- tuned it deliberately -- very likely in /admin/settings, which can edit every setting -- and
-- overwriting that would take a decision away from the person who made it. The owner can still set
-- any value there afterwards; this moves the DEFAULT, once.

set search_path = public, extensions;

do $$
declare
  v_current jsonb;
begin
  select value into v_current from public.app_settings where key = 'dispatch.ring_radii_miles';

  if v_current is null then
    raise notice 'dispatch.ring_radii_miles is absent; nothing to change';
  elsif v_current = '[10, 30, 60]'::jsonb then
    update public.app_settings
       set value = '[15, 30, 60]'::jsonb
     where key = 'dispatch.ring_radii_miles';
    raise notice 'first wave widened from 10 to 15 miles';
  else
    raise notice 'dispatch.ring_radii_miles is % -- already tuned, left alone', v_current;
  end if;
end;
$$;

-- Read back through the function the dispatcher actually calls, not the raw row: a correct row and
-- a wrong index would look identical here otherwise.
select
  app.ring_radius_miles(1) as wave_1_miles,
  app.ring_radius_miles(2) as wave_2_miles,
  app.ring_radius_miles(3) as wave_3_miles;
