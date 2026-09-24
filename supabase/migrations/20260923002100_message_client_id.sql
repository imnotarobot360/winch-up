-- Winch Up :: a message sent twice because the phone was not sure the first one arrived
--
-- Section 5 of the group-chat spec asks for an offline queue. The hard part of an offline queue
-- is not holding the message, it is the reconnect: the browser sent it, the response never came
-- back over one bar of signal, and the retry has no way to know whether the first attempt landed.
-- Retry too eagerly and the team sees the same line twice. Retry too carefully and "I'm at the
-- gate" never arrives at all.
--
-- The fix is an idempotency key the CLIENT generates before the first attempt, so every retry of
-- that message carries the same one. The server stores it and refuses to write a second row for
-- it. Which attempt actually won stops mattering, and the browser can retry as often as it likes.
--
-- Scoped per sender rather than globally unique. A client_id is a crypto.randomUUID() so a
-- collision between two members is not realistic, but scoping it means one member cannot suppress
-- another member's message by guessing -- and the uniqueness the feature needs is "this person
-- did not say this twice", which is exactly (sender, key).
--
-- Null is allowed and unconstrained: system messages have no client and no sender, and the older
-- rows predate the column.

set search_path = public, extensions;

alter table public.request_messages
  add column if not exists client_id uuid;

comment on column public.request_messages.client_id is
  'Idempotency key minted by the sender''s browser before the first attempt. Retries reuse it, so '
  'a reconnect cannot duplicate a message.';

create unique index if not exists request_messages_sender_client_idx
  on public.request_messages (sender_user_id, client_id)
  where client_id is not null;

-- ---------------------------------------------------------------------------
-- send_request_message
--
-- Same shape, one new optional key in the payload. A caller that does not send client_id gets
-- exactly the old behaviour.
-- ---------------------------------------------------------------------------

create or replace function public.send_request_message(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_request_id uuid := nullif(p_payload ->> 'request_id', '')::uuid;
  v_body       text := nullif(btrim(coalesce(p_payload ->> 'body', '')), '');
  v_path       text := nullif(btrim(coalesce(p_payload ->> 'attachment_path', '')), '');
  v_type       text := nullif(btrim(coalesce(p_payload ->> 'attachment_type', '')), '');
  v_client_id  uuid := nullif(p_payload ->> 'client_id', '')::uuid;
  v_request    public.requests%rowtype;
  v_role       actor_kind;
  v_existing   uuid;
  v_new_id     uuid;
begin
  if not app.is_request_participant(v_request_id) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  -- Answered before anything else that could refuse it, and deliberately before the rate limit.
  -- A retry is not a new message: the first attempt already paid for it, and a member on bad
  -- signal retrying six times must not be able to rate-limit themselves out of the conversation.
  -- It is also answered before the 'closed' check, because a message written while the recovery
  -- was live and retried after it finished did happen and is already in the thread -- telling the
  -- phone it failed would leave it queued forever.
  if v_client_id is not null then
    select id into v_existing
      from request_messages
     where sender_user_id = auth.uid()
       and client_id = v_client_id;

    if found then
      return jsonb_build_object('ok', true, 'duplicate', true, 'id', v_existing);
    end if;
  end if;

  if v_body is null and v_path is null then
    return jsonb_build_object('ok', false, 'error', 'empty');
  end if;

  if v_body is not null and length(v_body) > 2000 then
    return jsonb_build_object('ok', false, 'error', 'too_long');
  end if;

  if v_type is not null and v_type not in ('image/jpeg', 'image/png', 'image/webp') then
    return jsonb_build_object('ok', false, 'error', 'bad_attachment_type');
  end if;

  select * into v_request from public.requests where id = v_request_id;

  -- Closed jobs stop accepting messages. A thread that stays open forever is a channel between
  -- two strangers who met once, which is not what this is for; the incident report is the route
  -- if something needs saying afterwards.
  if v_request.status in ('recovered', 'cancelled', 'expired') then
    return jsonb_build_object('ok', false, 'error', 'closed');
  end if;

  if not app.check_rate_limit('message:' || auth.uid()::text, 60, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  v_role := case
              when v_request.requester_user_id = auth.uid() then 'requester'::actor_kind
              else 'responder'::actor_kind
            end;

  insert into request_messages (
    request_id, sender_user_id, sender_role, body, attachment_path, attachment_type, client_id
  ) values (
    v_request_id, auth.uid(), v_role, v_body, v_path, v_type, v_client_id
  )
  on conflict (sender_user_id, client_id) where client_id is not null do nothing
  returning id into v_new_id;

  -- The select above and this insert are not one atomic step, so two retries racing each other
  -- can both get past the lookup. The index settles it and the loser lands here with no row.
  if v_new_id is null and v_client_id is not null then
    select id into v_new_id
      from request_messages
     where sender_user_id = auth.uid()
       and client_id = v_client_id;

    return jsonb_build_object('ok', true, 'duplicate', true, 'id', v_new_id);
  end if;

  return jsonb_build_object('ok', true, 'id', v_new_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- request_thread, now returning the caller's own idempotency key
--
-- Same shape plus one field. A message from somebody else has client_id null, because it is not
-- the reader's to reconcile.
-- ---------------------------------------------------------------------------

create or replace function public.request_thread(p_request_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_rows   jsonb;
  v_team   jsonb;
  v_closed boolean;
begin
  if not app.is_request_participant(p_request_id) then
    -- The same answer whether the request does not exist, exists and belongs to somebody else, or
    -- exists and the caller was removed from it. Three different truths, one reply, so nobody can
    -- walk request ids to find out which are real.
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  select r.status in ('recovered', 'cancelled', 'expired') into v_closed
    from public.requests r where r.id = p_request_id;

  -- Per person, not per message. Moving one timestamp is what makes unread counts correct for a
  -- third participant.
  update public.recovery_participants
     set last_read_at = now()
   where request_id = p_request_id and user_id = auth.uid() and left_at is null;

  select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at), '[]'::jsonb) into v_rows
  from (
    select
      msg.id,
      msg.sender_role,
      msg.body,
      msg.attachment_path,
      msg.attachment_type,
      msg.created_at,
      (msg.sender_user_id = auth.uid()) as mine,
      -- Their own key only. The browser holds unsent messages keyed by this, and needs to know
      -- which of them the server already has before it decides what to draw as pending.
      (case when msg.sender_user_id = auth.uid() then msg.client_id end) as client_id,
      -- Who said it. A first name only: this is a group now, and "responder" is not a name when
      -- there are two of them. Null for a system message, which renders differently.
      (select coalesce(pr.display_name, resp.first_name)
         from public.recovery_participants rp
         left join public.profiles   pr   on pr.user_id = rp.user_id
         left join public.responders resp on resp.id    = rp.responder_id
        where rp.request_id = msg.request_id
          and rp.user_id is not distinct from msg.sender_user_id
        limit 1) as sender_name
      from public.request_messages msg
     where msg.request_id = p_request_id
     order by msg.created_at
     limit 500
  ) m;

  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id',   p.user_id,
           'role',      p.role,
           'status',    p.status,
           'name',      coalesce(pr.display_name, resp.first_name),
           'vehicle',   resp.vehicle_desc,
           'equipment', resp.equipment,
           'joined_at', p.joined_at,
           'is_me',     p.user_id = auth.uid()
         ) order by p.role desc, p.joined_at), '[]'::jsonb) into v_team
    from public.recovery_participants p
    left join public.profiles   pr   on pr.user_id = p.user_id
    left join public.responders resp on resp.id    = p.responder_id
   where p.request_id = p_request_id and p.left_at is null;

  return jsonb_build_object(
    'ok', true,
    'messages', v_rows,
    'team', v_team,
    -- Spec section 10: a finished recovery keeps its history and stops accepting new messages.
    'read_only', coalesce(v_closed, false)
  );
end;
$fn$;
