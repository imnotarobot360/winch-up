-- A recovery can ask for more than one helper, and the search keeps going until it has them.
--
-- The spec: "Once enough helpers have been accepted, stop expanding the SMS search. Make the
-- required helper count configurable." Both halves were missing. app.advance_one returned
-- action 'none' the moment status became 'accepted', so the first acceptance ended the search --
-- correct when a recovery was one person coming, and wrong since 2026-09-23, when it became a
-- TEAM. A winch truck and a tractor arriving together is the normal case.
--
-- THE BOUNDARY THAT MATTERS. The branch that declares a request 'unmatched' -- which alerts the
-- admins and shows the requester paid tow options -- stays gated on status 'dispatching' ALONE.
-- A recovery with one helper on the way must never be announced as nobody having come, however
-- short-handed it is. Widening is allowed to continue for 'accepted' and 'on_site'; giving up is
-- not.
--
-- And when the waves run out while still short-handed, scheduling STOPS rather than deferring.
-- A tick that re-arms every two minutes for the life of a recovery, with no wave left to open,
-- is a lock taken for nothing.

set search_path = public, extensions;

-- 1 by default, so every existing recovery behaves exactly as it does today. The ceiling is a
-- guard against a typo turning one recovery into a mass text, not a belief about how many trucks
-- a ditch can hold.
alter table public.requests
  add column if not exists helpers_needed smallint not null default 1
    check (helpers_needed between 1 and 5);

comment on column public.requests.helpers_needed is
  'How many helpers this recovery wants before the SMS search stops expanding. Default 1.';

-- Who counts as aboard.
--
-- left_at is null, not merely membership -- the rule the whole team feature is built on. A helper
-- who withdrew keeps their history and their messages, and must not keep counting towards a crew
-- that no longer includes them, or a recovery could sit short-handed with the search switched off.
create or replace function app.active_helper_count(p_request_id uuid)
returns integer
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  select count(*)::integer
    from public.recovery_participants
   where request_id = p_request_id
     and role = 'helper'
     and left_at is null
     and status <> 'withdrawn';
$$;

create or replace function app.advance_one(p_request_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  req          public.requests%rowtype;
  -- Read after the lock; see 20261004000600 for why.
  wait_min     integer;
  v_needed     integer;
  v_team       integer;
  v_recruiting boolean;
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

  update public.requests set next_action_at = now() + make_interval(mins => wait_min)
   where id = req.id;

  return jsonb_build_object('ok', true, 'action', 'deferred');
end;
$$;

-- TELL POSTGREST. This adds a COLUMN, and the schema cache holds columns as well as functions:
-- without a reload, requests.helpers_needed is invisible to every select the app makes, and a
-- screen reading it gets a 42703 that looks like the migration never ran.
notify pgrst, 'reload schema';

-- Prove the column exists, the counter answers, and -- the one that matters -- that the unmatched
-- branch is still gated on 'dispatching' alone. That last one is a source read rather than a
-- behaviour test because reproducing it needs a 25-minute-old request, and a regression there
-- would page the admins about a recovery that already has somebody driving to it.
select
  (select count(*) from information_schema.columns
    where table_schema = 'public' and table_name = 'requests'
      and column_name = 'helpers_needed')                                      as column_added,
  app.active_helper_count('00000000-0000-0000-0000-000000000000'::uuid)        as counter_answers,
  strpos(pg_get_functiondef('app.advance_one(uuid)'::regprocedure),
         'elapsed_min >= unmatched_after and req.status = ''dispatching''') > 0
                                                                               as unmatched_still_dispatching_only;
