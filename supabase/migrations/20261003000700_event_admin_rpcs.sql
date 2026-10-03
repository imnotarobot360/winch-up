-- Winch Up :: creating and editing an event from the admin surface, and reading one back
--
-- Sections 2 and 14 of the owner's spec. Two functions: one the admin Content & Marketing screen
-- writes through, and a replacement for the reader every member already uses.
--
-- WHY EVENT TARGETING DOES NOT HIDE EVENTS, which is the one judgement in this file the owner should
-- disagree with if they want to.
--
-- For an advert, "does not match" means do not show it, and the cost of being wrong is an impression
-- nobody wanted. For an event it would mean a member cannot SEE their community's events -- and
-- replacing a Facebook group where everybody sees every post is the entire point of this product. A
-- Dallas member who might happily drive to a Houston recovery clinic would never learn it existed,
-- and nothing on screen would say why.
--
-- So event targeting decides who is TOLD and what is marked as near them. `events_upcoming` returns
-- every published event either way and carries `matches_my_area` so the page can badge or filter;
-- hiding is not available from the database, which means it cannot happen by a later accident. If the
-- owner wants targeted events actually hidden, that is a deliberate change to this function and it
-- should be made knowingly.
--
-- `events_upcoming(integer)` IS REPLACED HERE, same signature, and that is the dangerous kind of
-- change in this repo: a `create or replace` with a matching signature silently REPLACED the real
-- events_upcoming once already, and only data_model_test failing on `going_count` caught it. Every
-- field the old one returned is still returned -- going_count, my_response, group_name, group_slug,
-- trail_name, trail_slug -- and the new fields are added beside them.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. The admin writer
-- ---------------------------------------------------------------------------

create or replace function public.admin_save_event(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  -- app.require_admin() returns VOID -- it raises or it does not. Assigning it to a uuid compiles
  -- fine, because plpgsql does not check a body until it runs, and then fails on the first call.
  v_me      uuid := auth.uid();
  v_id      uuid := nullif(p_payload ->> 'id', '')::uuid;
  v_lng     double precision := nullif(p_payload ->> 'lng', '')::double precision;
  v_lat     double precision := nullif(p_payload ->> 'lat', '')::double precision;
  v_point   extensions.geography;
  v_targets jsonb := coalesce(p_payload -> 'targets', '[]'::jsonb);
  v_target  jsonb;
  v_new     boolean := v_id is null;
begin
  -- Raises 'forbidden', or 'mfa_required' when security.require_admin_mfa is on and this session
  -- has not been challenged. Both are insufficient_privilege, and the UI needs to tell them apart.
  perform app.require_admin();

  if nullif(p_payload ->> 'starts_at', '') is null then
    return jsonb_build_object('ok', false, 'error', 'no_start');
  end if;

  if v_lng is not null and v_lat is not null then
    v_point := extensions.st_setsrid(extensions.st_point(v_lng, v_lat), 4326)::extensions.geography;
  end if;

  if v_new then
    insert into public.events (
      title, description, event_type, starts_at, ends_at, meet_point, meet_note, capacity,
      address_line, city, state, postal_code, country,
      cover_image_path, image_paths,
      is_official, organizer_name, registration_url, website_url, contact_email, contact_phone,
      status, created_by
    ) values (
      btrim(coalesce(p_payload ->> 'title', '')),
      nullif(btrim(coalesce(p_payload ->> 'description', '')), ''),
      coalesce(nullif(p_payload ->> 'event_type', ''), 'other')::event_type,
      (p_payload ->> 'starts_at')::timestamptz,
      nullif(p_payload ->> 'ends_at', '')::timestamptz,
      v_point,
      nullif(btrim(coalesce(p_payload ->> 'meet_note', '')), ''),
      nullif(p_payload ->> 'capacity', '')::integer,
      nullif(btrim(coalesce(p_payload ->> 'address_line', '')), ''),
      nullif(btrim(coalesce(p_payload ->> 'city', '')), ''),
      nullif(upper(btrim(coalesce(p_payload ->> 'state', ''))), ''),
      nullif(btrim(coalesce(p_payload ->> 'postal_code', '')), ''),
      coalesce(nullif(upper(btrim(coalesce(p_payload ->> 'country', ''))), ''), 'US'),
      nullif(btrim(coalesce(p_payload ->> 'cover_image_path', '')), ''),
      coalesce(
        (select array_agg(x) from jsonb_array_elements_text(coalesce(p_payload -> 'image_paths', '[]'::jsonb)) x),
        '{}'::text[]),
      -- NOT from the payload. This column is what the promotional CHECK keys on, so letting a
      -- caller set it would make the constraint advisory. It is true because this function is the
      -- admin surface; `create_event` never touches it and so can never write those fields.
      true,
      nullif(btrim(coalesce(p_payload ->> 'organizer_name', '')), ''),
      nullif(btrim(coalesce(p_payload ->> 'registration_url', '')), ''),
      nullif(btrim(coalesce(p_payload ->> 'website_url', '')), ''),
      nullif(btrim(coalesce(p_payload ->> 'contact_email', '')), ''),
      nullif(btrim(coalesce(p_payload ->> 'contact_phone', '')), ''),
      coalesce(nullif(p_payload ->> 'status', ''), 'draft')::event_status,
      v_me
    )
    returning id into v_id;
  else
    update public.events set
      title            = btrim(coalesce(p_payload ->> 'title', title)),
      description      = nullif(btrim(coalesce(p_payload ->> 'description', '')), ''),
      event_type       = coalesce(nullif(p_payload ->> 'event_type', ''), event_type::text)::event_type,
      starts_at        = (p_payload ->> 'starts_at')::timestamptz,
      ends_at          = nullif(p_payload ->> 'ends_at', '')::timestamptz,
      -- COALESCE, not assignment: the edit form may not carry a point, and a map pin that
      -- disappears because somebody corrected a spelling is a bug nobody reports clearly.
      meet_point       = coalesce(v_point, meet_point),
      meet_note        = nullif(btrim(coalesce(p_payload ->> 'meet_note', '')), ''),
      capacity         = nullif(p_payload ->> 'capacity', '')::integer,
      address_line     = nullif(btrim(coalesce(p_payload ->> 'address_line', '')), ''),
      city             = nullif(btrim(coalesce(p_payload ->> 'city', '')), ''),
      state            = nullif(upper(btrim(coalesce(p_payload ->> 'state', ''))), ''),
      postal_code      = nullif(btrim(coalesce(p_payload ->> 'postal_code', '')), ''),
      country          = coalesce(nullif(upper(btrim(coalesce(p_payload ->> 'country', ''))), ''), country),
      cover_image_path = nullif(btrim(coalesce(p_payload ->> 'cover_image_path', '')), ''),
      image_paths      = coalesce(
        (select array_agg(x) from jsonb_array_elements_text(coalesce(p_payload -> 'image_paths', '[]'::jsonb)) x),
        '{}'::text[]),
      is_official      = true,
      organizer_name   = nullif(btrim(coalesce(p_payload ->> 'organizer_name', '')), ''),
      registration_url = nullif(btrim(coalesce(p_payload ->> 'registration_url', '')), ''),
      website_url      = nullif(btrim(coalesce(p_payload ->> 'website_url', '')), ''),
      contact_email    = nullif(btrim(coalesce(p_payload ->> 'contact_email', '')), ''),
      contact_phone    = nullif(btrim(coalesce(p_payload ->> 'contact_phone', '')), ''),
      status           = coalesce(nullif(p_payload ->> 'status', ''), status::text)::event_status,
      updated_at       = now()
    where id = v_id;

    if not found then
      return jsonb_build_object('ok', false, 'error', 'no_such_event');
    end if;
  end if;

  -- TARGETING IS REPLACED WHOLESALE WHEN `targets` IS PRESENT, and left alone when it is absent.
  --
  -- Those are different intentions and conflating them loses one of them: a form that submits an
  -- empty array means "this is for everybody now", while a call that omits the key entirely -- say a
  -- status change -- must not quietly widen a campaign to the whole membership.
  if p_payload ? 'targets' then
    delete from public.target_locations where scope = 'event' and target_id = v_id;

    for v_target in select * from jsonb_array_elements(v_targets) loop
      insert into public.target_locations (scope, target_id, kind, state, city, postal_code,
                                           center, radius_miles)
      values (
        'event', v_id,
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
  end if;

  perform app.audit(
    case when v_new then 'event.create' else 'event.update' end,
    'event', v_id::text,
    jsonb_build_object('status', p_payload ->> 'status',
                       'targets', jsonb_array_length(v_targets))
  );

  return jsonb_build_object('ok', true, 'id', v_id,
                            'audience', app.target_audience_count('event', v_id));
exception
  -- The CHECKs on this table are the real validation, and an admin typing a bad link should read a
  -- sentence rather than a Postgres error code. Named individually so the message can be specific.
  when check_violation then
    return jsonb_build_object('ok', false, 'error',
      case
        when sqlerrm like '%events_urls_are_web%'        then 'bad_url'
        when sqlerrm like '%events_contact_formats%'     then 'bad_contact'
        when sqlerrm like '%events_title_no_contact_info%' then 'contact_info_in_title'
        when sqlerrm like '%events_city_sane%'           then 'contact_info_in_city'
        when sqlerrm like '%events_address_sane%'        then 'contact_info_in_address'
        when sqlerrm like '%events_postal_format%'       then 'bad_postal_code'
        when sqlerrm like '%events_state_format%'        then 'bad_state'
        when sqlerrm like '%events_images_bounded%'      then 'too_many_images'
        when sqlerrm like '%events_description_check%'   then 'contact_info_in_description'
        else 'invalid'
      end);
end;
$fn$;

revoke all on function public.admin_save_event(jsonb) from public, anon;
-- Granted to `authenticated`, not `service_role`: the gate is auth.uid() through app.require_admin(),
-- so there is no shared key anywhere that grants admin.
grant execute on function public.admin_save_event(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. The reader every member already uses
-- ---------------------------------------------------------------------------

create or replace function public.events_upcoming(p_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me     uuid := auth.uid();
  v_rows   jsonb;
  v_city   text;
  v_state  text;
  v_postal text;
  v_center extensions.geography;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  -- The member's STATED area, the advertising-purpose one, for deciding what is near them. Four
  -- scalars and nothing else from the row, for the same reason the advertising path does it that
  -- way: the recovery position on a volunteer record is not this.
  select p.city, p.state, p.postal_code, p.postal_center
    into v_city, v_state, v_postal, v_center
    from public.profiles p
   where p.user_id = v_me;

  select coalesce(jsonb_agg(to_jsonb(e) order by e.starts_at), '[]'::jsonb) into v_rows
  from (
    select ev.id, ev.title, ev.description, ev.starts_at, ev.ends_at, ev.meet_note,
           ev.capacity,
           -- Everything above this line is what the previous version returned, unchanged.
           ev.event_type::text as event_type,
           ev.address_line, ev.city, ev.state, ev.postal_code,
           ev.cover_image_path, ev.image_paths,
           ev.is_official, ev.organizer_name, ev.registration_url, ev.website_url,
           ev.contact_email, ev.contact_phone,
           g.name as group_name, g.slug as group_slug,
           t.name as trail_name, t.slug as trail_slug,
           (select count(*) from event_rsvps r
             where r.event_id = ev.id and r.response = 'going') as going_count,
           (select r.response::text from event_rsvps r
             where r.event_id = ev.id and r.user_id = v_me) as my_response,

           -- NOT A FILTER. See the header: an event is never hidden from a member. This says whether
           -- it was aimed at them, so the page can badge it or offer a "near me" toggle, and so that
           -- notifications can be sent to the right people without the directory lying to anybody.
           -- An untargeted event matches everybody, which is why most of these are true.
           app.member_matches_target('event', ev.id, v_state, v_city, v_postal, v_center)
             as matches_my_area
      from events ev
      left join groups g on g.id = ev.group_id
      left join trails t on t.id = ev.trail_id
     where ev.status = 'published'
       and ev.starts_at > now() - interval '6 hours'
     order by ev.starts_at
     limit greatest(1, least(coalesce(p_limit, 20), 100))
  ) e;

  return jsonb_build_object('ok', true, 'events', v_rows);
end;
$fn$;

notify pgrst, 'reload schema';
