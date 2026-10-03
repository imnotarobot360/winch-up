-- Winch Up :: a radius target has to survive being edited
--
-- `admin_campaigns()` and `admin_announcements()` return each row's targeting as a list of places, and
-- for a radius they returned the distance and NOT the centre. Reasonable-looking -- a list screen has
-- no use for coordinates -- and it makes the admin editor silently destructive.
--
-- THE PATH THAT LOSES DATA. The editor loads a row's targets, the admin adds a ZIP code, and the save
-- sends the whole `targets` array; the writer replaces the targeting wholesale when that key is
-- present, which is correct and is what "this is for everybody now" needs. But a radius the editor
-- could not represent is not in the array it sends back, so it is deleted. Nothing errors. The campaign
-- quietly stops reaching the area it was bought for, and the only evidence is a number on a report
-- getting smaller.
--
-- Found while writing the editor, by asking what `fromStored` should do with a radius row rather than
-- what it could do. The alternatives were worse: dropping radius rows from the editor and hoping
-- nobody edits a radius-targeted campaign, or having the UI avoid sending `targets` unless it was
-- touched -- which protects the common case and still loses the row the moment somebody does touch it.
--
-- So the centre travels with the distance, both functions are redefined here, and a radius is editable
-- rather than invisible.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- One expression, used by both
-- ---------------------------------------------------------------------------
--
-- A function rather than the same jsonb_agg copied into two places. The point of this migration is
-- that the two were allowed to be subtly different, and writing it twice again would re-create exactly
-- that.

create or replace function app.target_list(p_scope target_scope, p_target_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'kind', t.kind::text,
        'state', t.state,
        'city', t.city,
        'postal_code', t.postal_code,
        'radius_miles', t.radius_miles,
        -- THE CENTRE, so a radius can be loaded back into the editor and saved again unchanged.
        -- st_x/st_y need a geometry; a geography casts to one without reprojecting, since this is
        -- stored in 4326 already.
        'lng', case when t.center is not null
                    then extensions.st_x(t.center::extensions.geometry) end,
        'lat', case when t.center is not null
                    then extensions.st_y(t.center::extensions.geometry) end
      )
      order by t.kind, t.state, t.city, t.postal_code
    ),
    '[]'::jsonb)
    from public.target_locations t
   where t.scope = p_scope and t.target_id = p_target_id;
$fn$;

revoke all on function app.target_list(target_scope, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The two listings, now using it
-- ---------------------------------------------------------------------------
--
-- Same signatures, same return shapes, one field added inside the `targets` array. Adding a parameter
-- would overload these and PostgREST could not choose between the two.

create or replace function public.admin_campaigns(
  p_phase          text default null,
  p_include_archived boolean default false,
  p_limit          integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_rows jsonb;
begin
  perform app.require_admin();

  select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at desc), '[]'::jsonb) into v_rows
  from (
    select
      ca.id, ca.name, ca.status::text as status,
      app.campaign_phase(ca.status, ca.starts_on, ca.ends_on, ca.archived_at) as phase,
      ca.surfaces::text[] as surfaces,
      ca.starts_on, ca.ends_on, ca.monthly_price_cents,
      ca.archived_at, ca.created_at,
      b.id as business_id, b.name as business_name, b.category::text as business_category,
      app.target_list('campaign', ca.id) as targets,
      app.target_audience_count('campaign', ca.id) as audience,
      (select count(*) from public.ad_creatives cr where cr.campaign_id = ca.id) as creative_count,
      (select count(*) from public.ad_creatives cr
        where cr.campaign_id = ca.id and cr.status = 'approved' and cr.is_active) as live_creatives
    from public.ad_campaigns ca
    join public.businesses b on b.id = ca.business_id
   where (p_include_archived or ca.archived_at is null)
     and (p_phase is null
          or app.campaign_phase(ca.status, ca.starts_on, ca.ends_on, ca.archived_at) = p_phase)
   order by ca.created_at desc
   limit greatest(1, least(coalesce(p_limit, 50), 200))
  ) c;

  return jsonb_build_object('ok', true, 'campaigns', v_rows);
end;
$fn$;

revoke all on function public.admin_campaigns(text, boolean, integer) from public, anon;
grant execute on function public.admin_campaigns(text, boolean, integer) to authenticated;

create or replace function public.admin_announcements(
  p_status text default null,
  p_limit  integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_rows jsonb;
begin
  perform app.require_admin();

  select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at desc), '[]'::jsonb) into v_rows
  from (
    select an.id, an.title, an.body, an.category::text as category, an.status::text as status,
           an.link_url, an.link_label, an.starts_at, an.ends_at, an.pinned, an.created_at,
           app.target_list('announcement', an.id) as targets,
           app.target_audience_count('announcement', an.id) as audience,
           (select count(*)::integer from public.announcement_dismissals d
             where d.announcement_id = an.id) as dismissed_count
      from public.announcements an
     where (p_status is null or an.status::text = p_status)
     order by an.created_at desc
     limit greatest(1, least(coalesce(p_limit, 50), 200))
  ) a;

  return jsonb_build_object('ok', true, 'announcements', v_rows);
end;
$fn$;

revoke all on function public.admin_announcements(text, integer) from public, anon;
grant execute on function public.admin_announcements(text, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- And events, which had no admin listing at all
-- ---------------------------------------------------------------------------
--
-- admin_save_event() exists and there was no way to read an event back for editing: events_upcoming()
-- is the member's view -- published only, nothing more than six hours past -- so an admin could create
-- an event and then never find the draft again.

create or replace function public.admin_events(
  p_status text default null,
  p_limit  integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_rows jsonb;
begin
  perform app.require_admin();

  select coalesce(jsonb_agg(to_jsonb(e) order by e.starts_at desc), '[]'::jsonb) into v_rows
  from (
    select ev.id, ev.title, ev.description, ev.event_type::text as event_type,
           ev.status::text as status, ev.starts_at, ev.ends_at,
           ev.address_line, ev.city, ev.state, ev.postal_code,
           ev.meet_note, ev.capacity, ev.is_official,
           ev.organizer_name, ev.registration_url, ev.website_url,
           ev.contact_email, ev.contact_phone,
           ev.cover_image_path, ev.image_paths,
           -- The point, so an event with a pin keeps it through an edit. Same reasoning as the radius
           -- centre above: a field the editor cannot see is a field the editor silently clears.
           case when ev.meet_point is not null
                then extensions.st_x(ev.meet_point::extensions.geometry) end as lng,
           case when ev.meet_point is not null
                then extensions.st_y(ev.meet_point::extensions.geometry) end as lat,
           app.target_list('event', ev.id) as targets,
           app.target_audience_count('event', ev.id) as audience,
           (select count(*)::integer from public.event_rsvps r
             where r.event_id = ev.id and r.response = 'going') as going_count
      from public.events ev
     where (p_status is null or ev.status::text = p_status)
     order by ev.starts_at desc
     limit greatest(1, least(coalesce(p_limit, 50), 200))
  ) e;

  return jsonb_build_object('ok', true, 'events', v_rows);
end;
$fn$;

revoke all on function public.admin_events(text, integer) from public, anon;
grant execute on function public.admin_events(text, integer) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- Setting a campaign's targeting from the admin screen
-- ---------------------------------------------------------------------------
--
-- A campaign is CREATED by its advertiser on /business and reviewed by an admin. Targeting is the one
-- part of it the admin screen writes, which is why this is a narrow function rather than an
-- admin_save_campaign() that would be a second form writing the same row with different validation --
-- the way "approve the shop, then rename it to a tow company" becomes possible.
--
-- Deliberately NOT touching status, dates, surfaces or price. Changing where an approved advert is shown
-- does not change the words that were approved, so this does not send the campaign back for review;
-- changing the words still does, which is the existing rule and is enforced elsewhere.

create or replace function public.admin_save_campaign_targets(
  p_campaign_id uuid,
  p_targets     jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_target jsonb;
begin
  perform app.require_admin();

  if not exists (select 1 from public.ad_campaigns where id = p_campaign_id) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  -- Replaced wholesale. Unlike the save functions, there is no "absent means leave alone" case here:
  -- this function exists only to set targeting, so being called at all is the deliberate statement, and
  -- an empty array means "everybody now".
  delete from public.target_locations where scope = 'campaign' and target_id = p_campaign_id;

  for v_target in select * from jsonb_array_elements(coalesce(p_targets, '[]'::jsonb)) loop
    insert into public.target_locations (scope, target_id, kind, state, city, postal_code,
                                         center, radius_miles)
    values (
      'campaign', p_campaign_id,
      (v_target ->> 'kind')::target_kind,
      nullif(upper(btrim(coalesce(v_target ->> 'state', ''))), ''),
      nullif(btrim(coalesce(v_target ->> 'city', '')), ''),
      nullif(btrim(coalesce(v_target ->> 'postal_code', '')), ''),
      case
        when (v_target ->> 'lng') is not null and (v_target ->> 'lat') is not null
          then extensions.st_setsrid(
                 extensions.st_point((v_target ->> 'lng')::double precision,
                                     (v_target ->> 'lat')::double precision),
                 4326)::extensions.geography
      end,
      nullif(v_target ->> 'radius_miles', '')::integer
    )
    on conflict do nothing;
  end loop;

  perform app.audit('campaign.targets', 'ad_campaign', p_campaign_id::text,
                    jsonb_build_object('targets', jsonb_array_length(coalesce(p_targets, '[]'::jsonb))));

  return jsonb_build_object('ok', true,
                            'audience', app.target_audience_count('campaign', p_campaign_id));
exception
  when check_violation then
    -- The shape CHECK on target_locations is the real validation: a city without a state, a
    -- four-digit ZIP, a zero-mile radius. An admin should read a sentence, not a constraint name.
    return jsonb_build_object('ok', false, 'error', 'bad_target');
end;
$fn$;

revoke all on function public.admin_save_campaign_targets(uuid, jsonb) from public, anon;
grant execute on function public.admin_save_campaign_targets(uuid, jsonb) to authenticated;

notify pgrst, 'reload schema';
