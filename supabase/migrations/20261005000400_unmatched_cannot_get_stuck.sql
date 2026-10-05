-- An unmatched recovery cannot fall out of the state machine and sit on the board for ever.
--
-- TX-FMHP went unmatched on 2026-10-04 and was still unmatched on the public board at 14:30Z on
-- 10-05 -- an hour and a quarter past the latest its 24-hour expiry could have been due, with the
-- tick running every sixty seconds the whole time and the scheduler reporting healthy.
--
-- THE HOLE IS A NULL next_action_at, AND IT TOOK BOTH HALVES TO CLOSE.
--
--   advance_dispatch collected only rows with `next_action_at is not null and <= now()`, so a
--   row whose due time was null was never collected again.
--
--   advance_one then treated `next_action_at is null` as 'not_due', so even handing it one
--   directly achieved nothing.
--
-- Fixing either alone looks like a fix and changes nothing, which is why both are here. A null
-- due time is supposed to mean "settled, nothing left to do" -- true for recovered, cancelled and
-- expired. For UNMATCHED it means a request nobody can clear: not the requester, who has usually
-- gone, and until 20261005000200 not an admin either.
--
-- NARROW ON PURPOSE. Only unmatched rows, and only ones already past the expiry window. A
-- 'submitted' row with a null due time is a different fault with a different cause, and widening
-- this to catch it would change when live recoveries are handled -- the last thing to be casual
-- about in the function that decides whether anybody is told somebody is stuck.
--
-- Both bodies read out of the live database with pg_get_functiondef, not copied from a file: six
-- migrations name these two functions and the grep for declarations does not find the ones that
-- patch.

set search_path = public, extensions;

CREATE OR REPLACE FUNCTION public.advance_dispatch(p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  target  uuid;
  results jsonb := '[]'::jsonb;
  outcome jsonb;
  seen    integer := 0;
begin
  -- Heartbeat first, before any work and regardless of whether there is any.
  --
  -- This is the only way to tell "nothing to dispatch" from "the scheduler stopped". Without it
  -- a dead pg_cron job looks exactly like a quiet afternoon: no requests move, no texts go out,
  -- and the dashboard shows nothing wrong because nothing wrong is visible from the inside.
  insert into public.system_heartbeats (key, beat_at)
  values ('dispatch_tick', clock_timestamp())
  on conflict (key) do update set beat_at = excluded.beat_at;

  for target in
    select id from public.requests
     where status in ('submitted', 'dispatching', 'unmatched')
       and (
         -- The normal case: something is due.
         (next_action_at is not null and next_action_at <= now())
         -- OR THE ROW HAS NO DUE TIME AT ALL, which used to mean it was never looked at again.
         --
         -- A null next_action_at is how a recovery leaves the state machine permanently. It is
         -- supposed to mean "settled, nothing to do", and for recovered/cancelled/expired it
         -- does. For an UNMATCHED row it means the request sits on the PUBLIC BOARD for ever:
         -- nobody can clear it but an admin, and until 2026-10-05 no admin could either. That is
         -- exactly what happened to TX-FMHP, still unmatched an hour and a quarter after its
         -- expiry was due, with the tick running every sixty seconds and never looking at it.
         --
         -- Scoped to unmatched and to rows already past the expiry window, so this rescues the
         -- stuck case without changing when anything else is handled.
         or (next_action_at is null
          and status = 'unmatched'
          and coalesce(unmatched_at, created_at)
                < now() - make_interval(hours => app.setting_int('dispatch.expire_after_hours', 24)))
       )
     order by coalesce(next_action_at, unmatched_at, created_at)
     limit greatest(1, least(coalesce(p_limit, 50), 200))
     for update skip locked
  loop
    outcome := app.advance_one(target);
    results := results || jsonb_build_array(jsonb_build_object('request_id', target) || outcome);
    seen := seen + 1;
  end loop;

  return jsonb_build_object('processed', seen, 'results', results);
end;
$function$;

CREATE OR REPLACE FUNCTION app.advance_one(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  req          public.requests%rowtype;
  -- Read after the lock; see 20261004000600 for why.
  wait_min     integer;
  v_needed     integer;
  v_team       integer;
  v_recruiting boolean;
  unmatched_after integer := app.setting_int('dispatch.unmatched_after_minutes', 25);
  expire_hours integer := app.setting_int('dispatch.expire_after_hours', 24);
  v_rescue     boolean;
  elapsed_min  numeric;
  notified     integer;
  admin_phone  text;
begin
  select * into req from public.requests where id = p_request_id for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  -- HOW MANY HELPERS DOES THIS RECOVERY STILL WANT?
  --
  -- Until now the first acceptance ended the search, because a recovery was one person coming.
  -- It has been a TEAM since 2026-09-23 and the spec asks for the count to be configurable: a
  -- winch truck and a tractor arriving together is the normal case, not an exception.
  v_needed     := greatest(1, coalesce(req.helpers_needed, 1));
  v_team       := app.active_helper_count(req.id);
  v_recruiting := v_team < v_needed;

  -- Settled is none of this function's business. Accepted-but-short-handed still is.
  if req.status in ('recovered', 'cancelled', 'expired')
     or (req.status in ('accepted', 'on_site') and not v_recruiting) then
    if req.next_action_at is not null then
      update public.requests set next_action_at = null where id = req.id;
    end if;
    return jsonb_build_object('ok', true, 'action', 'none', 'status', req.status);
  end if;

  -- A ROW WITH NO DUE TIME IS NORMALLY NOT DUE, AND THAT IS THE BUG WHEN IT IS UNMATCHED.
  --
  -- Fixing the batch query alone would have achieved nothing: it would have collected the stuck
  -- row and this guard would have sent it straight back as 'not_due', every minute, for ever. The
  -- two halves only work together, which is why they are in one migration.
  v_rescue := req.next_action_at is null
              and req.status = 'unmatched'
              and coalesce(req.unmatched_at, req.created_at)
                    < now() - make_interval(hours => expire_hours);

  if not v_rescue and (req.next_action_at is null or req.next_action_at > now()) then
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
  --
  -- 'accepted' and 'on_site' are here, and 'unmatched' deliberately is NOT: the branch above that
  -- declares a recovery unmatched stays gated on 'dispatching' alone, so a recovery with one
  -- helper already on the way can never be announced to the admins as nobody having come.
  if req.status in ('dispatching', 'accepted', 'on_site') and req.current_ring < 3 then
    notified := app.notify_ring(req.id, req.current_ring + 1);
    return jsonb_build_object(
      'ok', true, 'action', 'ring_' || (req.current_ring + 1), 'notified', notified
    );
  end if;

  -- OUT OF WAVES AND STILL SHORT-HANDED. Stop scheduling entirely.
  --
  -- Without this the deferral at the bottom would re-arm every couple of minutes for the life of
  -- an accepted recovery, forever, with no wave left to open -- a tick that does nothing but cost
  -- a row lock. The requester keeps their helper and can ask for more by hand.
  if req.status in ('accepted', 'on_site') and req.current_ring >= 3 then
    update public.requests set next_action_at = null where id = req.id;
    return jsonb_build_object(
      'ok', true, 'action', 'team_incomplete', 'team', v_team, 'needed', v_needed
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

  -- ASSIGNED HERE, after the row lock, because which wave is running is only known once
  -- current_ring has been read -- and because without this line wait_min is null and the
  -- interval below evaluates to null, which is how a recovery loses its due time for ever.
  wait_min := app.ring_wait_minutes(coalesce(req.current_ring, 1));

  update public.requests set next_action_at = now() + make_interval(mins => wait_min)
   where id = req.id;

  return jsonb_build_object('ok', true, 'action', 'deferred');
end;
$function$;

notify pgrst, 'reload schema';

select
  strpos(pg_get_functiondef('public.advance_dispatch(integer)'::regprocedure),
         'next_action_at is null') > 0                                  as batch_collects_stuck_rows,
  strpos(pg_get_functiondef('app.advance_one(uuid)'::regprocedure),
         'v_rescue') > 0                                                as advance_one_acts_on_them,
  -- Everything these two carry from the last three days must survive the replacement.
  strpos(pg_get_functiondef('app.advance_one(uuid)'::regprocedure),
         'ring_wait_minutes') > 0                                       as per_wave_wait_intact,
  strpos(pg_get_functiondef('app.advance_one(uuid)'::regprocedure),
         'active_helper_count') > 0                                     as helpers_needed_intact,
  strpos(pg_get_functiondef('app.advance_one(uuid)'::regprocedure),
         'elapsed_min >= unmatched_after and req.status = ''dispatching''') > 0
                                                                        as unmatched_still_dispatching_only;
