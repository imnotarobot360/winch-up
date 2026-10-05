-- A call-out goes out by EMAIL as well as by text.
--
-- The owner, 2026-10-05: "we need to send an email and sms when someone is asking for help." The
-- text half has worked since yesterday and reached a real handset. This adds the email, on the
-- same event, in the same loop, to the same people.
--
-- WHY EMAIL IS NOT GATED ON sms_opt_in. That column is consent to be TEXTED. Email is neither
-- metered nor interrupting, app.candidates() already enforces notify_recovery, and somebody who
-- declined texts has not declined email. Gating it behind the SMS switch would mean most
-- volunteers hear nothing at all.
--
-- WHY THE ROW CARRIES IDS AND NOT CONTENT. email_deliveries holds no address, no subject, no body
-- and no action URL, and a test pins that column list -- because a log of verification links would
-- be worth more than the mail it records. A params column would quietly turn it into a durable
-- record of who is stuck, where, and in what. So the row points at the request and the dispatch,
-- and claim_email_deliveries builds the facts AT SEND TIME. This mirrors sms_messages, which has
-- carried request_id, responder_id and dispatch_id all along.
--
-- BOTH BODIES BELOW WERE READ OUT OF THE LIVE DATABASE with pg_get_functiondef, not copied from a
-- migration file. On 2026-10-04 I chose "the latest definition" by grepping for
-- `create or replace function` and missed two migrations that patch a function by rewriting its
-- live text -- so the grep found the files that DECLARE it and none of the ones that most recently
-- CHANGED it, and I shipped a body four migrations out of date. The database does not have that
-- problem.

set search_path = public, extensions;

-- ON DELETE SET NULL, matching the user_id FK already on this table and for the same reason:
-- deleting a recovery must never erase the evidence that mail went out about it. The row keeps its
-- template key and its timestamp; only the ability to re-resolve the facts goes, and by then it
-- has been sent.
alter table public.email_deliveries
  add column if not exists request_id  uuid references public.requests (id)   on delete set null,
  add column if not exists dispatch_id uuid references public.dispatches (id) on delete set null;

-- Every foreign key gets an index; schema_audit_test asserts that over the whole catalogue.
create index if not exists email_deliveries_request_idx  on public.email_deliveries (request_id);
create index if not exists email_deliveries_dispatch_idx on public.email_deliveries (dispatch_id);

CREATE OR REPLACE FUNCTION app.notify_ring(p_request_id uuid, p_ring integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
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

    -- AND BY EMAIL, for the same call-out.
    --
    -- Gated on having an account and nothing else: notify_recovery is already enforced inside
    -- app.candidates(), so everybody reaching this loop has asked to hear about nearby recoveries.
    -- It is deliberately NOT gated on sms_opt_in -- that is consent to be TEXTED, which costs
    -- money and interrupts a phone, which is why it defaults to false and has its own switch.
    -- Agreeing to one is not agreeing to the other, and somebody who declined texts has not
    -- declined the email. Gating email behind the SMS switch would mean most volunteers hear
    -- nothing at all, which is the failure this whole feature exists to remove.
    --
    -- The row carries IDS, NEVER CONTENT. claim_email_deliveries resolves the recovery facts at
    -- send time, so nothing durable records who was told what about which stuck vehicle.
    --
    -- Idempotent on the dispatch, which is already unique per (request, responder): a retry of
    -- this ring can no more produce a second email than it can produce a second text.
    if resp.user_id is not null then
      insert into public.email_deliveries (user_id, template_key, locale, status,
                                           request_id, dispatch_id, idempotency_key)
      values (resp.user_id, 'recovery.offer',
              case when resp.locale in ('en', 'es') then resp.locale else 'en' end,
              'queued', p_request_id, new_dispatch,
              'recovery_offer:' || new_dispatch)
      on conflict (idempotency_key) where idempotency_key is not null do nothing;
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
$function$;

-- THE DROP GOES IN THE MIGRATION, NEVER IN A SCRIPT.
--
-- Adding `params` changes the function's OUT parameters, and Postgres refuses a create-or-replace
-- that changes a return type: "cannot change return type of existing function". The repo has been
-- here before -- two such statements once stopped the whole migration history replaying, and the
-- fix was worked around in rebuild.mjs so that THAT script worked while `supabase db reset`,
-- `supabase start` and anybody following the README still failed. The rule written down
-- afterwards is this one: put the drop where every replay gets it.
drop function if exists public.claim_email_deliveries(integer);

CREATE OR REPLACE FUNCTION public.claim_email_deliveries(p_limit integer DEFAULT 50)
 RETURNS TABLE(id uuid, user_id uuid, to_email text, template_key text, locale text, params jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
begin
  return query
  with claimed as (
    select d.id
    from public.email_deliveries d
    where d.status = 'queued'
    order by d.created_at
    limit greatest(1, least(coalesce(p_limit, 50), 200))
    for update skip locked
  ),
  marked as (
    update public.email_deliveries d
       set status = 'sending', attempts = d.attempts + 1
      from claimed c
     where d.id = c.id
    returning d.id, d.user_id, d.template_key, d.locale, d.request_id, d.dispatch_id
  )
  select
    m.id, m.user_id, u.email::text, m.template_key, m.locale,
    case
      when m.request_id is null then '{}'::jsonb
      else coalesce((
        select jsonb_build_object(
                 'short_code',         r.short_code,
                 'miles',              dd.distance_miles,
                 'stuck_type',         r.stuck_type,
                 'stuck_depth',        r.stuck_depth,
                 'vehicle_class',      r.vehicle_class,
                 'county',             r.county,
                 'land_type',          r.land_type,
                 'needs_tractor',      r.needs_tractor,
                 'needs_second_truck', r.needs_second_truck
               )
          from public.requests r
          left join public.dispatches dd on dd.id = m.dispatch_id
         where r.id = m.request_id
      ), '{}'::jsonb)
    end
  from marked m
  join auth.users u on u.id = m.user_id
  where u.email is not null;
end;
$function$;

-- A DROP TAKES THE GRANTS WITH IT. Restored exactly as 20260924000300 set them: the drain holds
-- the service role, and anon and authenticated have no business claiming anybody's mail.
revoke all on function public.claim_email_deliveries(integer) from public, anon, authenticated;
grant execute on function public.claim_email_deliveries(integer) to service_role;


notify pgrst, 'reload schema';

-- Did it all land? Shape here; recovery_email_test.sql drives the loop end to end.
select
  (select count(*) from information_schema.columns
    where table_schema = 'public' and table_name = 'email_deliveries'
      and column_name in ('request_id', 'dispatch_id'))                       as columns_added,
  strpos(pg_get_functiondef('app.notify_ring(uuid, integer)'::regprocedure),
         'recovery.offer') > 0                                                as ring_queues_email,
  strpos(pg_get_functiondef('public.claim_email_deliveries(integer)'::regprocedure),
         'short_code') > 0                                                    as claim_builds_params,
  -- Yesterday's per-wave work must survive this replacement.
  strpos(pg_get_functiondef('app.notify_ring(uuid, integer)'::regprocedure),
         'ring_max_helpers') > 0                                              as per_wave_intact;
