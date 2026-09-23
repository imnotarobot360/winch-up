-- Winch Up :: did 20260923000700_health_reachable.sql land?
--
-- Paste into the Supabase SQL editor. Read-only.
--
-- The two keys are mutually exclusive: the migration renames one to the other, so exactly one of
-- them exists at any time. That makes this a definitive answer rather than a hint.

select
  case
    when public.system_health_summary() ? 'reachable_volunteers'
      then 'PRESENT  000700 has run. reachable_volunteers = '
           || (public.system_health_summary() ->> 'reachable_volunteers')
    when public.system_health_summary() ? 'approved_active_responders'
      then '>>> NOT RUN  the function still returns approved_active_responders. '
           || 'Paste supabase/migrations/20260923000700_health_reachable.sql again.'
    else '>>> UNEXPECTED  neither key is present; something else redefined this function'
  end as health_metric;
