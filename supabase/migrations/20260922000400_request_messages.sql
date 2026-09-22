-- Winch Up :: messages between the two people on a recovery
--
-- Phase 7. One conversation per request, between the person who is stuck and the volunteer who
-- took the job. Nobody else, ever.
--
-- The design decision that shapes the rest:
--
--   MESSAGING REQUIRES A SIGNED-IN ACCOUNT. It is NOT reachable with the status token.
--
-- Every other requester action -- cancel, mark recovered, say thanks, report an incident -- works
-- with the token, because somebody pulled out of a ditch may be on a borrowed phone. But the
-- status link is deliberately shareable: the requester sends it to family so they can watch. A
-- conversation reachable by that token would be readable by anyone the link was forwarded to,
-- and that conversation contains a phone number and an exact location.
--
-- So this one is the exception, and it is the exception on purpose.
--
-- Access is derived, never stored. There is no participant list to get out of step with reality:
-- you are in the conversation if you are the request's requester_user_id, or the user behind its
-- accepted_responder_id. Change the accepted responder and the conversation follows.

set search_path = public, extensions;

create table request_messages (
  id            uuid primary key default gen_random_uuid(),
  request_id    uuid not null references requests (id) on delete cascade,

  -- Nullable so deleting an account does not delete the conversation the other person still
  -- needs. sender_role survives and is what the UI renders from.
  sender_user_id uuid references auth.users (id) on delete set null,
  sender_role    actor_kind not null,

  body          text check (
                  body is null
                  or length(btrim(body)) between 1 and 2000
                ),

  -- Private bucket, signed URLs only, same as recovery photos.
  attachment_path text,
  attachment_type text check (
                    attachment_type is null
                    or attachment_type in ('image/jpeg', 'image/png', 'image/webp')
                  ),

  -- Two participants, so one column is enough. Set when the other party reads the thread.
  read_at       timestamptz,
  created_at    timestamptz not null default now(),

  -- A message with neither text nor a picture is not a message.
  constraint request_messages_has_content check (body is not null or attachment_path is not null)
);

create index request_messages_thread_idx on request_messages (request_id, created_at);

comment on table request_messages is
  'One thread per request, between the requester and the accepted responder. Requires a signed-in '
  'account -- deliberately NOT reachable with the status token, which is shareable by design.';

-- Deliberately NOT applying contains_contact_info() to the body. These two people already have
-- each other's phone numbers -- the whole point of acceptance is that they were exchanged. This
-- is a private thread between them, not a public surface.

-- ---------------------------------------------------------------------------
-- No table access. Everything goes through functions that derive participation.
-- ---------------------------------------------------------------------------

alter table request_messages enable row level security;
revoke all on request_messages from anon, authenticated;

create or replace function app.is_request_participant(p_request_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  select exists (
    select 1
      from public.requests r
      left join public.responders resp on resp.id = r.accepted_responder_id
     where r.id = p_request_id
       and auth.uid() is not null
       and (r.requester_user_id = auth.uid() or resp.user_id = auth.uid())
  );
$$;

-- ---------------------------------------------------------------------------
-- Reading the thread
-- ---------------------------------------------------------------------------

create or replace function public.request_thread(p_request_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_rows jsonb;
begin
  if not app.is_request_participant(p_request_id) then
    -- Same answer whether the request does not exist or belongs to somebody else. A different
    -- message would let a signed-in user walk request ids to discover which are real.
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  -- Reading marks the other side's messages read. Two participants, so "not mine" is enough.
  update request_messages
     set read_at = now()
   where request_id = p_request_id
     and read_at is null
     and sender_user_id is distinct from auth.uid();

  select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at), '[]'::jsonb) into v_rows
  from (
    select id, sender_role, body, attachment_path, attachment_type, read_at, created_at,
           (sender_user_id = auth.uid()) as mine
      from request_messages
     where request_id = p_request_id
     order by created_at
     limit 500
  ) m;

  return jsonb_build_object('ok', true, 'messages', v_rows);
end;
$$;

-- ---------------------------------------------------------------------------
-- Sending
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
  v_request    public.requests%rowtype;
  v_role       actor_kind;
begin
  if not app.is_request_participant(v_request_id) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
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
    request_id, sender_user_id, sender_role, body, attachment_path, attachment_type
  ) values (
    v_request_id, auth.uid(), v_role, v_body, v_path, v_type
  );

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.request_thread(uuid) from public, anon;
grant execute on function public.request_thread(uuid) to authenticated;

revoke all on function public.send_request_message(jsonb) from public, anon;
grant execute on function public.send_request_message(jsonb) to authenticated;
