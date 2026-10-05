-- Approval gates dispatch again. Owner's decision, 2026-10-05: "nobody gets called out without
-- approval".
--
-- WHY THIS IS A RESTORATION AND NOT A NEW RULE. app.candidates() checked
-- `responders.approval = 'approved'` until universal membership rewrote it, and then it did not --
-- for weeks, while /join's own confirmation screen kept promising, in these words: "An admin checks
-- every signup before anyone starts getting call-outs. It is how we keep tow companies out of a
-- volunteer group." That sentence was false. Any member who turned availability on was dispatched
-- to, unreviewed, and the one screen that said otherwise was the one every new volunteer read.
--
-- REMOVING IT WAS DELIBERATE, and this reverses a decision rather than fixing an oversight.
-- dispatch_test.sql asserted "a volunteer nobody has approved is now reached -- that is the point of
-- this phase", and the comment above it called itself the gate's headstone: "if it ever reads 2
-- again, the gate is back". It reads 2 now. What nobody noticed was that /join kept promising the
-- review that had been removed.
--
-- AND THE STRONGER REASON, found by running the new suite against the pre-gate body: with no
-- approval check, approval = 'banned' removed somebody from the admin lists and from re-signup --
-- the blocklist is keyed by phone -- and did NOT stop them being dispatched to a member who is
-- alone and stuck. Suspension blocks a call-out through a different column (profiles.suspended_at),
-- which is why banning appeared to work. Four assertions fail against the old body and that is one
-- of them.
--
-- Found while auditing the notification spec, in the same sweep that found /join never setting
-- available_to_help at all. The two pointed opposite ways: one silently stopped real volunteers
-- being called out, the other silently called out people nobody had checked, including banned ones.
-- Fixing only the first would have widened the second.
--
-- THE COST, STATED PLAINLY. upsert_responder_profile creates a responder as 'pending', so from now
-- on completing /join does NOT make somebody dispatchable on its own -- an admin has to approve
-- them at /admin/responders. That is the promise being honoured rather than a side effect, but it
-- means the dispatcher reaches nobody until somebody does the approving. The notice at the bottom
-- of this migration names exactly how many volunteers are waiting, because a gate that quietly
-- empties the candidate set is indistinguishable from the bug fixed three hours earlier.
--
-- The body is read out of the live database and patched. app.candidates() is the function this
-- repo warns about most loudly: five migrations declare it and two more rewrite it through
-- pg_get_functiondef without containing a declaration, so the newest definition exists in no single
-- file. Reconstructing it from the newest-looking migration reverted four migrations' work on
-- 2026-10-04 -- the requester exclusion, the open directory and suspension handling, in one go.

set search_path = public, extensions;

do $mig$
declare
  src    text;
  anchor text;
  hits   int;
begin
  src := pg_get_functiondef('app.candidates(uuid, integer, integer)'::regprocedure);

  -- Idempotent: this will be applied by hand, possibly twice.
  if position('r.approval' in src) > 0 then
    raise notice 'app.candidates() already gates on approval -- nothing to do';
    return;
  end if;

  anchor := '  where r.availability = ''active''';

  hits := array_length(string_to_array(src, anchor), 1) - 1;
  if hits <> 1 then
    raise exception 'refusing to patch app.candidates(): anchor matched % times, expected 1', hits;
  end if;

  execute replace(
    src,
    anchor,
    anchor || chr(10) ||
    '    -- APPROVED, AND NOT MERELY NOT-BANNED. responder_approval also has ''pending'' and' || chr(10) ||
    '    -- ''rejected'', and a label added later must be excluded until somebody has thought about' || chr(10) ||
    '    -- it. That is the same reasoning as sms.enabled_templates being an allowlist: a blocklist' || chr(10) ||
    '    -- admits every future state by default, and the thing being admitted here is a stranger' || chr(10) ||
    '    -- driving to a member who is alone and stuck.' || chr(10) ||
    '    and r.approval = ''approved'''
  );
end
$mig$;

-- ---------------------------------------------------------------------------
-- What this just did to the candidate set
-- ---------------------------------------------------------------------------
--
-- A gate that empties the candidate set looks exactly like the bug fixed in 20261005000700, where
-- willing volunteers were silently never rung. The difference is that this one is intended -- so it
-- has to be loud about who is now waiting, or the next hour is spent diagnosing it as a regression.

do $br$
declare
  waiting  int;
  reachable int;
begin
  select count(*) into waiting
    from public.responders r
    join public.profiles p on p.user_id = r.user_id
   where p.available_to_help
     and p.suspended_at is null
     and r.availability = 'active'
     and r.home_location is not null
     and r.approval <> 'approved';

  select count(*) into reachable
    from public.responders r
    join public.profiles p on p.user_id = r.user_id
   where p.available_to_help
     and p.suspended_at is null
     and r.availability = 'active'
     and r.home_location is not null
     and r.approval = 'approved';

  raise notice '% volunteer(s) are approved and reachable right now', reachable;

  if waiting > 0 then
    raise notice 'HEADS UP: % willing volunteer(s) are now NOT dispatchable because they are not approved. Approve them at /admin/responders -- until then the dispatcher will reach % %.',
      waiting, reachable, case when reachable = 1 then 'person' else 'people' end;
  end if;
end
$br$;

notify pgrst, 'reload schema';

select
  strpos(pg_get_functiondef('app.candidates(uuid, integer, integer)'::regprocedure),
         'r.approval = ''approved''') > 0                          as approval_gates_dispatch,
  -- Everything else that lives in this function and has been reverted by a careless rewrite before.
  strpos(pg_get_functiondef('app.candidates(uuid, integer, integer)'::regprocedure),
         'suspended_at is null') > 0                               as suspension_intact,
  strpos(pg_get_functiondef('app.candidates(uuid, integer, integer)'::regprocedure),
         'is distinct from req.requester_user_id') > 0             as requester_exclusion_intact,
  strpos(pg_get_functiondef('app.candidates(uuid, integer, integer)'::regprocedure),
         'blocks_between') > 0                                     as blocking_intact,
  strpos(pg_get_functiondef('app.candidates(uuid, integer, integer)'::regprocedure),
         'available_to_help') > 0                                  as willingness_intact,
  (select count(*) from public.responders r join public.profiles p on p.user_id = r.user_id
    where p.available_to_help and r.availability = 'active'
      and r.home_location is not null and r.approval = 'approved') as reachable_volunteers,
  (select count(*) from public.responders r join public.profiles p on p.user_id = r.user_id
    where p.available_to_help and r.availability = 'active'
      and r.home_location is not null and r.approval <> 'approved') as waiting_for_approval;
