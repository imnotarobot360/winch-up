-- Winch Up :: one targeting model, shared by campaigns, events and announcements
--
-- Sections 2, 6, 10 and 11 of the owner's spec. The rules are the same whoever is being targeted --
-- all members, a state, a city, several cities, a ZIP, several ZIPs, or a radius around a point --
-- so there is ONE table and ONE matching function rather than three of each.
--
-- §10 is explicit: "Do not store comma-separated ZIP codes in one database field. Create structured
-- geographic targeting records." Hence a row per place rather than an array. It also makes the thing
-- the admin screen needs -- "how many members does this reach" -- a join instead of a string parse.
--
-- WHY A POLYMORPHIC TABLE RATHER THAN THREE.
--
-- campaign_target_locations, event_target_locations and advertisement_target_locations would be the
-- same six columns three times, and the matching rule would be written three times -- which is three
-- places for "did we remember ZIP codes are text, not integers" to be wrong. The spec names three
-- tables; it is asking for structured targeting, and one table with a `scope` discriminator delivers
-- that with one rule to get right. The audit doc records the departure.
--
-- TARGETS ARE ADDITIVE, AND THAT IS THE WHOLE SEMANTICS. A campaign with Houston and Katy and 77429
-- reaches a member in ANY of them. No rows at all means everybody -- which is "All Members" from the
-- spec's checkbox list, represented by absence rather than by a magic row, so nobody has to remember
-- to delete the magic row when they add a city.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. What a target can be
-- ---------------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_type where typname = 'target_kind') then
    create type target_kind as enum ('state', 'city', 'postal_code', 'radius');
  end if;

  if not exists (select 1 from pg_type where typname = 'target_scope') then
    -- What is being targeted. Announcements arrive in a later migration and are listed now so the
    -- enum does not need extending then -- a new label cannot be USED in the transaction that adds
    -- it, and that trap has already cost a split migration once this week.
    create type target_scope as enum ('campaign', 'event', 'announcement');
  end if;
end
$$;

create table if not exists public.target_locations (
  id          uuid primary key default gen_random_uuid(),

  scope       target_scope not null,
  -- Deliberately NOT a foreign key. One table serves three parents, so a real FK is impossible
  -- without three nullable columns and a check that exactly one is set. The orphan risk is handled
  -- by the delete triggers at the bottom, which is the honest trade and is written down rather than
  -- discovered.
  target_id   uuid not null,

  kind        target_kind not null,

  -- Exactly one of these is meaningful, per kind. The CHECK below is what makes that true rather
  -- than conventional.
  state       text,
  city        text,
  postal_code text,
  center      extensions.geography(Point, 4326),
  radius_miles integer,

  created_at  timestamptz not null default now(),

  constraint target_locations_shape check (
    case kind
      when 'state'       then state is not null and city is null and postal_code is null
                              and center is null and radius_miles is null
      when 'city'        then city is not null and state is not null and postal_code is null
                              and center is null and radius_miles is null
      when 'postal_code' then postal_code is not null and center is null and radius_miles is null
      when 'radius'      then center is not null and radius_miles is not null
                              and state is null and city is null and postal_code is null
    end
  ),

  -- Same formats as profiles, or a target can be written that no member can ever match.
  constraint target_locations_state_format
    check (state is null or state ~ '^[A-Z]{2}$'),
  constraint target_locations_postal_format
    check (postal_code is null or postal_code ~ '^[0-9]{5}$'),
  -- A radius of zero matches nobody and a radius of a thousand miles is not targeting.
  constraint target_locations_radius_sane
    check (radius_miles is null or radius_miles between 1 and 500)
);

-- A CITY IS MATCHED CASE-INSENSITIVELY AND WITH ITS STATE. "houston" and "Houston" are one place,
-- and Houston TX is not Houston MO -- which is why the shape check above requires a state alongside
-- a city rather than letting a bare city name mean four different towns.
create index if not exists target_locations_parent_idx
  on public.target_locations (scope, target_id);

create unique index if not exists target_locations_no_duplicates
  on public.target_locations (scope, target_id, kind,
                              coalesce(state, ''), lower(coalesce(city, '')),
                              coalesce(postal_code, ''));

create index if not exists target_locations_center_idx
  on public.target_locations using gist (center)
  where center is not null;

alter table public.target_locations enable row level security;
revoke all on public.target_locations from anon, authenticated;

comment on table public.target_locations is
  'Geographic targeting rows for campaigns, events and announcements. Additive: a member matching '
  'ANY row is in the audience, and no rows at all means everybody. No table access -- read through '
  'app.member_matches_target() and the admin RPCs.';

-- ---------------------------------------------------------------------------
-- 2. The matching rule, written once
-- ---------------------------------------------------------------------------
--
-- Takes the member's STATED location, never the recovery one. The arguments are the member's own
-- fields rather than a user id on purpose: a function that took a uuid could reach for
-- responders.home_location, and §7 says that must never happen for advertising. Passing the three
-- values in makes the boundary visible at every call site.

create or replace function app.member_matches_target(
  p_scope         target_scope,
  p_target_id     uuid,
  p_state         text,
  p_city          text,
  p_postal_code   text,
  p_postal_center extensions.geography
)
returns boolean
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
  select
    -- NO ROWS MEANS EVERYBODY. "All Members" is the absence of targeting rather than a special row,
    -- so adding a city to an all-members campaign cannot leave a stale "everyone" rule behind it.
    not exists (
      select 1 from public.target_locations t
       where t.scope = p_scope and t.target_id = p_target_id
    )
    or exists (
      select 1
        from public.target_locations t
       where t.scope = p_scope
         and t.target_id = p_target_id
         and (
              (t.kind = 'state'
               and p_state is not null
               and t.state = p_state)

           or (t.kind = 'city'
               and p_city is not null and p_state is not null
               and lower(t.city) = lower(p_city)
               and t.state = p_state)

           or (t.kind = 'postal_code'
               and p_postal_code is not null
               and t.postal_code = p_postal_code)

              -- Measured from the centroid of the member's stated postal code. A member who has not
              -- said where they are has no centroid and matches no radius -- which is the point:
              -- "we do not know" is not "show it to them".
           or (t.kind = 'radius'
               and p_postal_center is not null
               and extensions.st_dwithin(
                     p_postal_center, t.center,
                     app.miles_to_meters(t.radius_miles)))
         )
    );
$fn$;

revoke all on function app.member_matches_target(
  target_scope, uuid, text, text, text, extensions.geography)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. How many members does this reach?
-- ---------------------------------------------------------------------------
--
-- Section 14's "Estimated Audience: XXX members", and the number an admin needs BEFORE publishing.
-- Suspended and deleted members are excluded, because an audience estimate that counts people who
-- cannot see anything is a lie that makes a campaign look better than it is.

create or replace function app.target_audience_count(p_scope target_scope, p_target_id uuid)
returns integer
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
  select count(*)::integer
    from public.profiles p
    left join public.responders r on r.user_id = p.user_id
   where p.suspended_at is null
     and r.redacted_at is null
     and app.member_matches_target(p_scope, p_target_id, p.state, p.city,
                                   p.postal_code, p.postal_center);
$fn$;

revoke all on function app.target_audience_count(target_scope, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Orphans
-- ---------------------------------------------------------------------------
--
-- The price of one polymorphic table is no foreign key, so deletes are swept by hand. A trigger per
-- parent rather than a periodic job: targeting rows left behind after a campaign is deleted would be
-- invisible, would be counted by nothing, and would come back to life the day a new campaign was
-- issued the same uuid. Vanishingly unlikely, and trivial to prevent.

create or replace function app.sweep_target_locations()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $fn$
begin
  delete from public.target_locations
   where scope = tg_argv[0]::target_scope and target_id = old.id;
  return old;
end;
$fn$;

drop trigger if exists ad_campaigns_sweep_targets on public.ad_campaigns;
create trigger ad_campaigns_sweep_targets
  after delete on public.ad_campaigns
  for each row execute function app.sweep_target_locations('campaign');

drop trigger if exists events_sweep_targets on public.events;
create trigger events_sweep_targets
  after delete on public.events
  for each row execute function app.sweep_target_locations('event');

notify pgrst, 'reload schema';
