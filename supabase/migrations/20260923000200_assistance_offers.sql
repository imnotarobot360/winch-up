-- Winch Up :: the requester chooses
--
-- Until now the dispatcher decided. It rang volunteers in widening circles and the first one to
-- text back `1` was assigned, by a row lock, before the requester knew anybody had replied. That
-- is fast, and for somebody sitting in a creek at night, fast is worth a lot.
--
-- The owner's decision is that the requester chooses instead. Every response is now an OFFER.
-- Nothing assigns itself.
--
-- WHAT IS PRESERVED, DELIBERATELY
--
-- "A double accept must be impossible" is non-negotiable in this repo and stays true. Every path
-- that can assign somebody still goes through one function, app.assign_responder, which takes
-- `select ... for update` on the request row and refuses if accepted_responder_id is already set.
-- There are now more ways to offer and only one way to be assigned, which is a narrower funnel
-- than before, not a wider one.
--
-- Offers reuse `dispatches` rather than living in a new table. That row already means "this
-- volunteer and this request are connected", already carries the unique (request_id,
-- responder_id) that stops somebody offering twice, and already has the indexes. A parallel
-- offers table would have needed all three again and left two places to ask "who is on this job".
--
-- WHAT CHANGES FOR A VOLUNTEER
--
-- Replying `1` no longer wins the job; it puts their hand up. The SMS copy has to change with it,
-- because the old text promises the recovery is theirs. See src/lib/sms/templates.ts.
--
-- WHO SAID NO, AND WHY IT IS RECORDED SEPARATELY
--
--   declined     the volunteer said no.
--   passed_over  the requester picked somebody else.
--   superseded   the system stood down a ring.
--
-- Collapsing these would make a volunteer's history read as though they had turned down work
-- they actually offered to do.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. What an offer carries
-- ---------------------------------------------------------------------------

-- Guarded rather than a bare `create type`. These migrations reach production by being pasted
-- into the Supabase SQL editor, where a connection drop or a typo means somebody pastes it again;
-- a file that dies on "type already exists" turns a retry into a puzzle about what did land.
do $do$
begin
  if not exists (select 1 from pg_type where typname = 'offer_origin') then
    create type offer_origin as enum ('ring', 'self');
  end if;
end
$do$;

comment on type offer_origin is
  'ring: the dispatcher invited them. self: they found the request on /help and offered. The '
  'distinction matters for reading what happened afterwards -- a recovery covered entirely by '
  'people who came looking is a different signal about this community than one covered by the '
  'dispatcher having to ask.';

alter table public.dispatches
  add column if not exists origin            offer_origin not null default 'ring',
  add column if not exists offer_note        text,
  add column if not exists offer_eta_minutes integer,
  add column if not exists equipment_ack     boolean not null default false,
  add column if not exists offered_at        timestamptz;

-- The note is free text a stranger will read, so it gets the same treatment as every other
-- public text column here: no phone numbers, no URLs. This is the surface where a tow company
-- would put its number.
alter table public.dispatches drop constraint if exists dispatches_offer_note_is_clean;
alter table public.dispatches
  add constraint dispatches_offer_note_is_clean check (
    offer_note is null
    or (length(offer_note) <= 200 and not public.contains_contact_info(offer_note))
  );

alter table public.dispatches drop constraint if exists dispatches_offer_eta_is_sane;
alter table public.dispatches
  add constraint dispatches_offer_eta_is_sane check (
    offer_eta_minutes is null or offer_eta_minutes between 1 and 600
  );

-- Reading the offers on a request is the hot path for the status page.
create index if not exists dispatches_offered_idx
  on public.dispatches (request_id, offered_at desc)
  where state = 'offered';

-- ---------------------------------------------------------------------------
-- 2. Recording an offer
-- ---------------------------------------------------------------------------
--
-- One function for both origins. A volunteer who was rung and then offers through the app must
-- land on the SAME row the ring created, because unique (request_id, responder_id) says so --
-- hence the upsert rather than an insert.

create or replace function app.record_offer(
  p_request_id    uuid,
  p_responder_id  uuid,
  p_note          text        default null,
  p_eta_minutes   integer     default null,
  p_equipment_ack boolean     default false,
  p_origin        offer_origin default 'self'
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  req  public.requests%rowtype;
  resp public.responders%rowtype;
  v_id uuid;
begin
  select * into resp from public.responders where id = p_responder_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_recovery_profile');
  end if;

  -- Read-only lock on the request: an offer must not be recorded against a request that is being
  -- assigned in another transaction right now.
  select * into req from public.requests where id = p_request_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if req.status in ('recovered', 'cancelled', 'expired') then
    return jsonb_build_object('ok', false, 'error', 'already_closed', 'status', req.status);
  end if;

  if req.accepted_responder_id is not null then
    return jsonb_build_object('ok', false, 'error', 'already_covered');
  end if;

  -- Helping yourself is not a thing, and the check is here rather than in the UI because the UI
  -- is not the security boundary.
  if resp.user_id is not null and resp.user_id = req.requester_user_id then
    return jsonb_build_object('ok', false, 'error', 'own_request');
  end if;

  insert into public.dispatches (
    request_id, responder_id, ring, distance_miles, state,
    origin, offer_note, offer_eta_minutes, equipment_ack, offered_at, responded_at
  )
  values (
    p_request_id, p_responder_id, 1, 0, 'offered',
    p_origin, nullif(btrim(coalesce(p_note, '')), ''), p_eta_minutes, p_equipment_ack,
    now(), now()
  )
  on conflict (request_id, responder_id) do update
     set state             = 'offered',
         offer_note        = coalesce(nullif(btrim(coalesce(excluded.offer_note, '')), ''),
                                      public.dispatches.offer_note),
         offer_eta_minutes = coalesce(excluded.offer_eta_minutes, public.dispatches.offer_eta_minutes),
         equipment_ack     = excluded.equipment_ack or public.dispatches.equipment_ack,
         offered_at        = coalesce(public.dispatches.offered_at, now()),
         responded_at      = now()
   where public.dispatches.state in ('queued', 'sent', 'delivered', 'offered')
  returning id into v_id;

  if v_id is null then
    -- The row exists in a state an offer cannot come back from: declined, expired, passed over.
    return jsonb_build_object('ok', false, 'error', 'offer_not_possible');
  end if;

  insert into public.request_events (request_id, event_type, actor_kind, actor_responder_id, data, is_public)
  values (p_request_id, 'responder_offered', 'responder', p_responder_id,
          jsonb_build_object('origin', p_origin, 'eta_minutes', p_eta_minutes), false);

  return jsonb_build_object('ok', true, 'dispatch_id', v_id, 'state', 'offered');
end;
$fn$;

revoke all on function app.record_offer(uuid, uuid, text, integer, boolean, offer_origin)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. A member offering help
-- ---------------------------------------------------------------------------

create or replace function public.offer_assistance(
  p_request_id    uuid,
  p_note          text    default null,
  p_eta_minutes   integer default null,
  p_equipment_ack boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_rid uuid;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  -- Spec section 3: before confirming, the member is asked whether they have the equipment and
  -- can safely provide the assistance. Refusing without it is what makes that a real gate rather
  -- than a sentence on a screen.
  if not p_equipment_ack then
    return jsonb_build_object('ok', false, 'error', 'equipment_not_acknowledged');
  end if;

  -- No separate volunteer registration. This is the moment a member's capability row appears,
  -- and they never had to fill in a form to get here.
  v_rid := app.ensure_recovery_profile(v_uid);
  if v_rid is null then
    return jsonb_build_object('ok', false, 'error', 'no_recovery_profile');
  end if;

  return app.record_offer(p_request_id, v_rid, p_note, p_eta_minutes, true, 'self');
end;
$fn$;

revoke all on function public.offer_assistance(uuid, text, integer, boolean) from public, anon;
grant execute on function public.offer_assistance(uuid, text, integer, boolean)
  to authenticated, service_role;

create or replace function public.withdraw_my_offer(p_request_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
  v_rid uuid;
  v_hit integer;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  select id into v_rid from public.responders where user_id = v_uid;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_recovery_profile');
  end if;

  -- Only an offer that has not been chosen. Somebody already assigned must cancel properly, so
  -- the requester is told rather than finding out by the volunteer never arriving.
  update public.dispatches
     set state = 'declined', responded_at = now()
   where request_id = p_request_id
     and responder_id = v_rid
     and state = 'offered'
     and not exists (
       select 1 from public.requests r
        where r.id = p_request_id and r.accepted_responder_id = v_rid
     );

  get diagnostics v_hit = row_count;

  if v_hit = 0 then
    return jsonb_build_object('ok', false, 'error', 'no_open_offer');
  end if;

  insert into public.request_events (request_id, event_type, actor_kind, actor_responder_id, data, is_public)
  values (p_request_id, 'responder_withdrew', 'responder', v_rid, '{}'::jsonb, false);

  return jsonb_build_object('ok', true);
end;
$fn$;

revoke all on function public.withdraw_my_offer(uuid) from public, anon;
grant execute on function public.withdraw_my_offer(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. The one way somebody gets assigned
-- ---------------------------------------------------------------------------
--
-- This is app.accept_request from 20260920002000_dispatch.sql with three changes:
--
--   * the approval gate is gone (this phase removes it),
--   * 'offered' rows are stood down as 'passed_over' rather than 'superseded',
--   * every SMS is guarded on a phone actually existing, which is newly possible: a member who
--     joined with an email address and helps via push has no number.
--
-- The lock and the already-accepted check are untouched. They are the reason a double accept is
-- impossible and they are the last thing that should be rewritten casually.

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
  req   public.requests%rowtype;
  resp  public.responders%rowtype;
  offer public.dispatches%rowtype;
  loser record;
begin
  select * into resp from public.responders where id = p_responder_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_such_responder');
  end if;

  select * into req from public.requests where id = p_request_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if req.status in ('recovered', 'cancelled', 'expired') then
    return jsonb_build_object('ok', false, 'error', 'already_closed', 'status', req.status);
  end if;

  if req.accepted_responder_id is not null then
    return jsonb_build_object(
      'ok', false,
      'error', case when req.accepted_responder_id = p_responder_id
                    then 'already_yours' else 'already_covered' end
    );
  end if;

  if req.status not in ('submitted', 'dispatching', 'unmatched') then
    return jsonb_build_object('ok', false, 'error', 'already_closed', 'status', req.status);
  end if;

  select * into offer
    from public.dispatches
   where request_id = p_request_id and responder_id = p_responder_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_offered');
  end if;

  update public.requests
     set status                = 'accepted',
         accepted_responder_id = p_responder_id,
         accepted_at           = now(),
         eta_minutes           = coalesce(p_eta_minutes, offer.offer_eta_minutes),
         next_action_at        = null
   where id = p_request_id
   returning * into req;

  update public.dispatches
     set state = 'accepted', responded_at = now()
   where id = offer.id;

  update public.responders
     set last_accepted_at = now()
   where id = p_responder_id;

  for loser in
    select d.id, d.state, r2.phone, r2.locale, r2.sms_opt_in, r2.sms_opt_out_at
      from public.dispatches d
      join public.responders r2 on r2.id = d.responder_id
     where d.request_id = p_request_id
       and d.responder_id <> p_responder_id
       and d.state in ('queued', 'sent', 'delivered', 'offered')
  loop
    if loser.state in ('sent', 'delivered', 'offered')
       and loser.phone is not null and loser.sms_opt_in and loser.sms_opt_out_at is null then
      perform app.queue_sms(
        loser.phone, 'responder.already_covered',
        jsonb_build_object('short_code', req.short_code), loser.locale, req.id
      );
    end if;

    -- Somebody who put their hand up was passed over. Somebody who never answered was
    -- superseded. Recording both as the latter would misreport the first.
    -- The cast is required, not decorative: a bare CASE over string literals is `text`, and
    -- Postgres will not assign text to an enum column. Without it this line fails at run time,
    -- inside the one function that assigns somebody, which is the worst place to find out.
    update public.dispatches
       set state = (case when loser.state = 'offered' then 'passed_over' else 'superseded' end)::dispatch_state
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

  if req.requester_phone is not null then
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

  return jsonb_build_object('ok', true, 'short_code', req.short_code);
end;
$fn$;

revoke all on function app.assign_responder(uuid, uuid, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. The requester deciding
-- ---------------------------------------------------------------------------
--
-- Service-role only, like every other by_token write here: the server action is the caller, so
-- the token is checked somewhere the browser cannot reach around.

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

  -- The offer must belong to THIS request. Without this check a token for one recovery could
  -- assign a volunteer to another.
  select * into offer
    from public.dispatches
   where id = p_dispatch_id and request_id = req.id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_such_offer');
  end if;

  if offer.state <> 'offered' then
    return jsonb_build_object('ok', false, 'error', 'offer_not_open', 'state', offer.state);
  end if;

  return app.assign_responder(req.id, offer.responder_id, offer.offer_eta_minutes);
end;
$fn$;

revoke all on function public.accept_offer_by_token(text, uuid) from public, anon, authenticated;
grant execute on function public.accept_offer_by_token(text, uuid) to service_role;

create or replace function public.decline_offer_by_token(p_token text, p_dispatch_id uuid)
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
   where id = p_dispatch_id and request_id = req.id and state = 'offered';

  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_such_offer');
  end if;

  update public.dispatches
     set state = 'passed_over', responded_at = now()
   where id = offer.id;

  insert into public.request_events (request_id, event_type, actor_kind, actor_responder_id, data, is_public)
  values (req.id, 'offer_declined', 'requester', offer.responder_id, '{}'::jsonb, false);

  return jsonb_build_object('ok', true);
end;
$fn$;

revoke all on function public.decline_offer_by_token(text, uuid) from public, anon, authenticated;
grant execute on function public.decline_offer_by_token(text, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 6. A volunteer can no longer assign themselves
-- ---------------------------------------------------------------------------
--
-- public.accept_request was the in-app equivalent of texting `1`: the volunteer took the job.
-- That is the behaviour this phase removes, so the grant goes. The function itself stays for
-- service_role, because admin manual dispatch still needs a way to assign somebody directly, and
-- it now routes through app.assign_responder like everything else.

create or replace function public.accept_request(p_request_id uuid, p_eta_minutes integer default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  me uuid;
begin
  select id into me from public.responders where user_id = auth.uid();
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_recovery_profile');
  end if;

  return app.assign_responder(p_request_id, me, p_eta_minutes);
end;
$fn$;

revoke execute on function public.accept_request(uuid, integer) from public, anon, authenticated;
grant execute on function public.accept_request(uuid, integer) to service_role;
