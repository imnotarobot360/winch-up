-- Winch Up :: an event gets a place, a type, pictures and an organiser
--
-- Section 2 of the owner's spec: event type, address, city, state, ZIP, latitude and longitude, a
-- cover image and more images, an organiser, a registration URL, a website, contact details, and
-- geographic targeting.
--
-- WHAT WAS ALREADY HERE, because the notes have twice called something deferred that was built:
-- `events` has existed since phase 12 with group, trail, title, description, start, end, meet point,
-- meet note, capacity and status, and it got its screens on 2026-10-01. `create_event`,
-- `events_upcoming` and `event_rsvp` all work. This EXTENDS that. Nothing is replaced.
--
-- THE ONE THING THAT MADE THIS MORE THAN AN ALTER TABLE.
--
-- `create_event` is granted to every member, rate-limited at ten a day, and it takes `status` from
-- its payload -- so a member can publish an event that every other member sees, with no review. That
-- is existing behaviour and it is fine for "trail ride Saturday, meet at the gate".
--
-- It is NOT fine for the fields section 2 asks for. An organiser name, a website, a registration link
-- and a phone number, on a row any member can publish, is a billboard: "post an event" becomes "put
-- my towing company's number in front of six thousand people", which is the exact surface CLAUDE.md
-- warns about and the exact thing `contains_contact_info()` exists to stop in free text.
--
-- So those fields are reachable only through the admin surface, and that is enforced by a CHECK
-- rather than by `create_event` happening not to read them. `is_official` says the row came through
-- Content & Marketing, where whoever wrote the words can already reach every member anyway; the
-- promotional columns must be null unless it is set. A future RPC that forgets the rule fails at the
-- constraint instead of shipping a spam vector.
--
-- WHERE THE POINT COMES FROM. `meet_point` is reused as the event's position rather than adding a
-- second geography column. It is already the place members drive to, it already has a GiST index, and
-- two points on one row is how a map ends up showing the wrong one. The spec's "latitude/longitude"
-- is that column.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. The columns
-- ---------------------------------------------------------------------------

alter table public.events
  add column if not exists event_type       event_type not null default 'other',

  -- Where it is, in words. Targeting matches on city/state/postal_code exactly as it does for a
  -- member, which is the whole reason these are separate columns and not one "location" string.
  add column if not exists address_line     text,
  add column if not exists city             text,
  add column if not exists state            text,
  add column if not exists postal_code      text,
  add column if not exists country          text not null default 'US',

  -- Pictures. Paths into the existing private bucket, never URLs: a URL column is a way to hotlink
  -- anything, and every other image in this app is a signed path.
  add column if not exists cover_image_path text,
  add column if not exists image_paths      text[] not null default '{}',

  -- Admin-only, every one of them. See the header.
  add column if not exists is_official      boolean not null default false,
  add column if not exists organizer_name   text,
  add column if not exists registration_url text,
  add column if not exists website_url      text,
  add column if not exists contact_email    text,
  add column if not exists contact_phone    text;

comment on column public.events.is_official is
  'The row was written through the admin Content & Marketing surface. It is what the CHECK below '
  'keys the promotional columns on -- an organiser, a website, a registration link and a phone '
  'number are not safe on a row any member can publish.';

comment on column public.events.meet_point is
  'The event position. Section 2 of the spec calls this latitude/longitude; it is deliberately the '
  'same column members already drive to rather than a second point beside it.';

-- ---------------------------------------------------------------------------
-- 2. What the values may be
-- ---------------------------------------------------------------------------

do $$
begin
  -- Same formats as profiles, or an event can be given an address that no member can ever match.
  if not exists (select 1 from pg_constraint where conname = 'events_state_format') then
    alter table public.events add constraint events_state_format
      check (state is null or state ~ '^[A-Z]{2}$');
  end if;

  if not exists (select 1 from pg_constraint where conname = 'events_postal_format') then
    alter table public.events add constraint events_postal_format
      check (postal_code is null or postal_code ~ '^[0-9]{5}$');
  end if;

  if not exists (select 1 from pg_constraint where conname = 'events_country_format') then
    alter table public.events add constraint events_country_format
      check (country ~ '^[A-Z]{2}$');
  end if;

  -- City and street are public free text on a members-only surface, so they get the same treatment
  -- as description and meet_note already have. This is where a number would go if the dedicated
  -- contact columns were refused.
  if not exists (select 1 from pg_constraint where conname = 'events_city_sane') then
    alter table public.events add constraint events_city_sane
      check (city is null
             or (length(btrim(city)) between 1 and 80 and not public.contains_contact_info(city)));
  end if;

  if not exists (select 1 from pg_constraint where conname = 'events_address_sane') then
    alter table public.events add constraint events_address_sane
      check (address_line is null
             or (length(btrim(address_line)) between 1 and 200
                 and not public.contains_contact_info(address_line)));
  end if;

  -- THE PROMOTIONAL COLUMNS ARE NULL UNLESS THE ROW CAME FROM THE ADMIN SURFACE.
  -- This is the constraint the header is about. It is the enforcement, not a belt over a brace.
  if not exists (select 1 from pg_constraint where conname = 'events_promo_is_official') then
    alter table public.events add constraint events_promo_is_official
      check (
        is_official
        or (organizer_name is null and registration_url is null and website_url is null
            and contact_email is null and contact_phone is null)
      );
  end if;

  -- Links have to point somewhere a browser will follow. `javascript:` in a cta_url was a real
  -- finding in the advertising phase and the same rule applies here.
  if not exists (select 1 from pg_constraint where conname = 'events_urls_are_web') then
    alter table public.events add constraint events_urls_are_web
      -- LENGTH IS CHECKED WITH length(), NOT IN THE PATTERN. A POSIX repetition count above 255 is
      -- invalid, and Postgres compiles a CHECK's pattern on the first row rather than on the ALTER
      -- TABLE -- so '{3,500}' here created a constraint that looked applied and then refused every
      -- URL with "invalid repetition count(s)", an error naming nothing that would help.
      check (
        (registration_url is null
         or (length(registration_url) between 11 and 500
             and registration_url ~* '^https?://[^[:space:]]+$'))
        and (website_url is null
             or (length(website_url) between 11 and 500
                 and website_url ~* '^https?://[^[:space:]]+$'))
      );
  end if;

  if not exists (select 1 from pg_constraint where conname = 'events_contact_formats') then
    alter table public.events add constraint events_contact_formats
      check (
        (contact_phone is null or contact_phone ~ '^\+1[0-9]{10}$')
        and (contact_email is null
             or (length(contact_email) between 5 and 200 and contact_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'))
      );
  end if;

  if not exists (select 1 from pg_constraint where conname = 'events_organizer_sane') then
    alter table public.events add constraint events_organizer_sane
      check (organizer_name is null or length(btrim(organizer_name)) between 2 and 120);
  end if;

  -- Bounded, because an unbounded array on a members-only surface is a way to make a page that
  -- never finishes loading on a phone with one bar.
  if not exists (select 1 from pg_constraint where conname = 'events_images_bounded') then
    alter table public.events add constraint events_images_bounded
      check (array_length(image_paths, 1) is null or array_length(image_paths, 1) <= 8);
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- 3. The gap in the title check, closed without risking the migration
-- ---------------------------------------------------------------------------
--
-- `events_description_check` and `events_meet_note_check` both call contains_contact_info().
-- `events_title_check` only ever checked the length, so the one field every member reads first was
-- the one place a phone number was allowed. Pre-existing, found while reading the table rather than
-- by anything failing.
--
-- ADDED `not valid`, THEN VALIDATED SEPARATELY, and that is not timidity. A plain ADD CONSTRAINT
-- scans every existing row, so a single legacy event with a number in its title would abort this
-- migration -- in CI, against production, for a gap that has been open for days. `not valid` binds
-- every future insert and update immediately, which is what actually matters, and the validation
-- is attempted afterwards where a failure is a NOTICE naming the rows to fix rather than a dead
-- deploy.

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'events_title_no_contact_info') then
    alter table public.events add constraint events_title_no_contact_info
      check (not public.contains_contact_info(title)) not valid;
  end if;
end
$$;

do $$
begin
  alter table public.events validate constraint events_title_no_contact_info;
exception when check_violation then
  raise notice 'events_title_no_contact_info is enforced for new rows but some EXISTING event titles contain a phone number or a link. Find them with: select id, title from events where public.contains_contact_info(title);';
end
$$;

-- ---------------------------------------------------------------------------
-- 4. Indexes
-- ---------------------------------------------------------------------------
--
-- Targeting matches an event's city/state and postal code the same way it matches a member's, so
-- they are indexed the same way. Partial, because most events will not have them until somebody
-- fills them in.

create index if not exists events_city_state_idx
  on public.events (state, lower(city))
  where city is not null and state is not null;

create index if not exists events_postal_code_idx
  on public.events (postal_code)
  where postal_code is not null;

create index if not exists events_published_starts_idx
  on public.events (starts_at)
  where status = 'published';

notify pgrst, 'reload schema';
