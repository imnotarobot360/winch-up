-- Pressing Text in the admin queue must honour STOP, and must be able to try twice.
--
-- Three faults in one function, all found on 2026-10-05 when the owner pressed Text and got the
-- bare string "already_offered" back.
--
-- 1. IT TEXTED PEOPLE WHO HAD DECLINED. app.notify_ring() gates the call-out on phone +
--    sms_opt_in + no opt-out stamp. admin_manual_dispatch gated on nothing and called
--    app.queue_sms unconditionally -- so an admin pressing Text messaged a volunteer who had
--    explicitly declined recovery texts, including one who replied STOP. That is the refusal
--    that is not a preference. Consent was made explicit everywhere else yesterday while this
--    path quietly ignored it, and two paths disagreeing about consent is worse than either
--    answer alone.
--
-- 2. A SECOND PRESS COULD ONLY EVER FAIL. The function refused when a dispatch row already
--    existed, so once a volunteer had an offer there was no way to nudge them again -- phone
--    off, driving, first text eaten by a carrier, all the same dead end. The unique constraint
--    on (request_id, responder_id) is right and stays; a re-send reuses the existing row.
--
-- 3. IT COULD NOT SAY WHAT IT DID. 'ok' covered texted, not-texted and nothing-to-do alike. It
--    now returns resent, texted and a reason, so the screen can say which happened.
--
-- NOT TEXTING IS NOT NOT ALERTING. The dispatch row is the alert and is still written when
-- consent is absent: the volunteer gets it by push and in-app, exactly as the automatic rings
-- deliver it. Only the text is withheld.
--
-- Body read out of the live database with pg_get_functiondef rather than copied from a migration
-- file, because two migrations name this function and the grep that finds declarations does not
-- find the ones that patch.

set search_path = public, extensions;

CREATE OR REPLACE FUNCTION public.admin_manual_dispatch(p_request_id uuid, p_responder_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  req      public.requests%rowtype;
  resp     public.responders%rowtype;
  distance numeric;
  offer_id uuid;
  v_resent boolean := false;
  v_may_text boolean;
begin
  perform app.require_admin();

  select * into req from public.requests where id = p_request_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  select * into resp from public.responders where id = p_responder_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_responder');
  end if;

  -- ALREADY OFFERED IS NOT A DEAD END ANY MORE.
  --
  -- It used to return an error and stop, so once somebody had an offer for a recovery the Text
  -- button could only ever refuse -- and there was no way to try again for a volunteer whose
  -- phone was off, who was driving, or whose first text was eaten by a carrier. The unique
  -- constraint on (request_id, responder_id) means we must not write a second dispatch row, so a
  -- re-send reuses the existing one: same offer, another nudge.
  select id into offer_id
    from public.dispatches
   where request_id = p_request_id and responder_id = p_responder_id;

  v_resent := offer_id is not null;

  distance := round((extensions.st_distance(resp.home_location, req.location) / 1609.344)::numeric, 2);

  if not v_resent then
    insert into public.dispatches (request_id, responder_id, ring, distance_miles, state, is_manual)
    values (p_request_id, p_responder_id, greatest(1, req.current_ring), distance, 'queued', true)
    returning id into offer_id;
  end if;

  -- THIS PATH USED TO TEXT ANYBODY, INCLUDING SOMEBODY WHO REPLIED STOP.
  --
  -- app.notify_ring() has always gated the call-out on phone + sms_opt_in + no opt-out stamp.
  -- This one gated on nothing and called queue_sms unconditionally, so an admin pressing Text
  -- messaged a volunteer who had explicitly declined recovery texts -- and a STOP reply is the
  -- one refusal that is not merely a preference. Two paths disagreeing about whether somebody has
  -- consented is worse than either answer on its own.
  --
  -- NOT TEXTING IS NOT THE SAME AS NOT ALERTING. The dispatch row above is the alert, and it
  -- still happens: they get it by push and in-app exactly as the automatic rings would deliver
  -- it. The admin is told which of the two occurred rather than left to assume a text went out.
  v_may_text := resp.phone is not null
                and coalesce(resp.sms_opt_in, false)
                and resp.sms_opt_out_at is null;

  if v_may_text then
  perform app.queue_sms(
    resp.phone, 'responder.offer',
    jsonb_build_object(
      'short_code', req.short_code, 'miles', distance,
      'stuck_type', req.stuck_type, 'stuck_depth', req.stuck_depth,
      'vehicle_class', req.vehicle_class, 'county', req.county,
      'land_type', req.land_type,
      'needs_tractor', req.needs_tractor, 'needs_second_truck', req.needs_second_truck
    ),
    resp.locale, p_request_id, p_responder_id, offer_id
  );
  end if;

  -- A re-send reaches nobody new, so the count must not move. It is what the queue prints as
  -- "N notified", and an admin pressing Text four times should not make a recovery look like it
  -- reached four volunteers.
  if not v_resent then
    update public.requests set notified_count = notified_count + 1 where id = p_request_id;
  end if;

  perform app.audit(
    case when v_resent then 'request.manual_resend' else 'request.manual_dispatch' end,
    'request', p_request_id::text,
    jsonb_build_object('responder_id', p_responder_id, 'miles', distance, 'texted', v_may_text)
  );

  -- The caller is told which of the three things happened, because "ok" covered all of them and
  -- the admin could not tell a text from a push from a silent no-op.
  return jsonb_build_object(
    'ok', true,
    'miles', distance,
    'resent', v_resent,
    'texted', v_may_text,
    'reason', case when v_may_text then null
                   when resp.phone is null then 'no_phone'
                   when resp.sms_opt_out_at is not null then 'stopped'
                   else 'no_sms_consent' end
  );
end;
$function$;

notify pgrst, 'reload schema';

select
  strpos(pg_get_functiondef('public.admin_manual_dispatch(uuid, uuid)'::regprocedure),
         'sms_opt_in') > 0                                               as honours_consent,
  strpos(pg_get_functiondef('public.admin_manual_dispatch(uuid, uuid)'::regprocedure),
         'sms_opt_out_at') > 0                                           as honours_stop,
  strpos(pg_get_functiondef('public.admin_manual_dispatch(uuid, uuid)'::regprocedure),
         'already_offered') = 0                                          as resend_replaces_dead_end,
  has_function_privilege('authenticated', 'public.admin_manual_dispatch(uuid, uuid)', 'execute')
                                                                          as still_callable_by_admins;
