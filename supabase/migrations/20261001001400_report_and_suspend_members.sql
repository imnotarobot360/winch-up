-- Winch Up :: report a member, and suspend one
--
-- Spec §6: "Allow members to block and report other members" and "provide an appropriate process
-- for suspending abusive accounts and removing their profiles from the directory".
--
-- Blocking already existed and works (user_blocks, set_user_block, /account/blocked), and since
-- 20261001001100 it reaches the directory and the dispatcher too. The two things missing were a way
-- to report a PERSON rather than a post, and any concept of suspension at all.
--
-- WHY THIS MATTERS MORE NOW THAN IT DID LAST WEEK
--
-- When the directory was two opt-ins deep, an abusive member was mostly invisible by default. Now
-- every member is listed and every profile is readable, so the only thing standing between a bad
-- actor and the whole membership is moderation. /rules has been telling members for weeks that "an
-- account that breaks these rules can be suspended"; this is the first version of this schema that
-- could actually do it.
--
-- WHO MAY SUSPEND: admins only, not moderators. A moderator can hide content and nothing else --
-- CLAUDE.md is explicit that the moderator role stops short of anything reaching a volunteer's
-- phone number or the waiver, and suspending an account is a bigger action than hiding a post, not
-- a smaller one. The report queue is shared so moderators can triage and escalate.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. A member can be the target of a report
-- ---------------------------------------------------------------------------
--
-- target_kind is a text column with a CHECK rather than an enum, so this is a constraint swap and
-- not a new enum label -- which is the easier of the two, since a new label cannot be used in the
-- transaction that adds it.

alter table public.content_reports
  drop constraint if exists content_reports_target_kind_check;

alter table public.content_reports
  add constraint content_reports_target_kind_check
  check (target_kind in ('post', 'comment', 'trail_condition', 'member'));

-- ---------------------------------------------------------------------------
-- 2. Reporting one
-- ---------------------------------------------------------------------------
--
-- Deliberately NOT merged into report_content(): that one takes a post or comment id and resolves
-- the author, and widening it to mean "or a person" would make a function whose two branches share
-- nothing but a table.
--
-- Rate limited per reporter, on the same bucket shape as the rest. Reporting is how somebody in
-- trouble asks for help, so the ceiling is generous -- but a reporting form with no limit is a way
-- to bury the queue so the real report is never seen.
--
-- Reporting somebody does NOT block them. They are different acts: a report asks an admin to look,
-- a block is a decision the member makes for themselves, and quietly doing the second when asked
-- for the first takes the choice away. The UI offers both.

create or replace function public.report_member(
  p_user_id uuid,
  p_reason  report_reason,
  p_note    text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me uuid := auth.uid();
  v_id uuid;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  if p_user_id = v_me then
    return jsonb_build_object('ok', false, 'error', 'cannot_report_self');
  end if;

  -- The same not_found a profile read gives, for the same reason: this must not become a way to
  -- find out whether an account exists, is suspended, or has blocked you.
  if not exists (select 1 from public.profiles p where p.user_id = p_user_id) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if not app.check_rate_limit('report_member:' || v_me::text, 20, interval '24 hours') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  -- One open report per reporter per member. A second press of the button, or a second concern
  -- about the same person, should not put two rows in front of a moderator -- but once a report has
  -- been dealt with, the same member can be reported again, because people reoffend.
  select id into v_id
    from public.content_reports
   where target_kind = 'member'
     and target_id = p_user_id
     and reporter_user_id = v_me
     and status in ('new', 'reviewing')
   limit 1;

  if v_id is not null then
    return jsonb_build_object('ok', true, 'report_id', v_id, 'already_open', true);
  end if;

  insert into public.content_reports (target_kind, target_id, reporter_user_id, reason, note)
  values ('member', p_user_id, v_me, p_reason, nullif(btrim(p_note), ''))
  returning id into v_id;

  return jsonb_build_object('ok', true, 'report_id', v_id, 'already_open', false);
end;
$fn$;

revoke all on function public.report_member(uuid, report_reason, text) from public, anon;
grant execute on function public.report_member(uuid, report_reason, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Suspending and restoring
-- ---------------------------------------------------------------------------
--
-- Suspension is reversible and keeps everything. It is not deletion: the member's recoveries, their
-- signed waiver and their messages all stay exactly where they are, because a suspension that
-- destroyed evidence would be useless to whoever has to decide whether it was fair. Deleting an
-- account is a different function, owned by the member, and it scrubs.
--
-- What suspension does: out of the directory, profile unreadable, not dispatched to. That list is
-- not enforced here -- app.member_is_listable and app.candidates read suspended_at, so there is one
-- place each and no chance of this function and those two disagreeing.

create or replace function public.admin_suspend_member(
  p_user_id uuid,
  p_reason  text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me uuid;
begin
  perform app.require_admin();
  v_me := auth.uid();

  if p_user_id = v_me then
    -- Not a safety rail for the admin's benefit. An admin who suspends themselves is out of the
    -- directory AND still able to un-suspend, which is a confusing half-state for no gain.
    return jsonb_build_object('ok', false, 'error', 'cannot_suspend_self');
  end if;

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    -- A reason is required, and not as paperwork: this is the record somebody reads in three months
    -- when the member asks why, or when a second admin is deciding whether to lift it.
    return jsonb_build_object('ok', false, 'error', 'reason_required');
  end if;

  update public.profiles
     set suspended_at     = coalesce(suspended_at, now()),
         suspended_reason = btrim(p_reason),
         suspended_by     = v_me,
         updated_at       = now()
   where user_id = p_user_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  -- Their open reports are now somebody's decision rather than a pending question.
  update public.content_reports
     set status = 'actioned', reviewed_by = v_me, reviewed_at = now()
   where target_kind = 'member' and target_id = p_user_id and status in ('new', 'reviewing');

  perform app.audit('member.suspend', 'profile', p_user_id::text,
                    jsonb_build_object('reason', btrim(p_reason)));

  return jsonb_build_object('ok', true, 'suspended', true);
end;
$fn$;

revoke all on function public.admin_suspend_member(uuid, text) from public, anon;
grant execute on function public.admin_suspend_member(uuid, text) to authenticated, service_role;

create or replace function public.admin_restore_member(p_user_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me uuid;
begin
  perform app.require_admin();
  v_me := auth.uid();

  update public.profiles
     set suspended_at     = null,
         suspended_reason = null,
         suspended_by     = null,
         updated_at       = now()
   where user_id = p_user_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  perform app.audit('member.restore', 'profile', p_user_id::text, '{}'::jsonb);

  return jsonb_build_object('ok', true, 'suspended', false);
end;
$fn$;

revoke all on function public.admin_restore_member(uuid) from public, anon;
grant execute on function public.admin_restore_member(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. The queue a moderator reads
-- ---------------------------------------------------------------------------
--
-- Reported members, with enough to decide: who, by whom, why, and how long they have been a member.
-- No phone and no email -- a moderator deciding whether somebody is abusive does not need their
-- contact details, and the one screen in this app that shows a volunteer's number is admin-only.

create or replace function public.moderation_reported_members(p_limit integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_rows jsonb;
begin
  if not app.is_moderator() and not app.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'not_allowed');
  end if;

  select coalesce(jsonb_agg(x order by x.created_at desc), '[]'::jsonb)
    into v_rows
  from (
    select
      cr.id            as report_id,
      cr.target_id     as user_id,
      cr.reason::text  as reason,
      cr.note,
      cr.status::text  as status,
      cr.created_at,
      coalesce(nullif(btrim(p.display_name), ''), r.first_name) as display_name,
      p.suspended_at,
      p.suspended_reason,
      p.created_at     as member_since,
      (select count(*) from public.content_reports o
        where o.target_kind = 'member' and o.target_id = cr.target_id) as reports_total
      from public.content_reports cr
      join public.profiles p on p.user_id = cr.target_id
      left join public.responders r on r.user_id = cr.target_id
     where cr.target_kind = 'member'
       and cr.status in ('new', 'reviewing')
     order by cr.created_at desc
     limit greatest(1, least(coalesce(p_limit, 50), 200))
  ) x;

  return jsonb_build_object('ok', true, 'reports', v_rows);
end;
$fn$;

revoke all on function public.moderation_reported_members(integer) from public, anon;
grant execute on function public.moderation_reported_members(integer) to authenticated, service_role;

notify pgrst, 'reload schema';
