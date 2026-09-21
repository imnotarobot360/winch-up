-- TxRecover M1 :: triggers
--
-- Invariants that must hold no matter which client wrote the row live here, not in the app.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- updated_at
-- ---------------------------------------------------------------------------

create trigger app_settings_set_updated_at before update on app_settings
  for each row execute function app.set_updated_at();
create trigger pro_options_set_updated_at before update on pro_options
  for each row execute function app.set_updated_at();
create trigger responders_set_updated_at before update on responders
  for each row execute function app.set_updated_at();
create trigger requests_set_updated_at before update on requests
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------------
-- waivers: exactly one current version per slug
-- ---------------------------------------------------------------------------

create or replace function app.waivers_single_current()
returns trigger
language plpgsql
set search_path = public, extensions, pg_temp
as $$
begin
  if new.is_current then
    update public.waivers
       set is_current = false
     where slug = new.slug
       and id <> new.id
       and is_current;
  end if;
  return new;
end;
$$;

create trigger waivers_single_current after insert or update of is_current on waivers
  for each row when (new.is_current) execute function app.waivers_single_current();

-- ---------------------------------------------------------------------------
-- requests: derived columns
-- ---------------------------------------------------------------------------

create or replace function app.requests_derive()
returns trigger
language plpgsql
set search_path = public, extensions, pg_temp
as $$
begin
  -- The blurred pin is always derived. Never trust a caller-supplied value: a caller that could
  -- set it could set it equal to the exact point and defeat the whole privacy rule.
  new.approx_location := app.blur_point(new.location, new.id);

  new.required_equipment := app.required_equipment(
    new.needs_tractor, new.needs_second_truck, new.stuck_type, new.stuck_depth
  );

  new.state := upper(coalesce(nullif(btrim(new.state), ''), 'TX'));

  if tg_op = 'UPDATE' then
    -- Identifiers are handed out over SMS and printed in Facebook posts; they never change.
    if new.public_token is distinct from old.public_token then
      raise exception 'requests.public_token is immutable';
    end if;
    if new.short_code is distinct from old.short_code then
      raise exception 'requests.short_code is immutable';
    end if;
  end if;

  return new;
end;
$$;

create trigger requests_derive before insert or update on requests
  for each row execute function app.requests_derive();

-- ---------------------------------------------------------------------------
-- requests: blocklist
-- ---------------------------------------------------------------------------

create or replace function app.requests_check_blocklist()
returns trigger
language plpgsql
set search_path = public, extensions, pg_temp
as $$
begin
  if exists (
    select 1 from public.blocklist b
     where (b.phone is not null and b.phone = new.requester_phone)
        or (b.ip is not null and new.created_ip is not null and b.ip = new.created_ip)
  ) then
    raise exception 'blocked' using errcode = 'check_violation',
      detail = 'This phone number or address is blocked from creating requests.';
  end if;
  return new;
end;
$$;

create trigger requests_check_blocklist before insert on requests
  for each row execute function app.requests_check_blocklist();

-- ---------------------------------------------------------------------------
-- requests: timeline events
-- ---------------------------------------------------------------------------

create or replace function app.requests_log_events()
returns trigger
language plpgsql
set search_path = public, extensions, pg_temp
as $$
declare
  evt request_event_type;
begin
  if tg_op = 'INSERT' then
    insert into public.request_events (request_id, event_type, actor_kind, data)
    values (new.id, 'created', 'requester', jsonb_build_object('short_code', new.short_code));
    return new;
  end if;

  if new.status is distinct from old.status then
    evt := case new.status
             when 'dispatching' then 'dispatch_started'
             when 'unmatched'   then 'unmatched'
             when 'accepted'    then 'accepted'
             when 'on_site'     then 'on_site'
             when 'recovered'   then 'recovered'
             when 'cancelled'   then 'cancelled'
             when 'expired'     then 'expired'
             else null
           end;

    if evt is not null then
      insert into public.request_events (request_id, event_type, actor_kind, actor_responder_id, data)
      values (
        new.id,
        evt,
        -- Both branches need the cast: a CASE over two bare string literals resolves to text,
        -- and there is no implicit text -> enum cast, so this threw on every status change.
        case when new.status in ('accepted', 'on_site')
             then 'responder'::actor_kind else 'system'::actor_kind end,
        new.accepted_responder_id,
        jsonb_strip_nulls(jsonb_build_object(
          'from', old.status,
          'to', new.status,
          'eta_minutes', new.eta_minutes
        ))
      );
    end if;
  end if;

  if new.current_ring is distinct from old.current_ring and new.current_ring > 0 then
    insert into public.request_events (request_id, event_type, actor_kind, data)
    values (
      new.id, 'ring_escalated', 'system',
      jsonb_build_object('ring', new.current_ring, 'notified_count', new.notified_count)
    );
  end if;

  if new.thank_you_note is distinct from old.thank_you_note and new.thank_you_note is not null then
    insert into public.request_events (request_id, event_type, actor_kind, actor_responder_id, data)
    values (new.id, 'thanked', 'requester', new.accepted_responder_id, '{}'::jsonb);
  end if;

  return new;
end;
$$;

create trigger requests_log_events after insert or update on requests
  for each row execute function app.requests_log_events();

-- ---------------------------------------------------------------------------
-- request_photos: at most 3 per request (matches the /request form)
-- ---------------------------------------------------------------------------

create or replace function app.request_photos_limit()
returns trigger
language plpgsql
set search_path = public, extensions, pg_temp
as $$
declare
  n integer;
begin
  select count(*) into n from public.request_photos where request_id = new.request_id;
  if n >= 3 then
    raise exception 'A request can have at most 3 photos' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger request_photos_limit before insert on request_photos
  for each row execute function app.request_photos_limit();

-- ---------------------------------------------------------------------------
-- responders: tidy equipment, track approval
-- ---------------------------------------------------------------------------

create or replace function app.responders_normalize()
returns trigger
language plpgsql
set search_path = public, extensions, pg_temp
as $$
begin
  new.first_name := btrim(new.first_name);
  new.last_name  := nullif(btrim(coalesce(new.last_name, '')), '');

  -- de-duplicate and order the equipment array so `@>` checks and admin screens stay predictable
  select coalesce(array_agg(distinct e order by e), '{}'::equipment_type[])
    into new.equipment
    from unnest(coalesce(new.equipment, '{}'::equipment_type[])) as e;

  if tg_op = 'UPDATE' and new.approval is distinct from old.approval then
    if new.approval = 'approved' then
      new.approved_at := coalesce(new.approved_at, now());
    else
      new.approved_at := null;
      new.approved_by := null;
    end if;
  end if;

  -- A volunteer who texted STOP is out until they opt back in.
  if new.sms_opt_out_at is not null and new.sms_opt_in then
    new.sms_opt_in := false;
  end if;

  return new;
end;
$$;

create trigger responders_normalize before insert or update on responders
  for each row execute function app.responders_normalize();
