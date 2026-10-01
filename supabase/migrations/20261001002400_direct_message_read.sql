-- Winch Up :: reading an inbox and a conversation
--
-- Three reads, all of them deriving participation from auth.uid() rather than trusting the thread id
-- they were handed. A caller who makes up a uuid gets not_found, and the same not_found whether the
-- thread does not exist or belongs to two other people -- so this cannot be used to discover that two
-- particular members are talking.
--
-- READING IS ALLOWED TO A PARTICIPANT, FULL STOP. Not gated on allow_direct_messages, not gated on the
-- other member's standing, and not gated on the caller's own suspension. A conversation is half yours:
-- turning your switch off, being blocked, or being suspended must not delete your side of it. The
-- SENDING rules live in the previous file and are where every refusal belongs.
--
-- The one thing that does change what you see: a blocked member's thread stays readable, so somebody
-- who blocks a harasser keeps the evidence. Blocking stops new messages arriving; it does not rewrite
-- what happened.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. Am I in this thread, and who is the other person?
-- ---------------------------------------------------------------------------

create or replace function app.dm_other_member(p_thread_id uuid, p_me uuid)
returns uuid
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
  select case when t.member_a = p_me then t.member_b else t.member_a end
    from public.dm_threads t
   where t.id = p_thread_id
     and p_me in (t.member_a, t.member_b);
$fn$;

revoke all on function app.dm_other_member(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The inbox
-- ---------------------------------------------------------------------------
--
-- One row per conversation, newest first, with the unread count and a preview. The preview is the last
-- message whoever it came from -- an inbox that hid your own last line would read as if the other
-- person had gone quiet.
--
-- A thread with no messages is not listed. dm_send creates the thread and the message together, so that
-- only happens if the insert after it failed, and an empty conversation is not something to show.

create or replace function public.dm_inbox(p_limit integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me   uuid := auth.uid();
  v_rows jsonb;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  select coalesce(jsonb_agg(x order by x.last_message_at desc nulls last), '[]'::jsonb)
    into v_rows
  from (
    select
      t.id as thread_id,
      other.user_id as other_user_id,
      coalesce(nullif(btrim(op.display_name), ''), orr.first_name) as other_name,
      op.avatar_path as other_avatar_path,
      -- Suspended or deleted on the other side: the conversation stays, and the UI says why it cannot
      -- be continued rather than pretending the person is still there.
      (op.suspended_at is not null) as other_suspended,
      t.last_message_at,
      last_msg.body as preview,
      (last_msg.sender_user_id = v_me) as preview_is_mine,
      (select count(*) from public.dm_messages u
        where u.thread_id = t.id and u.read_at is null
          and u.sender_user_id is distinct from v_me) as unread
      from public.dm_threads t
      cross join lateral (
        select case when t.member_a = v_me then t.member_b else t.member_a end as user_id
      ) other
      join public.profiles op on op.user_id = other.user_id
      left join public.responders orr on orr.user_id = other.user_id
      left join lateral (
        select m.body, m.sender_user_id
          from public.dm_messages m
         where m.thread_id = t.id
         order by m.created_at desc
         limit 1
      ) last_msg on true
     where v_me in (t.member_a, t.member_b)
       and last_msg.body is not null
     order by t.last_message_at desc nulls last
     limit greatest(1, least(coalesce(p_limit, 50), 100))
  ) x;

  return jsonb_build_object('ok', true, 'threads', v_rows);
end;
$fn$;

revoke all on function public.dm_inbox(integer) from public, anon;
grant execute on function public.dm_inbox(integer) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. One conversation
-- ---------------------------------------------------------------------------
--
-- `mine` instead of a sender id on every message. request_thread() returns a first name rather than a
-- user id for the same reason -- a thread payload should not be a directory of account ids. Here the
-- OTHER member's id is returned once, deliberately: the UI links to their profile, and the caller could
-- reach it from the directory anyway.

create or replace function public.dm_thread(p_thread_id uuid, p_limit integer default 200)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me    uuid := auth.uid();
  v_other uuid;
  v_rows  jsonb;
  v_meta  jsonb;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  v_other := app.dm_other_member(p_thread_id, v_me);

  if v_other is null then
    -- Nonexistent and somebody else's are the same answer, so this is not a way to find out who is
    -- talking to whom.
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  select jsonb_build_object(
           'user_id',      op.user_id,
           'display_name', coalesce(nullif(btrim(op.display_name), ''), orr.first_name),
           'avatar_path',  op.avatar_path,
           'suspended',    (op.suspended_at is not null)
         ) into v_meta
    from public.profiles op
    left join public.responders orr on orr.user_id = op.user_id
   where op.user_id = v_other;

  select coalesce(jsonb_agg(m order by m.created_at), '[]'::jsonb)
    into v_rows
  from (
    select
      msg.id,
      msg.body,
      (msg.sender_user_id = v_me) as mine,
      msg.read_at,
      msg.created_at
      from public.dm_messages msg
     where msg.thread_id = p_thread_id
     order by msg.created_at desc
     limit greatest(1, least(coalesce(p_limit, 200), 500))
  ) m;

  return jsonb_build_object('ok', true, 'thread_id', p_thread_id, 'other', v_meta,
                            'messages', v_rows);
end;
$fn$;

revoke all on function public.dm_thread(uuid, integer) from public, anon;
grant execute on function public.dm_thread(uuid, integer) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Marking it read
-- ---------------------------------------------------------------------------
--
-- Only the OTHER person's messages. Stamping your own would make read_at meaningless as "they saw it",
-- which is the only thing it is for.

create or replace function public.dm_mark_read(p_thread_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me    uuid := auth.uid();
  v_other uuid;
  v_count integer;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  v_other := app.dm_other_member(p_thread_id, v_me);
  if v_other is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  with marked as (
    update public.dm_messages
       set read_at = now()
     where thread_id = p_thread_id
       and sender_user_id is distinct from v_me
       and read_at is null
    returning 1
  )
  select count(*) into v_count from marked;

  return jsonb_build_object('ok', true, 'marked', v_count);
end;
$fn$;

revoke all on function public.dm_mark_read(uuid) from public, anon;
grant execute on function public.dm_mark_read(uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
