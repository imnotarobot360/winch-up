-- Winch Up :: the team can see where they are driving to
--
-- Spec section 8. A recovery conversation is where coordination happens, and until now the one
-- thing it did not carry was the place. A helper had to go back to the status link -- which they
-- may not hold, because it belongs to the requester -- or ask in the chat and have somebody type
-- coordinates by hand, which is how a digit goes missing at night.
--
-- WHO SEES IT
--
-- request_thread() is already gated on app.is_request_participant(), so adding the location here
-- inherits exactly that rule: the requester and the helpers they accepted, and nobody else. Not
-- the public board, which gets approx_location blurred to about a mile. Not a member browsing
-- /help. Not an admin, who has no participant row. One function decides it, which is the reason
-- to put it here rather than in a new RPC of its own.
--
-- WHAT IS DELIBERATELY NOT HERE
--
-- The requester's phone number. That is released once, to the lead, at acceptance, and the rest
-- of the team coordinates through the chat. A location card is a place to drive to; it is not a
-- reason to hand five people the mobile number of somebody stranded on their own at night.
--
-- A scrubbed recovery returns null. Deletion and retention replace the exact pin with the blurred
-- one, and serving that back as "the recovery location" would send a volunteer to open country
-- half a mile from anywhere that mattered -- worse than showing nothing, because it looks precise.

set search_path = public, extensions;

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
  v_loc    jsonb;
begin
  if not app.is_request_participant(p_request_id) then
    -- The same answer whether the request does not exist, exists and belongs to somebody else, or
    -- exists and the caller was removed from it. Three different truths, one reply, so nobody can
    -- walk request ids to find out which are real.
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  select r.status in ('recovered', 'cancelled', 'expired') into v_closed
    from public.requests r where r.id = p_request_id;

  -- The confirmed recovery point, for the people who have to drive to it.
  --
  -- Exact, not the blurred approx_location the public board gets. Everything below this line has
  -- already passed app.is_request_participant(), which is the same gate that guards the
  -- conversation itself -- so "who may see precisely where somebody is stuck" has exactly one
  -- answer in one place, and widening it later means changing that function rather than
  -- remembering this call site.
  --
  -- The requester's phone is NOT here. It is released once, to the lead, at acceptance. A helper
  -- who needs to ring gets it from the contact card; the rest of the team gets a place to drive
  -- to and no way to cold-call a stranded stranger.
  select jsonb_build_object(
           'lat',        round(extensions.st_y(r.location::extensions.geometry)::numeric, 6),
           'lng',        round(extensions.st_x(r.location::extensions.geometry)::numeric, 6),
           'accuracy_m', r.location_accuracy_m,
           -- How the point was chosen. A dropped pin on satellite and a phone GPS fix with 300m
           -- of error are both "coordinates", and a volunteer deciding whether to trust it to the
           -- metre deserves to know which one they are looking at.
           'source',     r.location_source,
           'note',       r.location_note,
           'county',     r.county
         ) into v_loc
    from public.requests r
   where r.id = p_request_id
     -- A scrubbed recovery has had its exact pin destroyed and replaced with the blurred one.
     -- Handing that back as though it were the real location would send somebody to a field half
     -- a mile from where anything happened.
     and r.redacted_at is null;

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
    -- Null on a scrubbed recovery, so the card disappears rather than lying.
    'location', v_loc,
    -- Spec section 10: a finished recovery keeps its history and stops accepting new messages.
    'read_only', coalesce(v_closed, false)
  );
end;
$fn$;
