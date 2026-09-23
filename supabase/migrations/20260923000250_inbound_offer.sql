-- Winch Up :: replying `1` puts your hand up, it does not take the job
--
-- Two functions still carried the old behaviour after 20260923000200:
--
--   app.accept_request       the original three-argument assign, approval gate and all. It is
--                            still called by admin_manual_dispatch, so it cannot simply be
--                            dropped -- but leaving a second, older assignment path in the
--                            database is exactly how "a double accept must be impossible" stops
--                            being true. It becomes a thin delegate: one body, one lock, one
--                            place where somebody gets assigned.
--
--   handle_inbound_sms       replying `1` called that assign directly. Now it records an offer.
--
-- The reply copy has to change with it. The old flow could honestly say "it's yours"; this one
-- cannot, and telling a volunteer they have the job when the requester has not chosen yet would
-- send them driving to a recovery somebody else may be assigned.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- One assignment path, not two
-- ---------------------------------------------------------------------------

create or replace function app.accept_request(
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
begin
  -- Kept only because admin_manual_dispatch calls it, and an admin assigning somebody by hand is
  -- still a legitimate thing to do. Everything it used to do itself now happens in one place.
  return app.assign_responder(p_request_id, p_responder_id, p_eta_minutes);
end;
$fn$;

revoke all on function app.accept_request(uuid, uuid, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Inbound SMS
-- ---------------------------------------------------------------------------

create or replace function public.handle_inbound_sms(
  p_from       text,
  p_body       text,
  p_to         text default null,
  p_twilio_sid text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  resp     public.responders%rowtype;
  body     text := upper(btrim(coalesce(p_body, '')));
  word     text;
  eta      integer;
  offer    record;
  job      record;
  outcome  jsonb;
begin
  insert into public.sms_messages (direction, state, to_phone, from_phone, body, twilio_sid)
  values ('inbound', 'received', coalesce(p_to, 'unknown'), p_from, p_body, p_twilio_sid)
  on conflict (twilio_sid) do nothing;

  select * into resp from public.responders where phone = p_from;

  word := split_part(body, ' ', 1);
  eta  := nullif(regexp_replace(coalesce(split_part(body, ' ', 2), ''), '[^0-9]', '', 'g'), '')::integer;

  if word in ('STOP', 'STOPALL', 'UNSUBSCRIBE', 'CANCEL', 'END', 'QUIT', 'BAJA') then
    if resp.id is not null then
      update public.responders
         set sms_opt_in = false, sms_opt_out_at = now(), availability = 'paused'
       where id = resp.id;
    end if;
    return jsonb_build_object('ok', true, 'action', 'stop', 'reply_template', null);
  end if;

  if word in ('START', 'UNSTOP', 'YES-START', 'ALTA') then
    if resp.id is not null then
      update public.responders
         set sms_opt_in = true, sms_opt_out_at = null, availability = 'active'
       where id = resp.id;
    end if;
    return jsonb_build_object(
      'ok', true, 'action', 'start',
      'reply_template', 'responder.started',
      'locale', coalesce(resp.locale, 'en'), 'params', '{}'::jsonb
    );
  end if;

  if resp.id is null then
    return jsonb_build_object(
      'ok', true, 'action', 'unknown_sender',
      'reply_template', 'unknown.no_account',
      'locale', 'en', 'params', '{}'::jsonb
    );
  end if;

  if word in ('HELP', 'INFO', 'AYUDA') then
    return jsonb_build_object(
      'ok', true, 'action', 'help',
      'reply_template', 'responder.help',
      'locale', resp.locale, 'params', '{}'::jsonb
    );
  end if;

  if word in ('HERE', 'ONSITE', 'ON', 'LLEGUE', 'LLEGUÉ') then
    select r.id, r.short_code into job
      from public.requests r
     where r.accepted_responder_id = resp.id and r.status = 'accepted'
     order by r.accepted_at desc limit 1;

    if job.id is null then
      return jsonb_build_object('ok', true, 'action', 'no_job',
        'reply_template', 'responder.no_open_job', 'locale', resp.locale, 'params', '{}'::jsonb);
    end if;

    outcome := app.responder_on_site(job.id, resp.id);
    return jsonb_build_object('ok', true, 'action', 'on_site',
      'reply_template', 'responder.on_site_ack', 'locale', resp.locale,
      'params', jsonb_build_object('short_code', job.short_code));
  end if;

  if word in ('DONE', 'OUT', 'RECOVERED', 'LISTO', 'YA') then
    select r.id, r.short_code into job
      from public.requests r
     where r.accepted_responder_id = resp.id and r.status in ('accepted', 'on_site')
     order by r.accepted_at desc limit 1;

    if job.id is null then
      return jsonb_build_object('ok', true, 'action', 'no_job',
        'reply_template', 'responder.no_open_job', 'locale', resp.locale, 'params', '{}'::jsonb);
    end if;

    outcome := app.responder_complete(job.id, resp.id);
    return jsonb_build_object('ok', true, 'action', 'complete',
      'reply_template', 'responder.complete_ack', 'locale', resp.locale,
      'params', jsonb_build_object('short_code', job.short_code));
  end if;

  -- The invitation they are answering. 'offered' is included so that replying `1` twice is
  -- harmless rather than an error -- a volunteer who texts again because they did not see a
  -- confirmation should not be told there is no open job.
  select d.request_id, r.short_code into offer
    from public.dispatches d
    join public.requests r on r.id = d.request_id
   where d.responder_id = resp.id
     and d.state in ('queued', 'sent', 'delivered', 'offered')
     and r.status in ('submitted', 'dispatching', 'unmatched')
   order by coalesce(d.sent_at, d.queued_at) desc, d.queued_at desc
   limit 1;

  if word in ('1', 'YES', 'Y', 'SI', 'SÍ', 'OK', 'TAKE') then
    if offer.request_id is null then
      return jsonb_build_object('ok', true, 'action', 'no_offer',
        'reply_template', 'responder.no_open_job', 'locale', resp.locale, 'params', '{}'::jsonb);
    end if;

    -- An offer, not an assignment. equipment_ack is true here because the outbound text names
    -- what the recovery needs and replying `1` is the answer to that question -- the same
    -- acknowledgement the app asks for on screen, in the form the channel allows.
    outcome := app.record_offer(offer.request_id, resp.id, null, eta, true, 'ring');

    if (outcome ->> 'ok')::boolean then
      return jsonb_build_object('ok', true, 'action', 'offered',
        'reply_template', 'responder.offer_received', 'locale', resp.locale,
        'params', jsonb_build_object('short_code', offer.short_code));
    end if;

    return jsonb_build_object('ok', true, 'action', outcome ->> 'error',
      'reply_template', 'responder.already_covered', 'locale', resp.locale,
      'params', jsonb_build_object('short_code', offer.short_code));
  end if;

  if word in ('2', 'NO', 'N', 'PASS', 'PASO') then
    if offer.request_id is null then
      return jsonb_build_object('ok', true, 'action', 'no_offer',
        'reply_template', 'responder.no_open_job', 'locale', resp.locale, 'params', '{}'::jsonb);
    end if;

    perform app.decline_dispatch(offer.request_id, resp.id);
    return jsonb_build_object('ok', true, 'action', 'declined',
      'reply_template', 'responder.declined_ack', 'locale', resp.locale, 'params', '{}'::jsonb);
  end if;

  return jsonb_build_object(
    'ok', true, 'action', 'unparsed',
    'reply_template', 'responder.help',
    'locale', resp.locale, 'params', '{}'::jsonb
  );
end;
$fn$;

revoke execute on function public.handle_inbound_sms(text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.handle_inbound_sms(text, text, text, text) to service_role;
