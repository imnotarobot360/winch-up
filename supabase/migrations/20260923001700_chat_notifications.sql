-- Winch Up :: telling the team, and the preferences that govern it
--
-- Three things here: chat messages notify the rest of the team, the single notify_recovery switch
-- splits into the ones spec section 8 asks for, and the push sender finally gets a deep link.
--
-- ON DEEP LINKS, AND A RULE I ALMOST INVENTED
--
-- The team notifications below point at /recovery/<request_id>, which recovery_link() resolves
-- server-side for a participant and refuses to everybody else. A request id is not a capability:
-- it is already in the status payload, and access is decided by asking who you are.
--
-- I first wrote this up as fixing a leak, on the grounds that a status token should never sit in
-- notifications.url. That was wrong, and worth recording so nobody re-derives it. Phase 13's
-- producers have written '/r/' || public_token there since 20260922003000, and it is fine: a
-- notification about your own recovery, in your own authenticated list, carrying your own link.
-- A test asserting "no notification anywhere carries a token" failed with five, and those five
-- were correct. The assertion was the thing that was wrong.
--
-- So an id here is a small preference -- nothing needs the token to say "Mike is on site" -- not
-- a correction of working code.
--
-- THE ACTUAL BUG, FOUND WHILE CHECKING THAT
--
-- claim_push_deliveries returned n.params, and src/lib/push/send.ts reads params.url to decide
-- where a notification opens. app.notify does not put the url in params; it has its own column.
-- That key has therefore never existed, and every push notification would have opened /me.
-- Section 6 below fixes it. It went unnoticed because push has never run in production -- no
-- VAPID keys, drain reports skipped -- and my one end-to-end test checked that a payload arrived
-- rather than where it pointed.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. The preferences section 8 asks for
-- ---------------------------------------------------------------------------
--
-- notify_recovery was one switch covering "somebody near you is stuck", "your recovery changed"
-- and, from today, "somebody sent a message". Those are not one preference: a member happy to be
-- told their own recovery was cancelled may not want a buzz for every line of chatter.
--
-- Both default true. They are operational, not marketing, and they only reach people already
-- involved in a recovery. notify_marketing remains the only one that defaults off.

alter table public.profiles
  add column if not exists notify_chat            boolean not null default true,
  add column if not exists notify_recovery_status boolean not null default true;

comment on column public.profiles.notify_chat is
  'Messages in a recovery conversation. Separate from notify_recovery_status so somebody can '
  'silence chatter without missing that their recovery was cancelled.';

comment on column public.profiles.notify_recovery_status is
  'The recovery itself changing: a helper joining, arriving, withdrawing, the job being cancelled '
  'or completed.';

-- ---------------------------------------------------------------------------
-- 2. Consent, per kind
-- ---------------------------------------------------------------------------
--
-- Rewritten from 20260922002500 with two branches added. Everything else is as it was: in_app is
-- always written because it is the record of what happened rather than an interruption, and
-- marketing is still the only kind that defaults to no.

create or replace function app.notify(
  p_user_id   uuid,
  p_kind      notification_kind,
  p_title_key text,
  p_params    jsonb default '{}'::jsonb,
  p_url       text default null,
  p_channels  notification_channel[] default array['in_app']::notification_channel[],
  p_dedupe    text default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_id      uuid;
  v_profile public.profiles%rowtype;
  v_allowed boolean;
  v_channel notification_channel;
  v_key     text;
begin
  if p_user_id is null then
    return null;
  end if;

  select * into v_profile from public.profiles where user_id = p_user_id;

  insert into public.notifications (user_id, kind, title_key, params, url)
  values (p_user_id, p_kind, p_title_key, coalesce(p_params, '{}'::jsonb), p_url)
  returning id into v_id;

  foreach v_channel in array coalesce(p_channels, array['in_app']::notification_channel[])
  loop
    v_allowed := case
      when p_kind = 'marketing' then coalesce(v_profile.notify_marketing, false)
      when p_kind = 'community' or p_kind = 'event_reminder'
        then coalesce(v_profile.notify_community, true)
      -- The in-app record is always written. It is what happened; the switches govern whether a
      -- phone buzzes about it.
      when v_channel = 'in_app' then true
      -- Chatter.
      when p_kind = 'message' then coalesce(v_profile.notify_chat, true)
      -- The recovery itself moving: somebody joined, arrived, withdrew, it was cancelled.
      when p_kind in ('recovery_status', 'helper_joined', 'helper_status')
        then coalesce(v_profile.notify_recovery_status, true)
      else coalesce(v_profile.notify_recovery, true)
    end;

    v_key := coalesce(p_dedupe || ':' || v_channel::text, v_id::text || ':' || v_channel::text);

    insert into public.notification_deliveries (notification_id, channel, state, dedupe_key)
    values (
      v_id, v_channel,
      case when v_allowed then 'queued'::delivery_state else 'suppressed'::delivery_state end,
      v_key
    )
    on conflict (dedupe_key) do nothing;
  end loop;

  return v_id;
end;
$fn$;

revoke all on function app.notify(uuid, notification_kind, text, jsonb, text,
                                  notification_channel[], text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. A message tells the rest of the team
-- ---------------------------------------------------------------------------
--
-- A trigger, not a line in send_request_message, for the reason CLAUDE.md already gives about
-- notification producers: the message row is the event, and anything that writes one -- the RPC
-- today, an admin tool tomorrow -- should notify without having to remember to.
--
-- Who does NOT get told: the sender, anybody who has left, and anybody who muted this recovery.
-- System lines have no sender, so they notify everybody still on the team, which is right --
-- "Mike can no longer make it" is exactly what the others need to know.

create or replace function app.notify_on_recovery_message()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_other  record;
  v_name   text;
  v_body   text;
begin
  select coalesce(pr.display_name, resp.first_name) into v_name
    from public.recovery_participants p
    left join public.profiles   pr   on pr.user_id = p.user_id
    left join public.responders resp on resp.id    = p.responder_id
   where p.request_id = new.request_id
     and p.user_id is not distinct from new.sender_user_id
   limit 1;

  -- The first few words, so a notification says something. Never the whole message: it is
  -- rendered on a lock screen, and a recovery conversation carries gate codes and positions.
  v_body := left(coalesce(new.body, ''), 60);

  for v_other in
    select p.user_id
      from public.recovery_participants p
     where p.request_id = new.request_id
       and p.left_at is null
       and p.user_id is not null
       and p.user_id is distinct from new.sender_user_id
       and not p.muted
  loop
    perform app.notify(
      v_other.user_id,
      'message',
      'notify.message.recovery',
      jsonb_build_object('name', coalesce(v_name, 'Someone'), 'preview', v_body),
      '/recovery/' || new.request_id::text,
      array['in_app', 'push']::notification_channel[],
      'msg:' || new.id::text || ':' || v_other.user_id::text
    );
  end loop;

  return new;
end;
$fn$;

drop trigger if exists request_messages_notify on public.request_messages;
create trigger request_messages_notify
  after insert on public.request_messages
  for each row execute function app.notify_on_recovery_message();

-- ---------------------------------------------------------------------------
-- 4. The two deep links that carried a token
-- ---------------------------------------------------------------------------
--
-- Same functions as 20260923001400, with the URL changed and nothing else. Spelled out as full
-- replacements rather than a clever UPDATE on pg_proc, because a function body is code.

create or replace function public.set_my_participant_status(
  p_request_id uuid,
  p_status     text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_uid    uuid := auth.uid();
  v_status participant_status;
  v_me     public.recovery_participants%rowtype;
  v_name   text;
  v_other  record;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  begin
    v_status := p_status::participant_status;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'bad_status');
  end;

  if v_status = 'withdrawn' then
    return jsonb_build_object('ok', false, 'error', 'use_withdraw');
  end if;

  select * into v_me
    from public.recovery_participants
   where request_id = p_request_id and user_id = v_uid and left_at is null;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if v_me.role <> 'helper' then
    return jsonb_build_object('ok', false, 'error', 'not_a_helper');
  end if;

  if exists (select 1 from public.requests
              where id = p_request_id and status in ('recovered', 'cancelled', 'expired')) then
    return jsonb_build_object('ok', false, 'error', 'already_closed');
  end if;

  if v_me.status = v_status then
    return jsonb_build_object('ok', true, 'unchanged', true);
  end if;

  update public.recovery_participants
     set status = v_status, status_at = now()
   where id = v_me.id;

  select coalesce(pr.display_name, resp.first_name, 'A helper') into v_name
    from public.recovery_participants p
    left join public.profiles   pr   on pr.user_id = p.user_id
    left join public.responders resp on resp.id    = p.responder_id
   where p.id = v_me.id;

  if v_status = 'on_site' then
    update public.requests
       set status = 'on_site', on_site_at = coalesce(on_site_at, now())
     where id = p_request_id and status = 'accepted';
  end if;

  insert into public.request_events (request_id, event_type, actor_kind, actor_responder_id,
                                     data, is_public)
  values (p_request_id, 'helper_status', 'responder', v_me.responder_id,
          jsonb_build_object('status', v_status), false);

  insert into public.request_messages (request_id, sender_user_id, sender_role, body)
  values (p_request_id, null, 'system', v_name || ' is now ' || replace(v_status::text, '_', ' '));

  for v_other in
    select p.user_id from public.recovery_participants p
     where p.request_id = p_request_id and p.left_at is null
       and p.user_id is not null and p.user_id <> v_uid and not p.muted
  loop
    perform app.notify(
      v_other.user_id, 'helper_status', 'notify.request.helper_status',
      jsonb_build_object('name', v_name, 'status', v_status::text),
      '/recovery/' || p_request_id::text,
      array['in_app', 'push']::notification_channel[],
      'helper-status:' || v_me.id::text || ':' || v_status::text
    );
  end loop;

  return jsonb_build_object('ok', true, 'status', v_status);
end;
$fn$;

revoke all on function public.set_my_participant_status(uuid, text) from public, anon;
grant execute on function public.set_my_participant_status(uuid, text) to authenticated, service_role;

create or replace function public.withdraw_from_recovery(p_request_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_me    public.recovery_participants%rowtype;
  v_name  text;
  v_other record;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  select * into v_me
    from public.recovery_participants
   where request_id = p_request_id and user_id = v_uid and left_at is null;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if v_me.role = 'requester' then
    return jsonb_build_object('ok', false, 'error', 'requester_cannot_withdraw');
  end if;

  select coalesce(pr.display_name, resp.first_name, 'A helper') into v_name
    from public.recovery_participants p
    left join public.profiles   pr   on pr.user_id = p.user_id
    left join public.responders resp on resp.id    = p.responder_id
   where p.id = v_me.id;

  update public.recovery_participants
     set left_at = now(), status = 'withdrawn', status_at = now()
   where id = v_me.id;

  insert into public.request_events (request_id, event_type, actor_kind, actor_responder_id,
                                     data, is_public)
  values (p_request_id, 'helper_withdrew', 'responder', v_me.responder_id, '{}'::jsonb, false);

  insert into public.request_messages (request_id, sender_user_id, sender_role, body)
  values (p_request_id, null, 'system', v_name || ' can no longer make it');

  for v_other in
    select p.user_id from public.recovery_participants p
     where p.request_id = p_request_id and p.left_at is null
       and p.user_id is not null and p.user_id <> v_uid
  loop
    perform app.notify(
      v_other.user_id, 'recovery_status', 'notify.request.helper_withdrew',
      jsonb_build_object('name', v_name),
      '/recovery/' || p_request_id::text,
      array['in_app', 'push']::notification_channel[],
      'helper-withdrew:' || v_me.id::text
    );
  end loop;

  perform app.sync_recovery_lead(p_request_id);

  return jsonb_build_object('ok', true);
end;
$fn$;

revoke all on function public.withdraw_from_recovery(uuid) from public, anon;
grant execute on function public.withdraw_from_recovery(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Resolving a deep link
-- ---------------------------------------------------------------------------
--
-- Turns a request id into the caller's own status token, for a participant, and answers nothing
-- to anybody else. This is what lets a notification carry an id instead of a token.

create or replace function public.recovery_link(p_request_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
begin
  if not app.is_request_participant(p_request_id) then
    -- Same answer for "no such recovery" and "not yours", so ids cannot be walked.
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', (select public_token from public.requests where id = p_request_id)
  );
end;
$fn$;

revoke all on function public.recovery_link(uuid) from public, anon;
grant execute on function public.recovery_link(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. The push sender was never given the deep link
-- ---------------------------------------------------------------------------
--
-- claim_push_deliveries returned n.params, and src/lib/push/send.ts reads `params.url` to decide
-- where tapping a notification should land. app.notify does not put the url in params -- it has
-- its own column, notifications.url -- so that key has never existed and every push notification
-- ever sent would have opened /me.
--
-- Nobody noticed because push has never been enabled in production: the VAPID keys are not set,
-- the drain reports skipped, and the one end-to-end test I ran checked that a payload arrived
-- rather than where it pointed. Spec section 5 asks for a deep link to the relevant recovery, and
-- this is the line that makes that true.
--
-- Same shape as 20260923000400 with one column added to the return.
--
-- DROP FIRST, and it is not optional. `create or replace function` refuses to change a function's
-- return type, and adding `url` to a RETURNS TABLE is exactly that:
--
--     ERROR:  cannot change return type of existing function
--
-- This file applied cleanly against a database that had already been through it, and failed on
-- production, which still had the 20260923000400 version. Because it is the LAST object in a
-- 465-line file, everything above it landed and the verification query reported "1 of 6 missing"
-- -- which reads like a truncated paste rather than a statement that cannot succeed.
--
-- Nothing depends on this function's signature except src/lib/push/send.ts, which is deployed
-- separately and reads the columns by name, so dropping and recreating it costs nothing. The
-- grant below is re-issued because a drop takes the privileges with it.
drop function if exists public.claim_push_deliveries(integer);

create or replace function public.claim_push_deliveries(p_limit integer default 100)
returns table (
  delivery_id     uuid,
  subscription_id uuid,
  endpoint        text,
  p256dh          text,
  auth            text,
  kind            notification_kind,
  title_key       text,
  params          jsonb,
  locale          text,
  url             text
)
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
begin
  return query
  with due as (
    select d.id
      from public.notification_deliveries d
     where d.channel = 'push'
       and d.state in ('queued', 'failed')
       and d.attempts < 3
       and d.next_attempt_at <= now()
     order by d.created_at
     limit greatest(1, least(coalesce(p_limit, 100), 500))
     for update of d skip locked
  ),
  bumped as (
    update public.notification_deliveries d
       set attempts = d.attempts + 1, updated_at = now()
      from due
     where d.id = due.id
     returning d.id, d.notification_id
  )
  select
    b.id, s.id, s.endpoint, s.p256dh, s.auth,
    n.kind, n.title_key, n.params,
    coalesce((select r.locale from public.responders r where r.user_id = n.user_id), 'en'),
    n.url
  from bumped b
  join public.notifications n on n.id = b.notification_id
  join public.push_subscriptions s on s.user_id = n.user_id;
end;
$fn$;

revoke all on function public.claim_push_deliveries(integer) from public, anon, authenticated;
grant execute on function public.claim_push_deliveries(integer) to service_role;
