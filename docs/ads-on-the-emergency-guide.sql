-- Winch Up :: were adverts ever served beside the emergency contacts guide?
--
-- READ ONLY. Four SELECTs. No writes, no DDL, no temporary objects.
--
-- WHY. app.ad_slot_allowed refuses adverts on the emergency guidance guides by slug.
-- 20261001000100 added 'emergency' to that list and was never applied to production until
-- 2026-10-07 -- so from 2026-10-01, when the guide shipped (commit 7c07979, titled "Emergency
-- contacts: the seventh guide, and no advertising beside it"), until it was applied, production
-- had ('stuck', 'safety') and the emergency guide was monetizable.
--
-- WHAT THIS CAN AND CANNOT TELL YOU, which decides how to read the answer.
--
-- ad_daily_stats holds (creative_id, surface, day, impressions, clicks). There is NO slug column,
-- by design -- that table deliberately has nothing that could identify a person or a page beyond
-- the surface. So it can say whether adverts ran on the GUIDES surface, not on which guide.
--
--   * Zero on the resources surface for the whole window is conclusive: nothing was served on ANY
--     guide, so nothing was served beside the emergency one.
--   * Non-zero is NOT an attribution. It means adverts ran on some guide in that window, and this
--     table cannot say which. The six other guides were legitimately monetizable throughout.
--
-- One failure mode is ruled out before you start: /api/ads/event keeps a hardcoded set of accepted
-- surfaces, and a surface missing from it makes every impression 400 and the report sit at zero
-- while adverts really are being served. 'resources' IS in that set, and
-- src/app/[locale]/resources/[slug]/page.tsx mounts <AdSlot surface="resources" slug={slug} />, so
-- an impression on /resources/emergency would have been counted. A zero here is a real zero.
--
-- Statement 3 is the control for the other direction: if NO surface recorded anything that week,
-- the counting path was idle and a zero on resources proves nothing about what was displayed.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. Day by day, with the absence of a row shown as an absence
-- ---------------------------------------------------------------------------
--
-- Every day in the window appears, whether or not ad_daily_stats has a row for it. A missing row
-- and a row saying zero are different facts and are reported differently.

with window_days as (
  select generate_series(date '2026-10-01', date '2026-10-07', interval '1 day')::date as day
),
res as (
  select day,
         sum(impressions)::bigint as impressions,
         sum(clicks)::bigint      as clicks,
         count(*)::int            as rows_for_that_day
    from public.ad_daily_stats
   where surface = 'resources'
     and day between date '2026-10-01' and date '2026-10-07'
   group by day
)
select
  w.day,
  'resources'               as surface,
  r.impressions,
  r.clicks,
  coalesce(r.rows_for_that_day, 0) as rows_in_table,
  case
    when r.day is null        then 'NO ROW AT ALL -- nothing was recorded for this day'
    when r.impressions = 0    then 'a row exists and it says zero'
    else                           'ADVERTS WERE SERVED ON THE GUIDES SURFACE'
  end                       as reading
from window_days w
left join res r on r.day = w.day
order by w.day;

-- ---------------------------------------------------------------------------
-- 2. The totals
-- ---------------------------------------------------------------------------

select
  coalesce(sum(impressions), 0)::bigint                        as total_impressions,
  coalesce(sum(clicks), 0)::bigint                             as total_clicks,
  count(distinct day)::int                                     as days_with_a_row,
  count(distinct day) filter (where impressions > 0)::int      as days_with_impressions,
  count(distinct creative_id)::int                             as distinct_creatives,
  7 - count(distinct day)::int                                 as days_with_no_row_at_all
from public.ad_daily_stats
where surface = 'resources'
  and day between date '2026-10-01' and date '2026-10-07';

-- ---------------------------------------------------------------------------
-- 3. THE CONTROL: was the counter recording anything at all that week?
-- ---------------------------------------------------------------------------
--
-- Without this, a clean zero on resources is ambiguous -- it reads the same whether no advert was
-- shown or nothing was being counted. If other surfaces have rows for those days, the pipeline was
-- alive and a zero on resources means what it says.

select
  surface::text,
  count(distinct day)::int              as days_with_rows,
  coalesce(sum(impressions), 0)::bigint as impressions,
  coalesce(sum(clicks), 0)::bigint      as clicks
from public.ad_daily_stats
where day between date '2026-10-01' and date '2026-10-07'
group by surface
order by impressions desc, surface;

-- ---------------------------------------------------------------------------
-- 4. And has this table ever recorded anything, ever?
-- ---------------------------------------------------------------------------
--
-- The last ambiguity: an empty statement 3 could mean the advertising system has never served a
-- single impression since it was built. That is a different sentence from "nothing ran that week",
-- and the owner should be told which one is true.

select
  count(*)::bigint                      as rows_in_the_whole_table,
  min(day)                              as earliest_day_recorded,
  max(day)                              as latest_day_recorded,
  coalesce(sum(impressions), 0)::bigint as impressions_all_time
from public.ad_daily_stats;
