-- Winch Up :: trails
--
-- Phase 9, first half. A trail directory, condition reports, saved trails, and the route for a
-- member to submit a trail or tell us something on a listing is wrong.
--
-- The whole design turns on one line of the spec:
--
--   "Do not assume that a trail is open or legally accessible without reliable supporting
--    information."
--
-- That is not a disclaimer to paste at the bottom of a page. It is a schema constraint. A row
-- cannot claim an access status without naming where that claim came from
-- (trails_access_needs_a_source), and it cannot be published without a named human having
-- verified it (trails_published_is_verified). A listing that says "Open — public land" and is
-- wrong does not cost us a support ticket; it costs somebody a trespassing charge, or a locked
-- gate forty miles down a caliche road at dusk.
--
-- Two further consequences:
--
-- 1. THE DIRECTORY SHIPS EMPTY. There is no seed. I am not going to write access statuses for
--    real Texas trails out of a model's memory and mark them verified -- that is precisely the
--    thing the constraint exists to prevent. Admins add trails, citing a source, and the empty
--    state says so.
--
-- 2. VERIFIED AND USER-SUBMITTED ARE DIFFERENT TABLES, not a flag. `trails` is what an admin
--    checked. `trail_conditions` is what a member saw last Saturday. They can never be rendered
--    as the same kind of statement, because they cannot be joined into one row by accident.
--
-- Members-only, like the community feed and unlike /board. A public page asserting that a
-- named place is open to drive on is a publisher's liability; behind an account, shown with its
-- source and its date, it is a community reference. `robots: noindex` on the routes as well.

set search_path = public, extensions;

create type trail_status as enum ('pending', 'published', 'archived');

-- Deliberately has no value meaning "open, we're sure". `open_public` still requires a source.
create type trail_access as enum (
  'unknown',             -- the default, and the only one needing no source
  'open_public',         -- public land, open to vehicles
  'permit_required',     -- a park, a lease, a day pass
  'private_permission',  -- private land; you need the owner's word, every time
  'closed'
);

create type trail_difficulty as enum ('easy', 'moderate', 'difficult', 'extreme');

create type trail_condition_state as enum (
  'good',
  'wet',
  'muddy',
  'flooded',
  'impassable',
  'access_blocked'       -- gate locked, road closed, new fence
);

create type trail_edit_kind as enum ('new', 'correction', 'problem');

-- ---------------------------------------------------------------------------
-- The verified record
-- ---------------------------------------------------------------------------

create table trails (
  id            uuid primary key default gen_random_uuid(),
  slug          text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name          text not null check (length(btrim(name)) between 2 and 120),
  region        text check (region is null or length(btrim(region)) <= 120),

  location      extensions.geography(point, 4326) not null,

  status        trail_status not null default 'pending',

  -- Access, and where the claim came from.
  access            trail_access not null default 'unknown',
  access_source     text,
  access_checked_at timestamptz,

  -- Difficulty is somebody's opinion. Whose, then.
  difficulty        trail_difficulty,
  difficulty_source text,

  summary       text check (summary is null or length(btrim(summary)) <= 300),
  description   text check (description is null or length(btrim(description)) <= 4000),

  -- What to bring. Reuses the same vocabulary as matching, so "needs a winch" means the same
  -- thing on a trail page as it does on a recovery request.
  min_drivetrain        drivetrain not null default 'unknown',
  recommended_equipment equipment_type[] not null default '{}',

  created_by   uuid references auth.users (id) on delete set null,
  verified_by  uuid references auth.users (id) on delete set null,
  verified_at  timestamptz,

  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),

  -- The two that matter.
  constraint trails_access_needs_a_source check (
    access = 'unknown'
    or (access_source is not null and length(btrim(access_source)) > 0)
  ),
  constraint trails_published_is_verified check (
    status <> 'published'
    or (verified_by is not null and verified_at is not null)
  ),
  constraint trails_difficulty_needs_a_source check (
    difficulty is null
    or (difficulty_source is not null and length(btrim(difficulty_source)) > 0)
  )
);

comment on column trails.access_source is
  'Where the access claim came from, in words a person can check: "TPWD land use map, '
  'retrieved 2026-09-22", "park website", "owner gave permission by phone". Required for any '
  'access value other than unknown, and shown to members beside the status.';

create index trails_published_idx on trails (status, name) where status = 'published';
create index trails_location_idx on trails using gist (location);

create trigger trails_set_updated_at
  before update on trails
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------------
-- What members saw
-- ---------------------------------------------------------------------------

create table trail_conditions (
  id             uuid primary key default gen_random_uuid(),
  trail_id       uuid not null references trails (id) on delete cascade,
  author_user_id uuid references auth.users (id) on delete set null,

  state          trail_condition_state not null,
  note           text check (
                   note is null
                   or (length(btrim(note)) between 1 and 500
                       and not public.contains_contact_info(note))
                 ),

  -- Same vocabulary as the community feed, so a moderator hides a bad condition report with the
  -- control they already know.
  status         content_status not null default 'visible',
  moderated_by   uuid references auth.users (id) on delete set null,
  moderated_at   timestamptz,

  created_at     timestamptz not null default now()
);

create index trail_conditions_recent_idx
  on trail_conditions (trail_id, created_at desc)
  where status = 'visible';

comment on table trail_conditions is
  'User-submitted. Never presented as verified, always shown with its date -- a report from '
  'March is not information in September, and the UI ages them out rather than letting an old '
  'one read as current.';

-- ---------------------------------------------------------------------------
-- Saved trails
-- ---------------------------------------------------------------------------

create table trail_saves (
  user_id    uuid not null references auth.users (id) on delete cascade,
  trail_id   uuid not null references trails (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, trail_id)
);

-- ---------------------------------------------------------------------------
-- What members want changed
--
-- Three things arrive through one door: a trail we do not have, a correction to one we do, and
-- "this listing is wrong in a way that matters". They are one table because they are one queue
-- and one decision, and because a member reporting a locked gate should not have to work out
-- which of three forms they want.
-- ---------------------------------------------------------------------------

create table trail_edits (
  id             uuid primary key default gen_random_uuid(),
  kind           trail_edit_kind not null,
  trail_id       uuid references trails (id) on delete cascade,
  author_user_id uuid references auth.users (id) on delete set null,

  -- Only for kind = 'new'.
  name           text check (name is null or length(btrim(name)) between 2 and 120),
  region         text check (region is null or length(btrim(region)) <= 120),
  location       extensions.geography(point, 4326),

  body           text not null check (
                   length(btrim(body)) between 1 and 2000
                   and not public.contains_contact_info(body)
                 ),

  status         incident_status not null default 'new',
  reviewed_by    uuid references auth.users (id) on delete set null,
  reviewed_at    timestamptz,
  admin_notes    text check (admin_notes is null or length(admin_notes) <= 2000),

  created_at     timestamptz not null default now(),

  constraint trail_edits_points_somewhere check (kind = 'new' or trail_id is not null),
  constraint trail_edits_new_has_a_place check (
    kind <> 'new' or (name is not null and location is not null)
  )
);

create index trail_edits_triage_idx on trail_edits (status, created_at desc);

-- ---------------------------------------------------------------------------
-- Nothing is reachable directly.
-- ---------------------------------------------------------------------------

alter table trails enable row level security;
alter table trail_conditions enable row level security;
alter table trail_saves enable row level security;
alter table trail_edits enable row level security;

revoke all on trails, trail_conditions, trail_saves, trail_edits from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Reading
--
-- Published trails only. A pending row is somebody's suggestion, not a place we are telling
-- people to drive to, and it must never appear in a search result.
-- ---------------------------------------------------------------------------

create or replace function public.trails_search(
  p_query      text default null,
  p_access     text default null,
  p_difficulty text default null,
  p_saved_only boolean default false,
  p_near_lng   double precision default null,
  p_near_lat   double precision default null,
  p_limit      integer default 30
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me   uuid := auth.uid();
  v_q    text := nullif(btrim(coalesce(p_query, '')), '');
  v_near extensions.geography;
  v_rows jsonb;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  if p_near_lng is not null and p_near_lat is not null then
    v_near := extensions.st_setsrid(
                extensions.st_point(p_near_lng, p_near_lat), 4326)::extensions.geography;
  end if;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.sort_distance nulls last, r.name), '[]'::jsonb)
    into v_rows
  from (
    select
      t.id,
      t.slug,
      t.name,
      t.region,
      t.access::text,
      t.access_source,
      t.difficulty::text,
      t.summary,
      t.min_drivetrain::text,
      exists (select 1 from trail_saves s where s.trail_id = t.id and s.user_id = v_me) as saved,
      case when v_near is null then null
           else round((extensions.st_distance(t.location, v_near) / 1609.344)::numeric, 1)
      end as distance_miles,
      case when v_near is null then null
           else extensions.st_distance(t.location, v_near) end as sort_distance,
      -- The most recent thing a member said about it, so a search result can carry "flooded,
      -- two days ago" rather than looking evergreen.
      (select jsonb_build_object('state', c.state::text, 'at', c.created_at)
         from trail_conditions c
        where c.trail_id = t.id and c.status = 'visible'
        order by c.created_at desc limit 1) as latest_condition
    from trails t
   where t.status = 'published'
     and (v_q is null or t.name ilike '%' || v_q || '%' or coalesce(t.region, '') ilike '%' || v_q || '%')
     and (p_access is null or t.access = p_access::trail_access)
     and (p_difficulty is null or t.difficulty = p_difficulty::trail_difficulty)
     and (not coalesce(p_saved_only, false)
          or exists (select 1 from trail_saves s where s.trail_id = t.id and s.user_id = v_me))
   limit greatest(1, least(coalesce(p_limit, 30), 100))
  ) r;

  return jsonb_build_object('ok', true, 'trails', v_rows);
end;
$fn$;

create or replace function public.trail_detail(p_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me        uuid := auth.uid();
  v_trail     trails%rowtype;
  v_window    interval := interval '45 days';
  v_conditions jsonb;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  select * into v_trail from trails where slug = p_slug and status = 'published';

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  -- Forty-five days, and every one of them stamped. An old report is not current information,
  -- and a page that quietly shows one from March in September is worse than showing nothing --
  -- somebody packs for the trail it described.
  select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at desc), '[]'::jsonb) into v_conditions
  from (
    select cond.id,
           cond.state::text,
           cond.note,
           cond.created_at,
           (cond.author_user_id = v_me) as mine,
           coalesce(pr.display_name, '') as author_name
      from trail_conditions cond
      left join profiles pr on pr.user_id = cond.author_user_id
     where cond.trail_id = v_trail.id
       and cond.status = 'visible'
       and cond.created_at > now() - v_window
       -- Blocking carries over from the feed: somebody you blocked does not get to talk to you
       -- on a trail page either.
       and not app.blocks_between(v_me, cond.author_user_id)
     order by cond.created_at desc
     limit 50
  ) c;

  return jsonb_build_object(
    'ok', true,
    'trail', jsonb_build_object(
      'id', v_trail.id,
      'slug', v_trail.slug,
      'name', v_trail.name,
      'region', v_trail.region,
      'lng', extensions.st_x(v_trail.location::extensions.geometry),
      'lat', extensions.st_y(v_trail.location::extensions.geometry),
      'access', v_trail.access::text,
      'access_source', v_trail.access_source,
      'access_checked_at', v_trail.access_checked_at,
      'difficulty', v_trail.difficulty::text,
      'difficulty_source', v_trail.difficulty_source,
      'summary', v_trail.summary,
      'description', v_trail.description,
      'min_drivetrain', v_trail.min_drivetrain::text,
      'recommended_equipment', to_jsonb(v_trail.recommended_equipment),
      'verified_at', v_trail.verified_at,
      'saved', exists (select 1 from trail_saves s
                        where s.trail_id = v_trail.id and s.user_id = v_me)
    ),
    'conditions', v_conditions,
    'condition_window_days', 45
  );
end;
$fn$;

-- ---------------------------------------------------------------------------
-- Member actions
-- ---------------------------------------------------------------------------

create or replace function public.trail_save(p_trail_id uuid, p_on boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  if not exists (select 1 from trails where id = p_trail_id and status = 'published') then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if p_on then
    insert into trail_saves (user_id, trail_id) values (v_me, p_trail_id)
    on conflict do nothing;
  else
    delete from trail_saves where user_id = v_me and trail_id = p_trail_id;
  end if;

  return jsonb_build_object('ok', true);
end;
$fn$;

create or replace function public.report_trail_condition(
  p_trail_id uuid,
  p_state    text,
  p_note     text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me    uuid := auth.uid();
  v_state trail_condition_state;
  v_note  text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  if not exists (select 1 from trails where id = p_trail_id and status = 'published') then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  begin
    v_state := p_state::trail_condition_state;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'bad_state');
  end;

  if v_note is not null and length(v_note) > 500 then
    return jsonb_build_object('ok', false, 'error', 'too_long');
  end if;

  if v_note is not null and public.contains_contact_info(v_note) then
    return jsonb_build_object('ok', false, 'error', 'contact_info');
  end if;

  -- One trail, once an hour. Somebody driving the same loop twice in a day is welcome to report
  -- twice; somebody filling a page with reports is not.
  if not app.check_rate_limit(
       'trail_condition:' || v_me::text || ':' || p_trail_id::text, 1, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'already_reported');
  end if;

  insert into trail_conditions (trail_id, author_user_id, state, note)
  values (p_trail_id, v_me, v_state, v_note);

  return jsonb_build_object('ok', true);
end;
$fn$;

create or replace function public.submit_trail_edit(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me       uuid := auth.uid();
  v_kind     trail_edit_kind;
  v_trail_id uuid := nullif(p_payload ->> 'trail_id', '')::uuid;
  v_body     text := nullif(btrim(coalesce(p_payload ->> 'body', '')), '');
  v_name     text := nullif(btrim(coalesce(p_payload ->> 'name', '')), '');
  v_region   text := nullif(btrim(coalesce(p_payload ->> 'region', '')), '');
  v_lng      double precision := nullif(p_payload ->> 'lng', '')::double precision;
  v_lat      double precision := nullif(p_payload ->> 'lat', '')::double precision;
  v_location extensions.geography;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  begin
    v_kind := (p_payload ->> 'kind')::trail_edit_kind;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'bad_kind');
  end;

  if v_body is null or length(v_body) > 2000 then
    return jsonb_build_object('ok', false, 'error', 'bad_length');
  end if;

  if public.contains_contact_info(v_body) then
    return jsonb_build_object('ok', false, 'error', 'contact_info');
  end if;

  if v_kind = 'new' then
    if v_name is null or v_lng is null or v_lat is null then
      return jsonb_build_object('ok', false, 'error', 'incomplete');
    end if;
    v_location := extensions.st_setsrid(
                    extensions.st_point(v_lng, v_lat), 4326)::extensions.geography;
    v_trail_id := null;
  else
    if v_trail_id is null
       or not exists (select 1 from trails where id = v_trail_id and status = 'published') then
      return jsonb_build_object('ok', false, 'error', 'not_found');
    end if;
    v_name := null;
    v_region := null;
    v_location := null;
  end if;

  if not app.check_rate_limit('trail_edit:' || v_me::text, 10, interval '24 hours') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  insert into trail_edits (kind, trail_id, author_user_id, name, region, location, body)
  values (v_kind, v_trail_id, v_me, v_name, v_region, v_location, v_body);

  return jsonb_build_object('ok', true);
end;
$fn$;

-- ---------------------------------------------------------------------------
-- Admin
--
-- Adding and publishing trails is admin work, not moderator work. A moderator can hide a bad
-- condition report; asserting that a named place is legal to drive on is a different kind of
-- claim and belongs with the people who answer for it.
-- ---------------------------------------------------------------------------

create or replace function public.admin_trails(p_status text default null)
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

  select coalesce(jsonb_agg(to_jsonb(r) order by r.name), '[]'::jsonb) into v_rows
  from (
    select t.id, t.slug, t.name, t.region, t.status::text,
           t.access::text, t.access_source, t.access_checked_at,
           t.difficulty::text, t.difficulty_source, t.summary, t.description,
           t.min_drivetrain::text, to_jsonb(t.recommended_equipment) as recommended_equipment,
           extensions.st_x(t.location::extensions.geometry) as lng,
           extensions.st_y(t.location::extensions.geometry) as lat,
           t.verified_at, t.created_at,
           (select count(*) from trail_conditions c
             where c.trail_id = t.id and c.status = 'visible') as condition_count
      from trails t
     where p_status is null or t.status = p_status::trail_status
     order by t.name
     limit 500
  ) r;

  return jsonb_build_object('ok', true, 'trails', v_rows);
end;
$fn$;

create or replace function public.admin_save_trail(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_id       uuid := nullif(p_payload ->> 'id', '')::uuid;
  v_slug     text := lower(btrim(coalesce(p_payload ->> 'slug', '')));
  v_name     text := btrim(coalesce(p_payload ->> 'name', ''));
  v_access   trail_access;
  v_source   text := nullif(btrim(coalesce(p_payload ->> 'access_source', '')), '');
  v_diff     trail_difficulty;
  v_diffsrc  text := nullif(btrim(coalesce(p_payload ->> 'difficulty_source', '')), '');
  v_status   trail_status;
  v_lng      double precision := nullif(p_payload ->> 'lng', '')::double precision;
  v_lat      double precision := nullif(p_payload ->> 'lat', '')::double precision;
  v_location extensions.geography;
  v_equip    equipment_type[];
begin
  perform app.require_admin();

  if length(v_name) < 2 then
    return jsonb_build_object('ok', false, 'error', 'name_required');
  end if;

  if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then
    return jsonb_build_object('ok', false, 'error', 'bad_slug');
  end if;

  begin
    v_access := coalesce(nullif(p_payload ->> 'access', ''), 'unknown')::trail_access;
    v_diff   := nullif(p_payload ->> 'difficulty', '')::trail_difficulty;
    v_status := coalesce(nullif(p_payload ->> 'status', ''), 'pending')::trail_status;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'bad_enum');
  end;

  -- The constraint would catch this, but a 23514 is not something to show a person who just
  -- filled in a form.
  if v_access <> 'unknown' and v_source is null then
    return jsonb_build_object('ok', false, 'error', 'access_source_required');
  end if;

  if v_diff is not null and v_diffsrc is null then
    return jsonb_build_object('ok', false, 'error', 'difficulty_source_required');
  end if;

  if v_lng is null or v_lat is null then
    return jsonb_build_object('ok', false, 'error', 'location_required');
  end if;

  v_location := extensions.st_setsrid(
                  extensions.st_point(v_lng, v_lat), 4326)::extensions.geography;

  select coalesce(array_agg(e::equipment_type), '{}'::equipment_type[]) into v_equip
  from jsonb_array_elements_text(coalesce(p_payload -> 'recommended_equipment', '[]'::jsonb)) e;

  if v_id is null then
    insert into trails (
      slug, name, region, location, status, access, access_source, access_checked_at,
      difficulty, difficulty_source, summary, description, min_drivetrain,
      recommended_equipment, created_by,
      verified_by, verified_at
    ) values (
      v_slug, v_name, nullif(btrim(coalesce(p_payload ->> 'region', '')), ''), v_location,
      v_status, v_access, v_source,
      case when v_access = 'unknown' then null else now() end,
      v_diff, v_diffsrc,
      nullif(btrim(coalesce(p_payload ->> 'summary', '')), ''),
      nullif(btrim(coalesce(p_payload ->> 'description', '')), ''),
      coalesce(nullif(p_payload ->> 'min_drivetrain', ''), 'unknown')::drivetrain,
      v_equip, auth.uid(),
      case when v_status = 'published' then auth.uid() end,
      case when v_status = 'published' then now() end
    )
    returning id into v_id;
  else
    update trails set
      slug = v_slug,
      name = v_name,
      region = nullif(btrim(coalesce(p_payload ->> 'region', '')), ''),
      location = v_location,
      status = v_status,
      access = v_access,
      access_source = v_source,
      access_checked_at = case when v_access = 'unknown' then null
                               when access is distinct from v_access
                                 or access_source is distinct from v_source then now()
                               else coalesce(access_checked_at, now()) end,
      difficulty = v_diff,
      difficulty_source = v_diffsrc,
      summary = nullif(btrim(coalesce(p_payload ->> 'summary', '')), ''),
      description = nullif(btrim(coalesce(p_payload ->> 'description', '')), ''),
      min_drivetrain = coalesce(nullif(p_payload ->> 'min_drivetrain', ''), 'unknown')::drivetrain,
      recommended_equipment = v_equip,
      -- Publishing records who said so. Un-publishing leaves the record of who last did.
      verified_by = case when v_status = 'published' then auth.uid() else verified_by end,
      verified_at = case when v_status = 'published' then coalesce(verified_at, now())
                         else verified_at end
    where id = v_id;

    if not found then
      return jsonb_build_object('ok', false, 'error', 'not_found');
    end if;
  end if;

  perform app.audit('trail.save', 'trail', v_id::text,
                    jsonb_build_object('slug', v_slug, 'status', v_status, 'access', v_access));

  return jsonb_build_object('ok', true, 'id', v_id);
exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'slug_taken');
end;
$fn$;

create or replace function public.admin_trail_edits(p_status text default 'new')
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

  select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb) into v_rows
  from (
    select e.id, e.kind::text, e.body, e.name, e.region, e.status::text, e.admin_notes,
           e.created_at, e.reviewed_at,
           t.slug as trail_slug, t.name as trail_name,
           case when e.location is null then null
                else extensions.st_x(e.location::extensions.geometry) end as lng,
           case when e.location is null then null
                else extensions.st_y(e.location::extensions.geometry) end as lat,
           coalesce(pr.display_name, '') as author_name
      from trail_edits e
      left join trails t on t.id = e.trail_id
      left join profiles pr on pr.user_id = e.author_user_id
     where p_status is null or e.status = p_status::incident_status
     order by e.created_at desc
     limit 200
  ) r;

  return jsonb_build_object('ok', true, 'edits', v_rows);
end;
$fn$;

create or replace function public.admin_review_trail_edit(
  p_id     uuid,
  p_status text,
  p_notes  text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_status incident_status;
begin
  perform app.require_admin();

  begin
    v_status := p_status::incident_status;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'bad_status');
  end;

  update trail_edits
     set status = v_status,
         reviewed_by = auth.uid(),
         reviewed_at = now(),
         admin_notes = coalesce(nullif(btrim(coalesce(p_notes, '')), ''), admin_notes)
   where id = p_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  perform app.audit('trail_edit.review', 'trail_edit', p_id::text,
                    jsonb_build_object('status', v_status));

  return jsonb_build_object('ok', true);
end;
$fn$;

-- ---------------------------------------------------------------------------
-- Moderation, extended to cover condition reports
--
-- A condition report is user-submitted free text on a page other members act on, which is the
-- same shape of problem as a comment. It goes to the same queue and the same two buttons rather
-- than growing a second moderation surface nobody checks.
-- ---------------------------------------------------------------------------

do $$
declare c text;
begin
  select conname into c
    from pg_constraint
   where conrelid = 'public.content_reports'::regclass
     and contype = 'c'
     and pg_get_constraintdef(oid) like '%target_kind%';

  if c is not null then
    execute format('alter table content_reports drop constraint %I', c);
  end if;
end
$$;

alter table content_reports
  add constraint content_reports_target_kind_check
  check (target_kind in ('post', 'comment', 'trail_condition'));

create or replace function public.community_report(
  p_kind   text,
  p_id     uuid,
  p_reason text,
  p_note   text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me uuid := auth.uid();
  v_reason report_reason;
  v_exists boolean;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  if p_kind = 'post' then
    select exists (select 1 from community_posts where id = p_id) into v_exists;
  elsif p_kind = 'comment' then
    select exists (select 1 from community_comments where id = p_id) into v_exists;
  elsif p_kind = 'trail_condition' then
    select exists (select 1 from trail_conditions where id = p_id) into v_exists;
  else
    return jsonb_build_object('ok', false, 'error', 'bad_kind');
  end if;

  if not v_exists then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  begin
    v_reason := p_reason::report_reason;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'bad_reason');
  end;

  if not app.check_rate_limit('content_report:' || v_me::text, 20, interval '24 hours') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  insert into content_reports (target_kind, target_id, reporter_user_id, reason, note)
  values (p_kind, p_id, v_me, v_reason, nullif(btrim(coalesce(p_note, '')), ''))
  on conflict (target_kind, target_id, reporter_user_id) do nothing;

  return jsonb_build_object('ok', true);
end;
$fn$;

create or replace function public.moderation_queue(p_status text default 'new')
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_rows jsonb;
begin
  if not app.is_moderator() then
    raise exception 'forbidden' using errcode = 'insufficient_privilege';
  end if;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.report_count desc, r.created_at desc),
                  '[]'::jsonb) into v_rows
  from (
    select cr.target_kind,
           cr.target_id,
           min(cr.created_at) as created_at,
           count(*) as report_count,
           array_agg(distinct cr.reason::text) as reasons,
           max(cr.note) filter (where cr.note is not null) as note,
           coalesce(p.body, c.body, tc.note, '') as content,
           coalesce(p.status, c.status, tc.status)::text as content_status,
           coalesce(pp.display_name, cp.display_name, tp.display_name, '') as author_name,
           -- Only a condition report has one; it tells the moderator which page the thing is on.
           t.name as trail_name
      from content_reports cr
      left join community_posts p on cr.target_kind = 'post' and p.id = cr.target_id
      left join community_comments c on cr.target_kind = 'comment' and c.id = cr.target_id
      left join trail_conditions tc on cr.target_kind = 'trail_condition' and tc.id = cr.target_id
      left join trails t on t.id = tc.trail_id
      left join profiles pp on pp.user_id = p.author_user_id
      left join profiles cp on cp.user_id = c.author_user_id
      left join profiles tp on tp.user_id = tc.author_user_id
     where p_status is null or cr.status = p_status::incident_status
     group by cr.target_kind, cr.target_id, p.body, c.body, tc.note,
              p.status, c.status, tc.status,
              pp.display_name, cp.display_name, tp.display_name, t.name
     order by count(*) desc, min(cr.created_at) desc
     limit 100
  ) r;

  return jsonb_build_object('ok', true, 'items', v_rows);
end;
$fn$;

create or replace function public.moderate_content(
  p_kind   text,
  p_id     uuid,
  p_action text,
  p_note   text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_status content_status;
  v_hit integer;
begin
  if not app.is_moderator() then
    raise exception 'forbidden' using errcode = 'insufficient_privilege';
  end if;

  v_status := case p_action
                when 'hide'    then 'hidden'::content_status
                when 'restore' then 'visible'::content_status
                else null
              end;

  if v_status is null then
    return jsonb_build_object('ok', false, 'error', 'bad_action');
  end if;

  if p_kind = 'post' then
    update community_posts
       set status = v_status,
           moderated_by = auth.uid(),
           moderated_at = now(),
           moderation_note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), moderation_note)
     where id = p_id;
  elsif p_kind = 'comment' then
    update community_comments
       set status = v_status, moderated_by = auth.uid(), moderated_at = now()
     where id = p_id;
  elsif p_kind = 'trail_condition' then
    update trail_conditions
       set status = v_status, moderated_by = auth.uid(), moderated_at = now()
     where id = p_id;
  else
    return jsonb_build_object('ok', false, 'error', 'bad_kind');
  end if;

  get diagnostics v_hit = row_count;

  if v_hit = 0 then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  update content_reports
     set status = 'actioned', reviewed_by = auth.uid(), reviewed_at = now()
   where target_kind = p_kind and target_id = p_id and status <> 'actioned';

  perform app.audit('content.' || p_action, p_kind, p_id::text,
                    jsonb_build_object('note', nullif(btrim(coalesce(p_note, '')), '')));

  return jsonb_build_object('ok', true);
end;
$fn$;

create or replace function public.moderation_dismiss(p_kind text, p_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
begin
  if not app.is_moderator() then
    raise exception 'forbidden' using errcode = 'insufficient_privilege';
  end if;

  if p_kind not in ('post', 'comment', 'trail_condition') then
    return jsonb_build_object('ok', false, 'error', 'bad_kind');
  end if;

  update content_reports
     set status = 'dismissed', reviewed_by = auth.uid(), reviewed_at = now()
   where target_kind = p_kind and target_id = p_id and status = 'new';

  perform app.audit('content.dismiss', p_kind, p_id::text);

  return jsonb_build_object('ok', true);
end;
$fn$;

-- ---------------------------------------------------------------------------
-- Grants. Nothing for anon: the directory is behind an account.
-- ---------------------------------------------------------------------------

do $grants$
declare fn text;
begin
  foreach fn in array array[
    'public.trails_search(text, text, text, boolean, double precision, double precision, integer)',
    'public.trail_detail(text)',
    'public.trail_save(uuid, boolean)',
    'public.report_trail_condition(uuid, text, text)',
    'public.submit_trail_edit(jsonb)',
    'public.admin_trails(text)',
    'public.admin_save_trail(jsonb)',
    'public.admin_trail_edits(text)',
    'public.admin_review_trail_edit(uuid, text, text)'
  ]
  loop
    execute format('revoke all on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated', fn);
  end loop;
end
$grants$;
