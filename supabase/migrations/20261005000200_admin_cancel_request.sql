-- An admin can close a request. Until now nobody could but the person who filed it.
--
-- `cancel_request_by_token` was the ONLY cancel path, and it needs the requester's token. So a
-- request filed and then abandoned -- a test, a duplicate, somebody who got pulled out by a mate
-- and closed the tab, somebody who lost the link -- sat on the PUBLIC BOARD until the 24-hour
-- expiry, with no one able to clear it. Found on 2026-10-05 trying to cancel a test recovery:
-- there is no admin equivalent, and `/admin` has a queue it cannot act on in that one way.
--
-- THE CORE IS EXTRACTED RATHER THAN COPIED. Cancelling means four things -- close the request,
-- stand down the outstanding dispatches, tell the accepted volunteer, leave the audit trail -- and
-- writing that twice is how the two paths drift until one of them forgets to stand down the
-- dispatches. `app.cancel_request()` is now the single answer, and both public functions are thin
-- wrappers that differ only in how they establish WHO is allowed to do it.
--
-- WHAT THE ADMIN PATH ADDS beyond the token path: an audit row, because every mutating admin RPC
-- writes one, and a reason that is recorded rather than optional-in-practice -- "why did this
-- disappear from the board" should have an answer that is not "an admin, at some point".
--
-- The body below was read out of the live database with pg_get_functiondef and then split, not
-- retyped from the migration that first created it.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- What cancelling a recovery actually means. One place.
-- ---------------------------------------------------------------------------
create or replace function app.cancel_request(p_request_id uuid, p_reason text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  r public.requests%rowtype;
begin
  -- FOR UPDATE, exactly as the token path did: two cancels racing must not both stand down the
  -- dispatches and both text the volunteer.
  select * into r from public.requests where id = p_request_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if r.status in ('recovered', 'cancelled', 'expired') then
    return jsonb_build_object('ok', false, 'error', 'already_closed', 'status', r.status);
  end if;

  update public.requests
     set status         = 'cancelled',
         cancelled_at   = now(),
         cancel_reason  = nullif(btrim(coalesce(p_reason, '')), ''),
         -- Stop the tick looking at it again. Without this an admin-cancelled request keeps a
         -- due time and advance_one wakes up to find nothing to do, forever.
         next_action_at = null
   where id = r.id
   returning * into r;

  -- Outstanding offers are stood down, or a volunteer answers 1 to a recovery that is over and
  -- gets told their job was cancelled by a path that assumed they were assigned to it.
  update public.dispatches
     set state = 'superseded'
   where request_id = r.id
     and state in ('queued', 'sent', 'delivered');

  -- Somebody may already be driving. They are told however the cancel was initiated -- this is
  -- the part that would have been easiest to leave out of a second copy.
  if r.accepted_responder_id is not null then
    perform app.queue_sms(
      resp.phone, 'responder.job_cancelled',
      jsonb_build_object('short_code', r.short_code),
      resp.locale, r.id, resp.id
    )
    from public.responders resp where resp.id = r.accepted_responder_id;
  end if;

  return jsonb_build_object('ok', true, 'status', r.status, 'short_code', r.short_code);
end;
$fn$;

revoke all on function app.cancel_request(uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The requester's path, now a wrapper. Behaviour unchanged.
-- ---------------------------------------------------------------------------
create or replace function public.cancel_request_by_token(p_token text, p_reason text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_id uuid;
begin
  -- The token IS the authorisation here, and it is all this wrapper contributes.
  select id into v_id from public.requests where public_token = p_token;
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return app.cancel_request(v_id, p_reason);
end;
$fn$;

revoke execute on function public.cancel_request_by_token(text, text) from public, anon, authenticated;
grant execute on function public.cancel_request_by_token(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- The admin's path
-- ---------------------------------------------------------------------------
create or replace function public.admin_cancel_request(p_request_id uuid, p_reason text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_result jsonb;
begin
  -- Returns VOID, so performed rather than assigned: assigning it compiles and fails on the first
  -- call, because plpgsql does not check a body until it runs.
  perform app.require_admin();

  v_result := app.cancel_request(p_request_id, p_reason);

  -- AUDITED ONLY WHEN SOMETHING HAPPENED. A refused call -- already closed, no such request --
  -- is not an administrative act on a recovery, and logging it would bury the real ones.
  if coalesce((v_result ->> 'ok')::boolean, false) then
    perform app.audit(
      'request.cancelled', 'request', p_request_id::text,
      jsonb_build_object(
        'reason', nullif(btrim(coalesce(p_reason, '')), ''),
        'short_code', v_result ->> 'short_code'
      )
    );
  end if;

  return v_result;
end;
$fn$;

-- Granted to `authenticated`, not service_role: the gate is auth.uid() through app.require_admin(),
-- so there is no shared key that confers admin. Same as every other admin RPC here.
revoke all on function public.admin_cancel_request(uuid, text) from public, anon;
grant execute on function public.admin_cancel_request(uuid, text) to authenticated;

notify pgrst, 'reload schema';

-- Shape here; admin_cancel_test.sql drives the behaviour, including that an ordinary member is
-- refused and that the dispatches really are stood down.
select
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'admin_cancel_request')          as admin_fn_exists,
  has_function_privilege('authenticated', 'public.admin_cancel_request(uuid, text)', 'execute')
                                                                                as authenticated_may_call,
  has_function_privilege('anon', 'public.admin_cancel_request(uuid, text)', 'execute')
                                                                                as anon_may_call,
  -- The token path must still exist and must now go through the shared core.
  strpos(pg_get_functiondef('public.cancel_request_by_token(text, text)'::regprocedure),
         'app.cancel_request') > 0                                              as token_path_shares_core;
