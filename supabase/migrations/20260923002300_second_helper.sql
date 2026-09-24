-- Winch Up :: the second helper, who could not actually be accepted
--
-- This phase built a recovery team: a participants table, a lead trigger, a group chat, a roster
-- on the status page, per-participant unread counts, team notifications, status-per-helper. All
-- of it working, all of it tested.
--
-- And no way to get a second person onto a team.
--
-- Three separate things had to be true for that, which is why none of them was noticed:
--
--   1. app.assign_responder refuses outright when accepted_responder_id is already set, and marks
--      every other outstanding offer as passed_over on the way through. Found by trying it rather
--      than by reading it: two members offer, the requester accepts the first, the second accept
--      comes back {"ok": false, "error": "already_covered"}, the team stays at one, and the other
--      offer is already dead. This is the door the inbound SMS reply and admin reassign use.
--   2. get_request_by_token stops returning offers once accepted_responder_id is set.
--   3. The status page hides the offers card on the same condition.
--
-- public.accept_offer_by_token -- the door the status page actually uses -- DID have its own
-- branch for a second helper, added in 20260923001300. It was simply unreachable: with (2) and
-- (3) there were no offers on the screen and therefore no button to press. So the capability
-- existed in one of the two assignment paths and could not be used from anywhere.
--
-- This file fixes (1) and consolidates the two paths into one; 20260923002400 fixes (2) and the
-- component fixes (3). Any one of the three left alone leaves the feature broken while looking
-- fixed, which is most of why it survived a phase that tested the team from every other angle.
--
-- The pgTAP suites built their teams by inserting recovery_participants directly, which is the
-- other half of the answer: they proved the table, the chat and the roster, and never once went
-- through the function a requester's button calls.
--
-- That refusal was right when it was written. One winning responder per request was a deliberate
-- standing assumption, and the check plus the row lock is what makes a double accept impossible.
-- The team model changes what needs to be impossible, and the distinction is worth being exact
-- about:
--
--   STILL IMPOSSIBLE  two people believing they are the assigned lead. accepted_responder_id is
--                     set once, under `for update`, by whoever gets there first, and is never
--                     reassigned by this function.
--   NOW ALLOWED       a second, third, fourth helper joining the team behind that lead, because
--                     a winch truck and a tractor turning up together is the normal case this
--                     phase exists for.
--
-- ---------------------------------------------------------------------------------------------
-- THE OTHER HALF: OFFERS ARE NO LONGER LOSERS
--
-- Standing the other offers down was correct in a one-winner model -- they had lost, and telling
-- them promptly is the courteous thing. Under a team model the requester may well want the
-- tractor as well, ten minutes later, once they have seen how buried they are. Passing those
-- offers over at the moment of the first acceptance destroys that choice before it is made, and
-- tells somebody who is still willing to come that they are not needed.
--
-- So an outstanding offer now survives an acceptance. Nobody is told "already covered" at that
-- moment, because it is not true any more. They are stood down when the recovery actually ends,
-- which already happens elsewhere, or when the requester declines them, which is explicit.
--
-- A dispatch that was merely QUEUED or SENT and never answered is still superseded here: those
-- are rings the dispatcher fired that nobody replied to, the recovery now has somebody on it, and
-- continuing to escalate would be ringing strangers about a job already being done.

set search_path = public, extensions;

create or replace function app.assign_responder(
  p_request_id   uuid,
  p_responder_id uuid,
  p_eta_minutes  integer default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  req       public.requests%rowtype;
  resp      public.responders%rowtype;
  offer     public.dispatches%rowtype;
  loser     record;
  v_is_lead boolean;
begin
  select * into resp from public.responders where id = p_responder_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_such_responder');
  end if;

  -- The lock. Everything below reads req.accepted_responder_id and decides whether this caller
  -- is the lead; two concurrent accepts without this would both read null and both think so.
  select * into req from public.requests where id = p_request_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if req.status in ('recovered', 'cancelled', 'expired') then
    return jsonb_build_object('ok', false, 'error', 'already_closed', 'status', req.status);
  end if;

  -- Accepting the same person twice is still a mistake worth naming, and it is now the ONLY
  -- already-* case: somebody else being assigned is no longer a refusal.
  if req.accepted_responder_id = p_responder_id then
    return jsonb_build_object('ok', false, 'error', 'already_yours');
  end if;

  if exists (
    select 1 from public.recovery_participants
     where request_id = p_request_id and responder_id = p_responder_id and left_at is null
  ) then
    return jsonb_build_object('ok', false, 'error', 'already_yours');
  end if;

  -- 'accepted' and 'on_site' are now live states a further helper can be added during. A helper
  -- arriving after the first one is on site is the ordinary case, not an edge one.
  if req.status not in ('submitted', 'dispatching', 'unmatched', 'accepted', 'on_site') then
    return jsonb_build_object('ok', false, 'error', 'already_closed', 'status', req.status);
  end if;

  select * into offer
    from public.dispatches
   where request_id = p_request_id and responder_id = p_responder_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_offered');
  end if;

  v_is_lead := req.accepted_responder_id is null;

  if v_is_lead then
    update public.requests
       set status                = 'accepted',
           accepted_responder_id = p_responder_id,
           accepted_at           = now(),
           eta_minutes           = coalesce(p_eta_minutes, offer.offer_eta_minutes),
           next_action_at        = null
     where id = p_request_id
     returning * into req;
  else
    -- A second helper does not move the recovery's status or overwrite the lead's ETA. The
    -- status belongs to the recovery; each helper's own progress is their participant row.
    select * into req from public.requests where id = p_request_id;
  end if;

  update public.dispatches
     set state = 'accepted', responded_at = now()
   where id = offer.id;

  update public.responders
     set last_accepted_at = now()
   where id = p_responder_id;

  -- The participant row. The lead's is created by the trigger in 20260923001300 off
  -- accepted_responder_id; a second helper has no such hook, so it is written here. Idempotent
  -- against the trigger, which may have got there first for the lead.
  insert into public.recovery_participants (request_id, user_id, responder_id, role, status)
  values (p_request_id, resp.user_id, p_responder_id, 'helper', 'accepted')
  on conflict (request_id, user_id) where user_id is not null
    do update set left_at = null, status = 'accepted', responder_id = excluded.responder_id;

  -- The timeline and the chat, for a helper who is NOT the lead. The lead's arrival is already
  -- announced by the status change and by requester.accepted; a second truck turning up is the
  -- thing the people already coordinating would otherwise discover on arrival.
  if not v_is_lead then
    insert into public.request_events (request_id, event_type, actor_kind, actor_responder_id,
                                       data, is_public)
    values (p_request_id, 'helper_joined', 'requester', p_responder_id,
            jsonb_build_object('eta_minutes', coalesce(p_eta_minutes, offer.offer_eta_minutes)),
            false);

    insert into public.request_messages (request_id, sender_user_id, sender_role, body)
    values (p_request_id, null, 'system',
            coalesce((select pr.display_name from public.profiles pr where pr.user_id = resp.user_id),
                     resp.first_name, 'Another member') || ' joined the recovery');
  end if;

  -- Only the rings nobody answered. An outstanding OFFER is left exactly where it is: the
  -- requester may still want that tractor, and the moment of the first acceptance is not the
  -- moment to decide for them.
  for loser in
    select d.id, d.state, r2.phone, r2.locale, r2.sms_opt_in, r2.sms_opt_out_at
      from public.dispatches d
      join public.responders r2 on r2.id = d.responder_id
     where d.request_id = p_request_id
       and d.responder_id <> p_responder_id
       and d.state in ('queued', 'sent', 'delivered')
  loop
    update public.dispatches
       set state = 'superseded'::dispatch_state
     where id = loser.id;
  end loop;

  if resp.phone is not null and resp.sms_opt_in and resp.sms_opt_out_at is null then
    perform app.queue_sms(
      resp.phone, 'responder.assigned',
      jsonb_build_object(
        'short_code',      req.short_code,
        'requester_name',  req.requester_name,
        'requester_phone', req.requester_phone,
        'lat',             round(extensions.st_y(req.location::extensions.geometry)::numeric, 5),
        'lng',             round(extensions.st_x(req.location::extensions.geometry)::numeric, 5),
        'location_note',   req.location_note
      ),
      resp.locale, req.id, resp.id, offer.id
    );
  end if;

  -- The requester is told about the lead. They are not texted again for each further helper they
  -- themselves chose a moment ago on their own screen -- the team panel is already in front of
  -- them, and this is the message that carries a phone number.
  if v_is_lead and req.requester_phone is not null then
    perform app.queue_sms(
      req.requester_phone, 'requester.accepted',
      jsonb_build_object(
        'short_code',    req.short_code,
        'first_name',    resp.first_name,
        'vehicle_desc',  coalesce(resp.vehicle_desc, ''),
        'vehicle_class', resp.vehicle_class,
        'phone',         resp.phone,
        'eta_minutes',   coalesce(p_eta_minutes, offer.offer_eta_minutes)
      ),
      req.locale, req.id, resp.id
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'short_code', req.short_code,
    -- So the caller can say "Mike is coming" or "Rosa is joining Mike" rather than guessing.
    'lead', v_is_lead
  );
end;
$fn$;

revoke all on function app.assign_responder(uuid, uuid, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Standing the rest down when the recovery actually ends
--
-- This used to be a side effect of the first acceptance. Now that an offer survives that, the
-- offers have to be closed off at the point they genuinely stop being wanted: the recovery is
-- over. Otherwise somebody sits on /me with an outstanding offer to a job that finished
-- yesterday.
-- ---------------------------------------------------------------------------

create or replace function app.stand_down_open_offers(p_request_id uuid)
returns integer
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_req   public.requests%rowtype;
  v_offer record;
  v_count integer := 0;
begin
  select * into v_req from public.requests where id = p_request_id;

  for v_offer in
    select d.id, r.phone, r.locale, r.sms_opt_in, r.sms_opt_out_at
      from public.dispatches d
      join public.responders r on r.id = d.responder_id
     where d.request_id = p_request_id
       and d.state in ('queued', 'sent', 'delivered', 'offered')
  loop
    update public.dispatches
       set state = 'passed_over'::dispatch_state
     where id = v_offer.id;

    if v_offer.phone is not null and v_offer.sms_opt_in and v_offer.sms_opt_out_at is null then
      perform app.queue_sms(
        v_offer.phone, 'responder.already_covered',
        jsonb_build_object('short_code', v_req.short_code), v_offer.locale, p_request_id
      );
    end if;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

comment on function app.stand_down_open_offers(uuid) is
  'Closes any offer still outstanding on a recovery and tells the member. Called when a recovery '
  'ends -- an offer now survives somebody else being accepted, so this is where it is retired.';

-- A trigger rather than a line added to each of mark_recovered / cancel / expire, for the reason
-- CLAUDE.md gives about notification producers: there are several ways a recovery can end and
-- only one of them is the one you remember to edit.
create or replace function app.stand_down_on_close()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if new.status in ('recovered', 'cancelled', 'expired')
     and old.status is distinct from new.status then
    perform app.stand_down_open_offers(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists requests_stand_down_offers on public.requests;
create trigger requests_stand_down_offers
  after update of status on public.requests
  for each row execute function app.stand_down_on_close();

-- ---------------------------------------------------------------------------
-- One assignment path, again
--
-- 20260923001300 gave accept_offer_by_token its own branch for the second helper, because
-- app.assign_responder refused that case outright. Now that it does not, there are two pieces of
-- code that add somebody to a recovery, and they had already drifted: the inline branch wrote a
-- helper_joined event and a system line in the chat, and the assign_responder path wrote neither.
-- So who was announced to the team depended on which door they came through -- a member accepted
-- from the status page appeared in the chat, one accepted by an admin or by replying to a text
-- just silently turned up.
--
-- Both behaviours now live in assign_responder, and this function goes back to being what its
-- name says: find the offer for this token, check it is still open, hand it over.
-- ---------------------------------------------------------------------------

create or replace function public.accept_offer_by_token(p_token text, p_dispatch_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  req   public.requests%rowtype;
  offer public.dispatches%rowtype;
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

  -- Withdrawn, declined, or already accepted. Checked here rather than in assign_responder
  -- because this is the only caller that takes a dispatch id from a browser.
  if offer.state <> 'offered' then
    return jsonb_build_object('ok', false, 'error', 'offer_not_open', 'state', offer.state);
  end if;

  return app.assign_responder(req.id, offer.responder_id, offer.offer_eta_minutes);
end;
$fn$;

revoke all on function public.accept_offer_by_token(text, uuid) from public, anon, authenticated;
grant execute on function public.accept_offer_by_token(text, uuid) to service_role;
