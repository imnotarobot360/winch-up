-- Winch Up :: the life of a campaign
--
-- Section 9 of the owner's spec: "draft, scheduled, active, expired, with pause, resume, duplicate
-- and archive".
--
-- WHAT ALREADY EXISTED. `campaign_status` has draft, pending, approved, rejected, paused and ended,
-- and `set_campaign_running()` is pause and resume -- deliberately only between approved and paused,
-- so resuming can never be a way to approve something that never was. So of the eight things the spec
-- names, five are built.
--
-- SCHEDULED, ACTIVE AND EXPIRED ARE DERIVED, NOT STORED, and that is the main decision in this file.
--
-- They are entirely a function of `status`, `starts_on` and `ends_on`, all of which exist. Storing
-- them as enum labels would mean a job somewhere flipping active to expired every night -- and the
-- morning that job fails, a campaign reads `active` while the serving query, which looks at the
-- dates, has already stopped showing it. Or worse, the reverse. Two sources of truth about whether
-- somebody's money is buying anything is one more than can be allowed.
--
-- Derived, the label is computed from the same three columns ads_for() reads, so the admin screen and
-- the serving path cannot disagree. A campaign cannot be `active` and invisible.
--
-- ARCHIVE IS STORAGE, because it is the one state that is not implied by anything else: it means
-- "stop showing me this in the list", and it has to survive without claiming the campaign never ran.
-- It is NOT a status, for the same reason -- an archived campaign that was approved and ran for a
-- month is still a campaign that was approved and ran for a month, and the reports have to say so.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. Archiving
-- ---------------------------------------------------------------------------

alter table public.ad_campaigns
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by uuid references auth.users(id) on delete set null;

-- schema_audit_test requires an index on every foreign key.
create index if not exists ad_campaigns_archived_by_idx
  on public.ad_campaigns (archived_by)
  where archived_by is not null;

comment on column public.ad_campaigns.archived_at is
  'Hidden from the working list. NOT a status: an archived campaign that was approved and ran is '
  'still that, and the reports have to keep saying so.';

-- ---------------------------------------------------------------------------
-- 2. The phase
-- ---------------------------------------------------------------------------
--
-- One function, so that the admin list, the advertiser view and any future report all answer this
-- question the same way. Order matters inside it: archived beats everything, because an archived
-- campaign is not something anybody wants to read as "active".

create or replace function app.campaign_phase(
  p_status      campaign_status,
  p_starts_on   date,
  p_ends_on     date,
  p_archived_at timestamptz
)
returns text
language sql
immutable
set search_path = public, extensions, pg_temp
as $fn$
  select case
    when p_archived_at is not null then 'archived'
    when p_status = 'draft'        then 'draft'
    when p_status = 'pending'      then 'pending'
    when p_status = 'rejected'     then 'rejected'
    when p_status = 'paused'       then 'paused'
    when p_status = 'ended'        then 'expired'
    -- From here the campaign is approved, and the DATES decide -- the same three comparisons
    -- ads_for() makes, so the word on the screen matches what is being served.
    when p_ends_on is not null and p_ends_on < current_date then 'expired'
    when p_starts_on > current_date                         then 'scheduled'
    else 'active'
  end;
$fn$;

revoke all on function app.campaign_phase(campaign_status, date, date, timestamptz)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Archiving and restoring
-- ---------------------------------------------------------------------------

create or replace function public.set_campaign_archived(p_id uuid, p_archived boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me  uuid := auth.uid();
  v_hit integer;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  -- The advertiser OR an admin. An advertiser tidying their own list is routine; an admin needs it
  -- for a campaign whose owner has gone quiet.
  update public.ad_campaigns
     set archived_at = case when p_archived then now() else null end,
         archived_by = case when p_archived then v_me else null end,
         updated_at  = now()
   where id = p_id
     and (app.owns_business(business_id) or app.is_admin());

  get diagnostics v_hit = row_count;
  if v_hit = 0 then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object('ok', true);
end;
$fn$;

revoke all on function public.set_campaign_archived(uuid, boolean) from public, anon;
grant execute on function public.set_campaign_archived(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Duplicating
-- ---------------------------------------------------------------------------
--
-- A COPY IS NEW WORDS AND STARTS AS A DRAFT. This is the rule CLAUDE.md states as "approval attaches
-- to the words, not the row": editing an approved creative sends it back to pending, so duplicating an
-- approved campaign and inheriting its approval would be the same hole with an extra step --
-- "approve this, then duplicate it and change the headline" is a two-step way past review.
--
-- So the copy carries the targeting, the surfaces, the dates and the creatives' text, and carries none
-- of the approval: no reviewed_by, no reviewed_at, no review_note, status draft, every creative draft
-- and inactive. The only thing being saved is retyping.

create or replace function public.duplicate_campaign(p_id uuid, p_name text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me  uuid := auth.uid();
  v_src   public.ad_campaigns;
  v_new   uuid;
  v_shift integer;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  select * into v_src from public.ad_campaigns where id = p_id;

  if v_src.id is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if not (app.owns_business(v_src.business_id) or app.is_admin()) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  v_shift := greatest(v_src.starts_on, current_date) - v_src.starts_on;

  insert into public.ad_campaigns (
    business_id, name, status, surfaces,
    target_center, target_radius_miles, target_counties,
    starts_on, ends_on, monthly_price_cents
  ) values (
    v_src.business_id,
    left(coalesce(nullif(btrim(coalesce(p_name, '')), ''), v_src.name || ' (copy)'), 120),
    -- Draft. Never v_src.status. See the header.
    'draft',
    v_src.surfaces,
    v_src.target_center, v_src.target_radius_miles, v_src.target_counties,
    -- THE WHOLE WINDOW MOVES, not just the start.
    --
    -- A copy that starts in the past would begin serving the moment it was approved, which is not
    -- what duplicating something means -- so the start is today at the earliest. Clamping the start
    -- alone was the first version of this, and `ad_campaigns_dates_make_sense` caught it: a campaign
    -- that ran from sixty days ago to thirty days ago duplicated into one starting today and ending a
    -- month before that. The constraint refused it, which is the constraint doing its job.
    --
    -- Shifting both by the same number of days preserves what the advertiser actually bought: a
    -- thirty-day campaign duplicates as a thirty-day campaign starting today. A copy that needs no
    -- shift keeps its dates exactly.
    v_src.starts_on + v_shift,
    case when v_src.ends_on is null then null else v_src.ends_on + v_shift end,
    v_src.monthly_price_cents
  )
  returning id into v_new;

  -- The structured targeting travels with it. This is most of the value of duplicating: a campaign
  -- aimed at fourteen ZIP codes is the one nobody wants to retype.
  insert into public.target_locations (scope, target_id, kind, state, city, postal_code,
                                       center, radius_miles)
  select 'campaign', v_new, kind, state, city, postal_code, center, radius_miles
    from public.target_locations
   where scope = 'campaign' and target_id = p_id;

  -- The words, with the approval stripped off every one.
  -- (See the note below on why 'pending' rather than 'draft'.)
  insert into public.ad_creatives (
    campaign_id, headline, body, cta_label, cta_url, image_path, status, is_active
  )
  -- 'pending', not 'draft': creative_status is pending / approved / rejected and has no draft. That
  -- is the right landing place anyway -- unreviewed words belong in the review queue rather than in a
  -- state nobody looks at -- and nothing can serve regardless, because the campaign itself is a draft
  -- and is_active is false on every row.
  select v_new, headline, body, cta_label, cta_url, image_path, 'pending', false
    from public.ad_creatives
   where campaign_id = p_id;

  perform app.audit('campaign.duplicate', 'ad_campaign', v_new::text,
                    jsonb_build_object('from', p_id));

  return jsonb_build_object('ok', true, 'id', v_new);
end;
$fn$;

revoke all on function public.duplicate_campaign(uuid, text) from public, anon;
grant execute on function public.duplicate_campaign(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. The admin list
-- ---------------------------------------------------------------------------
--
-- Section 14 wants the estimated audience in front of an admin BEFORE they publish, which is why the
-- count is in this list rather than only on a detail screen: the decision being made on this page is
-- "is this campaign aimed at anybody at all".

create or replace function public.admin_campaigns(
  p_phase          text default null,
  p_include_archived boolean default false,
  p_limit          integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_rows jsonb;
begin
  perform app.require_admin();

  select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at desc), '[]'::jsonb) into v_rows
  from (
    select
      ca.id, ca.name, ca.status::text as status,
      app.campaign_phase(ca.status, ca.starts_on, ca.ends_on, ca.archived_at) as phase,
      ca.surfaces::text[] as surfaces,
      ca.starts_on, ca.ends_on, ca.monthly_price_cents,
      ca.archived_at, ca.created_at,
      b.id as business_id, b.name as business_name, b.category::text as business_category,
      -- The targeting, as rows rather than a string, so the screen can list the places.
      coalesce((
        select jsonb_agg(jsonb_build_object(
                 'kind', t.kind::text, 'state', t.state, 'city', t.city,
                 'postal_code', t.postal_code, 'radius_miles', t.radius_miles)
               order by t.kind, t.state, t.city, t.postal_code)
          from public.target_locations t
         where t.scope = 'campaign' and t.target_id = ca.id
      ), '[]'::jsonb) as targets,
      app.target_audience_count('campaign', ca.id) as audience,
      (select count(*) from public.ad_creatives cr where cr.campaign_id = ca.id) as creative_count,
      (select count(*) from public.ad_creatives cr
        where cr.campaign_id = ca.id and cr.status = 'approved' and cr.is_active) as live_creatives
    from public.ad_campaigns ca
    join public.businesses b on b.id = ca.business_id
   where (p_include_archived or ca.archived_at is null)
     and (p_phase is null
          or app.campaign_phase(ca.status, ca.starts_on, ca.ends_on, ca.archived_at) = p_phase)
   order by ca.created_at desc
   limit greatest(1, least(coalesce(p_limit, 50), 200))
  ) c;

  return jsonb_build_object('ok', true, 'campaigns', v_rows);
end;
$fn$;

revoke all on function public.admin_campaigns(text, boolean, integer) from public, anon;
grant execute on function public.admin_campaigns(text, boolean, integer) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 6. The serving path uses the same phase function
-- ---------------------------------------------------------------------------
--
-- Archiving has to stop a campaign serving, and the lifecycle labels above are only trustworthy if
-- the thing that serves adverts asks the same question the screen asks. Both are settled by replacing
-- four conditions in ads_for() with one call to app.campaign_phase().
--
-- Same signature, same return type, body copied from 20261003000400 with that one change -- adding a
-- parameter would OVERLOAD this function and PostgREST could not then choose between the two.

create or replace function public.ads_for(
  p_surface text,
  p_slug    text default null,
  p_lng     double precision default null,
  p_lat     double precision default null,
  p_limit   integer default 1
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_surface ad_surface;
  v_here    extensions.geography;
  v_rows    jsonb;

  -- The reader's STATED location, and nothing else about them. Four scalars, read once.
  v_me      uuid := auth.uid();
  v_city    text;
  v_state   text;
  v_postal  text;
  v_center  extensions.geography;
begin
  begin
    v_surface := p_surface::ad_surface;
  exception when others then
    -- Including, deliberately, every emergency surface somebody might try to name. There is no
    -- enum value for the request wizard, a live recovery, or a message thread.
    return jsonb_build_object('ok', false, 'error', 'bad_surface');
  end;

  if not app.ad_slot_allowed(v_surface, p_slug) then
    return jsonb_build_object('ok', true, 'ads', '[]'::jsonb, 'blocked', true);
  end if;

  -- The advertising-purpose location, declared by the member on /account/location for exactly this.
  -- It is NOT the recovery position held on a volunteer record, which is what a call-out is measured
  -- from. A member who has never volunteered has no such position and must still be reachable by a
  -- campaign; a member who has one must not have it quietly repurposed to sell to them.
  --
  -- THAT SENTENCE AVOIDS THE TWO IDENTIFIERS ON PURPOSE, and so must anything written here later.
  -- The section 7 guard in targeting_test.sql is a textual check over this function's source, and a
  -- textual check cannot tell a comment from a reference -- naming either identifier in a comment
  -- fails the suite with a message about reading recovery data, which is exactly the kind of
  -- confusing failure that gets a guard deleted instead of understood. The guard stays blunt because
  -- blunt is what survives; the comment works around it.
  if v_me is not null then
    select p.city, p.state, p.postal_code, p.postal_center
      into v_city, v_state, v_postal, v_center
      from public.profiles p
     where p.user_id = v_me;
  end if;

  -- WHICH POINT A RADIUS IS MEASURED FROM.
  --
  -- The member's own stated centroid wins: they chose it for this purpose, and it is derived from
  -- their postal code by the server rather than claimed by a browser. The caller-supplied point is
  -- the fallback, and it is the ONLY way a signed-out reader on a public page can ever match a
  -- geo-targeted campaign -- /trails and /resources serve adverts to anonymous visitors.
  --
  -- What a null point is no longer is a LICENCE. It used to mean "show it anyway"; it now means the
  -- reader matches no radius target, which is the whole point of this migration.
  v_center := coalesce(
    v_center,
    case
      when p_lng is not null and p_lat is not null
        then extensions.st_setsrid(extensions.st_point(p_lng, p_lat), 4326)::extensions.geography
    end
  );
  v_here := v_center;

  select coalesce(jsonb_agg(to_jsonb(a)), '[]'::jsonb) into v_rows
  from (
    select
      cr.id as creative_id,
      cr.headline,
      cr.body,
      cr.cta_label,
      cr.cta_url,
      cr.image_path,
      b.name as business_name,
      b.category::text as category,
      v_surface::text as surface,

      -- Both labels travel with the ad. `labelled` is always true and is asserted by a test:
      -- an ad that arrives without it is a bug, not a styling choice.
      true as labelled,
      -- The second line, for the category where confusing a paid advertiser with a volunteer
      -- actually costs somebody money at the roadside.
      (b.category = 'recovery_towing') as not_a_volunteer
    from ad_creatives cr
    join ad_campaigns c on c.id = cr.campaign_id
    join businesses b on b.id = c.business_id
   where cr.status = 'approved'
     and cr.is_active
     and b.status = 'approved'
     and v_surface = any (c.surfaces)

     -- ONE FUNCTION DECIDES WHETHER A CAMPAIGN IS LIVE, and it is the same one the admin screen
     -- prints. This replaces four separate conditions -- status approved, started, not finished, and
     -- (new) not archived -- with the single question app.campaign_phase() answers.
     --
     -- The point is not brevity. Section 9's lifecycle labels are derived rather than stored so that
     -- the word on the admin screen cannot disagree with what is being served; leaving the date
     -- comparisons duplicated here would have made that claim aspirational instead of true, and the
     -- two copies would have drifted the first time somebody changed one. A campaign cannot now read
     -- "active" and be invisible, or read "expired" and still be serving.
     and app.campaign_phase(c.status, c.starts_on, c.ends_on, c.archived_at) = 'active'

     -- The structured targeting from section 10: state, city, several cities, ZIP, several ZIPs,
     -- radius. No rows for this campaign means everybody, which is the spec's "All Members".
     and app.member_matches_target('campaign', c.id, v_state, v_city, v_postal, v_center)

     -- THE LEGACY RADIUS COLUMNS, STILL HONOURED.
     --
     -- target_center / target_radius_miles predate target_locations and may already be set on a
     -- campaign somebody configured. BOTH gates have to pass, which is the conservative reading of
     -- section 6 -- a campaign narrowed two ways reaches the intersection, never the union. The
     -- alternative would let a new city target WIDEN an existing radius campaign, which is not what
     -- anybody adding a city believes they are doing.
     --
     -- And a null point is no longer an escape hatch here either.
     and (
       c.target_center is null
       or (
         v_here is not null
         and extensions.st_dwithin(c.target_center, v_here,
                                   c.target_radius_miles * 1609.344)
       )
     )
   -- Random rather than by price. With inventory this small, ordering by what somebody paid
   -- turns the one slot on the page into a permanent billboard for whoever bid most once.
   order by random()
   limit greatest(1, least(coalesce(p_limit, 1), 5))
  ) a;

  return jsonb_build_object('ok', true, 'ads', v_rows);
end;
$fn$;

notify pgrst, 'reload schema';
