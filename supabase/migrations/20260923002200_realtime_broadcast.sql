-- Winch Up :: the socket that makes a message appear, without opening the table it came from
--
-- The obvious way to do realtime chat on Supabase is postgres_changes on request_messages. It
-- does not work here, and finding out why is worth writing down, because the wrong fix is easy
-- and quiet.
--
-- postgres_changes authorises each subscriber by running the table's RLS as that member. But
-- request_messages has NO policy and NO grant to authenticated -- it is deny-by-default and is
-- served entirely through public.request_thread(), a security definer RPC that shapes what a
-- participant may see (a first name instead of a user id, no read receipts, the caller's own
-- idempotency key and nobody else's). Confirmed by reading pg_policies and
-- role_table_grants: authenticated has nothing on that table at all.
--
-- So a postgres_changes subscription would connect, report SUBSCRIBED, and deliver nothing,
-- forever. It would look like a working feature.
--
-- The tempting fix is a SELECT policy on request_messages. That is the wrong trade: it makes the
-- raw table readable through PostgREST as well, which hands every participant the sender_user_id
-- of everyone else on the recovery -- exactly what the RPC goes to the trouble of not returning.
-- Widening a table's access so that a transport can authorise itself is how a careful design gets
-- undone by a convenience.
--
-- Broadcast instead. A trigger sends a nudge to a topic, the client hears the nudge and re-reads
-- the thread through the RPC. Three consequences, all of them wanted:
--
--   * The payload carries no message content. Not the body, not who wrote it -- only the request
--     id, which the subscriber already had in order to be listening. Even if the authorisation
--     below were wrong, there is nothing in the event to leak.
--   * Authorisation is app.is_request_participant(), the same one function that guards the thread,
--     the team panel and every participant action. One rule, one place to get right.
--   * request_messages stays shut.
--
-- The poll in the component remains the floor and is not optional. This whole file is an
-- accelerator: if it never fires, messages arrive in fifteen seconds instead of instantly.
--
-- UNVERIFIED LOCALLY, DELIBERATELY. The no-Docker local stack is PostgREST plus an auth shim and
-- has no realtime schema at all, so everything here is wrapped in an existence check and is a
-- no-op there. That means the socket path is proven only against a real Supabase project. It is
-- built so that being wrong about it costs latency and nothing else.

set search_path = public, extensions;

do $do$
begin
  if not exists (select 1 from pg_namespace where nspname = 'realtime') then
    raise notice 'no realtime schema (local stack) -- broadcast skipped, polling carries the thread';
    return;
  end if;

  -- ---------------------------------------------------------------------------
  -- Who may listen on a recovery topic
  --
  -- Topics are 'recovery:<request uuid>'. The shape is checked with a regex BEFORE the cast,
  -- because a policy that raises on a malformed topic is a policy that can be made to error
  -- rather than to refuse.
  -- ---------------------------------------------------------------------------
  execute $p$
    drop policy if exists recovery_broadcast_listen on realtime.messages;
  $p$;

  execute $p$
    create policy recovery_broadcast_listen on realtime.messages
      for select to authenticated
      using (
        realtime.topic() ~ '^recovery:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        and app.is_request_participant(substring(realtime.topic() from 10)::uuid)
      );
  $p$;

  -- Nobody writes to a recovery topic from a browser. The only sender is the trigger below,
  -- which runs as the definer and is not subject to this. A member who could broadcast could put
  -- words on other people's screens.
  execute $p$
    drop policy if exists recovery_broadcast_no_client_send on realtime.messages;
  $p$;
end
$do$;

-- ---------------------------------------------------------------------------
-- The nudge
-- ---------------------------------------------------------------------------

create or replace function app.broadcast_recovery_change()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_request_id uuid := coalesce(new.request_id, old.request_id);
begin
  if to_regprocedure('realtime.send(jsonb, text, text, boolean)') is null then
    return coalesce(new, old);
  end if;

  -- Wrapped: a realtime outage must not be able to fail the insert that a member is waiting on.
  -- Losing the nudge costs up to fifteen seconds. Losing the message loses the message.
  begin
    perform realtime.send(
      jsonb_build_object('request_id', v_request_id),
      'changed',
      'recovery:' || v_request_id::text,
      true
    );
  exception when others then
    null;
  end;

  return coalesce(new, old);
end;
$$;

drop trigger if exists request_messages_broadcast on public.request_messages;
create trigger request_messages_broadcast
  after insert on public.request_messages
  for each row execute function app.broadcast_recovery_change();

-- A helper joining, arriving or dropping out changes the roster the thread renders, so the same
-- nudge covers it. Same payload, same topic, same reload on the other end.
drop trigger if exists recovery_participants_broadcast on public.recovery_participants;
create trigger recovery_participants_broadcast
  after insert or update on public.recovery_participants
  for each row execute function app.broadcast_recovery_change();

comment on function app.broadcast_recovery_change() is
  'Tells a recovery''s participants that something changed, carrying only the request id. The '
  'content is re-read through request_thread(), so the socket never becomes a second, less '
  'careful way to read a conversation.';
