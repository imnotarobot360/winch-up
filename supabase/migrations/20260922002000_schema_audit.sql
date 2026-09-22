-- Winch Up :: schema audit, and what it found
--
-- Phase 12 asks for the database to be inspected before anything is changed, and for foreign
-- keys, indexes, constraints, geospatial indexes and server-side authorization to be right. So
-- the database was inspected. This migration is what that turned up.
--
-- WHAT WAS ALREADY RIGHT, and is now asserted by supabase/tests/schema_audit_test.sql so it
-- stays that way:
--
--   Every table in public has row level security on. Eighteen of them have no policies and no
--   grants at all, which is the deny-by-default design working: they are reachable only through
--   security definer functions.
--
--   Every reference to auth.users has an explicit ON DELETE. That was a real bug in Phase 3 --
--   seven of them defaulted to NO ACTION and account deletion threw -- and nothing since has
--   reintroduced it.
--
--   Every table has a primary key. Dispatches are unique per (request, responder), so a
--   volunteer cannot be texted twice about the same job. Requests carry an idempotency key.
--
--   app.check_rate_limit already prunes rate_limit_hits on every call. I had this down as a
--   finding -- an unbounded table -- until I read the function. It is not one.
--
-- WHAT WAS WRONG:
--
--   1. ONE OPEN REQUEST PER ACCOUNT WAS A READ-THEN-WRITE. create_request selected any open
--      request and returned it if found; two submits arriving together both find none and both
--      insert. The spec for this phase names race conditions and duplicate requests explicitly.
--      Fixed with a partial unique index -- the database decides -- plus a handler so the loser
--      still gets the friendly answer rather than a 23505.
--
--   2. ad_campaigns.target_center HAD NO GIST INDEX, and every ad served runs st_dwithin against
--      it. Introduced by me, today, in Phase 10. businesses.service_center and
--      trail_edits.location had none either; those are not queried spatially yet, and get one
--      now so that the rule "every geography column is indexed" can be asserted rather than
--      remembered.
--
--   3. THREE FUNCTIONS DID NOT PIN search_path. public.contains_contact_info is the one that
--      matters: it is called from CHECK constraints on a dozen columns across the schema. The
--      other two are app.miles_to_meters and app.ad_slot_allowed, the second of which I wrote
--      yesterday against this project's own convention.
--
--   4. THIRTY-FOUR FOREIGN KEY COLUMNS HAD NO INDEX. Deleting an account -- a feature this app
--      has -- makes Postgres scan every one of those tables to enforce the reference. Several
--      also have real query patterns: every comment by one person, every save of one trail.
--      Partial where the column is nullable, because most of them are almost always null.
--
-- None of this changes behaviour anybody can see, except the race, which changes it from
-- "sometimes two open requests" to "never".

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. One open request per account, enforced where it cannot be raced
-- ---------------------------------------------------------------------------

create unique index if not exists requests_one_open_per_account
  on requests (requester_user_id)
  where requester_user_id is not null
    and status in ('submitted', 'dispatching', 'unmatched', 'accepted', 'on_site');

comment on index requests_one_open_per_account is
  'The application check in create_request reads then writes, which two concurrent submits can '
  'both pass. This is the same rule where it cannot be raced.';

create or replace function public.create_request(p_payload jsonb, p_site_url text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_submission_id uuid   := nullif(p_payload ->> 'submission_id', '')::uuid;
  v_phone         text   := btrim(p_payload ->> 'phone');
  v_locale        text   := coalesce(nullif(p_payload ->> 'locale', ''), 'en');
  v_ip            inet   := nullif(p_payload ->> 'ip', '')::inet;
  v_lat           double precision := (p_payload ->> 'lat')::double precision;
  v_lng           double precision := (p_payload ->> 'lng')::double precision;
  v_user_id       uuid   := nullif(p_payload ->> 'requester_user_id', '')::uuid;
  v_waiver_id     uuid;
  v_existing      public.requests%rowtype;
  v_open          public.requests%rowtype;
  v_request       public.requests%rowtype;
  v_photo         jsonb;
  v_max_phone     integer;
  v_max_ip        integer;
  v_url           text;
begin
  -- Replay of a retried submit: hand back the same request instead of making a second one.
  if v_submission_id is not null then
    select * into v_existing from public.requests where submission_id = v_submission_id;
    if found then
      return jsonb_build_object(
        'ok', true, 'replayed', true,
        'request_id', v_existing.id,
        'token', v_existing.public_token,
        'short_code', v_existing.short_code
      );
    end if;
  end if;

  -- A request belongs to an account. Checked after the replay guard so a retried submit still
  -- returns the original request rather than failing differently the second time.
  if v_user_id is null then
    return jsonb_build_object('ok', false, 'error', 'account_required');
  end if;

  -- One open recovery per account.
  --
  -- The per-phone rate limit allows three a day, which is right for "stuck again on Sunday"
  -- and wrong for three at once: each would dispatch separately and send volunteers to the
  -- same truck three times. Someone who submits twice has usually lost the link, or is on a
  -- bad connection and unsure the first one went through, so hand back the request they
  -- already have rather than refusing them. Only open states block; once recovered, cancelled
  -- or expired they can file again.
  select * into v_open
    from public.requests
   where requester_user_id = v_user_id
     and status in ('submitted', 'dispatching', 'unmatched', 'accepted', 'on_site')
   order by created_at desc
   limit 1;

  if found then
    return jsonb_build_object(
      'ok', true, 'replayed', true, 'existing_open', true,
      'request_id', v_open.id,
      'token', v_open.public_token,
      'short_code', v_open.short_code
    );
  end if;

  if v_phone is null or v_phone !~ '^\+1[0-9]{10}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_phone');
  end if;

  if v_lat is null or v_lng is null
     or v_lat not between -90 and 90 or v_lng not between -180 and 180 then
    return jsonb_build_object('ok', false, 'error', 'invalid_location');
  end if;

  if exists (
    select 1 from public.blocklist b
     where (b.phone is not null and b.phone = v_phone)
        or (b.ip is not null and v_ip is not null and b.ip = v_ip)
  ) then
    return jsonb_build_object('ok', false, 'error', 'blocked');
  end if;

  select coalesce((value #>> '{}')::integer, 3) into v_max_phone
    from public.app_settings where key = 'limits.max_requests_per_phone_per_day';
  select coalesce((value #>> '{}')::integer, 5) into v_max_ip
    from public.app_settings where key = 'limits.max_requests_per_ip_per_hour';

  if not app.check_rate_limit('request:phone:' || v_phone, coalesce(v_max_phone, 3), interval '24 hours') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited_phone');
  end if;

  if v_ip is not null
     and not app.check_rate_limit('request:ip:' || host(v_ip), coalesce(v_max_ip, 5), interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited_ip');
  end if;

  select id into v_waiver_id
    from public.waivers where slug = 'requester_waiver' and is_current;

  if v_waiver_id is null then
    raise exception 'no current requester_waiver row: run supabase/seed.sql';
  end if;

  insert into public.requests (
    submission_id, locale, requester_user_id,
    requester_name, requester_phone,
    location, location_accuracy_m, location_source, location_note, county,
    vehicle_class, vehicle_make, vehicle_model, vehicle_year, drivetrain,
    stuck_type, stuck_depth, needs_tractor, needs_second_truck,
    land_type, land_permission_note, notes,
    emergency_ack_at, rules_accepted, waiver_id, waiver_accepted_at,
    waiver_ip, waiver_user_agent, created_ip, created_user_agent,
    next_action_at
  ) values (
    v_submission_id,
    case when v_locale in ('en', 'es') then v_locale else 'en' end,
    v_user_id,
    btrim(p_payload ->> 'name'),
    v_phone,
    extensions.st_setsrid(extensions.st_point(v_lng, v_lat), 4326)::extensions.geography,
    nullif(p_payload ->> 'accuracy_m', '')::numeric,
    coalesce(nullif(p_payload ->> 'location_source', ''), 'gps')::location_source,
    nullif(btrim(coalesce(p_payload ->> 'location_note', '')), ''),
    nullif(btrim(coalesce(p_payload ->> 'county', '')), ''),
    (p_payload ->> 'vehicle_class')::vehicle_class,
    nullif(btrim(coalesce(p_payload ->> 'vehicle_make', '')), ''),
    nullif(btrim(coalesce(p_payload ->> 'vehicle_model', '')), ''),
    nullif(p_payload ->> 'vehicle_year', '')::smallint,
    coalesce(nullif(p_payload ->> 'drivetrain', ''), 'unknown')::drivetrain,
    (p_payload ->> 'stuck_type')::stuck_type,
    nullif(p_payload ->> 'stuck_depth', '')::stuck_depth,
    coalesce((p_payload ->> 'needs_tractor')::boolean, false),
    coalesce((p_payload ->> 'needs_second_truck')::boolean, false),
    (p_payload ->> 'land_type')::land_type,
    nullif(btrim(coalesce(p_payload ->> 'land_permission_note', '')), ''),
    nullif(btrim(coalesce(p_payload ->> 'notes', '')), ''),
    now(), true, v_waiver_id, now(),
    v_ip, nullif(p_payload ->> 'user_agent', ''), v_ip, nullif(p_payload ->> 'user_agent', ''),
    -- The 60 s tick picks this up immediately and starts ring 1.
    now()
  )
  returning * into v_request;

  for v_photo in select * from jsonb_array_elements(coalesce(p_payload -> 'photos', '[]'::jsonb))
  loop
    begin
      insert into public.request_photos (request_id, storage_path, content_type, bytes, width, height, sort_order)
      values (
        v_request.id,
        v_photo ->> 'path',
        coalesce(nullif(v_photo ->> 'content_type', ''), 'image/jpeg'),
        nullif(v_photo ->> 'bytes', '')::integer,
        nullif(v_photo ->> 'width', '')::integer,
        nullif(v_photo ->> 'height', '')::integer,
        coalesce(nullif(v_photo ->> 'sort_order', '')::smallint, 0)
      );
    exception when others then
      -- A photo that will not attach must never cost someone their recovery request.
      raise notice 'create_request: skipped photo % (%)', v_photo ->> 'path', sqlerrm;
    end;
  end loop;

  v_url := rtrim(coalesce(p_site_url, ''), '/') || '/r/' || v_request.public_token;

  perform app.queue_sms(
    v_request.requester_phone,
    'requester.created',
    jsonb_build_object('short_code', v_request.short_code, 'url', v_url),
    v_request.locale,
    v_request.id
  );

  return jsonb_build_object(
    'ok', true, 'replayed', false,
    'request_id', v_request.id,
    'token', v_request.public_token,
    'short_code', v_request.short_code,
    'status_url', v_url
  );
-- ---------------------------------------------------------------------------
-- The losing half of a race.
--
-- Everything above is unchanged from 20260921001000. This block is the addition: if two submits
-- arrive at once, both read no open request, both insert, and the new unique index rejects one
-- of them. That request has not failed -- the person has an open recovery, which is what they
-- were trying to get -- so hand back the one that won, exactly as the check above would have.
--
-- Narrowed to the constraint by name. public_token and short_code are generated and also unique;
-- a collision there is a different problem and must keep raising.
-- ---------------------------------------------------------------------------
exception
  when unique_violation then
    declare
      v_constraint text;
      v_raced      public.requests%rowtype;
    begin
      get stacked diagnostics v_constraint = constraint_name;

      if v_constraint is distinct from 'requests_one_open_per_account' then
        raise;
      end if;

      select * into v_raced
        from public.requests
       where requester_user_id = v_user_id
         and status in ('submitted', 'dispatching', 'unmatched', 'accepted', 'on_site')
       order by created_at desc
       limit 1;

      if not found then
        raise;
      end if;

      return jsonb_build_object(
        'ok', true, 'replayed', true, 'existing_open', true,
        'request_id', v_raced.id,
        'token', v_raced.public_token,
        'short_code', v_raced.short_code
      );
    end;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Geospatial indexes
-- ---------------------------------------------------------------------------

-- Queried on every ad served.
create index if not exists ad_campaigns_target_idx on ad_campaigns using gist (target_center);

-- Not queried spatially yet. Indexed anyway, so "every geography column has a GiST index" is a
-- property that can be tested rather than a habit that can lapse.
create index if not exists businesses_service_idx on businesses using gist (service_center);
create index if not exists trail_edits_location_idx on trail_edits using gist (location);

-- ---------------------------------------------------------------------------
-- 3. Pin search_path on the three that did not
--
-- ALTER rather than CREATE OR REPLACE: contains_contact_info is referenced by CHECK constraints
-- on a dozen columns, and this way its body is not touched at all.
-- ---------------------------------------------------------------------------

alter function public.contains_contact_info(text) set search_path = pg_catalog, public, pg_temp;
alter function app.miles_to_meters(numeric) set search_path = pg_catalog, public, pg_temp;
alter function app.ad_slot_allowed(ad_surface, text) set search_path = pg_catalog, public, pg_temp;

-- ---------------------------------------------------------------------------
-- 4. An index on every foreign key
--
-- Generated from the catalogue rather than typed, so the list is exactly what was missing.
-- ---------------------------------------------------------------------------

create index if not exists ad_campaigns_reviewed_by_idx on ad_campaigns (reviewed_by) where reviewed_by is not null;
create index if not exists ad_creatives_reviewed_by_idx on ad_creatives (reviewed_by) where reviewed_by is not null;
create index if not exists app_settings_updated_by_idx on app_settings (updated_by) where updated_by is not null;
create index if not exists audit_log_actor_user_id_idx on audit_log (actor_user_id) where actor_user_id is not null;
create index if not exists blocklist_created_by_idx on blocklist (created_by) where created_by is not null;
create index if not exists businesses_reviewed_by_idx on businesses (reviewed_by) where reviewed_by is not null;
create index if not exists community_comments_author_user_id_idx on community_comments (author_user_id) where author_user_id is not null;
create index if not exists community_comments_moderated_by_idx on community_comments (moderated_by) where moderated_by is not null;
create index if not exists community_posts_moderated_by_idx on community_posts (moderated_by) where moderated_by is not null;
create index if not exists community_reactions_user_id_idx on community_reactions (user_id);
create index if not exists content_reports_reporter_user_id_idx on content_reports (reporter_user_id) where reporter_user_id is not null;
create index if not exists content_reports_reviewed_by_idx on content_reports (reviewed_by) where reviewed_by is not null;
create index if not exists request_events_actor_responder_id_idx on request_events (actor_responder_id) where actor_responder_id is not null;
create index if not exists request_events_actor_user_id_idx on request_events (actor_user_id) where actor_user_id is not null;
create index if not exists request_messages_sender_user_id_idx on request_messages (sender_user_id) where sender_user_id is not null;
create index if not exists requests_created_by_idx on requests (created_by) where created_by is not null;
create index if not exists requests_waiver_id_idx on requests (waiver_id);
create index if not exists responders_approved_by_idx on responders (approved_by) where approved_by is not null;
create index if not exists safety_incidents_reporter_user_id_idx on safety_incidents (reporter_user_id) where reporter_user_id is not null;
create index if not exists safety_incidents_request_id_idx on safety_incidents (request_id) where request_id is not null;
create index if not exists safety_incidents_reviewed_by_idx on safety_incidents (reviewed_by) where reviewed_by is not null;
create index if not exists safety_incidents_subject_user_id_idx on safety_incidents (subject_user_id) where subject_user_id is not null;
create index if not exists sms_messages_dispatch_id_idx on sms_messages (dispatch_id) where dispatch_id is not null;
create index if not exists sms_messages_responder_id_idx on sms_messages (responder_id) where responder_id is not null;
create index if not exists trail_conditions_author_user_id_idx on trail_conditions (author_user_id) where author_user_id is not null;
create index if not exists trail_conditions_moderated_by_idx on trail_conditions (moderated_by) where moderated_by is not null;
create index if not exists trail_edits_author_user_id_idx on trail_edits (author_user_id) where author_user_id is not null;
create index if not exists trail_edits_reviewed_by_idx on trail_edits (reviewed_by) where reviewed_by is not null;
create index if not exists trail_edits_trail_id_idx on trail_edits (trail_id) where trail_id is not null;
create index if not exists trail_saves_trail_id_idx on trail_saves (trail_id);
create index if not exists trails_created_by_idx on trails (created_by) where created_by is not null;
create index if not exists trails_verified_by_idx on trails (verified_by) where verified_by is not null;
create index if not exists user_blocks_blocked_user_id_idx on user_blocks (blocked_user_id);
create index if not exists user_roles_granted_by_idx on user_roles (granted_by) where granted_by is not null;
