-- Winch Up :: announcements
--
-- Section 1 of the owner's spec, and the only part of it with no backend at all -- checked against the
-- whole migrations folder first, because "deferred" in this project's notes has twice meant "the UI is
-- deferred, the backend is built", and events nearly got clobbered that way on 2026-10-01.
--
-- WHAT AN ANNOUNCEMENT IS, AND WHAT IT IS NOT.
--
-- It is an admin putting words in front of members, with geographic targeting, for a window of time.
-- It is not a community post: `community_posts` is members talking to each other and
-- contains_contact_info() applies to it because that is where a tow company would leave its number. An
-- announcement is written by somebody who can already reach everybody, so it may carry a link.
--
-- TARGETING FILTERS AN ANNOUNCEMENT, UNLIKE AN EVENT, and the asymmetry is deliberate.
--
-- 20261003000700 argues that hiding a targeted EVENT is wrong: a member who cannot see their own
-- community's events has lost the thing this product replaces, and a Dallas member might happily drive
-- to a Houston clinic. An announcement is the opposite shape. It is pushed at somebody who did not ask
-- for it, there is no directory of announcements to browse, and one about a gate closure four hundred
-- miles away is pure noise. So an announcement a member does not match is not shown.
--
-- DISMISSAL IS PER MEMBER AND PERMANENT. Anything that appears unbidden at the top of a screen must be
-- closeable, or the next one is ignored along with it -- and an announcement that comes back tomorrow
-- is worse than one nobody reads.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. The table
-- ---------------------------------------------------------------------------

create table if not exists public.announcements (
  id          uuid primary key default gen_random_uuid(),

  title       text not null,
  body        text not null,
  category    announcement_category not null default 'operational',
  status      announcement_status not null default 'draft',

  -- A LINK IS ALLOWED, unlike in community text, because an admin wrote it. Still has to point
  -- somewhere a browser will follow.
  link_url    text,
  link_label  text,

  -- The window. `starts_at` null means "as soon as it is published", which is what somebody writing
  -- about a locked gate wants; `ends_at` null means it stays until it is archived.
  starts_at   timestamptz,
  ends_at     timestamptz,

  -- Pinned announcements sort first. Not a priority scale: three levels invite a culture where
  -- everything is urgent, and the only question worth answering is "does this go above the others".
  pinned      boolean not null default false,

  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint announcements_title_sane
    check (length(btrim(title)) between 2 and 120),
  constraint announcements_body_sane
    check (length(btrim(body)) between 2 and 2000),
  -- Length in length(), not in the pattern: a POSIX repetition count above 255 is invalid and is
  -- compiled on the first row rather than at ALTER TABLE, which already produced one constraint today
  -- that looked applied and refused every URL.
  constraint announcements_link_is_web
    check (link_url is null
           or (length(link_url) between 11 and 500 and link_url ~* '^https?://[^[:space:]]+$')),
  constraint announcements_link_label_sane
    check (link_label is null or length(btrim(link_label)) between 2 and 60),
  -- A label with no link is a button that does nothing. A link with no label is fine -- the UI has a
  -- default word for it.
  constraint announcements_label_needs_link
    check (link_label is null or link_url is not null),
  constraint announcements_window_makes_sense
    check (ends_at is null or starts_at is null or ends_at >= starts_at)
);

alter table public.announcements enable row level security;
revoke all on public.announcements from anon, authenticated;

-- Read through my_announcements() and the admin RPCs only. No table access, so a member can never
-- read a draft -- which is somebody's unfinished words about a gate they have not confirmed yet.
comment on table public.announcements is
  'Admin announcements to members, geographically targeted through target_locations with scope '
  '''announcement''. No table access: read through my_announcements() or admin_announcements(). '
  'Unlike an event, an announcement a member does not match is NOT shown -- see the migration header.';

create index if not exists announcements_live_idx
  on public.announcements (pinned desc, created_at desc)
  where status = 'published';

create index if not exists announcements_created_by_idx
  on public.announcements (created_by)
  where created_by is not null;

-- ---------------------------------------------------------------------------
-- 2. Dismissal
-- ---------------------------------------------------------------------------

create table if not exists public.announcement_dismissals (
  announcement_id uuid not null references public.announcements(id) on delete cascade,
  user_id         uuid not null references auth.users(id) on delete cascade,
  dismissed_at    timestamptz not null default now(),
  primary key (announcement_id, user_id)
);

alter table public.announcement_dismissals enable row level security;
revoke all on public.announcement_dismissals from anon, authenticated;

-- The primary key leads with announcement_id, so the user_id direction -- "what has this member
-- dismissed", which is the lookup my_announcements() makes -- needs its own index.
create index if not exists announcement_dismissals_user_idx
  on public.announcement_dismissals (user_id);

comment on table public.announcement_dismissals is
  'Which member closed which announcement. Permanent: an announcement that comes back tomorrow is '
  'worse than one nobody reads.';

notify pgrst, 'reload schema';
