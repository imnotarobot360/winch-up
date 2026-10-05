-- Pressing Text cannot call out an unapproved volunteer either.
--
-- Owner's decision, 2026-10-05, completing the one made an hour earlier: approval gates
-- app.candidates() (20261005000900), so the automatic waves skip anybody an admin has not looked
-- at -- but admin_manual_dispatch had no such check, so the Text button in the admin queue was a
-- way round the gate. The promise on /join is "an admin checks every signup before anyone starts
-- getting call-outs", and a route that bypasses it makes that sentence false again by a different
-- path.
--
-- I argued for leaving this open, on the reasoning that an admin deliberately choosing somebody IS
-- the review. The owner read their own promise more strictly. They are right that the two should
-- not disagree: a gate with one documented exception is a gate somebody has to remember, and the
-- admin queue is exactly where a hurried person would reach for it at 2am.
--
-- IT REFUSES BEFORE ANYTHING IS WRITTEN. No dispatch row, no text, no email, no audit entry that
-- implies a call-out happened. The earlier work on this function was careful that withholding a
-- TEXT must not withhold the ALERT -- somebody who declined SMS still gets the dispatch row, which
-- is the alert -- and this is deliberately the opposite case: not approved means not called out at
-- all, by any channel. The distinction is consent (they chose) versus review (nobody has checked).
--
-- The error is NAMED, because 'failed' sends an admin to look for a bug. The dashboard already
-- renders t('err.' || error), so 'not_approved' reaches the screen as a sentence telling them where
-- to go and what to do -- the same reason 'no_sms_consent' and 'stopped' are distinguished rather
-- than lumped together.
--
-- Body read out of the live database, not reconstructed. This function has been rewritten three
-- times today alone (admin cancel's shared core, STOP handling and re-send, then the call-out
-- email), so no single file holds its current definition.

set search_path = public, extensions;

do $mig$
declare
  src    text;
  anchor text;
  hits   int;
begin
  src := pg_get_functiondef('public.admin_manual_dispatch(uuid, uuid)'::regprocedure);

  if position('not_approved' in src) > 0 then
    raise notice 'admin_manual_dispatch already requires approval -- nothing to do';
    return;
  end if;

  -- Immediately after the responder is loaded and before the already-offered handling, so the
  -- refusal lands before a single row is touched.
  anchor := '  select * into resp from public.responders where id = p_responder_id;' || chr(10) ||
            '  if not found then' || chr(10) ||
            '    return jsonb_build_object(''ok'', false, ''error'', ''no_responder'');' || chr(10) ||
            '  end if;';

  hits := array_length(string_to_array(src, anchor), 1) - 1;
  if hits <> 1 then
    raise exception
      'refusing to patch admin_manual_dispatch: anchor matched % times, expected 1', hits;
  end if;

  execute replace(
    src,
    anchor,
    anchor || chr(10) || chr(10) ||
    '  -- NOT APPROVED IS NOT CALLED OUT, by any route.' || chr(10) ||
    '  --' || chr(10) ||
    '  -- app.candidates() gates the automatic waves on this; without the same check here the Text' || chr(10) ||
    '  -- button was a way round it, and /join promises an admin checks every signup before anyone' || chr(10) ||
    '  -- starts getting call-outs. An allowlist, matching candidates(): pending, rejected and' || chr(10) ||
    '  -- banned are all refused, and so is any label added later before somebody has thought' || chr(10) ||
    '  -- about it.' || chr(10) ||
    '  --' || chr(10) ||
    '  -- Before anything is written. No dispatch row, no text, no email. Note the contrast with' || chr(10) ||
    '  -- the SMS rules below: declining texts withholds the TEXT and still writes the dispatch' || chr(10) ||
    '  -- row, because that row is the alert and the member only refused one channel. This is the' || chr(10) ||
    '  -- other kind of refusal -- nobody has reviewed them, so there is no alert to make.' || chr(10) ||
    '  if resp.approval <> ''approved'' then' || chr(10) ||
    '    return jsonb_build_object(''ok'', false, ''error'', ''not_approved'',' || chr(10) ||
    '                             ''approval'', resp.approval);' || chr(10) ||
    '  end if;'
  );
end
$mig$;

notify pgrst, 'reload schema';

select
  strpos(pg_get_functiondef('public.admin_manual_dispatch(uuid, uuid)'::regprocedure),
         'resp.approval <> ''approved''') > 0                       as text_requires_approval,
  -- The refusal must come BEFORE the dispatch insert, or it writes a row and then refuses.
  strpos(pg_get_functiondef('public.admin_manual_dispatch(uuid, uuid)'::regprocedure),
         'not_approved')
    < strpos(pg_get_functiondef('public.admin_manual_dispatch(uuid, uuid)'::regprocedure),
         'insert into public.dispatches')                           as refuses_before_writing,
  -- Today's earlier work on this same function must survive a third patch.
  strpos(pg_get_functiondef('public.admin_manual_dispatch(uuid, uuid)'::regprocedure),
         'sms_opt_out_at') > 0                                      as honours_stop,
  strpos(pg_get_functiondef('public.admin_manual_dispatch(uuid, uuid)'::regprocedure),
         'v_resent') > 0                                            as resend_intact,
  strpos(pg_get_functiondef('public.admin_manual_dispatch(uuid, uuid)'::regprocedure),
         'recovery.offer') > 0                                      as emails_too_intact;
