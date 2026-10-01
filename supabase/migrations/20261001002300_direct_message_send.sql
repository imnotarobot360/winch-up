-- Winch Up :: starting and continuing a direct conversation
--
-- The access rule for member-to-member messaging. This is the security work of the phase: one function
-- decides who may talk to whom, and everything else calls it. Spec §9's "users must not be able to add
-- themselves by manipulating ids" is this.
--
-- THE RULE, and the distinction that matters most:
--
--   STARTING a conversation needs the recipient's allow_direct_messages.
--   CONTINUING one does not.
--
-- That is not laziness, it is what the switch means. "Do not let strangers message me" is a statement
-- about new conversations; it cannot retroactively mute somebody you have been talking to for a month,
-- because then turning it on would silently strand every thread you already had. What stops a specific
-- person is blocking, which is symmetric and stops both directions immediately -- and that is the
-- control to reach for, so the UI offers it on every thread.
--
-- Suspension and blocking override everything, in both directions, through app.member_is_listable --
-- the same predicate the directory and the profile use, so a member who cannot be found cannot be
-- messaged either. Reusing it is the point: three places deciding "can this member see that one"
-- separately is three places to get it wrong.
--
-- A SUSPENDED MEMBER CAN STILL READ their own threads (see the next file) but cannot send. Suspension
-- destroys nothing, and somebody appealing it needs to see what was said.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. Are these two members allowed to see each other at all?
-- ---------------------------------------------------------------------------
--
-- Both directions. member_is_listable already covers the other member's suspension, their deletion and
-- blocks in either direction; what it does not cover is the CALLER being suspended, because the
-- directory never needed to ask that about the person browsing it.

create or replace function app.dm_members_ok(p_me uuid, p_other uuid)
returns boolean
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
  select p_me is not null
     and p_other is not null
     and p_me <> p_other
     and exists (
       select 1
         from public.profiles p
         left join public.responders r on r.user_id = p.user_id
        where p.user_id = p_other
          and app.member_is_listable(p, r, p_me)
     )
     -- The caller's own standing. A suspended member is out of the community, which includes not
     -- being able to open new conversations in it.
     and exists (
       select 1
         from public.profiles me
         left join public.responders mr on mr.user_id = me.user_id
        where me.user_id = p_me
          and me.suspended_at is null
          and mr.redacted_at is null
     );
$fn$;

revoke all on function app.dm_members_ok(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. What the UI asks before it draws a Message button
-- ---------------------------------------------------------------------------
--
-- A button that opens a form that then refuses is worse than no button. This answers the same question
-- dm_send will answer, so the two cannot disagree -- and it leaks nothing a profile read does not: the
-- caller can already see this member, or they could not have got here.

create or replace function public.dm_can_message(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me     uuid := auth.uid();
  v_thread uuid;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  if not app.dm_members_ok(v_me, p_user_id) then
    -- One answer for blocked, suspended, deleted, nonexistent and yourself, matching member_profile.
    return jsonb_build_object('ok', true, 'can_message', false, 'reason', 'not_found');
  end if;

  select id into v_thread
    from public.dm_threads
   where member_a = least(v_me, p_user_id) and member_b = greatest(v_me, p_user_id);

  -- An existing conversation can always be continued, whatever the switch says now.
  if v_thread is not null then
    return jsonb_build_object('ok', true, 'can_message', true, 'thread_id', v_thread);
  end if;

  if not coalesce(
       (select p.allow_direct_messages from public.profiles p where p.user_id = p_user_id), true) then
    return jsonb_build_object('ok', true, 'can_message', false, 'reason', 'messages_off');
  end if;

  return jsonb_build_object('ok', true, 'can_message', true);
end;
$fn$;

revoke all on function public.dm_can_message(uuid) from public, anon;
grant execute on function public.dm_can_message(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Sending
-- ---------------------------------------------------------------------------
--
-- Takes the RECIPIENT, not a thread id, so there is no id for a caller to manipulate and no separate
-- "create conversation" call that could be raced into two threads. The thread is a detail of storage.

create or replace function public.dm_send(
  p_to_user_id uuid,
  p_body       text,
  p_client_id  text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me      uuid := auth.uid();
  v_body    text := btrim(coalesce(p_body, ''));
  v_thread  uuid;
  v_id      uuid;
  v_new     boolean := false;
  v_name    text;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  if length(btrim(coalesce(p_client_id, ''))) not between 8 and 64 then
    return jsonb_build_object('ok', false, 'error', 'bad_client_id');
  end if;

  -- THE DUPLICATE CHECK COMES FIRST, before the rate limit and before any permission test.
  --
  -- A retry over one bar of signal cannot tell whether the first attempt landed. If this ran after the
  -- rate limit, a flaky connection would spend the member's allowance on messages that already exist;
  -- if it ran after the permission test, somebody blocked between the two attempts would be told their
  -- already-sent message failed. Same ordering, and the same reasoning, as send_request_message.
  select m.id, m.thread_id into v_id, v_thread
    from public.dm_messages m
   where m.sender_user_id = v_me and m.client_id = btrim(p_client_id);

  if v_id is not null then
    return jsonb_build_object('ok', true, 'thread_id', v_thread, 'message_id', v_id,
                              'duplicate', true);
  end if;

  if length(v_body) < 1 or length(v_body) > 2000 then
    return jsonb_build_object('ok', false, 'error', 'bad_body');
  end if;

  if not app.dm_members_ok(v_me, p_to_user_id) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  select id into v_thread
    from public.dm_threads
   where member_a = least(v_me, p_to_user_id) and member_b = greatest(v_me, p_to_user_id);

  if v_thread is null then
    -- Starting one. This is the half the recipient's switch governs, and the half worth rate limiting
    -- hard: ten NEW conversations a day is generous for a member and useless for somebody working
    -- through the membership offering paid recovery. Messages within a thread are limited separately
    -- and much higher, because that is a conversation rather than a broadcast.
    if not coalesce(
         (select p.allow_direct_messages from public.profiles p where p.user_id = p_to_user_id),
         true) then
      return jsonb_build_object('ok', false, 'error', 'messages_off');
    end if;

    if not app.check_rate_limit('dm_start:' || v_me::text, 10, interval '24 hours') then
      return jsonb_build_object('ok', false, 'error', 'rate_limited_new');
    end if;

    insert into public.dm_threads (member_a, member_b)
    values (least(v_me, p_to_user_id), greatest(v_me, p_to_user_id))
    on conflict (member_a, member_b) do nothing
    returning id into v_thread;

    -- Somebody else won the race, or the other member opened it first between the select and here.
    if v_thread is null then
      select id into v_thread
        from public.dm_threads
       where member_a = least(v_me, p_to_user_id) and member_b = greatest(v_me, p_to_user_id);
    else
      v_new := true;
    end if;
  end if;

  if not app.check_rate_limit('dm_send:' || v_me::text, 60, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  begin
    insert into public.dm_messages (thread_id, sender_user_id, body, client_id)
    values (v_thread, v_me, v_body, btrim(p_client_id))
    returning id into v_id;
  exception
    when unique_violation then
      -- Two attempts landed at once; the other won. That is a success for this caller.
      select m.id into v_id
        from public.dm_messages m
       where m.sender_user_id = v_me and m.client_id = btrim(p_client_id);
      return jsonb_build_object('ok', true, 'thread_id', v_thread, 'message_id', v_id,
                                'duplicate', true);
  end;

  update public.dm_threads set last_message_at = now() where id = v_thread;

  -- The sender's own name, from the same place the directory takes it.
  select coalesce(nullif(btrim(p.display_name), ''), r.first_name, 'Someone') into v_name
    from public.profiles p
    left join public.responders r on r.user_id = p.user_id
   where p.user_id = v_me;

  -- NO MESSAGE BODY IN THE NOTIFICATION PARAMS.
  --
  -- The recovery thread puts a preview in, and that is defensible there: both parties are already in a
  -- recovery together and the notification goes to one of two people who know each other. A direct
  -- message can come from a stranger, and notification params are stored and rendered in more places
  -- than the thread is -- so the push payload carries who, not what. Somebody shoulder-reading a lock
  -- screen learns that a member wrote, not what they wrote.
  perform app.notify(
    p_to_user_id,
    'direct_message',
    'notify.direct_message.new',
    jsonb_build_object('name', v_name),
    '/messages/' || v_thread::text,
    array['in_app', 'push']::notification_channel[],
    'dm:' || v_id::text
  );

  return jsonb_build_object('ok', true, 'thread_id', v_thread, 'message_id', v_id,
                            'duplicate', false, 'started', v_new);
end;
$fn$;

revoke all on function public.dm_send(uuid, text, text) from public, anon;
grant execute on function public.dm_send(uuid, text, text) to authenticated, service_role;

notify pgrst, 'reload schema';
