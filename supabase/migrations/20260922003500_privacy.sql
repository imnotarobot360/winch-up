-- Winch Up :: what deletion deletes, and what time deletes
--
-- Phase 14 is a security and privacy review. This migration is the part of that review that
-- turned into code. The findings that did not are in docs/security-review.md.
--
-- THE FINDING.
--
-- Deleting an account did not delete the account. Measured against the database rather than
-- reasoned about: create a user, a volunteer profile, a recovery request and a post, delete the
-- user, and this is what is left behind --
--
--     responders: phone=+15125559999  name=Gone      user_id=(null)
--     requests:   phone=+15125559999  name=Gone      user_id=(null)
--     requests:   exact location still stored: true
--
-- The foreign keys were doing exactly what Phase 3 set them up to do -- SET NULL, so history
-- survives with the attribution removed. What nobody checked is that the identifying data was
-- never in the foreign key. It was in the columns beside it: a mobile number, a first name, and
-- the exact coordinates of somewhere this person got stuck at night.
--
-- A delete button that leaves a phone number behind is not a delete button, and this project's
-- own rules say phones are private. So: a trigger on auth.users that scrubs the identifiers
-- before the row goes. It fires wherever the delete comes from -- the account screen, an admin,
-- the Supabase dashboard -- because it is on the table rather than in one code path.
--
-- WHAT IS SCRUBBED, AND WHAT IS KEPT.
--
-- Scrubbed: mobile number, name, exact location, home location, last shared position. Everything
-- that identifies a person or says where they were.
--
-- Kept: that a recovery happened, when, roughly where, and what was said in it. A conversation
-- belongs to two people and one of them leaving does not erase the other's copy; a post somebody
-- replied to does not vanish and take the replies with it. The account deletion screen says this
-- in words, because a promise of erasure that is quietly partial is worse than an honest one.
--
-- RETENTION. Nothing expired before this. A recovery from 2026 kept a phone number and an exact
-- pin for ever, for no reason -- the job was done the same evening. Closed requests are now
-- scrubbed after a number of days the owner can set, using the same code path as deletion.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- A place to record that a row has been through this
-- ---------------------------------------------------------------------------

alter table requests   add column if not exists redacted_at timestamptz;
alter table responders add column if not exists redacted_at timestamptz;

create index if not exists requests_unredacted_idx
  on requests (created_at)
  where redacted_at is null;

comment on column requests.redacted_at is
  'Set when the identifying columns were scrubbed, by account deletion or by retention. The row '
  'survives as history; the person does not appear in it.';

-- The number written where a real one used to be. A valid E.164 shape, so the CHECK constraints
-- and every code path that expects a phone keep working, and an unassignable area code, so
-- nobody can dial it by accident.
create or replace function app.redacted_phone()
returns text
language sql
immutable
set search_path = pg_catalog
as $$ select '+10000000000'::text $$;

-- ---------------------------------------------------------------------------
-- The scrub itself, shared by deletion and retention
-- ---------------------------------------------------------------------------

create or replace function app.scrub_request(p_request_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  update requests
     set requester_phone = app.redacted_phone(),
         requester_name  = 'Removed',
         -- The exact pin is destroyed. approx_location is the blurred one that has been on the
         -- public board all along, so keeping it reveals nothing new and leaves the history
         -- legible.
         location        = approx_location,
         location_note   = null,
         notes           = null,
         thank_you_note  = null,
         redacted_at     = now()
   where id = p_request_id
     and redacted_at is null;

  -- The outbox holds the number it texted, and the body it rendered.
  update sms_messages
     set to_phone = app.redacted_phone(),
         body = null
   where request_id = p_request_id;
end;
$$;

create or replace function app.scrub_responder(p_responder_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  update responders
     set phone         = app.redacted_phone(),
         first_name    = 'Removed',
         last_name     = null,
         -- Their home. Moved to a point in the Gulf of Mexico rather than nulled, because the
         -- column is NOT NULL and every query that reads it expects a point. Availability and
         -- approval below make sure it is never matched against anything again.
         home_location = extensions.st_setsrid(
                           extensions.st_point(-90.0, 25.0), 4326)::extensions.geography,
         last_location = null,
         last_location_at = null,
         share_location = false,
         availability  = 'paused',
         approval      = 'rejected',
         sms_opt_in    = false,
         redacted_at   = now()
   where id = p_responder_id
     and redacted_at is null;
end;
$$;

-- ---------------------------------------------------------------------------
-- Deletion
--
-- BEFORE DELETE on auth.users, so it runs whoever does the deleting and whatever they use.
-- ---------------------------------------------------------------------------

create or replace function app.scrub_on_account_delete()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_id uuid;
begin
  -- An open recovery cannot be left running with nobody to call. Cancelled first, so the
  -- dispatch state machine stops working it, then scrubbed with the rest.
  update requests
     set status = 'cancelled',
         cancel_reason = 'account deleted'
   where requester_user_id = old.id
     and status in ('submitted', 'dispatching', 'unmatched', 'accepted', 'on_site');

  for v_id in select id from requests where requester_user_id = old.id
  loop
    perform app.scrub_request(v_id);
  end loop;

  for v_id in select id from responders where user_id = old.id
  loop
    perform app.scrub_responder(v_id);
  end loop;

  -- Their own shared position, wherever it is recorded.
  update responders set last_location = null, last_location_at = null, share_location = false
   where user_id = old.id;

  return old;
end;
$$;

drop trigger if exists users_scrub_on_delete on auth.users;

create trigger users_scrub_on_delete
  before delete on auth.users
  for each row execute function app.scrub_on_account_delete();

-- ---------------------------------------------------------------------------
-- Retention
--
-- A recovery is over the evening it happens. Keeping the phone number and the exact pin for
-- ever afterwards serves nobody and is one breach away from being somebody's problem.
-- ---------------------------------------------------------------------------

insert into app_settings (key, value, description)
values (
  'privacy.request_retention_days',
  '180'::jsonb,
  'Days after a recovery closes before the phone number, name and exact pin are scrubbed. '
  'The recovery itself, its timings and its blurred location are kept.'
)
on conflict (key) do nothing;

create or replace function app.apply_retention()
returns integer
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_days  integer := coalesce(app.setting_int('privacy.request_retention_days', 180), 180);
  v_id    uuid;
  v_count integer := 0;
begin
  -- Zero or less turns it off rather than scrubbing everything, which is the safer way round
  -- for a setting somebody might clear by accident.
  if v_days <= 0 then
    return 0;
  end if;

  for v_id in
    select id from requests
     where redacted_at is null
       and status in ('recovered', 'cancelled', 'expired')
       -- updated_at is when it last moved, which for a closed request is when it closed.
       and coalesce(updated_at, created_at) < now() - (v_days || ' days')::interval
     limit 500
  loop
    perform app.scrub_request(v_id);
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- Retention runs on the schedule that already exists
--
-- Called from /api/sms/drain, which the scheduled job already hits every minute to empty the
-- SMS outbox and the notification queue. A third queue there costs nothing when there is
-- nothing to do -- one indexed query against requests that have not been redacted -- and needs
-- no new cron entry for somebody to forget to create.
--
-- Not wrapped around drain_notifications, because that would mean rewriting a function that is
-- working in order to add something unrelated to it.
-- ---------------------------------------------------------------------------

create or replace function public.apply_retention()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
begin
  return jsonb_build_object('ok', true, 'scrubbed', app.apply_retention());
end;
$fn$;

revoke all on function public.apply_retention() from public, anon, authenticated;
