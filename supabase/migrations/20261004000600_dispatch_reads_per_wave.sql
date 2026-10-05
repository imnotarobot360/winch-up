-- The dispatcher reads the per-wave numbers, which until now it could not.
--
-- 20261004000400 added app.ring_max_helpers() and app.ring_wait_minutes() and nothing called them.
-- A setting nothing reads is worse than no setting: /admin/settings would have offered the owner a
-- field for "helpers in wave 1", accepted the edit, and changed nothing about who gets texted.
--
-- Both bodies are EXTRACTED verbatim from their latest definitions and patched in two places each
-- -- notify_ring from 20260923000100 (universal membership), advance_one from 20260920002000 --
-- rather than retyped. Retyping a hundred-line function is how a later migration in this repo
-- silently reverted an earlier one, and notify_ring in particular carries the universal-membership
-- changes that must not be lost.
--
-- advance_one's wait is read AFTER the row lock, deliberately. It is a deferral rather than a wave
-- opening, and which wave is running is not known until current_ring has been read from the locked
-- row; a declaration-time read would have applied wave 1's wait to every wave, which is exactly
-- the bug this whole change exists to remove.

set search_path = public, extensions;

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
  -- PER WAVE now, not one number for all three. Both helpers fall back to the old scalar
  -- setting, so an admin who tuned that keeps their value for any wave the array omits.
  per_ring     integer := app.ring_max_helpers(p_ring);
  wait_min     integer := app.ring_wait_minutes(p_ring);
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

create or replace function app.advance_one(p_request_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  req          public.requests%rowtype;
  -- Deliberately NOT read here. This is a deferral, and which wave is running is only known
  -- once the row is locked below -- reading a wave-specific wait before that would use wave 1's
  -- number for every wave. See the assignment near the end of the body.
  wait_min     integer;
  unmatched_after integer := app.setting_int('dispatch.unmatched_after_minutes', 25);
  expire_hours integer := app.setting_int('dispatch.expire_after_hours', 24);
  elapsed_min  numeric;
  notified     integer;
  admin_phone  text;
begin
  select * into req from public.requests where id = p_request_id for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  -- Anything already settled is none of this function's business.
  if req.status in ('accepted', 'on_site', 'recovered', 'cancelled', 'expired') then
    if req.next_action_at is not null then
      update public.requests set next_action_at = null where id = req.id;
    end if;
    return jsonb_build_object('ok', true, 'action', 'none', 'status', req.status);
  end if;

  if req.next_action_at is null or req.next_action_at > now() then
    return jsonb_build_object('ok', true, 'action', 'not_due');
  end if;

  -- First run: open ring 1. The status-change trigger writes the `dispatch_started` timeline row.
  if req.status = 'submitted' and req.current_ring = 0 then
    notified := app.notify_ring(req.id, 1);
    return jsonb_build_object('ok', true, 'action', 'ring_1', 'notified', notified);
  end if;

  elapsed_min := extract(epoch from (now() - coalesce(req.dispatch_started_at, req.created_at))) / 60.0;

  -- Out of patience: tell the admins, show the requester paid options, keep the request open so
  -- a volunteer can still pick it up.
  if elapsed_min >= unmatched_after and req.status = 'dispatching' then
    update public.requests
       set status           = 'unmatched',
           unmatched_at     = now(),
           admin_alerted_at = now(),
           next_action_at   = now() + make_interval(hours => expire_hours)
     where id = req.id;

    for admin_phone in
      select jsonb_array_elements_text(value)
        from public.app_settings where key = 'contact.admin_phones'
    loop
      perform app.queue_sms(
        admin_phone, 'admin.unmatched_alert',
        jsonb_build_object(
          'short_code', req.short_code,
          'minutes', round(elapsed_min),
          'notified', req.notified_count,
          'county', req.county
        ),
        'en', req.id
      );
    end loop;

    perform app.queue_sms(
      req.requester_phone, 'requester.unmatched',
      jsonb_build_object('short_code', req.short_code),
      req.locale, req.id
    );

    return jsonb_build_object('ok', true, 'action', 'unmatched');
  end if;

  -- Still inside the window: widen the search.
  if req.status = 'dispatching' and req.current_ring < 3 then
    notified := app.notify_ring(req.id, req.current_ring + 1);
    return jsonb_build_object(
      'ok', true, 'action', 'ring_' || (req.current_ring + 1), 'notified', notified
    );
  end if;

  -- Ring 3 is exhausted but the 25 minutes are not up yet. Wait for the rest of it.
  if req.status = 'dispatching' and req.current_ring >= 3 then
    update public.requests
       set next_action_at = coalesce(req.dispatch_started_at, req.created_at)
                            + make_interval(mins => unmatched_after)
     where id = req.id;
    return jsonb_build_object('ok', true, 'action', 'waiting_for_unmatched');
  end if;

  -- Unmatched and nobody ever came.
  if req.status = 'unmatched' then
    update public.requests
       set status = 'expired', next_action_at = null
     where id = req.id;

    update public.dispatches
       set state = 'expired'
     where request_id = req.id and state in ('queued', 'sent', 'delivered');

    return jsonb_build_object('ok', true, 'action', 'expired');
  end if;

  -- The CURRENT wave's wait, now that req is locked and current_ring is known. coalesce for a
  -- request that has not opened a wave yet, where there is no wave to ask about.
  wait_min := app.ring_wait_minutes(coalesce(req.current_ring, 1));

  update public.requests set next_action_at = now() + make_interval(mins => wait_min)
   where id = req.id;

  return jsonb_build_object('ok', true, 'action', 'deferred');
end;
$$;

-- Do the two functions now answer per wave? Read through the catalogue rather than by calling them
-- with side effects: a body that still names the old scalar would look identical from outside.
select
  strpos(pg_get_functiondef('app.notify_ring(uuid, integer)'::regprocedure), 'ring_max_helpers') > 0
    as notify_ring_reads_per_wave_count,
  strpos(pg_get_functiondef('app.notify_ring(uuid, integer)'::regprocedure), 'ring_wait_minutes') > 0
    as notify_ring_reads_per_wave_wait,
  strpos(pg_get_functiondef('app.advance_one(uuid)'::regprocedure), 'ring_wait_minutes') > 0
    as advance_one_reads_per_wave_wait;
