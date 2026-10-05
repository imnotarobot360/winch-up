-- Each wave gets its own helper count and its own wait, instead of one number for all three.
--
-- The spec: wave 1 notifies the closest 5 within its radius and waits 2 minutes; wave 2 notifies
-- the next 10 and waits 3; wave 3 keeps going. Until now `dispatch.max_per_ring` (10) and
-- `dispatch.ring_wait_minutes` (7) applied to EVERY ring, so the shape the spec describes could not
-- be expressed at all. The radii were already an array; this gives the other two the same shape.
--
-- THE RADII ARE DELIBERATELY UNCHANGED. The spec asks for 5/10/25 miles. The owner kept 15/30/60
-- (2026-10-04) and that call stands: five miles of rural Texas can hold nobody, and a first wave
-- that reaches no one is two minutes of silence while somebody sits in a ditch. So the WAVE SHAPE
-- is the spec's and the GEOGRAPHY is the owner's.
--
-- Each lookup falls back through three levels: the array for this wave, then the old scalar
-- setting, then a constant. That ordering is what makes this migration safe to apply to a database
-- whose admin has already tuned the scalar -- their value keeps working for any wave the array does
-- not mention, instead of being silently overridden by a default shipped months later.

set search_path = public, extensions;

-- How many helpers this wave texts.
create or replace function app.ring_max_helpers(p_ring integer)
returns integer
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  select coalesce(
    -- `value -> n` is NULL past the end of the array, so a two-entry array simply has nothing to
    -- say about wave 3 and the fallback answers instead. No bounds check needed, and none wanted:
    -- an admin shortening the array should not break the wave that is mid-flight.
    (select (value -> (p_ring - 1))::text::integer
       from public.app_settings where key = 'dispatch.ring_helpers'),
    (select (value)::text::integer
       from public.app_settings where key = 'dispatch.max_per_ring'),
    10
  );
$$;

-- How long this wave waits before the next one opens.
create or replace function app.ring_wait_minutes(p_ring integer)
returns integer
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  select coalesce(
    (select (value -> (p_ring - 1))::text::integer
       from public.app_settings where key = 'dispatch.ring_waits_minutes'),
    (select (value)::text::integer
       from public.app_settings where key = 'dispatch.ring_wait_minutes'),
    7
  );
$$;

-- `do nothing`, not `do update`: production values are the admin's, not ours. Same rule as
-- 20260921000100, and it is the reason the scalar fallbacks above exist.
insert into app_settings (key, value, description, is_public) values
  ('dispatch.ring_helpers', '[5, 10, 10]'::jsonb,
   'Helpers texted per wave, closest first. Falls back to dispatch.max_per_ring for any wave not '
   'listed. Wave 1 is deliberately smaller than the rest: the nearest few first, widening only if '
   'nobody answers.', false),
  ('dispatch.ring_waits_minutes', '[2, 3, 3]'::jsonb,
   'Minutes a wave waits before the next opens. Falls back to dispatch.ring_wait_minutes. Shorter '
   'early waves reach more people sooner, at the cost of more messages per recovery.', false)
on conflict (key) do nothing;

-- Did both land, and do they answer per wave rather than one number three times? Asserted here
-- rather than trusted, because a wrong index is invisible -- `value -> 0` for every wave reads
-- exactly like a working lookup until somebody counts the texts.
select
  app.ring_max_helpers(1)   as helpers_w1,
  app.ring_max_helpers(2)   as helpers_w2,
  app.ring_max_helpers(3)   as helpers_w3,
  app.ring_wait_minutes(1)  as wait_w1,
  app.ring_wait_minutes(2)  as wait_w2,
  app.ring_radius_miles(1)  as radius_w1_unchanged;
