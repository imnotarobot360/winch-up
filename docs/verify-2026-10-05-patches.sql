-- Winch Up :: the two patches applied by hand on 2026-10-05, re-verified
--
-- READ ONLY. 20261005001000 and 20261005001100 rewrite function bodies through pg_get_functiondef
-- and declare nothing, so docs/verify-group-b.sql cannot extract a marker for them -- they are 2 of
-- its 11 unverifiable. Their evidence is their OWN trailing verification query, the one that ran
-- when they were applied and printed every column true.
--
-- Re-running it is the owner's instruction: keep that evidence, and confirm independently that both
-- are COMPLETELY applied rather than partially. EVERY COLUMN BELOW MUST READ t.
--
-- Extracted verbatim from the migration files; regenerate rather than editing.

set search_path = public, extensions;

-- 20261005001000_manual_dispatch_needs_approval.sql
select
  '20261005001000' as migration,
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

-- 20261005001100_stand_down_tells_everyone.sql
select
  '20261005001100' as migration,
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
