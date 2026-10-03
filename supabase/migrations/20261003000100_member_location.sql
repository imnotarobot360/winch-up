-- Winch Up :: where a member says they are, which is not where a recovery is
--
-- The foundation for the owner's geo-targeting spec. Section 11 asks for structured city, state,
-- postal code and country on a member's profile instead of free text, and section 7 is emphatic that
-- advertising must not use recovery location data.
--
-- WHY THIS CANNOT REUSE WHAT IS ALREADY THERE.
--
-- profiles.home_region is one free-text field -- "a town or county", typed by the member -- which is
-- exactly what §11 says not to depend on. "Cypress" and "Cypress, TX" and "cypress tx" are three
-- different strings and one place.
--
-- responders.home_location IS structured, a PostGIS point captured at volunteer signup. It is also
-- RECOVERY DATA: it is what app.candidates() measures a call-out from, and §7 forbids advertising
-- from touching it. So the ad path gets its own notion of where somebody is, declared by them for
-- this purpose, and the two never meet. A member who has never volunteered has no home_location at
-- all and must still be targetable; a member who has one must not have it quietly repurposed.
--
-- THE POINT IS DERIVED, NOT TYPED. postal_center is the centroid of the stated postal code, filled in
-- by the server after geocoding. It exists so radius targeting has something to measure against
-- without going anywhere near the recovery point. A member cannot write it -- there is no grant --
-- because the whole value of it is that it follows from the postal code rather than from a claim.
--
-- WHAT HAPPENS WHEN IT IS NOT SET, and this is a real behaviour change the owner should know about:
-- a member with no stated location matches no radius-targeted and no city-targeted campaign. Today
-- ads_for() treats "we do not know where the reader is" as a reason to SHOW a targeted campaign, so
-- radius targeting currently narrows nothing at all. §6 says only matching members should see a
-- campaign, so the default flips -- and until members fill this in, targeted campaigns reach fewer
-- people, which is the honest consequence of targeting actually working.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. The fields
-- ---------------------------------------------------------------------------

alter table public.profiles
  add column if not exists city          text,
  add column if not exists state         text,
  add column if not exists postal_code   text,
  add column if not exists country       text not null default 'US',
  -- Derived from postal_code by the server. No grant: see the header.
  add column if not exists postal_center extensions.geography(Point, 4326),
  add column if not exists location_set_at timestamptz;

-- NORMALIZED AT THE BOUNDARY, not at read time. §11 says to normalize ZIP codes before matching, and
-- the place to do that is once on the way in rather than in every query that compares them -- a
-- single `where postal_code = '77429 '` that forgot to trim is a member who silently stops matching.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_postal_code_format') then
    alter table public.profiles add constraint profiles_postal_code_format
      check (postal_code is null or postal_code ~ '^[0-9]{5}$');
  end if;

  -- Two letters, upper case. The product is US-only (phones are ^\+1 and the trail directory is
  -- Texas), so this is a real constraint rather than a guess about the future.
  if not exists (select 1 from pg_constraint where conname = 'profiles_state_format') then
    alter table public.profiles add constraint profiles_state_format
      check (state is null or state ~ '^[A-Z]{2}$');
  end if;

  if not exists (select 1 from pg_constraint where conname = 'profiles_country_format') then
    alter table public.profiles add constraint profiles_country_format
      check (country ~ '^[A-Z]{2}$');
  end if;

  -- A city is shown to other members on a profile, so it is a public text column, and CLAUDE.md's
  -- rule for those is not optional: contains_contact_info() goes on every one. This is the surface a
  -- tow company would put a phone number on.
  if not exists (select 1 from pg_constraint where conname = 'profiles_city_sane') then
    alter table public.profiles add constraint profiles_city_sane
      check (
        city is null
        or (length(btrim(city)) between 1 and 80 and not public.contains_contact_info(city))
      );
  end if;
end
$$;

-- Matching is by equality on these three, so they are indexed together. Partial, because most rows
-- will have them null until members fill them in.
create index if not exists profiles_postal_code_idx
  on public.profiles (postal_code)
  where postal_code is not null;

create index if not exists profiles_city_state_idx
  on public.profiles (state, lower(city))
  where city is not null and state is not null;

create index if not exists profiles_postal_center_idx
  on public.profiles using gist (postal_center)
  where postal_center is not null;

comment on column public.profiles.postal_code is
  'The member''s stated postal code, five digits, normalized on write. Used for advertising and '
  'event targeting. NOT recovery data -- responders.home_location is that, and the two must not be '
  'substituted for one another.';

comment on column public.profiles.postal_center is
  'Centroid of the stated postal code, geocoded server-side. Exists so radius targeting has a point '
  'to measure from that is not the recovery location. No grant to authenticated: it follows from the '
  'postal code rather than from a claim.';

-- ---------------------------------------------------------------------------
-- 2. Grants
-- ---------------------------------------------------------------------------
--
-- SELECT on the four stated fields so a member's own account screen can show them back. No UPDATE:
-- writes go through set_my_location() below, which normalizes and clears the stale centroid in one
-- step. A member who could UPDATE postal_code directly would leave postal_center pointing at where
-- they used to live, and radius targeting would quietly use the old place.
--
-- profiles has an ENUMERATED column grant list -- a column added later is in none of it, and the
-- whole select is then refused rather than just that column. That cost a regression two days ago
-- where every switch on the notification screen silently showed its default. Hence this block.

grant select (city, state, postal_code, country, location_set_at) on public.profiles to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Setting it
-- ---------------------------------------------------------------------------

create or replace function public.set_my_location(
  p_city        text,
  p_state       text,
  p_postal_code text,
  p_country     text default 'US'
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me     uuid := auth.uid();
  v_city   text := nullif(btrim(coalesce(p_city, '')), '');
  v_state  text := nullif(upper(btrim(coalesce(p_state, ''))), '');
  v_postal text := nullif(btrim(coalesce(p_postal_code, '')), '');
  v_country text := coalesce(nullif(upper(btrim(coalesce(p_country, ''))), ''), 'US');
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  -- NORMALIZE BEFORE VALIDATING. "77429-1234" is a postal code somebody will type, and the five-digit
  -- form is the one that matches. Anything that is not then five digits is refused rather than
  -- stored, because a stored value that cannot match is worse than an empty one: the member believes
  -- they have set a location.
  if v_postal is not null then
    v_postal := substring(regexp_replace(v_postal, '[^0-9]', '', 'g') from 1 for 5);
    if v_postal !~ '^[0-9]{5}$' then
      return jsonb_build_object('ok', false, 'error', 'bad_postal_code');
    end if;
  end if;

  if v_state is not null and v_state !~ '^[A-Z]{2}$' then
    return jsonb_build_object('ok', false, 'error', 'bad_state');
  end if;

  if v_city is not null and public.contains_contact_info(v_city) then
    return jsonb_build_object('ok', false, 'error', 'contact_info');
  end if;

  update public.profiles
     set city            = v_city,
         state           = v_state,
         postal_code     = v_postal,
         country         = v_country,
         -- CLEARED, NOT KEPT. The centroid belongs to the OLD postal code; leaving it would point
         -- radius targeting at where the member used to live, which is the one failure mode nobody
         -- would ever notice. The server geocodes and refills it straight after.
         postal_center   = null,
         location_set_at = now(),
         updated_at      = now()
   where user_id = v_me;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object('ok', true, 'city', v_city, 'state', v_state,
                            'postal_code', v_postal, 'country', v_country);
end;
$fn$;

revoke all on function public.set_my_location(text, text, text, text) from public, anon;
grant execute on function public.set_my_location(text, text, text, text)
  to authenticated, service_role;

notify pgrst, 'reload schema';
