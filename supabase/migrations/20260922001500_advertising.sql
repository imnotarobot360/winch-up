-- Winch Up :: business advertising
--
-- Phase 10. Business accounts, campaigns, creatives, labelled ad serving, and counting.
--
-- The spec for this phase is mostly a list of things that must never happen, so most of this
-- file is those things made structurally impossible rather than written down and hoped for.
--
-- 1. ADS CANNOT APPEAR ON AN EMERGENCY SURFACE.
--    `ad_surface` has three values. Not one of them is the request wizard, a live recovery
--    status page, or the message thread between two people on a job. There is no value to pass,
--    so there is no code path to write by accident and no setting to get wrong later.
--
--    The resources section is a surface, but two of its guides are emergency guidance -- "when
--    the stuck one is you" and "doing a recovery without hurting anyone". `app.ad_slot_allowed()`
--    refuses those by name, and there is a test.
--
-- 2. NOBODY CAN BUY PRIORITY IN MATCHING.
--    Nothing in this file is readable from `app.candidates()`, and nothing in the dispatch path
--    joins any table defined here. That is asserted in the test suite by reading the function
--    source, because "we would never do that" is not a guarantee and the next person to touch
--    matching will not have read this comment.
--
-- 3. NOBODY IS TOLD A PAID ADVERTISER IS A BETTER RECOVERY OPTION.
--    Every served ad carries a label. An advertiser in a recovery or towing category carries a
--    second one saying plainly that they are not a Winch Up volunteer. The serving function
--    returns both; the component cannot render an ad without them, because they arrive in the
--    same row as the headline.
--
-- 4. NOTHING PERSONAL IS COLLECTED BY THE AD SYSTEM.
--    `ad_daily_stats` has no user column, no session column and no IP column, and it never will:
--    it is a count per creative per surface per day. The spec asks for consent management and
--    privacy controls appropriate to the jurisdiction. The strongest available control is not
--    collecting, and it is what this does. There is a test asserting the table has no column
--    that could identify a person.
--
-- 5. NO FABRICATED NUMBERS.
--    There is no seed. An advertiser's dashboard shows real counts or it shows zero. The spec
--    says do not fabricate impressions, clicks, advertiser results or revenue, and a demo row
--    that looks like traffic is exactly that.
--
-- WHAT IS DELIBERATELY NOT HERE
--
--    Google AdMob. The spec says to use it for native mobile advertising only after the mobile
--    applications exist and are approved. They do not exist. Nothing here pretends otherwise.
--
--    A public directory of paid businesses. Of the four formats named, that is the one most
--    likely to read as an endorsement by a volunteer recovery group, and it needs its labelling
--    worked out before it is built rather than after.
--
-- BILLING MODEL -- an assumption the owner should overrule if it is wrong: a flat monthly price
-- per campaign, not CPM. Metered impressions across two counties would bill in cents and would
-- cost more in engineering than it could ever collect. Stripe wiring is a separate migration.

set search_path = public, extensions;

create type business_status as enum ('draft', 'pending', 'approved', 'rejected', 'suspended');

create type business_category as enum (
  'recovery_towing',      -- the one that needs the extra label
  'offroad_shop',
  'tires_wheels',
  'fabrication',
  'parts',
  'powersports',
  'land_access',          -- parks, leases, ranch access
  'food_lodging',
  'insurance',
  'other'
);

create type campaign_status as enum (
  'draft', 'pending', 'approved', 'rejected', 'paused', 'ended'
);

create type creative_status as enum ('pending', 'approved', 'rejected');

-- Three values. The request wizard, /r/[token] and the message thread are not among them, and
-- adding one is a schema change somebody has to justify in a migration.
create type ad_surface as enum ('community_feed', 'trails', 'resources');

create type ad_event_kind as enum ('impression', 'click');

-- ---------------------------------------------------------------------------
-- Businesses
-- ---------------------------------------------------------------------------

create table businesses (
  id            uuid primary key default gen_random_uuid(),
  owner_user_id uuid references auth.users (id) on delete set null,

  name          text not null check (length(btrim(name)) between 2 and 120),
  slug          text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  category      business_category not null,

  -- An advertiser's own contact details are the point of advertising, so
  -- contains_contact_info() deliberately does NOT apply to these columns. The rule it enforces
  -- elsewhere exists so members do not arrange paid recoveries in the group feed; a labelled,
  -- admin-approved advertiser showing its own number is the opposite situation.
  description   text check (description is null or length(btrim(description)) <= 1000),
  website       text check (website is null or website ~* '^https?://'),
  contact_email text,
  contact_phone text,
  logo_path     text,

  -- Where they actually work. Used to target, and shown so a reader can tell whether an
  -- advertiser is anywhere near them.
  service_counties     text[] not null default '{}',
  service_center       extensions.geography(point, 4326),
  service_radius_miles integer check (service_radius_miles is null
                                      or service_radius_miles between 1 and 500),

  status        business_status not null default 'draft',

  -- Same discipline as a trail's access source: an admin does not mark a business approved
  -- without recording what they actually checked. "Their LLC is registered in Texas and the
  -- phone number answers" is a sentence somebody can be held to; a green tick is not.
  verification_note text,
  reviewed_by   uuid references auth.users (id) on delete set null,
  reviewed_at   timestamptz,
  review_note   text,

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  constraint businesses_approved_is_verified check (
    status <> 'approved'
    or (verification_note is not null and length(btrim(verification_note)) > 0)
  )
);

create index businesses_owner_idx on businesses (owner_user_id);
create index businesses_status_idx on businesses (status, name);

create trigger businesses_set_updated_at
  before update on businesses
  for each row execute function app.set_updated_at();

comment on column businesses.verification_note is
  'What the admin actually checked before approving. Required for approval, in the same way a '
  'trail cannot claim to be open without naming a source.';

-- ---------------------------------------------------------------------------
-- Campaigns
-- ---------------------------------------------------------------------------

create table ad_campaigns (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses (id) on delete cascade,

  name        text not null check (length(btrim(name)) between 2 and 120),
  status      campaign_status not null default 'draft',

  surfaces    ad_surface[] not null default '{}'
                check (array_length(surfaces, 1) between 1 and 3),

  -- Geographic targeting. Null centre means "anywhere we run", which for this product is two
  -- counties, so it is not the land grab it would be elsewhere.
  target_center       extensions.geography(point, 4326),
  target_radius_miles integer check (target_radius_miles is null
                                     or target_radius_miles between 1 and 500),
  target_counties     text[] not null default '{}',

  -- Scheduling.
  starts_on   date not null default current_date,
  ends_on     date,

  -- Budget, as a flat monthly price. See the header: metered CPM for an audience this size
  -- would bill in cents.
  monthly_price_cents integer not null default 0 check (monthly_price_cents >= 0),

  reviewed_by uuid references auth.users (id) on delete set null,
  reviewed_at timestamptz,
  review_note text,

  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint ad_campaigns_dates_make_sense check (ends_on is null or ends_on >= starts_on),
  constraint ad_campaigns_radius_needs_a_centre check (
    (target_center is null) = (target_radius_miles is null)
  )
);

create index ad_campaigns_business_idx on ad_campaigns (business_id);
create index ad_campaigns_live_idx on ad_campaigns (status, starts_on, ends_on);

create trigger ad_campaigns_set_updated_at
  before update on ad_campaigns
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------------
-- Creatives
--
-- Approved one at a time, not per campaign. An advertiser who gets a campaign approved and then
-- swaps the artwork for something else is the oldest trick in this business.
-- ---------------------------------------------------------------------------

create table ad_creatives (
  id          uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references ad_campaigns (id) on delete cascade,

  headline    text not null check (length(btrim(headline)) between 2 and 60),
  body        text check (body is null or length(btrim(body)) <= 180),
  cta_label   text check (cta_label is null or length(btrim(cta_label)) <= 30),
  cta_url     text not null check (cta_url ~* '^https?://'),
  image_path  text,

  status      creative_status not null default 'pending',
  is_active   boolean not null default true,

  reviewed_by uuid references auth.users (id) on delete set null,
  reviewed_at timestamptz,
  review_note text,

  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index ad_creatives_campaign_idx on ad_creatives (campaign_id, status);

create trigger ad_creatives_set_updated_at
  before update on ad_creatives
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------------
-- Counting
--
-- One row per creative per surface per day. No user id, no session id, no IP, no user agent,
-- no referrer. There is nothing here to link to a person, which is why this system needs no
-- consent banner: the strongest privacy control available is not collecting, and that is the
-- one being used.
--
-- Deduplication and abuse control happen at /api/ads/event, which sees the IP and rate limits
-- on it without storing it -- the same shape as the photo upload signer.
-- ---------------------------------------------------------------------------

create table ad_daily_stats (
  creative_id uuid not null references ad_creatives (id) on delete cascade,
  surface     ad_surface not null,
  day         date not null,
  impressions integer not null default 0 check (impressions >= 0),
  clicks      integer not null default 0 check (clicks >= 0),
  primary key (creative_id, surface, day)
);

comment on table ad_daily_stats is
  'Counts only. Adding any column that could identify a person -- user id, session, IP, user '
  'agent -- breaks the privacy claim this system is built on, and breaks a test that checks '
  'for exactly that.';

-- ---------------------------------------------------------------------------
-- No table access for anybody.
-- ---------------------------------------------------------------------------

alter table businesses enable row level security;
alter table ad_campaigns enable row level security;
alter table ad_creatives enable row level security;
alter table ad_daily_stats enable row level security;

revoke all on businesses, ad_campaigns, ad_creatives, ad_daily_stats from anon, authenticated;

create or replace function app.owns_business(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  select exists (
    select 1 from public.businesses b
     where b.id = p_business_id
       and auth.uid() is not null
       and b.owner_user_id = auth.uid()
  );
$$;

-- ---------------------------------------------------------------------------
-- Where an ad may go.
--
-- Two checks in one place, so both the serving function and anything written later have a
-- single answer to ask.
-- ---------------------------------------------------------------------------

create or replace function app.ad_slot_allowed(p_surface ad_surface, p_slug text)
returns boolean
language sql
immutable
as $$
  select case
    -- Two of the six resource guides are emergency guidance: what to do when you are the one
    -- stuck, and how to run a recovery without hurting somebody. Selling space beside either is
    -- the thing the spec forbids, and it would be indefensible regardless.
    when p_surface = 'resources' and coalesce(p_slug, '') in ('stuck', 'safety') then false
    else true
  end;
$$;

-- ---------------------------------------------------------------------------
-- Serving
--
-- One function, called by every surface that may carry an ad. It returns the label in the same
-- row as the headline, so a component physically cannot render the ad without having been
-- handed the thing that says it is an ad.
--
-- Geographic targeting narrows only when the reader's location is known. A campaign targeted to
-- Bastrop County is still shown to a reader whose browser gave no position, because the
-- alternative is that "targeting" quietly means "almost nobody sees this" while the advertiser
-- is charged the same. The whole audience is two counties wide; this is not a land grab.
-- ---------------------------------------------------------------------------

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

  if p_lng is not null and p_lat is not null then
    v_here := extensions.st_setsrid(
                extensions.st_point(p_lng, p_lat), 4326)::extensions.geography;
  end if;

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
     and c.status = 'approved'
     and b.status = 'approved'
     and v_surface = any (c.surfaces)
     and c.starts_on <= current_date
     and (c.ends_on is null or c.ends_on >= current_date)
     and (
       -- Untargeted, or we do not know where the reader is, or they are inside the radius.
       c.target_center is null
       or v_here is null
       or extensions.st_dwithin(c.target_center, v_here, c.target_radius_miles * 1609.344)
     )
   -- Random rather than by price. With inventory this small, ordering by what somebody paid
   -- turns the one slot on the page into a permanent billboard for whoever bid most once.
   order by random()
   limit greatest(1, least(coalesce(p_limit, 1), 5))
  ) a;

  return jsonb_build_object('ok', true, 'ads', v_rows);
end;
$fn$;

-- Counting. Called only by the server route, which has the IP and rate limits on it.
create or replace function public.ad_record_event(
  p_creative_id uuid,
  p_surface     text,
  p_kind        text
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
begin
  begin
    v_surface := p_surface::ad_surface;
    v_kind := p_kind::ad_event_kind;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'bad_event');
  end;

  -- Only against a creative that is actually live. A stale id from a cached page does not get
  -- to inflate a number somebody is being billed against.
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

  insert into ad_daily_stats (creative_id, surface, day, impressions, clicks)
  values (
    p_creative_id, v_surface, current_date,
    case when v_kind = 'impression' then 1 else 0 end,
    case when v_kind = 'click' then 1 else 0 end
  )
  on conflict (creative_id, surface, day) do update
    set impressions = ad_daily_stats.impressions
                      + case when v_kind = 'impression' then 1 else 0 end,
        clicks = ad_daily_stats.clicks + case when v_kind = 'click' then 1 else 0 end;

  return jsonb_build_object('ok', true);
end;
$fn$;

-- ---------------------------------------------------------------------------
-- The advertiser's side
-- ---------------------------------------------------------------------------

create or replace function public.advertiser_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me uuid := auth.uid();
  v_rows jsonb;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.name), '[]'::jsonb) into v_rows
  from (
    select
      b.id, b.name, b.slug, b.category::text, b.description, b.website,
      b.contact_email, b.contact_phone, b.status::text, b.review_note,
      b.service_counties,
      coalesce((
        select jsonb_agg(to_jsonb(c) order by c.created_at desc)
        from (
          select
            ca.id, ca.name, ca.status::text, ca.review_note, ca.created_at,
            to_jsonb(ca.surfaces) as surfaces,
            ca.starts_on, ca.ends_on, ca.monthly_price_cents,
            ca.target_radius_miles,
            coalesce((
              select jsonb_agg(to_jsonb(cr) order by cr.created_at)
              from (
                select id, headline, body, cta_label, cta_url, image_path,
                       status::text, is_active, review_note, created_at
                  from ad_creatives where campaign_id = ca.id
              ) cr
            ), '[]'::jsonb) as creatives,
            -- Real numbers or zero. Never anything else: the spec says do not fabricate
            -- impressions, clicks or results, and a demo row that looks like traffic is that.
            coalesce((
              select sum(s.impressions) from ad_daily_stats s
                join ad_creatives k on k.id = s.creative_id
               where k.campaign_id = ca.id
            ), 0) as impressions,
            coalesce((
              select sum(s.clicks) from ad_daily_stats s
                join ad_creatives k on k.id = s.creative_id
               where k.campaign_id = ca.id
            ), 0) as clicks
          from ad_campaigns ca
         where ca.business_id = b.id
        ) c
      ), '[]'::jsonb) as campaigns
    from businesses b
   where b.owner_user_id = v_me
  ) x;

  return jsonb_build_object('ok', true, 'businesses', v_rows);
end;
$fn$;

create or replace function public.save_business(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me   uuid := auth.uid();
  v_id   uuid := nullif(p_payload ->> 'id', '')::uuid;
  v_slug text := lower(btrim(coalesce(p_payload ->> 'slug', '')));
  v_cat  business_category;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then
    return jsonb_build_object('ok', false, 'error', 'bad_slug');
  end if;

  begin
    v_cat := (p_payload ->> 'category')::business_category;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'bad_category');
  end;

  if v_id is null then
    if not app.check_rate_limit('business:' || v_me::text, 5, interval '24 hours') then
      return jsonb_build_object('ok', false, 'error', 'rate_limited');
    end if;

    insert into businesses (
      owner_user_id, name, slug, category, description, website,
      contact_email, contact_phone, service_counties
    ) values (
      v_me,
      btrim(coalesce(p_payload ->> 'name', '')),
      v_slug, v_cat,
      nullif(btrim(coalesce(p_payload ->> 'description', '')), ''),
      nullif(btrim(coalesce(p_payload ->> 'website', '')), ''),
      nullif(btrim(coalesce(p_payload ->> 'contact_email', '')), ''),
      nullif(btrim(coalesce(p_payload ->> 'contact_phone', '')), ''),
      coalesce((select array_agg(value) from jsonb_array_elements_text(
                  coalesce(p_payload -> 'service_counties', '[]'::jsonb))), '{}')
    )
    returning id into v_id;
  else
    if not app.owns_business(v_id) then
      return jsonb_build_object('ok', false, 'error', 'not_found');
    end if;

    -- Editing an approved business sends it back for review. Otherwise "approve the plumber,
    -- then rename it to a tow company" is a two-step way past the approval it just passed.
    update businesses set
      name = btrim(coalesce(p_payload ->> 'name', name)),
      slug = v_slug,
      category = v_cat,
      description = nullif(btrim(coalesce(p_payload ->> 'description', '')), ''),
      website = nullif(btrim(coalesce(p_payload ->> 'website', '')), ''),
      contact_email = nullif(btrim(coalesce(p_payload ->> 'contact_email', '')), ''),
      contact_phone = nullif(btrim(coalesce(p_payload ->> 'contact_phone', '')), ''),
      service_counties = coalesce((select array_agg(value) from jsonb_array_elements_text(
                           coalesce(p_payload -> 'service_counties', '[]'::jsonb))), '{}'),
      status = case when status in ('approved', 'rejected') then 'pending'::business_status
                    else status end,
      verification_note = case when status = 'approved' then null else verification_note end
    where id = v_id;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'slug_taken');
end;
$fn$;

create or replace function public.save_campaign(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_id       uuid := nullif(p_payload ->> 'id', '')::uuid;
  v_business uuid := nullif(p_payload ->> 'business_id', '')::uuid;
  v_surfaces ad_surface[];
  v_lng      double precision := nullif(p_payload ->> 'target_lng', '')::double precision;
  v_lat      double precision := nullif(p_payload ->> 'target_lat', '')::double precision;
  v_radius   integer := nullif(p_payload ->> 'target_radius_miles', '')::integer;
  v_center   extensions.geography;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  if v_id is not null then
    select business_id into v_business from ad_campaigns where id = v_id;
  end if;

  if v_business is null or not app.owns_business(v_business) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  begin
    select coalesce(array_agg(value::ad_surface), '{}'::ad_surface[]) into v_surfaces
      from jsonb_array_elements_text(coalesce(p_payload -> 'surfaces', '[]'::jsonb));
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'bad_surface');
  end;

  if array_length(v_surfaces, 1) is null then
    return jsonb_build_object('ok', false, 'error', 'no_surfaces');
  end if;

  if (v_lng is null) <> (v_lat is null) or (v_center is not null and v_radius is null) then
    return jsonb_build_object('ok', false, 'error', 'bad_targeting');
  end if;

  if v_lng is not null and v_lat is not null and v_radius is not null then
    v_center := extensions.st_setsrid(
                  extensions.st_point(v_lng, v_lat), 4326)::extensions.geography;
  else
    v_radius := null;
  end if;

  if v_id is null then
    insert into ad_campaigns (
      business_id, name, surfaces, target_center, target_radius_miles, target_counties,
      starts_on, ends_on, monthly_price_cents
    ) values (
      v_business,
      btrim(coalesce(p_payload ->> 'name', '')),
      v_surfaces, v_center, v_radius,
      coalesce((select array_agg(value) from jsonb_array_elements_text(
                  coalesce(p_payload -> 'target_counties', '[]'::jsonb))), '{}'),
      coalesce(nullif(p_payload ->> 'starts_on', '')::date, current_date),
      nullif(p_payload ->> 'ends_on', '')::date,
      coalesce(nullif(p_payload ->> 'monthly_price_cents', '')::integer, 0)
    )
    returning id into v_id;
  else
    update ad_campaigns set
      name = btrim(coalesce(p_payload ->> 'name', name)),
      surfaces = v_surfaces,
      target_center = v_center,
      target_radius_miles = v_radius,
      target_counties = coalesce((select array_agg(value) from jsonb_array_elements_text(
                          coalesce(p_payload -> 'target_counties', '[]'::jsonb))), '{}'),
      starts_on = coalesce(nullif(p_payload ->> 'starts_on', '')::date, starts_on),
      ends_on = nullif(p_payload ->> 'ends_on', '')::date,
      monthly_price_cents = coalesce(
        nullif(p_payload ->> 'monthly_price_cents', '')::integer, monthly_price_cents),
      -- Same reasoning as a business: changing where an approved campaign runs, or when, puts it
      -- back in front of a person.
      status = case when status in ('approved', 'rejected') then 'pending'::campaign_status
                    else status end
    where id = v_id;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$fn$;

create or replace function public.save_creative(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_id       uuid := nullif(p_payload ->> 'id', '')::uuid;
  v_campaign uuid := nullif(p_payload ->> 'campaign_id', '')::uuid;
  v_business uuid;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  if v_id is not null then
    select campaign_id into v_campaign from ad_creatives where id = v_id;
  end if;

  select business_id into v_business from ad_campaigns where id = v_campaign;

  if v_business is null or not app.owns_business(v_business) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if coalesce(p_payload ->> 'cta_url', '') !~* '^https?://' then
    return jsonb_build_object('ok', false, 'error', 'bad_url');
  end if;

  if v_id is null then
    insert into ad_creatives (campaign_id, headline, body, cta_label, cta_url, image_path)
    values (
      v_campaign,
      btrim(coalesce(p_payload ->> 'headline', '')),
      nullif(btrim(coalesce(p_payload ->> 'body', '')), ''),
      nullif(btrim(coalesce(p_payload ->> 'cta_label', '')), ''),
      btrim(p_payload ->> 'cta_url'),
      nullif(btrim(coalesce(p_payload ->> 'image_path', '')), '')
    )
    returning id into v_id;
  else
    -- Every edit goes back to pending. An advertiser who gets artwork approved and then swaps it
    -- is the oldest trick in this business, and the only defence is that approval attaches to
    -- the words, not to the row.
    update ad_creatives set
      headline = btrim(coalesce(p_payload ->> 'headline', headline)),
      body = nullif(btrim(coalesce(p_payload ->> 'body', '')), ''),
      cta_label = nullif(btrim(coalesce(p_payload ->> 'cta_label', '')), ''),
      cta_url = btrim(p_payload ->> 'cta_url'),
      image_path = nullif(btrim(coalesce(p_payload ->> 'image_path', '')), ''),
      status = 'pending',
      reviewed_by = null,
      reviewed_at = null
    where id = v_id;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$fn$;

create or replace function public.submit_for_review(p_kind text, p_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare v_hit integer;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  if p_kind = 'business' then
    update businesses set status = 'pending'
     where id = p_id and app.owns_business(id) and status in ('draft', 'rejected');
  elsif p_kind = 'campaign' then
    update ad_campaigns set status = 'pending'
     where id = p_id and status in ('draft', 'rejected')
       and app.owns_business(business_id);
  else
    return jsonb_build_object('ok', false, 'error', 'bad_kind');
  end if;

  get diagnostics v_hit = row_count;
  if v_hit = 0 then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object('ok', true);
end;
$fn$;

-- An advertiser may pause and resume their own campaign, and end it. They may not approve it.
create or replace function public.set_campaign_running(p_id uuid, p_running boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare v_hit integer;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  update ad_campaigns
     set status = case when p_running then 'approved'::campaign_status
                       else 'paused'::campaign_status end
   where id = p_id
     and app.owns_business(business_id)
     -- Only between these two. Resuming cannot be a way to approve something that never was.
     and status in ('approved', 'paused');

  get diagnostics v_hit = row_count;
  if v_hit = 0 then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object('ok', true);
end;
$fn$;

-- ---------------------------------------------------------------------------
-- Admin review
-- ---------------------------------------------------------------------------

create or replace function public.admin_ad_queue(p_status text default 'pending')
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_b jsonb; v_c jsonb; v_cr jsonb;
begin
  perform app.require_admin();

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at), '[]'::jsonb) into v_b
  from (
    select b.id, b.name, b.slug, b.category::text, b.description, b.website,
           b.contact_email, b.contact_phone, b.status::text, b.service_counties,
           b.verification_note, b.created_at,
           coalesce(pr.display_name, '') as owner_name
      from businesses b
      left join profiles pr on pr.user_id = b.owner_user_id
     where p_status is null or b.status = p_status::business_status
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at), '[]'::jsonb) into v_c
  from (
    select c.id, c.name, c.status::text, to_jsonb(c.surfaces) as surfaces,
           c.starts_on, c.ends_on, c.monthly_price_cents, c.created_at,
           b.name as business_name, b.category::text as business_category
      from ad_campaigns c
      join businesses b on b.id = c.business_id
     where p_status is null or c.status = p_status::campaign_status
  ) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at), '[]'::jsonb) into v_cr
  from (
    select cr.id, cr.headline, cr.body, cr.cta_label, cr.cta_url, cr.image_path,
           cr.status::text, cr.created_at,
           c.name as campaign_name, b.name as business_name,
           b.category::text as business_category
      from ad_creatives cr
      join ad_campaigns c on c.id = cr.campaign_id
      join businesses b on b.id = c.business_id
     where p_status is null or cr.status = p_status::creative_status
  ) x;

  return jsonb_build_object('ok', true, 'businesses', v_b, 'campaigns', v_c, 'creatives', v_cr);
end;
$fn$;

create or replace function public.admin_review_ad(
  p_kind   text,
  p_id     uuid,
  p_status text,
  p_note   text default null,
  p_verification_note text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_note  text := nullif(btrim(coalesce(p_note, '')), '');
  v_ver   text := nullif(btrim(coalesce(p_verification_note, '')), '');
  v_owner uuid;
  v_hit   integer;
begin
  perform app.require_admin();

  if p_kind = 'business' then
    if p_status = 'approved' and v_ver is null then
      -- The constraint would refuse this anyway. An admin who has just typed for two minutes
      -- deserves a sentence rather than a 23514.
      return jsonb_build_object('ok', false, 'error', 'verification_note_required');
    end if;

    update businesses
       set status = p_status::business_status,
           verification_note = coalesce(v_ver, verification_note),
           review_note = v_note,
           reviewed_by = auth.uid(),
           reviewed_at = now()
     where id = p_id
     returning owner_user_id into v_owner;

    get diagnostics v_hit = row_count;

    -- This is where `business_owner` finally means something. It has sat in app_role since
    -- Phase 3 doing nothing.
    if v_hit > 0 and p_status = 'approved' and v_owner is not null then
      insert into user_roles (user_id, role, granted_by)
      values (v_owner, 'business_owner', auth.uid())
      on conflict do nothing;
    end if;

  elsif p_kind = 'campaign' then
    update ad_campaigns
       set status = p_status::campaign_status,
           review_note = v_note, reviewed_by = auth.uid(), reviewed_at = now()
     where id = p_id;
    get diagnostics v_hit = row_count;

  elsif p_kind = 'creative' then
    update ad_creatives
       set status = p_status::creative_status,
           review_note = v_note, reviewed_by = auth.uid(), reviewed_at = now()
     where id = p_id;
    get diagnostics v_hit = row_count;

  else
    return jsonb_build_object('ok', false, 'error', 'bad_kind');
  end if;

  if v_hit = 0 then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  perform app.audit('ad.' || p_kind || '.' || p_status, p_kind, p_id::text,
                    jsonb_build_object('note', v_note));

  return jsonb_build_object('ok', true);
exception
  when invalid_text_representation then
    return jsonb_build_object('ok', false, 'error', 'bad_status');
end;
$fn$;

-- ---------------------------------------------------------------------------
-- Grants
--
-- ads_for is the only one anon may call, because the resources section is public and is the one
-- part of this app useful to somebody who has never signed in.
--
-- ad_record_event is granted to NOBODY here: it is called by the server route that holds the
-- service-role key and sees the IP it rate limits on.
-- ---------------------------------------------------------------------------

revoke all on function public.ads_for(text, text, double precision, double precision, integer)
  from public;
grant execute on function public.ads_for(text, text, double precision, double precision, integer)
  to anon, authenticated;

revoke all on function public.ad_record_event(uuid, text, text) from public, anon, authenticated;

do $grants$
declare fn text;
begin
  foreach fn in array array[
    'public.advertiser_overview()',
    'public.save_business(jsonb)',
    'public.save_campaign(jsonb)',
    'public.save_creative(jsonb)',
    'public.submit_for_review(text, uuid)',
    'public.set_campaign_running(uuid, boolean)',
    'public.admin_ad_queue(text)',
    'public.admin_review_ad(text, uuid, text, text, text)'
  ]
  loop
    execute format('revoke all on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated', fn);
  end loop;
end
$grants$;
