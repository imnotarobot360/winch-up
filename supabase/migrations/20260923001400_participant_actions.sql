-- Winch Up :: what a helper can say about themselves
--
-- Spec section 4: helpers update their own status, the requester sees the team's, and the chat
-- shows a system line when somebody joins, withdraws or moves.
--
-- WHY STATUS LIVES ON THE PARTICIPANT AND NOT THE REQUEST
--
-- requests.status is the recovery: submitted, dispatching, accepted, on_site, recovered. That
-- worked when one person was coming, because their state and the recovery's state were the same
-- sentence. With a team they are not: a winch truck can be on site while a tractor is still
-- loading, and neither fact is "the recovery is on_site".
--
-- So the request keeps its own status, and each helper carries theirs. The request moves to
-- on_site when the FIRST helper arrives, which is the honest reading of "somebody is there" and
-- keeps every existing timeline, SMS template and status page working unchanged.
--
-- WHAT A HELPER MAY NOT DO
--
-- Set somebody else's status, set their own to withdrawn through this path (there is a function
-- for leaving, and it does more), or touch a recovery that is over. Each of those is refused in
-- the database rather than hidden in the UI.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- A helper saying where they have got to
-- ---------------------------------------------------------------------------

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

  -- Cast defensively: an unknown label from a stale client should be a refusal, not a 500.
  begin
    v_status := p_status::participant_status;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'bad_status');
  end;

  if v_status = 'withdrawn' then
    -- Leaving is not a status change. It revokes access and may hand the lead to somebody else,
    -- so it has its own function and its own consequences.
    return jsonb_build_object('ok', false, 'error', 'use_withdraw');
  end if;

  select * into v_me
    from public.recovery_participants
   where request_id = p_request_id and user_id = v_uid and left_at is null;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if v_me.role <> 'helper' then
    -- The requester is not travelling anywhere; their state is the recovery's state.
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

  -- The first helper to arrive moves the recovery itself. Later arrivals do not move it back.
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

  -- Everybody else on the recovery hears about it. Not the person who did it.
  for v_other in
    select p.user_id from public.recovery_participants p
     where p.request_id = p_request_id and p.left_at is null
       and p.user_id is not null and p.user_id <> v_uid and not p.muted
  loop
    perform app.notify(
      v_other.user_id, 'helper_status', 'notify.request.helper_status',
      jsonb_build_object('name', v_name, 'status', v_status::text),
      '/r/' || (select public_token from public.requests where id = p_request_id),
      array['in_app', 'push']::notification_channel[],
      'helper-status:' || v_me.id::text || ':' || v_status::text
    );
  end loop;

  return jsonb_build_object('ok', true, 'status', v_status);
end;
$fn$;

revoke all on function public.set_my_participant_status(uuid, text) from public, anon;
grant execute on function public.set_my_participant_status(uuid, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Leaving
-- ---------------------------------------------------------------------------
--
-- A volunteer who cannot come any more must be able to say so, and the person in the ditch must
-- find out immediately rather than by waiting. This is the honest counterpart to offering: the
-- app should make leaving easy, because the alternative is somebody who never arrives and never
-- says why.

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
    -- The person who is stuck cannot leave their own recovery; they cancel it, which tells
    -- everybody who was coming to turn round.
    return jsonb_build_object('ok', false, 'error', 'requester_cannot_withdraw');
  end if;

  select coalesce(pr.display_name, resp.first_name, 'A helper') into v_name
    from public.recovery_participants p
    left join public.profiles   pr   on pr.user_id = p.user_id
    left join public.responders resp on resp.id    = p.responder_id
   where p.id = v_me.id;

  -- left_at is what every access check reads. The row stays: it is the record of who was there.
  update public.recovery_participants
     set left_at = now(), status = 'withdrawn', status_at = now()
   where id = v_me.id;

  insert into public.request_events (request_id, event_type, actor_kind, actor_responder_id,
                                     data, is_public)
  values (p_request_id, 'helper_withdrew', 'responder', v_me.responder_id, '{}'::jsonb, false);

  insert into public.request_messages (request_id, sender_user_id, sender_role, body)
  values (p_request_id, null, 'system', v_name || ' can no longer make it');

  -- Notify before the lead is recomputed, so the message is about the person who left.
  for v_other in
    select p.user_id from public.recovery_participants p
     where p.request_id = p_request_id and p.left_at is null
       and p.user_id is not null and p.user_id <> v_uid
  loop
    perform app.notify(
      v_other.user_id, 'recovery_status', 'notify.request.helper_withdrew',
      jsonb_build_object('name', v_name),
      '/r/' || (select public_token from public.requests where id = p_request_id),
      array['in_app', 'push']::notification_channel[],
      'helper-withdrew:' || v_me.id::text
    );
  end loop;

  -- Hands the lead on, or -- if that was the last helper -- puts the request back to unmatched so
  -- it reappears on /help instead of leaving somebody on a page that says help is coming.
  perform app.sync_recovery_lead(p_request_id);

  return jsonb_build_object('ok', true);
end;
$fn$;

revoke all on function public.withdraw_from_recovery(uuid) from public, anon;
grant execute on function public.withdraw_from_recovery(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Muting one recovery
-- ---------------------------------------------------------------------------
--
-- Spec section 7. Separate from the account-level preference on purpose: "stop pinging me about
-- this one" is a different request from "stop pinging me". Muting silences chatter, and
-- deliberately does NOT silence the recovery's own status changes -- somebody who muted a busy
-- thread still needs to know it was cancelled.

create or replace function public.set_recovery_mute(p_request_id uuid, p_muted boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_hit integer;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  update public.recovery_participants
     set muted = coalesce(p_muted, false)
   where request_id = p_request_id and user_id = v_uid and left_at is null;

  get diagnostics v_hit = row_count;
  if v_hit = 0 then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object('ok', true, 'muted', coalesce(p_muted, false));
end;
$fn$;

revoke all on function public.set_recovery_mute(uuid, boolean) from public, anon;
grant execute on function public.set_recovery_mute(uuid, boolean) to authenticated, service_role;
