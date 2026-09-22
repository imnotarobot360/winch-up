-- Winch Up :: surface the sharing state to the volunteer's own dashboard
--
-- my_responder_profile() is how /me knows anything about itself. Without these two fields the
-- dashboard cannot show whether a position is being shared or how old it is, and a control that
-- cannot show its own state is worse than none -- the volunteer would have no way to tell they
-- are still being matched from a trailhead they left on Sunday.

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
    'current_job', (
      select jsonb_build_object(
               'request_id', r.id,
               'short_code', r.short_code,
               'status', r.status,
               'accepted_at', r.accepted_at,
               'eta_minutes', r.eta_minutes
             )
        from public.requests r
       where r.accepted_responder_id = me.id
         and r.status in ('accepted', 'on_site')
       order by r.accepted_at desc
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
          select * from public.requests
           where accepted_responder_id = me.id
             and status in ('recovered', 'cancelled')
           order by recovered_at desc nulls last
           limit 20
        ) h
    ), '[]'::jsonb)
  );
end;
$$;
