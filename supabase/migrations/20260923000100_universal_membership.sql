-- Winch Up :: one membership, both directions
--
-- Until now this app had two kinds of person. A requester had an account. A volunteer was a
-- separate `responders` row created at /join, sitting at approval = 'pending' until an admin
-- approved it, and only then reachable by the dispatcher. Somebody who wanted to help had to
-- register a second time and then wait.
--
-- The owner's decision is that there is one membership: every registered member can request help
-- and offer it. This migration is the database half of that.
--
-- WHAT THIS DOES NOT DO
--
-- It does not merge `responders` into `profiles`. The row is still there, and still holds the
-- recovery-specific facts -- home base, radius, kit, night preference, how many jobs at once.
-- What changes is that it stops being an identity and becomes a capability record, created for a
-- member the moment they need one. One account, one role; the spec's "do not create separate
-- requester and volunteer account roles" is about who a person is, not about which table their
-- winch capacity is stored in. Doing it this way also keeps the dispatch state machine, its
-- indexes and its six hundred existing assertions intact, which a table merge would not.
--
-- THE APPROVAL GATE
--
-- `approval` no longer gates anything. It is kept and still written, because it is the only
-- signal separating a checked volunteer from an account created five minutes ago, and it now
-- shows as a "verified" badge on an offer. This is a deliberate reduction in protection: the old
-- gate is recorded in CLAUDE.md as keeping out tow companies posing as volunteers, and a badge
-- informs where a gate blocked. Reporting, feedback and moderation carry that weight now.
--
-- THE TWO SWITCHES, NOW THREE
--
--   responders.sms_opt_in     the carrier channel. Flipped by replying STOP. Legally binding for
--                             SMS and now enforced where the message is queued rather than where
--                             candidates are chosen, so a member who stopped texts can still be
--                             reached by push.
--   profiles.notify_recovery  the person's choice about recovery alerts, made on a screen.
--   profiles.available_to_help  NEW. "I am willing to be called out." Controls notifications
--                             ONLY. A member with this off can still browse requests, offer help
--                             and ask for it -- that is spec section 5, and it is why the default
--                             is false rather than true: being listed as willing to drive to a
--                             stranger at 2am is a thing somebody opts into.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. The toggle, on every member
-- ---------------------------------------------------------------------------

alter table public.profiles
  add column if not exists available_to_help boolean not null default false;

comment on column public.profiles.available_to_help is
  'Willing to receive nearby recovery alerts and be called out. Notifications only: a member with '
  'this off can still browse requests, offer assistance and request help.';

-- Anyone who already went through /join and came out approved and active was, under the old
-- model, exactly the set of people who had said they were willing to be called out. Keep them
-- willing rather than silently switching them off.
update public.profiles p
   set available_to_help = true
  from public.responders r
 where r.user_id = p.user_id
   and r.approval = 'approved'
   and r.availability = 'active';

-- ---------------------------------------------------------------------------
-- 2. A capability row must be creatable for an ordinary member
-- ---------------------------------------------------------------------------
--
-- Both of these were NOT NULL because the only way to get a responders row was /join, which asked
-- for them. A member who signed up with an email address has neither, and the point of this
-- change is that they should not have to fill in a volunteer form to help somebody.
--
-- phone: nullable. Postgres allows many NULLs under a unique constraint, so uniqueness still
-- holds for everyone who has one. Every SMS path now checks for it -- see notify_ring below.
-- home_location: nullable. Matching falls back to a shared live position, which is how somebody
-- already out on the trail should be matched anyway. With neither, st_dwithin yields NULL and the
-- member is simply not matched by the ring; they can still browse and offer.

alter table public.responders alter column phone drop not null;
alter table public.responders alter column home_location drop not null;

comment on column public.responders.approval is
  'No longer a gate. Retained as the verification signal shown as a badge on an offer, so a '
  'checked volunteer is distinguishable from an account created five minutes ago.';

-- ---------------------------------------------------------------------------
-- 3. Create the capability row on demand
-- ---------------------------------------------------------------------------

create or replace function app.ensure_recovery_profile(p_user_id uuid)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_id    uuid;
  v_name  text;
  v_phone text;
begin
  if p_user_id is null then
    return null;
  end if;

  select id into v_id from public.responders where user_id = p_user_id;
  if found then
    return v_id;
  end if;

  -- first_name is NOT NULL with a length check, so it needs something real. The display name if
  -- there is one, otherwise a neutral placeholder the member can change -- never a guess derived
  -- from an email address.
  select nullif(btrim(coalesce(p.display_name, '')), '')
    into v_name
    from public.profiles p
   where p.user_id = p_user_id;

  -- Only adopt an account phone if it is the shape this table accepts, and only if no other
  -- responder row already holds it.
  select u.phone into v_phone from auth.users u where u.id = p_user_id;
  if v_phone is not null and v_phone !~ '^\+1[0-9]{10}$' then
    v_phone := null;
  end if;
  if v_phone is not null
     and exists (select 1 from public.responders where phone = v_phone) then
    v_phone := null;
  end if;

  -- locale is left to the column default ('en'). profiles has no locale column -- the language is
  -- a URL segment, not a stored preference -- and inventing one here would be a second source of
  -- truth for something next-intl already owns.
  insert into public.responders (user_id, phone, first_name)
  values (p_user_id, v_phone, left(coalesce(v_name, 'Member'), 40))
  returning id into v_id;

  return v_id;
end;
$fn$;

revoke all on function app.ensure_recovery_profile(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. The member-facing availability toggle
-- ---------------------------------------------------------------------------

create or replace function public.set_available_to_help(p_available boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  -- Turning it on is the moment a member needs a capability row: it is what the ring matches
  -- against. Turning it off does not remove it, because their kit and radius are still theirs.
  if p_available then
    perform app.ensure_recovery_profile(v_uid);
  end if;

  update public.profiles
     set available_to_help = p_available,
         updated_at        = now()
   where user_id = v_uid;

  return jsonb_build_object('ok', true, 'available_to_help', p_available);
end;
$fn$;

revoke all on function public.set_available_to_help(boolean) from public, anon;
grant execute on function public.set_available_to_help(boolean) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Who the ring reaches
-- ---------------------------------------------------------------------------
--
-- Rewritten from the version in 20260922000200_honour_notify_preference.sql, which is the live
-- one -- this function has been redefined twice and the copy in the original dispatch migration
-- is two versions stale.
--
-- Three changes, all of them removals:
--
--   approval = 'approved'   gone. That is the gate this phase removes.
--   sms_opt_in              gone from HERE and enforced where the text is actually sent. Replying
--                           STOP must stop texts; it should not make somebody invisible to a push
--                           notification they opted into separately. availability = 'paused' is
--                           still honoured, and STOP still sets it, so a full stop is still a
--                           full stop.
--   home_location assumed   gone. effective_location may now be NULL, in which case st_dwithin
--                           yields NULL, the row is filtered out, and the member is simply not
--                           rung. They can still browse and offer.
--
-- And one addition: profiles.available_to_help.

create or replace function app.candidates(p_request_id uuid, p_radius_miles integer, p_limit integer)
returns table (responder_id uuid, distance_miles numeric)
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
  with req as (
    select id, location, required_equipment
      from public.requests where id = p_request_id
  ),
  clock as (
    select (extract(hour from (now() at time zone 'America/Chicago')) >= 21
            or extract(hour from (now() at time zone 'America/Chicago')) < 6) as is_night
  ),
  fresh as (
    select app.setting_int('dispatch.location_freshness_minutes', 120) as minutes
  ),
  r as (
    select
      resp.*,
      case
        when resp.share_location
         and resp.last_location is not null
         and resp.last_location_at > now() - make_interval(mins => fresh.minutes)
        then resp.last_location
        else resp.home_location
      end as effective_location
    from public.responders resp
    cross join fresh
  )
  select
    r.id,
    round((extensions.st_distance(r.effective_location, req.location) / 1609.344)::numeric, 2)
  from r
  cross join req
  cross join clock
  where r.availability = 'active'
    -- The member said they are willing to be called out. coalesce false for an account holder
    -- with no profile row, true for a legacy responder with no account at all: the first is a
    -- data gap we should not read as consent, the second never had the chance to choose.
    and case
          when r.user_id is null then true
          else coalesce(
                 (select p.available_to_help from public.profiles p where p.user_id = r.user_id),
                 false
               )
        end
    and coalesce(
          (select p.notify_recovery from public.profiles p where p.user_id = r.user_id),
          true
        )
    and (r.paused_until is null or r.paused_until <= now())
    and (not clock.is_night or r.night_ok)
    and (
          r.equipment
          || coalesce(
               (select array_agg(distinct e)
                  from public.vehicles v, unnest(v.equipment) e
                 where v.user_id = r.user_id),
               '{}'::equipment_type[]
             )
        ) @> req.required_equipment
    and extensions.st_dwithin(
          r.effective_location,
          req.location,
          app.miles_to_meters(least(p_radius_miles, r.radius_miles))
        )
    and not exists (
      select 1 from public.dispatches d
       where d.request_id = req.id and d.responder_id = r.id
    )
    and (
      select count(*) from public.requests active
       where active.accepted_responder_id = r.id
         and active.status in ('accepted', 'on_site')
    ) < r.max_active_jobs
  order by extensions.st_distance(r.effective_location, req.location)
  limit greatest(1, p_limit);
$fn$;

-- ---------------------------------------------------------------------------
-- 6. Queue the text only for somebody who can and will receive one
-- ---------------------------------------------------------------------------
--
-- The opt-in check moved here from app.candidates. This is the only place it needs to hold, and
-- holding it here rather than there is what lets a member who replied STOP still be reached by a
-- push notification they asked for. A missing phone is now possible and must be checked: a
-- member who joined with an email address and never added a number has NULL there.
--
-- The dispatch row is still created either way. It is an invitation, and from this phase on it is
-- no longer an assignment -- see 20260923000200_assistance_offers.sql.

create or replace function app.notify_ring(p_request_id uuid, p_ring integer)
returns integer
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  req          public.requests%rowtype;
  radius       integer := app.ring_radius_miles(p_ring);
  per_ring     integer := app.setting_int('dispatch.max_per_ring', 10);
  wait_min     integer := app.setting_int('dispatch.ring_wait_minutes', 7);
  candidate    record;
  resp         public.responders%rowtype;
  sent_count   integer := 0;
  new_dispatch uuid;
begin
  select * into req from public.requests where id = p_request_id;
  if not found then
    return 0;
  end if;

  for candidate in
    select * from app.candidates(p_request_id, radius, per_ring)
  loop
    select * into resp from public.responders where id = candidate.responder_id;

    insert into public.dispatches (request_id, responder_id, ring, distance_miles, state)
    values (p_request_id, candidate.responder_id, p_ring, candidate.distance_miles, 'queued')
    returning id into new_dispatch;

    if resp.phone is not null and resp.sms_opt_in and resp.sms_opt_out_at is null then
      perform app.queue_sms(
        resp.phone,
        'responder.offer',
        jsonb_build_object(
          'short_code',    req.short_code,
          'miles',         candidate.distance_miles,
          'stuck_type',    req.stuck_type,
          'stuck_depth',   req.stuck_depth,
          'vehicle_class', req.vehicle_class,
          'county',        req.county,
          'land_type',     req.land_type,
          'needs_tractor', req.needs_tractor,
          'needs_second_truck', req.needs_second_truck
        ),
        resp.locale,
        p_request_id,
        candidate.responder_id,
        new_dispatch
      );
    end if;

    update public.responders
       set last_notified_at = now()
     where id = candidate.responder_id;

    insert into public.request_events (request_id, event_type, actor_kind, actor_responder_id, data, is_public)
    values (p_request_id, 'responder_notified', 'system', candidate.responder_id,
            jsonb_build_object('ring', p_ring, 'miles', candidate.distance_miles), false);

    sent_count := sent_count + 1;
  end loop;

  -- Advancing the request itself. This is unchanged from the original and belongs to the ring,
  -- not to the offers: it is what moves 'submitted' to 'dispatching' and schedules the next
  -- escalation. (It is spelled out here because dropping it while rewriting the function above
  -- it silently stopped every request escalating -- the ring still texted people, the request
  -- just never left 'submitted'. Twenty of the dispatch suite's assertions caught it.)
  update public.requests
     set current_ring        = p_ring,
         ring_started_at     = now(),
         notified_count      = notified_count + sent_count,
         dispatch_started_at = coalesce(dispatch_started_at, now()),
         status              = case when status = 'submitted' then 'dispatching' else status end,
         next_action_at      = now() + make_interval(mins => wait_min)
   where id = p_request_id;

  return sent_count;
end;
$fn$;
