-- Winch Up :: counting adverts by place, without counting people
--
-- Section 12 of the owner's spec asks for impressions and clicks broken down by city and by ZIP code,
-- unique reach, CTA clicks and event views.
--
-- THE CONFLICT, AND THE OWNER'S DECISION.
--
-- CLAUDE.md states the existing rule: "`ad_daily_stats` has no column that could identify a person
-- and must not grow one. That is the whole privacy position of the ad system -- counts per creative
-- per surface per day, belonging to nobody -- and a test asserts the exact column list."
--
-- A ZIP code with one member in it turns "impressions: 1" into "that member saw this advert". So the
-- two halves of the spec cannot both be taken literally. The owner approved the resolution on
-- 2026-10-03: add the geographic dimension, and never REPORT a bucket below a minimum cohort size.
--
-- How that is built, in three parts that each matter:
--
--   1. A SEPARATE TABLE. `ad_daily_stats` keeps its exact column list, so the test that pins it keeps
--      protecting what it was written to protect. The geographic counts live in their own table whose
--      rules are different and are written down here.
--   2. NO GRANTS, RLS ON. Nothing reads this table directly. The only way to a number is
--      `admin_ad_report()`, which applies the suppression -- so the suppression cannot be bypassed by
--      selecting the table, and a future grant cannot quietly open it.
--   3. SUPPRESSION AT READ, ROLLED UP RATHER THAN DROPPED. A bucket below the threshold is folded
--      into an "other" row instead of vanishing, so the totals still add up. A report whose parts do
--      not sum to its total is a report somebody will reconcile by hand, and the first thing they
--      will ask for is the raw table.
--
-- WHAT IS DELIBERATELY NOT BUILT: UNIQUE REACH PER PERSON.
--
-- "How many different members saw this" cannot be answered without storing something per member per
-- creative, which is exactly the column this table must not grow. There is no clever version of this:
-- a hash is still an identifier, and with the member directory now fully open a per-ZIP count of one
-- is already narrow. So the report returns `estimated_reach` -- how many members the campaign's
-- targeting actually matches, from app.target_audience_count() -- and says so by name. That is an
-- honest number an advertiser can use. A number labelled "unique viewers" that was really "days times
-- surfaces" would be worse than none.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. Where the counts go
-- ---------------------------------------------------------------------------

create table if not exists public.ad_geo_daily_stats (
  creative_id uuid not null references public.ad_creatives(id) on delete cascade,
  surface     ad_surface not null,
  day         date not null,

  -- The reader's STATED area, copied at the moment of the impression. Not a user id, not an IP, not
  -- a point -- there is nothing here that is about a person rather than about a place.
  --
  -- EMPTY STRING, NOT NULL, AND IT IS PART OF THE KEY. '' means "this reader has not said where they
  -- are", which is most of them and is reported as its own row rather than hidden among the suppressed
  -- buckets.
  --
  -- Null would be the more natural spelling and it does not work here. A key treats nulls as
  -- DISTINCT, so every anonymous impression would insert a new row instead of incrementing one, and
  -- the table would grow a row per page view while the report quietly read right. The alternative --
  -- a unique index over coalesce() expressions -- cannot be the target of a plain
  -- `on conflict (columns)`, which is the same inference trap that stopped posts being reportable on
  -- 2026-10-01 and failed no assertion while doing it. A primary key cannot hold an expression at all.
  state       text not null default '',
  city        text not null default '',
  postal_code text not null default '',

  impressions integer not null default 0,
  clicks      integer not null default 0,

  primary key (creative_id, surface, day, state, city, postal_code)
);

alter table public.ad_geo_daily_stats enable row level security;
revoke all on public.ad_geo_daily_stats from anon, authenticated;

-- schema_audit_test wants an index on every foreign key. The primary key leads with creative_id, so
-- it serves, but it is spelled out rather than argued about.
create index if not exists ad_geo_daily_stats_creative_idx
  on public.ad_geo_daily_stats (creative_id, day);

comment on table public.ad_geo_daily_stats is
  'Impressions and clicks per creative, surface, day and STATED AREA. No person-identifying column, '
  'and there must never be one. No table access: read through admin_ad_report(), which suppresses '
  'any bucket below analytics.min_cohort and rolls it into an "other" row.';

-- ---------------------------------------------------------------------------
-- 2. Event views
-- ---------------------------------------------------------------------------
--
-- The other half of section 12. Same shape and the same rule: a count per event per day, belonging to
-- nobody. event_rsvps already records who is going, which is a thing a member chose to publish to the
-- other attendees; a view is not, and is never attributed.

create table if not exists public.event_daily_stats (
  event_id uuid not null references public.events(id) on delete cascade,
  day      date not null,
  views    integer not null default 0,
  primary key (event_id, day)
);

alter table public.event_daily_stats enable row level security;
revoke all on public.event_daily_stats from anon, authenticated;

create index if not exists event_daily_stats_event_idx
  on public.event_daily_stats (event_id, day);

comment on table public.event_daily_stats is
  'Views per event per day. No viewer column, ever -- event_rsvps is where a member deliberately '
  'says they are going, and a view is not that.';

-- ---------------------------------------------------------------------------
-- 3. The threshold
-- ---------------------------------------------------------------------------

insert into public.app_settings (key, value)
values ('analytics.min_cohort', '5'::jsonb)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 4. Recording an impression, with the place
-- ---------------------------------------------------------------------------
--
-- A NEW SIGNATURE RATHER THAN A CHANGED ONE, and the old one is kept and delegates.
--
-- Adding defaulted parameters would OVERLOAD ad_record_event and PostgREST could not then choose
-- between the two for the three-argument call the deployed route still makes -- every impression
-- starts failing with an ambiguity error that says nothing about the change. Dropping the old one
-- instead leaves a window, between the migration and the deploy, where the route calls a function
-- that no longer exists.
--
-- So: six parameters with NO defaults, which can never be ambiguous with three, and the three-argument
-- version stays as a thin wrapper. Nothing breaks in either order.
--
-- THE PLACE COMES FROM THE SERVER, NEVER FROM THE BROWSER. /api/ads/event holds the service-role key,
-- so auth.uid() is null in here and this function cannot look the reader up itself. The route reads
-- the session and passes the member's stated area in. A browser-supplied city would let anybody write
-- whatever they liked into an advertiser's report.

create or replace function public.ad_record_event_at(
  p_creative_id uuid,
  p_surface     text,
  p_kind        text,
  p_state       text,
  p_city        text,
  p_postal_code text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_surface ad_surface;
  v_kind    ad_event_kind;
  -- '' rather than null, to match the key. See the table definition.
  v_state   text := btrim(coalesce(p_state, ''));
  v_city    text := btrim(coalesce(p_city, ''));
  v_postal  text := btrim(coalesce(p_postal_code, ''));
  v_imp     integer;
  v_clk     integer;
begin
  begin
    v_surface := p_surface::ad_surface;
    v_kind := p_kind::ad_event_kind;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'bad_event');
  end;

  -- Only against a creative that is actually live. A stale id from a cached page does not get to
  -- inflate a number somebody is being billed against.
  if not exists (
    select 1 from ad_creatives cr
      join ad_campaigns c on c.id = cr.campaign_id
      join businesses b on b.id = c.business_id
     where cr.id = p_creative_id
       and cr.status = 'approved' and cr.is_active
       and c.status = 'approved' and b.status = 'approved'
  ) then
    return jsonb_build_object('ok', false, 'error', 'not_live');
  end if;

  v_imp := case when v_kind = 'impression' then 1 else 0 end;
  v_clk := case when v_kind = 'click' then 1 else 0 end;

  -- The existing total, unchanged. Its column list is pinned by a test and stays pinned.
  insert into ad_daily_stats (creative_id, surface, day, impressions, clicks)
  values (p_creative_id, v_surface, current_date, v_imp, v_clk)
  on conflict (creative_id, surface, day) do update
    set impressions = ad_daily_stats.impressions + v_imp,
        clicks = ad_daily_stats.clicks + v_clk;

  -- And the same event again, against the place. Two rows rather than one table with a nullable
  -- geography, so that turning the geographic breakdown off later is deleting a table rather than
  -- unpicking the number everybody is billed against.
  insert into ad_geo_daily_stats (creative_id, surface, day, state, city, postal_code,
                                  impressions, clicks)
  values (p_creative_id, v_surface, current_date, v_state, v_city, v_postal, v_imp, v_clk)
  on conflict (creative_id, surface, day, state, city, postal_code)
  do update
    set impressions = ad_geo_daily_stats.impressions + v_imp,
        clicks = ad_geo_daily_stats.clicks + v_clk;

  return jsonb_build_object('ok', true);
end;
$fn$;

revoke all on function public.ad_record_event_at(uuid, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.ad_record_event_at(uuid, text, text, text, text, text)
  to service_role;

-- The old three-argument entry point, kept and delegating. A deploy in either order works.
create or replace function public.ad_record_event(p_creative_id uuid, p_surface text, p_kind text)
returns jsonb
language sql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
  select public.ad_record_event_at(p_creative_id, p_surface, p_kind, null, null, null);
$fn$;

revoke all on function public.ad_record_event(uuid, text, text) from public, anon, authenticated;
grant execute on function public.ad_record_event(uuid, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 5. Recording an event view
-- ---------------------------------------------------------------------------

create or replace function public.record_event_view(p_event_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
begin
  -- Published events only. A draft's view count is not a thing anybody needs, and counting views on
  -- an unpublished row would leak that it exists.
  if not exists (
    select 1 from public.events where id = p_event_id and status = 'published'
  ) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  insert into public.event_daily_stats (event_id, day, views)
  values (p_event_id, current_date, 1)
  on conflict (event_id, day) do update
    set views = public.event_daily_stats.views + 1;

  return jsonb_build_object('ok', true);
end;
$fn$;

revoke all on function public.record_event_view(uuid) from public, anon, authenticated;
grant execute on function public.record_event_view(uuid) to service_role;

notify pgrst, 'reload schema';
