-- Winch Up :: the report, and the suppression that makes it publishable
--
-- Section 12 of the owner's spec, and the half that carries the privacy decision. The counts exist in
-- ad_geo_daily_stats; this is the only way to read them, and it is where a bucket too small to be
-- about a place rather than a person gets folded away.
--
-- THE RULE, IN ONE SENTENCE: any geographic bucket whose impressions are below
-- `analytics.min_cohort` is not reported as that place -- it is added to an "other" row.
--
-- WHY ROLL UP RATHER THAN DROP. A report whose parts do not add up to its total is a report somebody
-- reconciles by hand, and the first thing they ask for when they cannot is the raw table. Rolling the
-- small buckets together keeps the arithmetic honest and still answers the question an advertiser
-- actually has -- "which areas is this reaching" -- while being useless for identifying anybody. The
-- "other" row is labelled as suppressed and carries how many buckets went into it, so nobody mistakes
-- it for a place called Other.
--
-- WHY THE THRESHOLD IS ON IMPRESSIONS AND NOT ON CLICKS. A bucket is reported or not on its impression
-- count, and its clicks travel with it. Thresholding the two independently would publish "0
-- impressions, 1 click in 77429", which is a worse disclosure than the thing being prevented: a click
-- is a deliberate act by one person.

set search_path = public, extensions;

create or replace function public.admin_ad_report(
  p_campaign_id uuid default null,
  p_creative_id uuid default null,
  p_days        integer default 30
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_k      integer := greatest(1, app.setting_int('analytics.min_cohort', 5));
  v_from   date;
  v_total  jsonb;
  v_byday  jsonb;
  v_cities jsonb;
  v_zips   jsonb;
  v_reach  integer;
begin
  perform app.require_admin();

  if p_campaign_id is null and p_creative_id is null then
    return jsonb_build_object('ok', false, 'error', 'no_subject');
  end if;

  v_from := current_date - greatest(1, least(coalesce(p_days, 30), 365));

  -- THE TOTALS COME FROM ad_daily_stats, NOT FROM THE GEOGRAPHIC TABLE.
  --
  -- They are the same events counted twice on purpose, and this is the copy that is pinned by a test
  -- and that nothing suppresses. Summing the geographic rows instead would make the headline number
  -- depend on a privacy threshold, which is the one number that must never move for that reason.
  select jsonb_build_object(
           'impressions', coalesce(sum(s.impressions), 0),
           'clicks', coalesce(sum(s.clicks), 0))
    into v_total
    from ad_daily_stats s
    join ad_creatives cr on cr.id = s.creative_id
   where s.day >= v_from
     and (p_creative_id is null or s.creative_id = p_creative_id)
     and (p_campaign_id is null or cr.campaign_id = p_campaign_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'day', d.day, 'impressions', d.impressions, 'clicks', d.clicks)
           order by d.day), '[]'::jsonb)
    into v_byday
    from (
      select s.day, sum(s.impressions)::integer as impressions, sum(s.clicks)::integer as clicks
        from ad_daily_stats s
        join ad_creatives cr on cr.id = s.creative_id
       where s.day >= v_from
         and (p_creative_id is null or s.creative_id = p_creative_id)
         and (p_campaign_id is null or cr.campaign_id = p_campaign_id)
       group by s.day
    ) d;

  -- By city. `suppressed` buckets are summed into one row rather than discarded, so the parts still
  -- add up to the total above.
  with buckets as (
    select g.city as city, g.state as state,
           sum(g.impressions)::integer as impressions,
           sum(g.clicks)::integer as clicks
      from ad_geo_daily_stats g
      join ad_creatives cr on cr.id = g.creative_id
     where g.day >= v_from
       and (p_creative_id is null or g.creative_id = p_creative_id)
       and (p_campaign_id is null or cr.campaign_id = p_campaign_id)
     group by 1, 2
  ),
  split as (
    -- A bucket with no city at all is not a small cohort, it is "readers who have not said where they
    -- are", and it is reported as that rather than hidden among the suppressed ones. It is usually the
    -- biggest row on the page, and calling it suppressed would be a lie about why.
    select *,
           case when city = '' then 'unknown'
                when impressions < v_k then 'suppressed'
                else 'named' end as bucket
      from buckets
  )
  select coalesce(
    (select jsonb_agg(jsonb_build_object(
              'city', city, 'state', nullif(state, ''),
              'impressions', impressions, 'clicks', clicks)
              order by impressions desc, city)
       from split where bucket = 'named')
    , '[]'::jsonb)
    ||
    coalesce(
      (select jsonb_agg(jsonb_build_object(
                'city', null, 'state', null, 'unknown_area', true,
                'impressions', impressions, 'clicks', clicks))
         from split where bucket = 'unknown')
      , '[]'::jsonb)
    ||
    coalesce(
      (select case when count(*) = 0 then '[]'::jsonb else jsonb_build_array(jsonb_build_object(
                'city', null, 'state', null, 'suppressed', true,
                'bucket_count', count(*)::integer,
                'impressions', sum(impressions)::integer,
                'clicks', sum(clicks)::integer)) end
         from split where bucket = 'suppressed')
      , '[]'::jsonb)
    into v_cities;

  -- By postal code, same rule. This is the one the owner asked for by name and the one where a bucket
  -- of one is closest to being a person.
  with buckets as (
    select g.postal_code as postal_code,
           sum(g.impressions)::integer as impressions,
           sum(g.clicks)::integer as clicks
      from ad_geo_daily_stats g
      join ad_creatives cr on cr.id = g.creative_id
     where g.day >= v_from
       and (p_creative_id is null or g.creative_id = p_creative_id)
       and (p_campaign_id is null or cr.campaign_id = p_campaign_id)
     group by 1
  ),
  split as (
    select *,
           case when postal_code = '' then 'unknown'
                when impressions < v_k then 'suppressed'
                else 'named' end as bucket
      from buckets
  )
  select coalesce(
    (select jsonb_agg(jsonb_build_object(
              'postal_code', postal_code, 'impressions', impressions, 'clicks', clicks)
              order by impressions desc, postal_code)
       from split where bucket = 'named')
    , '[]'::jsonb)
    ||
    coalesce(
      (select jsonb_agg(jsonb_build_object(
                'postal_code', null, 'unknown_area', true,
                'impressions', impressions, 'clicks', clicks))
         from split where bucket = 'unknown')
      , '[]'::jsonb)
    ||
    coalesce(
      (select case when count(*) = 0 then '[]'::jsonb else jsonb_build_array(jsonb_build_object(
                'postal_code', null, 'suppressed', true,
                'bucket_count', count(*)::integer,
                'impressions', sum(impressions)::integer,
                'clicks', sum(clicks)::integer)) end
         from split where bucket = 'suppressed')
      , '[]'::jsonb)
    into v_zips;

  -- ESTIMATED REACH, AND IT SAYS ESTIMATED.
  --
  -- Not "unique viewers". Counting distinct people requires storing something per person per creative,
  -- which is the column ad_geo_daily_stats must never grow, and a hash is still an identifier. This is
  -- how many members the campaign's targeting matches -- an honest number, and the one an advertiser
  -- is actually deciding on. A field labelled "unique viewers" holding something else would be worse
  -- than no field.
  v_reach := case
    when p_campaign_id is not null then app.target_audience_count('campaign', p_campaign_id)
    else (select app.target_audience_count('campaign', cr.campaign_id)
            from ad_creatives cr where cr.id = p_creative_id)
  end;

  return jsonb_build_object(
    'ok', true,
    'from', v_from,
    'min_cohort', v_k,
    'totals', v_total,
    'by_day', v_byday,
    'by_city', v_cities,
    'by_postal_code', v_zips,
    'estimated_reach', v_reach,
    -- Said in the payload, not only in a comment, so a screen rendering this cannot present the
    -- breakdown as complete.
    'note', 'Geographic buckets below min_cohort impressions are combined into one suppressed row. '
            'estimated_reach is how many members the targeting matches, not a count of viewers.'
  );
end;
$fn$;

revoke all on function public.admin_ad_report(uuid, uuid, integer) from public, anon;
grant execute on function public.admin_ad_report(uuid, uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- Event views, for the same screen
-- ---------------------------------------------------------------------------

create or replace function public.admin_event_report(p_days integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_rows jsonb;
  v_from date;
begin
  perform app.require_admin();

  v_from := current_date - greatest(1, least(coalesce(p_days, 30), 365));

  select coalesce(jsonb_agg(to_jsonb(e) order by e.views desc, e.starts_at), '[]'::jsonb)
    into v_rows
  from (
    select ev.id, ev.title, ev.starts_at, ev.city, ev.state,
           app.target_audience_count('event', ev.id) as estimated_reach,
           coalesce((select sum(s.views)::integer from public.event_daily_stats s
                      where s.event_id = ev.id and s.day >= v_from), 0) as views,
           (select count(*)::integer from public.event_rsvps r
             where r.event_id = ev.id and r.response = 'going') as going
      from public.events ev
     where ev.status = 'published'
     order by ev.starts_at desc
     limit 200
  ) e;

  return jsonb_build_object('ok', true, 'from', v_from, 'events', v_rows);
end;
$fn$;

revoke all on function public.admin_event_report(integer) from public, anon;
grant execute on function public.admin_event_report(integer) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- WHAT HAS NO CALLER YET, as of 2026-10-03
-- ---------------------------------------------------------------------------
--
-- `record_event_view()` is written, tested and granted, and NOTHING calls it. There is no event detail
-- page in this app: events are a tab on /community showing a list, and counting a "view" for every
-- event in a list is not a view of an event -- it would make the number meaningless on the first day.
--
-- Said here rather than left to be found, because the failure mode is specific and quiet:
-- admin_event_report() will show views: 0 for every event forever, which reads as "nobody is looking at
-- our events" rather than "nothing is counting". The RSVP count and the estimated reach on that report
-- are real numbers and do not depend on this.
--
-- The missing piece is a page, not a function. When an event gets one, it calls this once per load.
