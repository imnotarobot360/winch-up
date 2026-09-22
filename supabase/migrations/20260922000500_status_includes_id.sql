-- Winch Up :: the status payload carries the request id
--
-- Needed so a signed-in participant on /r/[token] can open the message thread.

set search_path = public, extensions;

create or replace function public.get_request_by_token(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
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

  -- Contact details are released only once someone has actually taken the job.
  assigned := r.accepted_responder_id is not null
              and r.status in ('accepted', 'on_site', 'recovered');

  select value into radii from public.app_settings where key = 'dispatch.ring_radii_miles';

  result := jsonb_build_object(
    -- The request id, so a signed-in participant's browser can open the message thread.
    -- Not a secret and not a capability: request_thread() decides access by checking who
    -- the caller is against the request, never by whether they knew the id. Anyone reading
    -- this payload already holds the token, which is the stronger secret.
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
    'responder', case when assigned then (
      select jsonb_build_object(
               'first_name',    resp.first_name,
               'vehicle_class', resp.vehicle_class,
               'vehicle_desc',  resp.vehicle_desc,
               'phone',         resp.phone          -- released only in this branch
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
$$;
