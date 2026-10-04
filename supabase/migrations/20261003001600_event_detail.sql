-- Winch Up :: one event, on its own page
--
-- `events_upcoming()` is a LIST: published only, soonest first, nothing more than six hours past, and
-- capped at a limit. None of that is right for a page somebody has been sent a link to. An event that
-- finished yesterday, or the fiftieth event in a busy month, is still a real page and reading it
-- through the list would silently 404.
--
-- WHY THIS EXISTS AT ALL. `record_event_view()` and `event_daily_stats` shipped in 20261003001000 with
-- NOTHING ABLE TO CALL THEM -- there was no per-event surface, and counting a "view" for every event
-- in a list is not a view. The migration said so rather than leaving it to be discovered. This is the
-- page that makes the counter mean something, and it is the reason `admin_event_report` stops showing
-- a column that could never move.
--
-- A DRAFT IS NOT READABLE HERE. `status = 'published'` is in the WHERE rather than checked by the
-- page, so an admin's unfinished words about a gate they have not confirmed are not one guessed uuid
-- away. A draft and a deleted event answer identically, which is the point.

set search_path = public, extensions;

create or replace function public.event_detail(p_event_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me     uuid := auth.uid();
  v_row    jsonb;
  v_city   text;
  v_state  text;
  v_postal text;
  v_center extensions.geography;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  -- The member's STATED area, four scalars and nothing else from the row -- the same discipline as
  -- every other function in this path, so none of them is able to reach for the recovery position on
  -- a volunteer record.
  select p.city, p.state, p.postal_code, p.postal_center
    into v_city, v_state, v_postal, v_center
    from public.profiles p
   where p.user_id = v_me;

  select to_jsonb(e) into v_row
  from (
    select ev.id, ev.title, ev.description, ev.event_type::text as event_type,
           ev.starts_at, ev.ends_at, ev.meet_note, ev.capacity,
           ev.address_line, ev.city, ev.state, ev.postal_code,
           ev.is_official, ev.organizer_name, ev.registration_url, ev.website_url,
           ev.contact_email, ev.contact_phone,
           g.name as group_name, g.slug as group_slug,
           t.name as trail_name, t.slug as trail_slug,
           (select count(*) from event_rsvps r
             where r.event_id = ev.id and r.response = 'going') as going_count,
           (select r.response::text from event_rsvps r
             where r.event_id = ev.id and r.user_id = v_me) as my_response,
           -- Not a gate. Targeting an event never hides it (20261003000700); this badges what is
           -- near the member, and the page says so in words.
           app.member_matches_target('event', ev.id, v_state, v_city, v_postal, v_center)
             as matches_my_area
      from events ev
      left join groups g on g.id = ev.group_id
      left join trails t on t.id = ev.trail_id
     -- Published only, and NOT limited to upcoming: a link to last weekend's run should still open.
     where ev.id = p_event_id
       and ev.status = 'published'
  ) e;

  if v_row is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object('ok', true, 'event', v_row);
end;
$fn$;

revoke all on function public.event_detail(uuid) from public, anon;
grant execute on function public.event_detail(uuid) to authenticated;

comment on function public.event_detail(uuid) is
  'One published event for its own page. Unlike events_upcoming() it is not limited to upcoming '
  'events, because a link to a past one should still open. Drafts answer not_found.';

notify pgrst, 'reload schema';
