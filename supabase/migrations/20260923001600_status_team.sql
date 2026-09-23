-- Winch Up :: the status page shows the team, not just the first one to arrive
--
-- get_request_by_token gained an 'offers' array when the requester started choosing. Now that a
-- recovery can have several helpers it needs the roster too, or the person waiting sees one name
-- while two trucks are on the way.
--
-- 'responder' is untouched: still the lead, still the only place a phone number is released, and
-- still only once somebody is assigned. The new 'team' key carries names, vehicles, kit and
-- status -- what you would want to know while you wait -- and no way to contact anybody.
--
-- Copied from 20260923000300 by a script with one key inserted, rather than retyped.

set search_path = public, extensions;

create or replace function public.get_request_by_token(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  r        public.requests%rowtype;
  radii    jsonb;
  assigned boolean;
  result   jsonb;
begin
  if p_token is null or length(p_token) < 16 then
    return null;
  end if;

  select * into r from public.requests where public_token = p_token;
  if not found then
    return null;
  end if;

  assigned := r.accepted_responder_id is not null
              and r.status in ('accepted', 'on_site', 'recovered');

  select value into radii from public.app_settings where key = 'dispatch.ring_radii_miles';

  result := jsonb_build_object(
    'id',              r.id,
    'short_code',      r.short_code,
    'status',          r.status,
    'locale',          r.locale,
    'created_at',      r.created_at,
    'requester_name',  r.requester_name,
    'lat',             extensions.st_y(r.location::extensions.geometry),
    'lng',             extensions.st_x(r.location::extensions.geometry),
    'accuracy_m',      r.location_accuracy_m,
    'county',          r.county,
    'vehicle', jsonb_build_object(
      'class', r.vehicle_class, 'make', r.vehicle_make,
      'model', r.vehicle_model, 'year', r.vehicle_year, 'drivetrain', r.drivetrain
    ),
    'situation', jsonb_build_object(
      'stuck_type', r.stuck_type, 'stuck_depth', r.stuck_depth,
      'needs_tractor', r.needs_tractor, 'needs_second_truck', r.needs_second_truck,
      'land_type', r.land_type, 'notes', r.notes
    ),
    'dispatch', jsonb_build_object(
      'current_ring',    r.current_ring,
      'radius_miles',    case when r.current_ring between 1 and 3
                              then (radii -> (r.current_ring - 1)) else null end,
      'notified_count',  r.notified_count,
      'started_at',      r.dispatch_started_at,
      'unmatched_at',    r.unmatched_at
    ),
    'eta_minutes',   r.eta_minutes,
    'on_site_at',    r.on_site_at,
    'recovered_at',  r.recovered_at,
    'cancelled_at',  r.cancelled_at,
    'thanked',       r.thank_you_note is not null,
    'photos', coalesce((
      select jsonb_agg(jsonb_build_object('path', p.storage_path, 'sort', p.sort_order)
                       order by p.sort_order)
        from public.request_photos p where p.request_id = r.id
    ), '[]'::jsonb),
    'timeline', coalesce((
      select jsonb_agg(jsonb_build_object(
               'type', e.event_type, 'at', e.created_at, 'data', e.data
             ) order by e.created_at, e.id)
        from public.request_events e
       where e.request_id = r.id and e.is_public
    ), '[]'::jsonb),

    -- Spec section 8, steps 4 and 5. Only while the request is still open: once somebody is
    -- assigned, 'responder' below is the answer and a list of people who were passed over is not
    -- information the requester needs on a live recovery.
    'offers', case when r.accepted_responder_id is null
                    and r.status in ('submitted', 'dispatching', 'unmatched')
              then coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',             d.id,
               'first_name',     resp.first_name,
               'vehicle_class',  resp.vehicle_class,
               'vehicle_desc',   resp.vehicle_desc,
               'distance_miles', d.distance_miles,
               'eta_minutes',    d.offer_eta_minutes,
               'note',           d.offer_note,
               'origin',         d.origin,
               -- The badge that replaced the approval gate.
               'verified',       resp.approval = 'approved',
               'offered_at',     d.offered_at
             ) order by d.offered_at)
        from public.dispatches d
        join public.responders resp on resp.id = d.responder_id
       where d.request_id = r.id and d.state = 'offered'
    ), '[]'::jsonb) else '[]'::jsonb end,

    -- Spec section 4: the Recovery Team. Everybody still on the recovery, with what they drive
    -- and what they carry, so the person waiting knows a tractor is coming as well as a winch.
    --
    -- No phone numbers here. 'responder' below still releases one, for the lead, at acceptance --
    -- that rule is unchanged. This list is also visible to anyone holding the shared status link,
    -- which gets forwarded to whoever is helping, so it carries names and kit and nothing that
    -- would let a stranger ring a volunteer directly.
    'team', coalesce((
      select jsonb_agg(jsonb_build_object(
               'role',      p.role,
               'status',    p.status,
               'name',      coalesce(pr.display_name, resp.first_name),
               'vehicle',   resp.vehicle_desc,
               'equipment', resp.equipment,
               'joined_at', p.joined_at
             ) order by p.role desc, p.joined_at)
        from public.recovery_participants p
        left join public.profiles   pr   on pr.user_id = p.user_id
        left join public.responders resp on resp.id    = p.responder_id
       where p.request_id = r.id and p.left_at is null
    ), '[]'::jsonb),

    'responder', case when assigned then (
      select jsonb_build_object(
               'first_name',    resp.first_name,
               'vehicle_class', resp.vehicle_class,
               'vehicle_desc',  resp.vehicle_desc,
               'phone',         resp.phone
             )
        from public.responders resp where resp.id = r.accepted_responder_id
    ) else null end,
    'pro_options', case when r.status = 'unmatched' then coalesce((
      select jsonb_agg(jsonb_build_object(
               'name', po.name, 'phone', po.phone, 'url', po.url,
               'blurb', case when r.locale = 'es' then po.blurb_es else po.blurb_en end
             ) order by po.sort_order)
        from public.pro_options po where po.is_active
    ), '[]'::jsonb) else null end
  );

  return result;
end;
$fn$;
