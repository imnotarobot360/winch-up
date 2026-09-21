-- Winch Up :: profiles, and the requester account link
--
-- Phase 3 asks for a profile for every user, and Phase 5 for requests made by an account rather
-- than by an anonymous stranger holding a token.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- Profiles
--
-- Deliberately NOT public. Phase 8 may publish some of this; until that decision is made the
-- safe default is that a profile is visible to its owner and to admins, and nothing else. It is
-- much easier to publish a field later than to un-publish one people have already scraped.
-- ---------------------------------------------------------------------------

create table profiles (
  user_id       uuid primary key references auth.users (id) on delete cascade,

  display_name  text check (
                  display_name is null
                  or (length(btrim(display_name)) between 1 and 60
                      and not public.contains_contact_info(display_name))
                ),
  -- Storage path only. Avatars live in a private bucket and are served through signed URLs, the
  -- same as recovery photos: a public bucket URL is a permanent uncontrolled handle.
  avatar_path   text,
  home_region   text check (home_region is null or length(btrim(home_region)) between 2 and 80),

  -- Recovery notifications are operational and default on. Marketing defaults OFF and stays off
  -- until the user turns it on: Phase 13 forbids marketing without consent, and a default-on
  -- checkbox is not consent.
  notify_recovery   boolean not null default true,
  notify_community  boolean not null default true,
  notify_marketing  boolean not null default false,

  -- Phase 8 will need this. Default false so publishing is an action someone takes, not one
  -- that happens to them.
  profile_public    boolean not null default false,

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create trigger profiles_set_updated_at
  before update on profiles
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------------
-- Every new user gets a profile and the `member` role, granted by the database.
--
-- This is the only path that writes user_roles for a normal signup, and it runs as definer with
-- a fixed role value. A user cannot reach it to ask for a different one.
-- ---------------------------------------------------------------------------

create or replace function app.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  insert into profiles (user_id) values (new.id)
  on conflict (user_id) do nothing;

  insert into user_roles (user_id, role) values (new.id, 'member')
  on conflict (user_id, role) do nothing;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function app.handle_new_user();

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table profiles enable row level security;
revoke all on profiles from anon, authenticated;

grant select (user_id, display_name, avatar_path, home_region,
              notify_recovery, notify_community, notify_marketing, profile_public,
              created_at, updated_at)
  on profiles to authenticated;

-- A user may change their own profile, but only these columns. user_id and the timestamps are
-- not in the list, so there is no way to re-point a row at somebody else.
grant update (display_name, avatar_path, home_region,
              notify_recovery, notify_community, notify_marketing, profile_public)
  on profiles to authenticated;

create policy profiles_self_read on profiles
  for select to authenticated
  using (user_id = auth.uid() or app.is_admin());

create policy profiles_self_update on profiles
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- No insert policy and no insert grant: profiles are created by the signup trigger only.
-- No delete: account deletion cascades from auth.users.

-- ---------------------------------------------------------------------------
-- Requests belong to an account
--
-- Nullable, because rows already exist that predate accounts and because admin intake creates
-- requests on behalf of someone who phoned a group admin. New requests from the app carry the
-- requester's user id; create_request enforces that, not this column.
-- ---------------------------------------------------------------------------

alter table requests add column requester_user_id uuid references auth.users (id) on delete set null;

create index requests_requester_user_idx on requests (requester_user_id, created_at desc)
  where requester_user_id is not null;

comment on column requests.requester_user_id is
  'The account that filed this request. Null for admin intake and for rows created before '
  'accounts were required. The unguessable public_token remains the requester''s access path: '
  'an account is how they are identified, not how the status page is reached.';
