-- Winch Up :: a second helper had nowhere to go
--
-- 20260923002300 and 002400 made it possible to add a second helper to a recovery. This is the
-- third place the one-winner assumption was load-bearing, and it is the one that would have made
-- the whole thing useless in the field.
--
-- my_responder_profile() resolves current_job through requests.accepted_responder_id = me.id.
-- That is the LEAD. A helper who joined the team behind them matched nothing, so /me showed
-- them no current job -- and because the dashboard renders the group chat and the arrival
-- controls inside that card, they also had no thread to talk to the team in and no way to say
-- "on site". They had been accepted onto a recovery and the app had no route back to it.
--
-- So: current_job comes from recovery_participants, which is what team membership actually means
-- now, with accepted_responder_id kept as the tie-break so the lead's own job still sorts first
-- if somebody is somehow on two.
--
-- History gets the same treatment. A volunteer who came out as the second truck did come out,
-- and a past-recoveries list that silently omits half their work is a worse answer than a
-- slightly longer query -- these are people volunteering their evenings, and the count is the
-- only thanks the app gives them.

set search_path = public, extensions;

create or replace function public.my_responder_profile()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  me public.responders%rowtype;
begin
  select * into me from public.responders where user_id = auth.uid();
  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'id', me.id,
    'first_name', me.first_name,
    'last_name', me.last_name,
    'phone', me.phone,
    'locale', me.locale,
    'lat', extensions.st_y(me.home_location::extensions.geometry),
    'lng', extensions.st_x(me.home_location::extensions.geometry),
    'home_address_text', me.home_address_text,
    'radius_miles', me.radius_miles,
    'equipment', to_jsonb(me.equipment),
    'vehicle_class', me.vehicle_class,
    'vehicle_desc', me.vehicle_desc,
    'drivetrain', me.drivetrain,
    'night_ok', me.night_ok,
    -- Whether a position is being shared, and how old it is. The coordinates themselves are
    -- deliberately not returned: the page has no use for them, and a payload that carries
    -- them is one screenshot away from somewhere it should not be.
    'share_location', me.share_location,
    'last_location_at', me.last_location_at,
    'approval', me.approval,
    'availability', me.availability,
    'recoveries_count', me.recoveries_count,
    'created_at', me.created_at,

    -- Live recoveries this member is ON, whether they lead them or joined them.
    --
    -- left_at is null, not merely a row: somebody who withdrew keeps their history and stops
    -- having a current job, which is the same rule the thread uses.
    --
    -- Ordered so the lead's own job wins a tie. Two live recoveries at once is not supposed to
    -- happen, but "not supposed to" is not a guarantee, and picking arbitrarily would put a
    -- member on the wrong job's chat.
    'current_job', (
      select jsonb_build_object(
               'request_id', r.id,
               'short_code', r.short_code,
               'status', r.status,
               'accepted_at', r.accepted_at,
               'eta_minutes', r.eta_minutes,
               -- So the dashboard can say "you are leading this" rather than implying it.
               'is_lead', r.accepted_responder_id = me.id
             )
        from public.requests r
        join public.recovery_participants p
          on p.request_id = r.id
         and p.responder_id = me.id
         and p.left_at is null
       where r.status in ('accepted', 'on_site')
       order by (r.accepted_responder_id = me.id) desc, r.accepted_at desc
       limit 1
    ),

    'history', coalesce((
      select jsonb_agg(jsonb_build_object(
               'short_code', h.short_code,
               'status', h.status,
               'recovered_at', h.recovered_at,
               'stuck_type', h.stuck_type,
               'thank_you', h.thank_you_note
             ) order by h.recovered_at desc nulls last)
        from (
          -- distinct, because the lead matches both halves of the union source below. A member
          -- seeing the same recovery twice in their history reads as a bug in the count.
          select distinct r.*
            from public.requests r
            join public.recovery_participants p
              on p.request_id = r.id and p.responder_id = me.id
           where r.status in ('recovered', 'cancelled')
           order by r.recovered_at desc nulls last
           limit 20
        ) h
    ), '[]'::jsonb)
  );
end;
$$;

-- Unchanged from the original: granted to the signed-in member, resolving itself from auth.uid().
revoke all on function public.my_responder_profile() from public, anon;
grant execute on function public.my_responder_profile() to authenticated, service_role;
