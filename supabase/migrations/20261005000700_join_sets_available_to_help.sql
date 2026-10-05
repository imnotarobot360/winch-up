-- Finishing /join: completing the volunteer form is what makes somebody dispatchable.
--
-- THE GAP THIS CLOSES. `profiles.available_to_help` is what app.candidates() matches on, it is
-- `not null default false`, and until now exactly two things had ever written it: a one-time
-- backfill in 20260923000100, and set_available_to_help() behind a toggle on /account/notifications.
-- upsert_responder_profile -- the function BEHIND THE VOLUNTEER FORM -- has never touched it, in
-- any of the five migrations that define it.
--
-- So a member filled in /join (home location, radius, equipment, a verified phone), was returned to
-- the home page, and was not dispatched to. Nothing was broken on screen and no error was raised
-- anywhere; they simply were not in the candidate set. Found on 2026-10-05 with three such members
-- sitting 0, 15 and 28 miles from the owner, every one of them skipped. The notifications screen
-- even knows the dependency runs the other way -- its own copy reads "Turn on I'm willing to help
-- above and add your number" -- so that screen knows about /join and /join did not know about it.
--
-- WHY A PAYLOAD KEY AND NOT AN UNCONDITIONAL SET. This same function is how a member edits their
-- radius later, and the key-present test is the same rule the phone already follows here: a caller
-- that does not mention a field must not change it. An unconditional write would mean editing your
-- radius silently re-consents you to 2am call-outs you had deliberately turned off. A payload that
-- names the key and gives a false value DOES turn it off -- that is the member unticking the box.
--
-- The body is read out of the live database and patched, never reconstructed from these files.
-- Five migrations define this function and two of them patch it exactly this way, so the newest
-- definition is not in any single file -- rebuilding it from the newest-looking one reverted four
-- migrations' work on app.candidates() yesterday.

set search_path = public, extensions;

do $mig$
declare
  src    text;
  anchor text;
  added  text;
  hits   int;
begin
  src := pg_get_functiondef('public.upsert_responder_profile(jsonb)'::regprocedure);

  -- Idempotent: re-running must not double-insert. This migration may be applied by hand.
  if position('available_to_help' in src) > 0 then
    raise notice 'upsert_responder_profile already sets available_to_help -- nothing to do';
    return;
  end if;

  anchor := '  return jsonb_build_object(' || chr(10) ||
            '    ''ok'', true,' || chr(10) ||
            '    ''responder_id'', me.id,';

  hits := array_length(string_to_array(src, anchor), 1) - 1;
  if hits <> 1 then
    raise exception
      'refusing to patch upsert_responder_profile: anchor matched % times, expected 1', hits;
  end if;

  added :=
    '  -- Willing to be called out. The form says so in words next to a checkbox; this is where' || chr(10) ||
    '  -- that answer lands. Only written when the payload NAMES the key, so editing a radius from' || chr(10) ||
    '  -- a client that does not send it cannot change a consent the member set deliberately.' || chr(10) ||
    '  if p_payload ? ''available_to_help'' then' || chr(10) ||
    '    update public.profiles' || chr(10) ||
    '       set available_to_help = coalesce((p_payload ->> ''available_to_help'')::boolean, false),' || chr(10) ||
    '           updated_at        = now()' || chr(10) ||
    '     where user_id = uid;' || chr(10) ||
    '  end if;' || chr(10) || chr(10) ||
    anchor;

  execute replace(src, anchor, added);
end
$mig$;

-- ---------------------------------------------------------------------------
-- The three who already did the work
-- ---------------------------------------------------------------------------
--
-- Same judgement as 20260923000100's backfill, whose comment reads "keep them willing rather than
-- silently switching them off": somebody who completed the volunteer form with a home location and
-- an active availability HAS said they are willing. Approval is deliberately not in the predicate
-- -- app.candidates() has not checked it since universal membership, so requiring it here would
-- skip members the dispatcher would happily ring.
--
-- Narrow on purpose. A suspended member is not quietly put back on call, and a member who already
-- chose false on /account/notifications is not overridden: `available_to_help = false` with no
-- home_location is an untouched default, but a member who turned it OFF also looks like that, so
-- this is as close as the data allows and the notice below reports exactly who moved.
do $bf$
declare
  moved int;
begin
  update public.profiles p
     set available_to_help = true,
         updated_at        = now()
    from public.responders r
   where r.user_id = p.user_id
     and p.available_to_help = false
     and p.suspended_at is null
     and r.home_location is not null
     and r.availability = 'active';

  get diagnostics moved = row_count;
  raise notice 'backfill: % member(s) who completed /join are now available to help', moved;
end
$bf$;

-- One statement, so a paste that half-arrives still tells you which half.
select
  strpos(pg_get_functiondef('public.upsert_responder_profile(jsonb)'::regprocedure),
         'available_to_help') > 0                                      as join_sets_the_flag,
  -- The key-present guard is the whole reason editing a radius is still safe. Assert the guard
  -- itself, not merely that the column is mentioned somewhere in the body.
  strpos(pg_get_functiondef('public.upsert_responder_profile(jsonb)'::regprocedure),
         'p_payload ? ''available_to_help''') > 0                      as only_when_asked,
  -- This morning's work on the same function must survive being patched again.
  strpos(pg_get_functiondef('public.upsert_responder_profile(jsonb)'::regprocedure),
         'phone_confirmed_at is not null') > 0                         as stale_token_fallback_intact,
  strpos(pg_get_functiondef('public.upsert_responder_profile(jsonb)'::regprocedure),
         'sms_opt_in') > 0                                             as sms_consent_intact,
  (select count(*) from public.profiles where available_to_help)       as members_available_now;
