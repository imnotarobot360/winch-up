-- Winch Up :: the reported-members queue is one row per member, and keeps the suspended ones
--
-- Found by using it, which is the only way this one shows up. Suspending a member from the screen
-- built for it made them VANISH from that screen: admin_suspend_member() closes their open reports
-- (correctly -- they are a decision now, not a pending question), the queue listed only reports with
-- status new or reviewing, so the member was gone a second after being suspended.
--
-- The restore path was written and unreachable. The warning text says "nothing is deleted and you
-- can undo it", and the only way to undo it was a SQL prompt. A promise in the UI that the UI cannot
-- keep is worse than not offering it.
--
-- Two changes:
--
--   ONE ROW PER MEMBER, not per report. Four people reporting the same member is one decision, which
--   is what the screen above it already says about posts -- "five people reporting one thing is one
--   decision, not five". The reported-members list was the one place that did not follow its own
--   heading. It carries the most recent report's reason and note, and the total count.
--
--   SUSPENDED MEMBERS STAY LISTED whether or not anything about them is open. This screen is "people
--   under or awaiting a decision", and somebody serving a suspension is the first of those.
--
-- Rebuilt from the live definition, which is 20261001001400.

set search_path = public, extensions;

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

  select coalesce(jsonb_agg(x order by x.suspended_at desc nulls first, x.created_at desc),
                  '[]'::jsonb)
    into v_rows
  from (
    select
      -- Kept for the UI's key and for nothing else; it is the most recent report, not the only one.
      (array_agg(cr.id order by cr.created_at desc))[1]            as report_id,
      p.user_id,
      coalesce(nullif(btrim(p.display_name), ''), r.first_name)    as display_name,
      (array_agg(cr.reason::text order by cr.created_at desc))[1]  as reason,
      (array_agg(cr.note order by cr.created_at desc))[1]          as note,
      (array_agg(cr.status::text order by cr.created_at desc))[1]  as status,
      max(cr.created_at)                                           as created_at,
      p.suspended_at,
      p.suspended_reason,
      p.created_at                                                 as member_since,
      count(cr.id)                                                 as reports_total,
      count(cr.id) filter (where cr.status in ('new', 'reviewing')) as reports_open
      from public.profiles p
      left join public.responders r on r.user_id = p.user_id
      -- ALL of their reports, so the totals are totals. Which members appear is decided below.
      left join public.content_reports cr
             on cr.target_kind = 'member' and cr.target_id = p.user_id
     where p.suspended_at is not null
        or exists (
             select 1 from public.content_reports o
              where o.target_kind = 'member'
                and o.target_id = p.user_id
                and o.status in ('new', 'reviewing')
           )
     group by p.user_id, p.display_name, r.first_name, p.suspended_at, p.suspended_reason,
              p.created_at
     order by p.suspended_at desc nulls first, max(cr.created_at) desc
     limit greatest(1, least(coalesce(p_limit, 50), 200))
  ) x;

  return jsonb_build_object('ok', true, 'reports', v_rows);
end;
$fn$;

revoke all on function public.moderation_reported_members(integer) from public, anon;
grant execute on function public.moderation_reported_members(integer) to authenticated, service_role;

notify pgrst, 'reload schema';
