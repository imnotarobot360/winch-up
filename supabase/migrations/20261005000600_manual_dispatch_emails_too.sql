-- Pressing Text also sends the email, as the automatic waves already do.
--
-- notify_ring has queued a 'recovery.offer' email beside the text since 20261005000100.
-- admin_manual_dispatch did not, so the two ways of alerting the same volunteer about the same
-- recovery used different channels -- and nobody noticed, because the SMS half usually worked.
--
-- On 2026-10-05 it did not: Twilio refused the account's auth token
-- ("authentication failed, auth token is not valid for account AC..."), so pressing Text queued
-- one message that could not be delivered and no email at all, while the email path was provably
-- healthy -- three welcome emails sent through Resend that same day, DKIM and SPF verified.
-- The owner pressed Text, nothing arrived, and the one channel that would have worked had never
-- been written.
--
-- A re-send queues a NEW email rather than being swallowed by the idempotency key. The key stops
-- a retried WAVE double-sending; an admin pressing Text twice is an explicit instruction to nudge
-- again, and quietly doing nothing is the dead end this path was rescued from this morning.
--
-- Body read out of the live database, not copied from a file.

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

  -- AND BY EMAIL, exactly as the automatic waves do.
  --
  -- notify_ring has queued a 'recovery.offer' email beside the text since 20261005000100. This
  -- path did not, so an admin pressing Text sent one channel where a wave sends two -- and on
  -- 2026-10-05, with Twilio refusing the account's auth token, that meant pressing Text reached
  -- nobody at all while the email that would have worked was never written. Two ways of alerting
  -- the same volunteer about the same recovery should not differ in which channels they use.
  --
  -- Gated on having an account and nothing else: notify_recovery is enforced where the candidate
  -- list is built, and email is not metered or interrupting the way a text is, so it is
  -- deliberately NOT behind sms_opt_in.
  --
  -- A RE-SEND QUEUES A NEW EMAIL, which is why the idempotency key is dropped for one. The key
  -- exists so a retried wave cannot double-send; an admin pressing Text a second time is an
  -- explicit instruction to nudge again, and silently doing nothing would be the same dead end
  -- this path had before.
  if resp.user_id is not null then
    insert into public.email_deliveries (user_id, template_key, locale, status,
                                         request_id, dispatch_id, idempotency_key)
    values (resp.user_id, 'recovery.offer',
            case when resp.locale in ('en', 'es') then resp.locale else 'en' end,
            'queued', p_request_id, offer_id,
            case when v_resent then null else 'recovery_offer:' || offer_id end)
    on conflict (idempotency_key) where idempotency_key is not null do nothing;
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
    'emailed', resp.user_id is not null,
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
         'recovery.offer') > 0                                        as queues_the_email,
  -- This morning's work on the same function must survive.
  strpos(pg_get_functiondef('public.admin_manual_dispatch(uuid, uuid)'::regprocedure),
         'sms_opt_in') > 0                                            as still_honours_consent,
  strpos(pg_get_functiondef('public.admin_manual_dispatch(uuid, uuid)'::regprocedure),
         'sms_opt_out_at') > 0                                        as still_honours_stop,
  strpos(pg_get_functiondef('public.admin_manual_dispatch(uuid, uuid)'::regprocedure),
         'v_resent') > 0                                              as resend_intact;
