-- Winch Up :: the conversation becomes a group, without becoming public
--
-- This is the security work of the phase. request_messages has no grants and no policies at all
-- -- the table is unreachable from PostgREST -- so access is decided by exactly one function,
-- app.is_request_participant(). Widening it from two people to a team is the whole risk: get it
-- wrong and private recovery conversations are readable by anyone signed in who can guess a
-- request id, which is spec section 9's explicit warning.
--
-- WHAT CHANGES
--
--   before   requester, or the single responder on requests.accepted_responder_id
--   after    anybody with a live row in recovery_participants for that request
--
-- "Live" means left_at is null. A helper who withdrew keeps their history and stops receiving
-- what is said next; that distinction is the reason the table records a leaving time instead of
-- deleting the row.
--
-- READ TRACKING HAD TO CHANGE TOO
--
-- The old version marked every message not sent by the reader as read, with the comment "two
-- participants, so not mine is enough". With three people that is wrong in a way that matters: A
-- opening the thread would mark C's unread messages as read for B. Unread is now per person,
-- from recovery_participants.last_read_at, which is also cheaper than a receipt row per message
-- per participant.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- Every request has a requester participant, from the moment it exists
-- ---------------------------------------------------------------------------
--
-- Without this a request created after this migration has an empty team and its own author cannot
-- read the conversation attached to it. The backfill in 20260923001100 handled the ones that
-- already existed; this handles every one from now on.

create or replace function app.add_requester_participant()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $fn$
begin
  if new.requester_user_id is not null then
    insert into public.recovery_participants (request_id, user_id, role, status)
    values (new.id, new.requester_user_id, 'requester', 'accepted')
    on conflict do nothing;
  end if;
  return new;
end;
$fn$;

drop trigger if exists requests_add_requester_participant on public.requests;
create trigger requests_add_requester_participant
  after insert on public.requests
  for each row execute function app.add_requester_participant();

-- ---------------------------------------------------------------------------
-- The gate
-- ---------------------------------------------------------------------------

create or replace function app.is_request_participant(p_request_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
  select exists (
    select 1
      from public.recovery_participants p
     where p.request_id = p_request_id
       and p.user_id = auth.uid()
       and p.left_at is null
       -- Spelled out rather than relying on `null = null` being null: this function is the only
       -- thing standing between a signed-out caller and every private recovery conversation.
       and auth.uid() is not null
  );
$fn$;

revoke all on function app.is_request_participant(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Reading the thread
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

revoke all on function public.request_thread(uuid) from public, anon;
grant execute on function public.request_thread(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Unread, for the bell and the tab badge
-- ---------------------------------------------------------------------------

create or replace function public.my_unread_counts()
returns table (request_id uuid, short_code text, unread integer)
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
  select
    p.request_id,
    r.short_code,
    (select count(*)::integer
       from public.request_messages m
      where m.request_id = p.request_id
        and m.sender_user_id is distinct from auth.uid()
        and (p.last_read_at is null or m.created_at > p.last_read_at))
  from public.recovery_participants p
  join public.requests r on r.id = p.request_id
  where p.user_id = auth.uid()
    and auth.uid() is not null
    and p.left_at is null
    and not p.muted
  order by r.created_at desc
  limit 50;
$fn$;

revoke all on function public.my_unread_counts() from public, anon;
grant execute on function public.my_unread_counts() to authenticated, service_role;
