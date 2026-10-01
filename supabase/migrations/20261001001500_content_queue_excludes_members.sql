-- Winch Up :: the content queue is for content
--
-- Caught in a browser, not by a test, which is the honest account: adding 'member' to
-- content_reports.target_kind in 20261001001400 put reported MEMBERS into the CONTENT moderation
-- queue as well as the new section built for them. The row rendered as
--
--     moderation.kind.member · Someone        1 report · Harassment
--     [Put it back]  [Leave it up]
--
-- A raw translation key, no author, no content -- because there is no post to join to -- and two
-- buttons offering to hide or restore a human being. Both of those call
-- moderation_set_content_status(), which would have looked up a post id that is actually a user id
-- and done nothing at all, silently, while the moderator believed they had acted.
--
-- Nothing in the earlier migration was wrong about the column. The queue simply predates there
-- being a kind of report that is not about a piece of content, and it selected every kind there
-- was because every kind there was had a body.
--
-- One line. Members are handled by moderation_reported_members(), which joins profiles and offers
-- suspension, which is the action that means something for a person.
--
-- Rebuilt from the live definition out of pg_proc, not from 20260922001000.

set search_path = public, extensions;

create or replace function public.moderation_queue(p_status text default 'new')
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_rows jsonb;
begin
  if not app.is_moderator() then
    raise exception 'forbidden' using errcode = 'insufficient_privilege';
  end if;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.report_count desc, r.created_at desc),
                  '[]'::jsonb) into v_rows
  from (
    select cr.target_kind,
           cr.target_id,
           min(cr.created_at) as created_at,
           count(*) as report_count,
           array_agg(distinct cr.reason::text) as reasons,
           max(cr.note) filter (where cr.note is not null) as note,
           coalesce(p.body, c.body, tc.note, '') as content,
           coalesce(p.status, c.status, tc.status)::text as content_status,
           coalesce(pp.display_name, cp.display_name, tp.display_name, '') as author_name,
           -- Only a condition report has one; it tells the moderator which page the thing is on.
           t.name as trail_name
      from content_reports cr
      left join community_posts p on cr.target_kind = 'post' and p.id = cr.target_id
      left join community_comments c on cr.target_kind = 'comment' and c.id = cr.target_id
      left join trail_conditions tc on cr.target_kind = 'trail_condition' and tc.id = cr.target_id
      left join trails t on t.id = tc.trail_id
      left join profiles pp on pp.user_id = p.author_user_id
      left join profiles cp on cp.user_id = c.author_user_id
      left join profiles tp on tp.user_id = tc.author_user_id
     -- A REPORTED MEMBER IS NOT CONTENT. Every other kind here joins to something with a body and
     -- a status that hiding changes; a person has neither. They go to
     -- moderation_reported_members() instead, where the action on offer is suspension.
     where cr.target_kind <> 'member'
       and (p_status is null or cr.status = p_status::incident_status)
     group by cr.target_kind, cr.target_id, p.body, c.body, tc.note,
              p.status, c.status, tc.status,
              pp.display_name, cp.display_name, tp.display_name, t.name
     order by count(*) desc, min(cr.created_at) desc
     limit 100
  ) r;

  return jsonb_build_object('ok', true, 'items', v_rows);
end;
$fn$;

revoke all on function public.moderation_queue(text) from public, anon;
grant execute on function public.moderation_queue(text) to authenticated, service_role;

notify pgrst, 'reload schema';
