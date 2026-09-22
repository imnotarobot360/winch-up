-- Winch Up :: the community feed
--
-- Phase 8. Posts, comments, reactions, blocking, and the moderation layer underneath them.
--
-- Three decisions that shape everything here:
--
-- 1. The feed is for signed-in members, not the public. /board is already the public surface and
--    it is deliberately thin -- no names, no phones, a blurred pin. A feed carrying names,
--    photos and conversation is a different thing and should not be readable by anyone who finds
--    the domain.
--
-- 2. contains_contact_info() DOES apply to posts and comments. This is the surface where a tow
--    company would post its number, and the rules everybody accepts already say "do not post
--    phone numbers or links". It costs a legitimate member the ability to paste a trail link,
--    which is a real loss, and it is still the right trade: the whole product rests on no money
--    changing hands, and a feed full of numbers is how that erodes.
--
-- 3. This is where `moderator` finally does something. It has sat in app_role since Phase 3
--    doing nothing, leaving admin as all-or-nothing. A moderator can hide content and nothing
--    else -- they cannot approve volunteers, read a requester's phone number, or change the
--    waiver. That is the least-privilege gap Phase 11 left open, closed by the phase that
--    actually needed it.

set search_path = public, extensions;

create type content_status as enum ('visible', 'hidden', 'removed');

create type report_reason as enum (
  'spam',
  'harassment',
  'impersonation',
  'unsafe_advice',
  'soliciting_payment',   -- the one that matters most here
  'other'
);

-- ---------------------------------------------------------------------------
-- Blocking, first, because everything else reads it
-- ---------------------------------------------------------------------------

create table user_blocks (
  blocker_user_id uuid not null references auth.users (id) on delete cascade,
  blocked_user_id uuid not null references auth.users (id) on delete cascade,
  created_at      timestamptz not null default now(),
  primary key (blocker_user_id, blocked_user_id),
  constraint user_blocks_not_self check (blocker_user_id <> blocked_user_id)
);

alter table user_blocks enable row level security;
revoke all on user_blocks from anon, authenticated;

-- Blocking is symmetric in effect. If either person has blocked the other, neither sees the
-- other's posts. A one-way block that still shows the blocker's content to the person they
-- blocked is how blocking fails the person who needed it.
create or replace function app.blocks_between(p_a uuid, p_b uuid)
returns boolean
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  select exists (
    select 1 from public.user_blocks b
     where (b.blocker_user_id = p_a and b.blocked_user_id = p_b)
        or (b.blocker_user_id = p_b and b.blocked_user_id = p_a)
  );
$$;

create or replace function app.is_moderator()
returns boolean
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  select exists (
    select 1 from public.user_roles
     where user_id = auth.uid() and role in ('moderator', 'admin')
  );
$$;

-- ---------------------------------------------------------------------------
-- Posts and comments
-- ---------------------------------------------------------------------------

create table community_posts (
  id             uuid primary key default gen_random_uuid(),
  author_user_id uuid references auth.users (id) on delete set null,

  body           text not null check (
                   length(btrim(body)) between 1 and 2000
                   and not public.contains_contact_info(body)
                 ),
  photo_path     text,

  status         content_status not null default 'visible',
  moderated_by   uuid references auth.users (id) on delete set null,
  moderated_at   timestamptz,
  moderation_note text,

  comment_count  integer not null default 0,
  reaction_count integer not null default 0,

  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index community_posts_feed_idx on community_posts (created_at desc) where status = 'visible';
create index community_posts_author_idx on community_posts (author_user_id);

create table community_comments (
  id             uuid primary key default gen_random_uuid(),
  post_id        uuid not null references community_posts (id) on delete cascade,
  author_user_id uuid references auth.users (id) on delete set null,

  body           text not null check (
                   length(btrim(body)) between 1 and 1000
                   and not public.contains_contact_info(body)
                 ),

  status         content_status not null default 'visible',
  moderated_by   uuid references auth.users (id) on delete set null,
  moderated_at   timestamptz,

  created_at     timestamptz not null default now()
);

create index community_comments_post_idx on community_comments (post_id, created_at);

create table community_reactions (
  post_id    uuid not null references community_posts (id) on delete cascade,
  user_id    uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create trigger community_posts_set_updated_at
  before update on community_posts
  for each row execute function app.set_updated_at();

alter table community_posts enable row level security;
alter table community_comments enable row level security;
alter table community_reactions enable row level security;
revoke all on community_posts, community_comments, community_reactions from anon, authenticated;

-- Counters kept on the post so the feed does not need a subquery per row.
create or replace function app.community_touch_counts()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if tg_table_name = 'community_comments' then
    update community_posts p
       set comment_count = (select count(*) from community_comments c
                             where c.post_id = p.id and c.status = 'visible')
     where p.id = coalesce(new.post_id, old.post_id);
  else
    update community_posts p
       set reaction_count = (select count(*) from community_reactions r where r.post_id = p.id)
     where p.id = coalesce(new.post_id, old.post_id);
  end if;
  return null;
end;
$$;

create trigger community_comments_count
  after insert or update or delete on community_comments
  for each row execute function app.community_touch_counts();

create trigger community_reactions_count
  after insert or delete on community_reactions
  for each row execute function app.community_touch_counts();

-- ---------------------------------------------------------------------------
-- Moderation reports
--
-- Separate from safety_incidents on purpose. That table is about what happened at a recovery --
-- somebody asked for cash, somebody got hurt -- and its subject must never see it. This is about
-- a piece of content, and the outcome is the content being hidden.
-- ---------------------------------------------------------------------------

create table content_reports (
  id               uuid primary key default gen_random_uuid(),
  target_kind      text not null check (target_kind in ('post', 'comment')),
  target_id        uuid not null,
  reporter_user_id uuid references auth.users (id) on delete set null,
  reason           report_reason not null,
  note             text check (note is null or length(note) <= 1000),
  status           incident_status not null default 'new',
  reviewed_by      uuid references auth.users (id) on delete set null,
  reviewed_at      timestamptz,
  created_at       timestamptz not null default now(),
  unique (target_kind, target_id, reporter_user_id)
);

create index content_reports_triage_idx on content_reports (status, created_at desc);

alter table content_reports enable row level security;
revoke all on content_reports from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Reading the feed
--
-- There are no table grants, so these functions are the only way in. They apply blocking, hide
-- moderated content, and page by timestamp rather than offset -- an offset pager shifts under you
-- as posts arrive, which is how people see one post twice and miss the one between.
-- ---------------------------------------------------------------------------

create or replace function public.community_feed(
  p_before timestamptz default null,
  p_limit  integer default 20
)
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

  select coalesce(jsonb_agg(to_jsonb(f) order by f.created_at desc), '[]'::jsonb) into v_rows
  from (
    select
      p.id,
      p.body,
      p.photo_path,
      p.comment_count,
      p.reaction_count,
      p.created_at,
      (p.author_user_id = v_me) as mine,
      p.author_user_id,
      -- A display name or nothing: not the email, not the account id. profiles.profile_public is
      -- deliberately not consulted -- that setting governs whether a profile is browsable, and
      -- writing a post is an affirmative act of putting your name on something.
      coalesce(pr.display_name, '') as author_name,
      exists (
        select 1 from community_reactions r where r.post_id = p.id and r.user_id = v_me
      ) as reacted
    from community_posts p
    left join profiles pr on pr.user_id = p.author_user_id
   where p.status = 'visible'
     and (p_before is null or p.created_at < p_before)
     and not app.blocks_between(v_me, p.author_user_id)
   order by p.created_at desc
   limit greatest(1, least(coalesce(p_limit, 20), 50))
  ) f;

  return jsonb_build_object('ok', true, 'posts', v_rows);
end;
$fn$;

create or replace function public.community_post_thread(p_post_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me uuid := auth.uid();
  v_post community_posts%rowtype;
  v_rows jsonb;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  select * into v_post from community_posts where id = p_post_id and status = 'visible';

  -- Hidden, deleted, never existed, or written by somebody there is a block with: one answer for
  -- all of them, so ids cannot be probed and a block cannot be detected.
  if not found or app.blocks_between(v_me, v_post.author_user_id) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at), '[]'::jsonb) into v_rows
  from (
    select c.id, c.body, c.created_at,
           (c.author_user_id = v_me) as mine,
           c.author_user_id,
           coalesce(pr.display_name, '') as author_name
      from community_comments c
      left join profiles pr on pr.user_id = c.author_user_id
     where c.post_id = p_post_id
       and c.status = 'visible'
       and not app.blocks_between(v_me, c.author_user_id)
     order by c.created_at
     limit 200
  ) c;

  return jsonb_build_object('ok', true, 'comments', v_rows);
end;
$fn$;

-- ---------------------------------------------------------------------------
-- Writing
-- ---------------------------------------------------------------------------

create or replace function public.community_post(p_body text, p_photo_path text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me uuid := auth.uid();
  v_body text := btrim(coalesce(p_body, ''));
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  if length(v_body) = 0 then
    return jsonb_build_object('ok', false, 'error', 'empty');
  end if;

  if length(v_body) > 2000 then
    return jsonb_build_object('ok', false, 'error', 'too_long');
  end if;

  -- Checked here as well as by the CHECK constraint, so the caller gets something it can show
  -- the member rather than a raw 23514.
  if public.contains_contact_info(v_body) then
    return jsonb_build_object('ok', false, 'error', 'contact_info');
  end if;

  if not app.check_rate_limit('community_post:' || v_me::text, 20, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  insert into community_posts (author_user_id, body, photo_path)
  values (v_me, v_body, nullif(btrim(coalesce(p_photo_path, '')), ''));

  return jsonb_build_object('ok', true);
end;
$fn$;

create or replace function public.community_comment(p_post_id uuid, p_body text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me uuid := auth.uid();
  v_body text := btrim(coalesce(p_body, ''));
  v_post community_posts%rowtype;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  select * into v_post from community_posts where id = p_post_id and status = 'visible';

  if not found or app.blocks_between(v_me, v_post.author_user_id) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if length(v_body) = 0 or length(v_body) > 1000 then
    return jsonb_build_object('ok', false, 'error', 'bad_length');
  end if;

  if public.contains_contact_info(v_body) then
    return jsonb_build_object('ok', false, 'error', 'contact_info');
  end if;

  if not app.check_rate_limit('community_comment:' || v_me::text, 60, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  insert into community_comments (post_id, author_user_id, body)
  values (p_post_id, v_me, v_body);

  return jsonb_build_object('ok', true);
end;
$fn$;

create or replace function public.community_react(p_post_id uuid, p_on boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me uuid := auth.uid();
  v_post community_posts%rowtype;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  select * into v_post from community_posts where id = p_post_id and status = 'visible';

  if not found or app.blocks_between(v_me, v_post.author_user_id) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if p_on then
    insert into community_reactions (post_id, user_id) values (p_post_id, v_me)
    on conflict do nothing;
  else
    delete from community_reactions where post_id = p_post_id and user_id = v_me;
  end if;

  return jsonb_build_object('ok', true);
end;
$fn$;

-- Authors can remove their own. Not edit: an edited post that somebody has already replied to is
-- a way to make another member look like they said something they did not.
create or replace function public.community_delete_own(p_kind text, p_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me uuid := auth.uid();
  v_hit integer;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  if p_kind = 'post' then
    update community_posts set status = 'removed'
     where id = p_id and author_user_id = v_me and status = 'visible';
  elsif p_kind = 'comment' then
    update community_comments set status = 'removed'
     where id = p_id and author_user_id = v_me and status = 'visible';
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

-- ---------------------------------------------------------------------------
-- Blocking and reporting, by ordinary members
-- ---------------------------------------------------------------------------

create or replace function public.community_block(p_user_id uuid, p_on boolean)
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

  if p_user_id is null or p_user_id = v_me then
    return jsonb_build_object('ok', false, 'error', 'bad_target');
  end if;

  if p_on then
    insert into user_blocks (blocker_user_id, blocked_user_id) values (v_me, p_user_id)
    on conflict do nothing;
  else
    delete from user_blocks where blocker_user_id = v_me and blocked_user_id = p_user_id;
  end if;

  -- No audit row and no notification. The person who was blocked is never told, because a block
  -- that announces itself is one the blocked person can retaliate for.
  return jsonb_build_object('ok', true);
end;
$fn$;

create or replace function public.community_blocked_list()
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

  -- Only the blocks this person made. Blocks made against them stay invisible, for the same
  -- reason community_block writes no audit row.
  select coalesce(jsonb_agg(to_jsonb(b) order by b.created_at desc), '[]'::jsonb) into v_rows
  from (
    select ub.blocked_user_id as user_id,
           coalesce(pr.display_name, '') as display_name,
           ub.created_at
      from user_blocks ub
      left join profiles pr on pr.user_id = ub.blocked_user_id
     where ub.blocker_user_id = v_me
     order by ub.created_at desc
  ) b;

  return jsonb_build_object('ok', true, 'blocked', v_rows);
end;
$fn$;

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

  -- One report per person per item. A second press of the button is not a second report, and the
  -- queue sorts on how many distinct people reported a thing.
  insert into content_reports (target_kind, target_id, reporter_user_id, reason, note)
  values (p_kind, p_id, v_me, v_reason, nullif(btrim(coalesce(p_note, '')), ''))
  on conflict (target_kind, target_id, reporter_user_id) do nothing;

  return jsonb_build_object('ok', true);
end;
$fn$;

-- ---------------------------------------------------------------------------
-- Moderation
--
-- Gated on app.is_moderator(), not app.require_admin(). This is the whole reason the moderator
-- role exists: somebody trusted to hide a post is not thereby trusted with a requester's phone
-- number or with approving volunteers.
-- ---------------------------------------------------------------------------

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
           coalesce(p.body, c.body) as content,
           coalesce(p.status, c.status)::text as content_status,
           coalesce(pp.display_name, cp.display_name, '') as author_name
      from content_reports cr
      left join community_posts p on cr.target_kind = 'post' and p.id = cr.target_id
      left join community_comments c on cr.target_kind = 'comment' and c.id = cr.target_id
      left join profiles pp on pp.user_id = p.author_user_id
      left join profiles cp on cp.user_id = c.author_user_id
     where p_status is null or cr.status = p_status::incident_status
     -- Grouped by the reported item, not by the report. Five people reporting one post is one
     -- decision for a moderator to make, not five.
     group by cr.target_kind, cr.target_id, p.body, c.body, p.status, c.status,
              pp.display_name, cp.display_name
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
       set status = v_status,
           moderated_by = auth.uid(),
           moderated_at = now()
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

  -- Every moderator action is auditable, including restores. Hiding is reversible; doing it
  -- unaccountably is what turns a moderator into a problem.
  perform app.audit('content.' || p_action, p_kind, p_id::text,
                    jsonb_build_object('note', nullif(btrim(coalesce(p_note, '')), '')));

  return jsonb_build_object('ok', true);
end;
$fn$;

-- Dismiss without touching the content: the report was wrong, the post stays up.
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

  if p_kind not in ('post', 'comment') then
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
-- Grants. Nothing is executable by anon: the feed is for members.
-- ---------------------------------------------------------------------------

do $grants$
declare fn text;
begin
  foreach fn in array array[
    'public.community_feed(timestamptz, integer)',
    'public.community_post_thread(uuid)',
    'public.community_post(text, text)',
    'public.community_comment(uuid, text)',
    'public.community_react(uuid, boolean)',
    'public.community_delete_own(text, uuid)',
    'public.community_block(uuid, boolean)',
    'public.community_blocked_list()',
    'public.community_report(text, uuid, text, text)',
    'public.moderation_queue(text)',
    'public.moderate_content(text, uuid, text, text)',
    'public.moderation_dismiss(text, uuid)'
  ]
  loop
    execute format('revoke all on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated', fn);
  end loop;
end
$grants$;
