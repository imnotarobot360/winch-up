-- Winch Up :: assigning somebody puts them on the team
--
-- 20260923001200 moved the conversation's access rule onto recovery_participants. Nothing yet
-- creates a helper's row, so five assertions in messages_test and lifecycle_test went red the
-- moment it landed: a volunteer was assigned to a recovery and then refused entry to its
-- conversation. Correct refusal, missing membership.
--
-- WHY A TRIGGER AND NOT A LINE IN assign_responder
--
-- Three code paths set requests.accepted_responder_id -- app.assign_responder, admin reassign,
-- and app.sync_recovery_lead -- and a fourth will be added by somebody who does not read this
-- file. Membership follows the column wherever it is written, so there is one rule instead of
-- three copies that can drift.
--
-- No recursion: this trigger writes recovery_participants, and sync_recovery_lead writes
-- requests. The cycle would need a participants trigger that writes requests, and there is none.
--
-- HANDOVER
--
-- If the lead changes from one person to a different one, the person it moved away from is off
-- the job -- that is what an admin reassign means, and messages_test has asserted it since Phase
-- 7. Growing a team does not trip this: adding a second helper leaves the lead alone, because
-- sync_recovery_lead keeps the FIRST helper as lead.

set search_path = public, extensions;

create or replace function app.sync_lead_participant()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_user uuid;
  v_old  uuid;
begin
  -- A request can arrive with a volunteer already on it -- admin intake does that, and so do
  -- several test fixtures -- so this fires on INSERT as well as UPDATE. OLD is unassigned during
  -- an INSERT trigger and referencing it raises, hence the branch rather than a coalesce.
  if tg_op = 'INSERT' then
    v_old := null;
  else
    v_old := old.accepted_responder_id;
  end if;

  if new.accepted_responder_id is not distinct from v_old then
    return new;
  end if;

  -- Handover: whoever it moved away from stops being on the recovery. Already-left rows are
  -- untouched, so the ordinary case of a lead changing because somebody withdrew is a no-op here.
  if v_old is not null then
    update public.recovery_participants
       set left_at = now(), status = 'withdrawn'
     where request_id = new.id
       and responder_id = v_old
       and role = 'helper'
       and left_at is null;
  end if;

  if new.accepted_responder_id is null then
    return new;
  end if;

  select user_id into v_user
    from public.responders where id = new.accepted_responder_id;

  -- A legacy responder with no account cannot be a chat participant -- there is nobody to
  -- authenticate as. They are still the assigned volunteer and still get the SMS handoff; they
  -- simply have no seat in a conversation that only exists for signed-in members.
  if v_user is null then
    return new;
  end if;

  insert into public.recovery_participants (request_id, user_id, responder_id, role, status)
  values (new.id, v_user, new.accepted_responder_id, 'helper', 'accepted')
  on conflict (request_id, user_id) where user_id is not null
    do update set left_at      = null,
                  status       = case when public.recovery_participants.status = 'withdrawn'
                                      then 'accepted'
                                      else public.recovery_participants.status end,
                  responder_id = excluded.responder_id;

  return new;
end;
$fn$;

drop trigger if exists requests_sync_lead_participant on public.requests;
create trigger requests_sync_lead_participant
  after insert or update of accepted_responder_id on public.requests
  for each row execute function app.sync_lead_participant();

-- ---------------------------------------------------------------------------
-- Accepting a second offer adds to the team instead of colliding with the first
-- ---------------------------------------------------------------------------
--
-- app.assign_responder refuses when accepted_responder_id is already set, which is what makes a
-- double LEAD impossible and stays exactly right. But the requester accepting a second helper is
-- no longer a double accept -- it is the point of the phase -- so it needs its own path that adds
-- a participant without touching the lead.
--
-- The request row is still locked. Two people accepted at the same instant serialise, and the
-- unique index on (request_id, user_id) is what makes a double-add impossible even if they did
-- not.

create or replace function public.accept_offer_by_token(p_token text, p_dispatch_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  req    public.requests%rowtype;
  offer  public.dispatches%rowtype;
  v_user uuid;
begin
  select * into req from public.requests where public_token = p_token;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  select * into offer
    from public.dispatches
   where id = p_dispatch_id and request_id = req.id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_such_offer');
  end if;

  if offer.state <> 'offered' then
    return jsonb_build_object('ok', false, 'error', 'offer_not_open', 'state', offer.state);
  end if;

  -- Nobody assigned yet: the ordinary path, which sets the lead and does the contact handoff.
  if req.accepted_responder_id is null then
    return app.assign_responder(req.id, offer.responder_id, offer.offer_eta_minutes);
  end if;

  -- Somebody is already coming, and the requester wants this person too.
  if req.status in ('recovered', 'cancelled', 'expired') then
    return jsonb_build_object('ok', false, 'error', 'already_closed', 'status', req.status);
  end if;

  select user_id into v_user from public.responders where id = offer.responder_id;
  if v_user is null then
    return jsonb_build_object('ok', false, 'error', 'no_account');
  end if;

  perform 1 from public.requests where id = req.id for update;

  insert into public.recovery_participants (request_id, user_id, responder_id, role, status)
  values (req.id, v_user, offer.responder_id, 'helper', 'accepted')
  on conflict (request_id, user_id) where user_id is not null
    do update set left_at = null, status = 'accepted', responder_id = excluded.responder_id;

  update public.dispatches
     set state = 'accepted', responded_at = now()
   where id = offer.id;

  insert into public.request_events (request_id, event_type, actor_kind, actor_responder_id,
                                     data, is_public)
  values (req.id, 'helper_joined', 'requester', offer.responder_id,
          jsonb_build_object('eta_minutes', offer.offer_eta_minutes), false);

  -- A system line in the chat, so the people already coordinating see the team change rather
  -- than discovering a third truck on arrival.
  insert into public.request_messages (request_id, sender_user_id, sender_role, body)
  values (req.id, null, 'system',
          (select coalesce(pr.display_name, resp.first_name, 'Another member')
             from public.responders resp
             left join public.profiles pr on pr.user_id = resp.user_id
            where resp.id = offer.responder_id) || ' joined the recovery');

  return jsonb_build_object('ok', true, 'added_to_team', true, 'short_code', req.short_code);
end;
$fn$;

revoke all on function public.accept_offer_by_token(text, uuid) from public, anon, authenticated;
grant execute on function public.accept_offer_by_token(text, uuid) to service_role;
