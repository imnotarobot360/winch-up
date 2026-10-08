-- Everybody who was called out is told HOW the recovery ended, by every channel they have.
--
-- WHAT WAS THERE. app.stand_down_open_offers is the single place an outstanding offer is closed --
-- called by a trigger whenever a request reaches recovered, cancelled or expired, which is right and
-- stays. For each volunteer it queued 'responder.already_covered' BY SMS ONLY.
--
-- Two faults in that.
--
--   1. SMS ONLY. No email, no push. sms_opt_in defaults false and is a separate consent, so a
--      volunteer who has not opted into texts is called out (by email and push, since
--      20261005000800) and then told NOTHING when the recovery ends. They are left holding an alert
--      that is never withdrawn -- the Facebook-comment-thread behaviour this product replaces.
--      Three volunteers approved on 2026-10-05 are in exactly that state: email yes, texts no.
--
--   2. IT ALWAYS SAID "ALREADY COVERED". The same words go out when the requester CANCELLED and
--      when the request EXPIRED with nobody able to go -- so a volunteer who offered and heard
--      nothing for 25 minutes was told somebody else had it covered, which is false and is the
--      opposite of the truth: nobody came. The trigger has always known which of the three
--      happened; the message never used it.
--
-- WHAT THIS DOES. Adds email and push beside the existing text, and makes the wording depend on how
-- the recovery actually ended. The SMS path is untouched on purpose -- 'responder.already_covered' is
-- in sms.enabled_templates and changing which template a consented member receives is a separate
-- decision from adding channels that were missing.
--
-- Found by preparing a file-and-cancel test against those three volunteers, on my own suggestion
-- that cancelling would explain itself to them. It would not have.
--
-- Bodies read out of the live database, not reconstructed.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. The email needs to know how it ended
-- ---------------------------------------------------------------------------
--
-- claim_email_deliveries resolves a recovery's facts at SEND time, which is why email_deliveries
-- rows carry ids and no content. It built every fact except the one a stand-down turns on. Read at
-- send time the status is still correct, because a closed recovery does not reopen.

do $mig1$
declare
  src    text;
  anchor text;
  hits   int;
begin
  src := pg_get_functiondef('public.claim_email_deliveries(integer)'::regprocedure);

  if position('''status'',             r.status' in src) > 0 then
    raise notice 'claim_email_deliveries already carries status -- nothing to do';
  else
    anchor := '                 ''short_code'',         r.short_code,';
    hits := array_length(string_to_array(src, anchor), 1) - 1;
    if hits <> 1 then
      raise exception 'refusing to patch claim_email_deliveries: anchor matched %, expected 1', hits;
    end if;
    execute replace(src, anchor,
      anchor || chr(10) ||
      '                 ''status'',             r.status,');
  end if;
end
$mig1$;

-- ---------------------------------------------------------------------------
-- 2. The stand-down reaches every channel the volunteer has
-- ---------------------------------------------------------------------------

do $mig2$
declare
  src    text;
  anchor text;
  hits   int;
begin
  src := pg_get_functiondef('app.stand_down_open_offers(uuid)'::regprocedure);

  if position('recovery.stood_down' in src) > 0 then
    raise notice 'app.stand_down_open_offers already notifies by email and push -- nothing to do';
    return;
  end if;

  -- The loop has to carry user_id, which it never selected: SMS needs a phone, the other two need
  -- an account.
  anchor := '    select d.id, r.phone, r.locale, r.sms_opt_in, r.sms_opt_out_at';
  hits := array_length(string_to_array(src, anchor), 1) - 1;
  if hits <> 1 then
    raise exception 'refusing to patch stand_down_open_offers: select anchor matched %', hits;
  end if;
  src := replace(src, anchor,
    '    select d.id, d.responder_id, r.user_id, r.phone, r.locale, r.sms_opt_in, r.sms_opt_out_at');

  -- And the notifications go in beside the text, not instead of it.
  anchor := '    v_count := v_count + 1;';
  hits := array_length(string_to_array(src, anchor), 1) - 1;
  if hits <> 1 then
    raise exception 'refusing to patch stand_down_open_offers: count anchor matched %', hits;
  end if;

  src := replace(src, anchor,
    '    -- EMAIL AND PUSH, beside the text rather than instead of it.' || chr(10) ||
    '    --' || chr(10) ||
    '    -- sms_opt_in defaults false and is its own consent, so SMS alone meant a volunteer who' || chr(10) ||
    '    -- declined texts was called out and then never told the recovery had ended. Push because a' || chr(10) ||
    '    -- stand-down is MORE urgent than the call-out, not less: they may be pulling boots on.' || chr(10) ||
    '    if v_offer.user_id is not null then' || chr(10) ||
    '      perform app.notify(' || chr(10) ||
    '        v_offer.user_id,' || chr(10) ||
    '        ''recovery_status''::notification_kind,' || chr(10) ||
    '        ''notify.responder.stood_down.'' || v_req.status::text,' || chr(10) ||
    '        jsonb_build_object(''short_code'', v_req.short_code),' || chr(10) ||
    '        ''/me'',' || chr(10) ||
    '        array[''in_app'', ''push'']::notification_channel[],' || chr(10) ||
    '        -- One per volunteer per recovery, whatever retries the tick makes.' || chr(10) ||
    '        ''standdown:'' || p_request_id::text || '':'' || v_offer.responder_id::text' || chr(10) ||
    '      );' || chr(10) || chr(10) ||
    '      insert into public.email_deliveries (user_id, template_key, locale, status,' || chr(10) ||
    '                                           request_id, dispatch_id, idempotency_key)' || chr(10) ||
    '      values (v_offer.user_id, ''recovery.stood_down'',' || chr(10) ||
    '              case when v_offer.locale in (''en'', ''es'') then v_offer.locale else ''en'' end,' || chr(10) ||
    '              ''queued'', p_request_id, v_offer.id,' || chr(10) ||
    '              ''stood_down:'' || v_offer.id::text)' || chr(10) ||
    '      on conflict (idempotency_key) where idempotency_key is not null do nothing;' || chr(10) ||
    '    end if;' || chr(10) || chr(10) ||
    anchor);

  execute src;
end
$mig2$;

-- ---------------------------------------------------------------------------
-- 3. And the volunteer who is already driving
-- ---------------------------------------------------------------------------
--
-- stand_down_open_offers covers the volunteers holding OFFERS: its loop is state in ('queued',
-- 'sent', 'delivered', 'offered'), which deliberately excludes the one who accepted, because they
-- were not stood down -- they were on the job.
--
-- That person is handled in app.cancel_request, by a single queue_sms of 'responder.job_cancelled'.
-- THAT TEMPLATE IS NOT IN sms.enabled_templates, so app.queue_sms suppresses it. The volunteer
-- actually driving to a recovery that gets called off is therefore the one person told nothing at
-- all, by any channel -- while the ones who merely offered now get an email and a push.
--
-- RECOMMENDED SEPARATELY, deliberately not done here: add that template to the allowlist. A text to
-- somebody at the wheel is exactly what the channel is for, and the allowlist exists so no template
-- starts costing money and interrupting people without a person deciding. That decision is the
-- owner's:
--   update app_settings set value = value || '["responder.job_cancelled"]'::jsonb
--    where key = 'sms.enabled_templates';

do $mig3$
declare
  src    text;
  anchor text;
  hits   int;
begin
  src := pg_get_functiondef('app.cancel_request(uuid, text)'::regprocedure);

  if position('recovery.stood_down' in src) > 0 then
    raise notice 'app.cancel_request already tells the accepted volunteer -- nothing to do';
    return;
  end if;

  anchor := '  if r.accepted_responder_id is not null then';
  hits := array_length(string_to_array(src, anchor), 1) - 1;
  if hits <> 1 then
    raise exception 'refusing to patch cancel_request: anchor matched %, expected 1', hits;
  end if;

  src := replace(src, anchor,
    '  -- BY EVERY CHANNEL THEY HAVE, not just the text that is currently suppressed. This is the' || chr(10) ||
    '  -- person most likely to be in the truck already.' || chr(10) ||
    '  if r.accepted_responder_id is not null then' || chr(10) ||
    '    perform app.notify(' || chr(10) ||
    '      resp.user_id,' || chr(10) ||
    '      ''recovery_status''::notification_kind,' || chr(10) ||
    '      ''notify.responder.stood_down.cancelled'',' || chr(10) ||
    '      jsonb_build_object(''short_code'', r.short_code),' || chr(10) ||
    '      ''/me'',' || chr(10) ||
    '      array[''in_app'', ''push'']::notification_channel[],' || chr(10) ||
    '      ''standdown:'' || r.id::text || '':'' || resp.id::text' || chr(10) ||
    '    )' || chr(10) ||
    '    from public.responders resp' || chr(10) ||
    '     where resp.id = r.accepted_responder_id and resp.user_id is not null;' || chr(10) || chr(10) ||
    '    insert into public.email_deliveries (user_id, template_key, locale, status,' || chr(10) ||
    '                                         request_id, idempotency_key)' || chr(10) ||
    '    select resp.user_id, ''recovery.stood_down'',' || chr(10) ||
    '           case when resp.locale in (''en'', ''es'') then resp.locale else ''en'' end,' || chr(10) ||
    '           ''queued'', r.id, ''stood_down_accepted:'' || r.id::text' || chr(10) ||
    '      from public.responders resp' || chr(10) ||
    '     where resp.id = r.accepted_responder_id and resp.user_id is not null' || chr(10) ||
    '    on conflict (idempotency_key) where idempotency_key is not null do nothing;' || chr(10) || chr(10) ||
    '  end if;' || chr(10) || chr(10) ||
    '  if r.accepted_responder_id is not null then');

  execute src;
end
$mig3$;

notify pgrst, 'reload schema';

select
  strpos(pg_get_functiondef('app.stand_down_open_offers(uuid)'::regprocedure),
         'recovery.stood_down') > 0                                  as emails_the_stand_down,
  strpos(pg_get_functiondef('app.stand_down_open_offers(uuid)'::regprocedure),
         'array[''in_app'', ''push'']') > 0                          as pushes_the_stand_down,
  -- The wording must depend on how it ended. Always saying "already covered" was the second fault.
  strpos(pg_get_functiondef('app.stand_down_open_offers(uuid)'::regprocedure),
         'stood_down.'' || v_req.status') > 0                        as wording_follows_the_ending,
  -- The existing text must survive: this adds channels, it does not replace one.
  strpos(pg_get_functiondef('app.stand_down_open_offers(uuid)'::regprocedure),
         'responder.already_covered') > 0                            as text_path_intact,
  strpos(pg_get_functiondef('app.stand_down_open_offers(uuid)'::regprocedure),
         'sms_opt_out_at is null') > 0                               as stop_still_honoured,
  strpos(pg_get_functiondef('public.claim_email_deliveries(integer)'::regprocedure),
         'r.status') > 0                                             as email_knows_the_ending,
  -- The person driving is told too, and the suppressed text they used to rely on is still attempted.
  strpos(pg_get_functiondef('app.cancel_request(uuid, text)'::regprocedure),
         'recovery.stood_down') > 0                                   as driver_told_by_email,
  strpos(pg_get_functiondef('app.cancel_request(uuid, text)'::regprocedure),
         'responder.job_cancelled') > 0                               as driver_text_still_attempted;
