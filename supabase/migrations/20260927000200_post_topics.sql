-- Winch Up :: what a community post is about, so the feed can be filtered
--
-- Screen 9 of the design reference has tabs across the feed: Recent, Trails, Events, Tips. The
-- feed had no way to say what a post was about, so there was nothing to filter and the screen
-- shipped without them.
--
-- THE TABS ARE NOT THE REFERENCE'S TABS, DELIBERATELY
--
-- Events and Tips are not features of this product. Groups and events were deferred in phase 8
-- and there is no such thing as a tip. Shipping four tabs where two open an empty list would
-- match the mockup and lie about what the app does -- and an empty tab is worse than a missing
-- one, because it reads as a broken feature rather than an absent one.
--
-- So the topics are the things CLAUDE.md already says this feed is for: "Trail conditions, gate
-- closures, questions about gear -- the things that used to be a Facebook post." That is three
-- topics and a general bucket, and every one of them has something to hold.
--
-- `general` is the default so every existing post stays visible under Recent and nothing has to
-- be backfilled by guessing what an old post was about.

set search_path = public, extensions;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'post_topic') then
    create type post_topic as enum ('general', 'trail_conditions', 'gear', 'recoveries');
  end if;
end
$$;

alter table public.community_posts
  add column if not exists topic post_topic not null default 'general';

comment on column public.community_posts.topic is
  'What the post is about, for the feed tabs. Defaults to general so nothing needs backfilling. '
  'Not the design reference''s Events/Tips: neither exists as a feature, and a tab that opens an '
  'empty list reads as broken rather than absent.';

-- The feed is "this topic, newest first", so the index is the pair. Without it every tab is a
-- sequential scan the moment the feed is longer than a screen.
create index if not exists community_posts_topic_created_idx
  on public.community_posts (topic, created_at desc)
  where status = 'visible';

-- ---------------------------------------------------------------------------
-- community_feed, with an optional topic
--
-- Optional, and null means all: an older client that does not send the argument gets exactly the
-- behaviour it had. The frontend deploys on a push and this migration goes across by hand, so
-- there is always a window where one is ahead of the other.
-- ---------------------------------------------------------------------------

-- Drop the two-argument version FIRST.
--
-- Adding a parameter with a default does not replace a function, it OVERLOADS it: both
-- signatures then exist, and PostgREST has no way to choose between them for a two-argument
-- call. The feed would start failing with an ambiguity error that says nothing about topics.
-- Same family as the return-type trap already in CLAUDE.md, and just as quiet.
--
-- Safe to drop: the new signature defaults p_topic, so a client that still sends only p_before
-- and p_limit resolves to it and behaves exactly as before.
drop function if exists public.community_feed(timestamptz, integer);

create or replace function public.community_feed(
  p_before timestamptz default null,
  p_limit  integer default 20,
  p_topic  text default null
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
  v_topic post_topic;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  -- An unknown topic is treated as no filter rather than an error. A stale bookmark or a client
  -- ahead of the schema should show the whole feed, not a failure on the page somebody opened to
  -- read about a gate closure.
  if p_topic is not null and p_topic <> '' then
    begin
      v_topic := p_topic::post_topic;
    exception when invalid_text_representation then
      v_topic := null;
    end;
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
      p.topic,
      (p.author_user_id = v_me) as mine,
      p.author_user_id,
      coalesce(pr.display_name, '') as author_name,
      exists (
        select 1 from community_reactions r where r.post_id = p.id and r.user_id = v_me
      ) as reacted
    from community_posts p
    left join profiles pr on pr.user_id = p.author_user_id
   where p.status = 'visible'
     and (p_before is null or p.created_at < p_before)
     and (v_topic is null or p.topic = v_topic)
     -- app.blocks_between, not a hand-written subquery: it is BIDIRECTIONAL. A one-sided check
     -- would show a blocked member's posts to the person who blocked them.
     and not app.blocks_between(v_me, p.author_user_id)
   order by p.created_at desc
   limit greatest(1, least(coalesce(p_limit, 20), 50))
  ) f;

  return jsonb_build_object('ok', true, 'posts', v_rows);
end;
$fn$;

revoke all on function public.community_feed(timestamptz, integer, text) from public, anon;
grant execute on function public.community_feed(timestamptz, integer, text) to authenticated;

-- ---------------------------------------------------------------------------
-- community_post, with the topic the composer picked
--
-- Same overload trap as above: a defaulted parameter would add a signature rather than replace
-- one, so the two-argument version is dropped first.
--
-- An unknown or missing topic becomes 'general' rather than an error. A post somebody typed out
-- must not be lost because a client sent a value this schema does not know yet -- the window
-- where the frontend is ahead of the database is a real one on this project, and the cost of
-- being wrong here is somebody's gate-closure warning disappearing on submit.
-- ---------------------------------------------------------------------------

drop function if exists public.community_post(text, text);

create or replace function public.community_post(
  p_body       text,
  p_photo_path text default null,
  p_topic      text default 'general'
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me uuid := auth.uid();
  v_body text := btrim(coalesce(p_body, ''));
  v_topic post_topic := 'general';
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

  if public.contains_contact_info(v_body) then
    return jsonb_build_object('ok', false, 'error', 'contact_info');
  end if;

  if not app.check_rate_limit('community_post:' || v_me::text, 20, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  if p_topic is not null and p_topic <> '' then
    begin
      v_topic := p_topic::post_topic;
    exception when invalid_text_representation then
      v_topic := 'general';
    end;
  end if;

  insert into community_posts (author_user_id, body, photo_path, topic)
  values (v_me, v_body, nullif(btrim(coalesce(p_photo_path, '')), ''), v_topic);

  return jsonb_build_object('ok', true);
end;
$fn$;

revoke all on function public.community_post(text, text, text) from public, anon;
grant execute on function public.community_post(text, text, text) to authenticated;
