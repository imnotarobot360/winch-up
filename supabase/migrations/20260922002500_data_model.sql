-- Winch Up :: the rest of the data model
--
-- Phase 12 lists the entities the finished product needs. Most already existed; the audit
-- migration before this one dealt with what was wrong about them. These are the ones that did
-- not exist at all:
--
--   Groups, group memberships, events        -- deferred twice, from Phase 8 and Phase 9
--   Notifications, delivery log              -- Phase 13 needs them
--   Payments, invoices, Stripe event log     -- the part of Phase 10 that needs the owner's keys
--
-- These are tables and the functions that reach them. The screens come with the phases that own
-- them, and this file says so rather than implying otherwise: there is no group UI yet, no event
-- UI, no notification bell. What there is, is a data model those can be built on without another
-- migration, which is what this phase asked for.
--
-- Two decisions worth stating:
--
-- GROUPS DO NOT GET THEIR OWN FEED. A group is a way to organise a ride and to say who is in it.
-- Posts stay in one community feed, because splitting a 6,800-member group into a dozen quiet
-- rooms is how a community stops being one.
--
-- STRIPE IDS ARE UNIQUE, EVERYWHERE THEY APPEAR. The spec asks for idempotent billing and
-- verified webhooks. Idempotency is not a code pattern here, it is a unique constraint:
-- stripe_webhook_events.id is the event id Stripe sent, so a replayed webhook inserts nothing
-- and the handler can stop. Same for payment intents and invoices.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- Groups
-- ---------------------------------------------------------------------------

create type group_visibility as enum ('open', 'request_to_join', 'invite_only');
create type group_role as enum ('member', 'organizer', 'owner');

create table groups (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name         text not null check (length(btrim(name)) between 2 and 80),
  description  text check (
                 description is null
                 or (length(btrim(description)) <= 1000
                     and not public.contains_contact_info(description))
               ),

  visibility   group_visibility not null default 'open',

  region       text check (region is null or length(btrim(region)) <= 120),
  center       extensions.geography(point, 4326),
  radius_miles integer check (radius_miles is null or radius_miles between 1 and 500),

  -- Same vocabulary as posts and trail conditions, so a moderator hides a group with the
  -- control they already know.
  status       content_status not null default 'visible',

  created_by   uuid references auth.users (id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index groups_visible_idx on groups (name) where status = 'visible';
create index groups_center_idx on groups using gist (center);
create index groups_created_by_idx on groups (created_by) where created_by is not null;

create trigger groups_set_updated_at
  before update on groups
  for each row execute function app.set_updated_at();

create table group_members (
  group_id  uuid not null references groups (id) on delete cascade,
  user_id   uuid not null references auth.users (id) on delete cascade,
  role      group_role not null default 'member',
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

create index group_members_user_idx on group_members (user_id);

-- ---------------------------------------------------------------------------
-- Events -- group rides, work days, meet-ups
-- ---------------------------------------------------------------------------

create type event_status as enum ('draft', 'published', 'cancelled');
create type rsvp_response as enum ('going', 'maybe', 'out');

create table events (
  id          uuid primary key default gen_random_uuid(),

  -- Both nullable: an event can belong to a group, can be about a trail, or neither.
  group_id    uuid references groups (id) on delete cascade,
  trail_id    uuid references trails (id) on delete set null,

  title       text not null check (length(btrim(title)) between 2 and 120),
  description text check (
                description is null
                or (length(btrim(description)) <= 2000
                    and not public.contains_contact_info(description))
              ),

  starts_at   timestamptz not null,
  ends_at     timestamptz,

  meet_point  extensions.geography(point, 4326),
  meet_note   text check (
                meet_note is null
                or (length(btrim(meet_note)) <= 300
                    and not public.contains_contact_info(meet_note))
              ),

  capacity    integer check (capacity is null or capacity between 1 and 500),

  status      event_status not null default 'draft',

  created_by  uuid references auth.users (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint events_end_after_start check (ends_at is null or ends_at >= starts_at)
);

create index events_upcoming_idx on events (starts_at) where status = 'published';
create index events_group_idx on events (group_id) where group_id is not null;
create index events_trail_idx on events (trail_id) where trail_id is not null;
create index events_meet_idx on events using gist (meet_point);
create index events_created_by_idx on events (created_by) where created_by is not null;

create trigger events_set_updated_at
  before update on events
  for each row execute function app.set_updated_at();

create table event_rsvps (
  event_id   uuid not null references events (id) on delete cascade,
  user_id    uuid not null references auth.users (id) on delete cascade,
  response   rsvp_response not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

create index event_rsvps_user_idx on event_rsvps (user_id);

create trigger event_rsvps_set_updated_at
  before update on event_rsvps
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------------
-- Notifications
--
-- One row per thing a person should know about, and a separate row per attempt to tell them.
-- Keeping them apart is what makes retries, fallbacks and "did this ever arrive" answerable:
-- the notification is the fact, the delivery is the attempt.
--
-- `kind` carries the priority ordering the spec asks for. Anything recovery-shaped outranks
-- community, which outranks marketing, and marketing is the only one gated on consent.
-- ---------------------------------------------------------------------------

create type notification_kind as enum (
  'recovery_request',    -- somebody near you is stuck
  'recovery_offer',      -- a volunteer answered
  'recovery_accepted',   -- your job was taken
  'recovery_status',     -- on site, recovered, expired
  'message',             -- a message on your recovery
  'community',           -- a reply, a reaction
  'event_reminder',
  'safety',              -- an incident outcome, a ban, a warning
  'marketing'            -- the only one that needs consent
);

create type notification_channel as enum ('in_app', 'sms', 'email', 'push');

create type delivery_state as enum (
  'queued', 'sent', 'delivered', 'failed', 'suppressed'
);

create table notifications (
  id        uuid primary key default gen_random_uuid(),
  user_id   uuid not null references auth.users (id) on delete cascade,

  kind      notification_kind not null,

  -- A key and its parameters, not a rendered sentence. The same rule as SMS: the database
  -- queues what happened, the sender renders it in the recipient's language.
  title_key text not null check (length(title_key) between 2 and 80),
  params    jsonb not null default '{}'::jsonb,

  -- Where it takes you. Relative, so it cannot be used to send somebody off-site.
  url       text check (url is null or url ~ '^/'),

  read_at    timestamptz,
  created_at timestamptz not null default now()
);

create index notifications_inbox_idx on notifications (user_id, created_at desc);
create index notifications_unread_idx on notifications (user_id) where read_at is null;

create table notification_deliveries (
  id              uuid primary key default gen_random_uuid(),
  notification_id uuid not null references notifications (id) on delete cascade,
  channel         notification_channel not null,

  state           delivery_state not null default 'queued',
  attempts        integer not null default 0 check (attempts >= 0),
  last_error      text,

  -- The duplicate-prevention the spec asks for. One delivery per (thing, channel, reason), and
  -- a retry that re-derives the same key inserts nothing instead of texting somebody twice at
  -- two in the morning.
  dedupe_key      text not null unique,

  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index notification_deliveries_pending_idx
  on notification_deliveries (state, created_at)
  where state in ('queued', 'failed');

create index notification_deliveries_notification_idx
  on notification_deliveries (notification_id);

create trigger notification_deliveries_set_updated_at
  before update on notification_deliveries
  for each row execute function app.set_updated_at();

-- ---------------------------------------------------------------------------
-- Money
--
-- Nothing writes these yet. Stripe needs the owner's account and keys, which is the one thing
-- in this project that cannot be built ahead of time. What can be built ahead of time is the
-- shape that makes the handler safe to write: every identifier Stripe sends is unique here, so
-- a replayed webhook is a no-op rather than a second charge on somebody's card.
-- ---------------------------------------------------------------------------

create type invoice_status as enum ('draft', 'open', 'paid', 'void', 'uncollectible');
create type payment_status as enum ('pending', 'succeeded', 'failed', 'refunded');

create table invoices (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses (id) on delete cascade,
  campaign_id  uuid references ad_campaigns (id) on delete set null,

  period_start date not null,
  period_end   date not null,

  amount_cents integer not null check (amount_cents >= 0),
  currency     text not null default 'usd' check (currency ~ '^[a-z]{3}$'),

  status       invoice_status not null default 'draft',

  stripe_invoice_id text unique,

  issued_at    timestamptz,
  paid_at      timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),

  constraint invoices_period_makes_sense check (period_end >= period_start),
  constraint invoices_paid_has_a_date check (status <> 'paid' or paid_at is not null)
);

create index invoices_business_idx on invoices (business_id, period_start desc);
create index invoices_campaign_idx on invoices (campaign_id) where campaign_id is not null;

create trigger invoices_set_updated_at
  before update on invoices
  for each row execute function app.set_updated_at();

create table payments (
  id          uuid primary key default gen_random_uuid(),
  invoice_id  uuid references invoices (id) on delete set null,
  business_id uuid not null references businesses (id) on delete cascade,

  amount_cents integer not null check (amount_cents >= 0),
  currency     text not null default 'usd' check (currency ~ '^[a-z]{3}$'),
  status       payment_status not null default 'pending',

  -- Stripe's own idempotency anchor. One payment row per payment intent, for ever.
  stripe_payment_intent_id text unique,

  failure_reason text,

  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index payments_business_idx on payments (business_id, created_at desc);
create index payments_invoice_idx on payments (invoice_id) where invoice_id is not null;

create trigger payments_set_updated_at
  before update on payments
  for each row execute function app.set_updated_at();

-- Every webhook Stripe ever sends, recorded by its own id. The handler's first statement will be
-- an insert here; if it conflicts, the event has already been processed and there is nothing to
-- do. That is the whole of "idempotent billing operations", and it is a primary key.
create table stripe_webhook_events (
  id          text primary key,
  type        text not null,
  received_at timestamptz not null default now(),
  payload     jsonb not null,
  handled_at  timestamptz,
  error       text
);

create index stripe_webhook_events_unhandled_idx
  on stripe_webhook_events (received_at)
  where handled_at is null;

-- ---------------------------------------------------------------------------
-- Deny by default, as everywhere else in this schema.
-- ---------------------------------------------------------------------------

alter table groups enable row level security;
alter table group_members enable row level security;
alter table events enable row level security;
alter table event_rsvps enable row level security;
alter table notifications enable row level security;
alter table notification_deliveries enable row level security;
alter table invoices enable row level security;
alter table payments enable row level security;
alter table stripe_webhook_events enable row level security;

revoke all on groups, group_members, events, event_rsvps,
              notifications, notification_deliveries,
              invoices, payments, stripe_webhook_events
  from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Telling somebody something
--
-- One entry point. It writes the fact, then one delivery row per channel, honouring the
-- preferences already on profiles. Two rules from the spec live here rather than in whatever
-- code calls it:
--
--   Marketing is the only kind that needs consent, and without it the delivery is written as
--   `suppressed` rather than skipped. A record that we chose not to send is worth having; a
--   silence is not.
--
--   Recovery outranks everything. The delivery rows carry the kind, so a sender draining the
--   queue can order by it and get the person who is stuck ahead of the person who got a reply.
-- ---------------------------------------------------------------------------

create or replace function app.notify(
  p_user_id   uuid,
  p_kind      notification_kind,
  p_title_key text,
  p_params    jsonb default '{}'::jsonb,
  p_url       text default null,
  p_channels  notification_channel[] default array['in_app']::notification_channel[],
  p_dedupe    text default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_id      uuid;
  v_profile public.profiles%rowtype;
  v_allowed boolean;
  v_channel notification_channel;
  v_key     text;
begin
  if p_user_id is null then
    return null;
  end if;

  select * into v_profile from public.profiles where user_id = p_user_id;

  insert into public.notifications (user_id, kind, title_key, params, url)
  values (p_user_id, p_kind, p_title_key, coalesce(p_params, '{}'::jsonb), p_url)
  returning id into v_id;

  foreach v_channel in array coalesce(p_channels, array['in_app']::notification_channel[])
  loop
    v_allowed := case
      -- The one that is gated. Absent a profile row, absent consent.
      when p_kind = 'marketing' then coalesce(v_profile.notify_marketing, false)
      when p_kind = 'community' or p_kind = 'event_reminder'
        then coalesce(v_profile.notify_community, true)
      -- Recovery and safety. A person can turn off the texts, but the in-app record is written
      -- either way: it is the thing that happened, not an interruption.
      when v_channel = 'in_app' then true
      else coalesce(v_profile.notify_recovery, true)
    end;

    -- Stable per notification and channel unless the caller knows better. A retry that
    -- re-derives the same key inserts nothing rather than sending twice.
    v_key := coalesce(p_dedupe || ':' || v_channel::text, v_id::text || ':' || v_channel::text);

    insert into public.notification_deliveries (notification_id, channel, state, dedupe_key)
    values (
      v_id, v_channel,
      case when v_allowed then 'queued'::delivery_state else 'suppressed'::delivery_state end,
      v_key
    )
    on conflict (dedupe_key) do nothing;
  end loop;

  return v_id;
end;
$fn$;

create or replace function public.my_notifications(p_limit integer default 30)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me   uuid := auth.uid();
  v_rows jsonb;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  select coalesce(jsonb_agg(to_jsonb(n) order by n.created_at desc), '[]'::jsonb) into v_rows
  from (
    select id, kind::text, title_key, params, url, read_at, created_at
      from notifications
     where user_id = v_me
     order by created_at desc
     limit greatest(1, least(coalesce(p_limit, 30), 100))
  ) n;

  return jsonb_build_object(
    'ok', true,
    'notifications', v_rows,
    'unread', (select count(*) from notifications where user_id = v_me and read_at is null)
  );
end;
$fn$;

create or replace function public.mark_notifications_read(p_ids uuid[] default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare v_me uuid := auth.uid();
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  update notifications
     set read_at = now()
   where user_id = v_me
     and read_at is null
     and (p_ids is null or id = any (p_ids));

  return jsonb_build_object('ok', true);
end;
$fn$;

-- ---------------------------------------------------------------------------
-- Groups
-- ---------------------------------------------------------------------------

create or replace function public.groups_list(p_query text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me uuid := auth.uid();
  v_q  text := nullif(btrim(coalesce(p_query, '')), '');
  v_rows jsonb;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  select coalesce(jsonb_agg(to_jsonb(g) order by g.name), '[]'::jsonb) into v_rows
  from (
    select gr.id, gr.slug, gr.name, gr.description, gr.region, gr.visibility::text,
           (select count(*) from group_members m where m.group_id = gr.id) as member_count,
           (select m.role::text from group_members m
             where m.group_id = gr.id and m.user_id = v_me) as my_role
      from groups gr
     where gr.status = 'visible'
       and (v_q is null or gr.name ilike '%' || v_q || '%'
            or coalesce(gr.region, '') ilike '%' || v_q || '%')
     order by gr.name
     limit 100
  ) g;

  return jsonb_build_object('ok', true, 'groups', v_rows);
end;
$fn$;

create or replace function public.create_group(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me   uuid := auth.uid();
  v_slug text := lower(btrim(coalesce(p_payload ->> 'slug', '')));
  v_id   uuid;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then
    return jsonb_build_object('ok', false, 'error', 'bad_slug');
  end if;

  if not app.check_rate_limit('group:' || v_me::text, 3, interval '24 hours') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  insert into groups (slug, name, description, region, visibility, created_by)
  values (
    v_slug,
    btrim(coalesce(p_payload ->> 'name', '')),
    nullif(btrim(coalesce(p_payload ->> 'description', '')), ''),
    nullif(btrim(coalesce(p_payload ->> 'region', '')), ''),
    coalesce(nullif(p_payload ->> 'visibility', ''), 'open')::group_visibility,
    v_me
  )
  returning id into v_id;

  -- Whoever made it owns it. There is no group with nobody in charge of it.
  insert into group_members (group_id, user_id, role) values (v_id, v_me, 'owner');

  return jsonb_build_object('ok', true, 'id', v_id, 'slug', v_slug);
exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'slug_taken');
  when invalid_text_representation then
    return jsonb_build_object('ok', false, 'error', 'bad_visibility');
end;
$fn$;

create or replace function public.group_membership(p_group_id uuid, p_join boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me    uuid := auth.uid();
  v_group groups%rowtype;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  select * into v_group from groups where id = p_group_id and status = 'visible';

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if p_join then
    -- Only open groups can be joined from here. The other two need an invite or an approval
    -- flow, and neither exists yet -- so this says so rather than quietly letting anybody in.
    if v_group.visibility <> 'open' then
      return jsonb_build_object('ok', false, 'error', 'not_open');
    end if;

    insert into group_members (group_id, user_id) values (p_group_id, v_me)
    on conflict do nothing;
  else
    -- An owner cannot walk out and leave a group with nobody in charge.
    if exists (select 1 from group_members
                where group_id = p_group_id and user_id = v_me and role = 'owner')
       and (select count(*) from group_members
             where group_id = p_group_id and role = 'owner') = 1 then
      return jsonb_build_object('ok', false, 'error', 'last_owner');
    end if;

    delete from group_members where group_id = p_group_id and user_id = v_me;
  end if;

  return jsonb_build_object('ok', true);
end;
$fn$;

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

create or replace function public.events_upcoming(p_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me   uuid := auth.uid();
  v_rows jsonb;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  select coalesce(jsonb_agg(to_jsonb(e) order by e.starts_at), '[]'::jsonb) into v_rows
  from (
    select ev.id, ev.title, ev.description, ev.starts_at, ev.ends_at, ev.meet_note,
           ev.capacity,
           g.name as group_name, g.slug as group_slug,
           t.name as trail_name, t.slug as trail_slug,
           (select count(*) from event_rsvps r
             where r.event_id = ev.id and r.response = 'going') as going_count,
           (select r.response::text from event_rsvps r
             where r.event_id = ev.id and r.user_id = v_me) as my_response
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

create or replace function public.create_event(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me       uuid := auth.uid();
  v_group    uuid := nullif(p_payload ->> 'group_id', '')::uuid;
  v_trail    uuid := nullif(p_payload ->> 'trail_id', '')::uuid;
  v_starts   timestamptz := nullif(p_payload ->> 'starts_at', '')::timestamptz;
  v_id       uuid;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  if v_starts is null then
    return jsonb_build_object('ok', false, 'error', 'no_start');
  end if;

  -- A group event has to be organised by somebody in the group who organises things.
  if v_group is not null and not exists (
    select 1 from group_members
     where group_id = v_group and user_id = v_me and role in ('organizer', 'owner')
  ) then
    return jsonb_build_object('ok', false, 'error', 'not_an_organizer');
  end if;

  if v_trail is not null and not exists (
    select 1 from trails where id = v_trail and status = 'published'
  ) then
    return jsonb_build_object('ok', false, 'error', 'no_such_trail');
  end if;

  if not app.check_rate_limit('event:' || v_me::text, 10, interval '24 hours') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  insert into events (
    group_id, trail_id, title, description, starts_at, ends_at, meet_note, capacity,
    status, created_by
  ) values (
    v_group, v_trail,
    btrim(coalesce(p_payload ->> 'title', '')),
    nullif(btrim(coalesce(p_payload ->> 'description', '')), ''),
    v_starts,
    nullif(p_payload ->> 'ends_at', '')::timestamptz,
    nullif(btrim(coalesce(p_payload ->> 'meet_note', '')), ''),
    nullif(p_payload ->> 'capacity', '')::integer,
    coalesce(nullif(p_payload ->> 'status', ''), 'draft')::event_status,
    v_me
  )
  returning id into v_id;

  -- Whoever is running it is going to it.
  insert into event_rsvps (event_id, user_id, response) values (v_id, v_me, 'going')
  on conflict do nothing;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$fn$;

create or replace function public.event_rsvp(p_event_id uuid, p_response text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_me       uuid := auth.uid();
  v_response rsvp_response;
  v_event    events%rowtype;
  v_going    integer;
begin
  if v_me is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in');
  end if;

  begin
    v_response := p_response::rsvp_response;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'bad_response');
  end;

  select * into v_event from events where id = p_event_id and status = 'published';

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if v_event.starts_at < now() then
    return jsonb_build_object('ok', false, 'error', 'already_started');
  end if;

  if v_response = 'going' and v_event.capacity is not null then
    select count(*) into v_going
      from event_rsvps
     where event_id = p_event_id and response = 'going' and user_id <> v_me;

    if v_going >= v_event.capacity then
      return jsonb_build_object('ok', false, 'error', 'full');
    end if;
  end if;

  insert into event_rsvps (event_id, user_id, response)
  values (p_event_id, v_me, v_response)
  on conflict (event_id, user_id) do update set response = excluded.response;

  return jsonb_build_object('ok', true);
end;
$fn$;

-- ---------------------------------------------------------------------------
-- Grants. Nothing for anon: all of this is members-only, and the money tables are reachable
-- only by the service role through the Stripe handler that does not exist yet.
-- ---------------------------------------------------------------------------

do $grants$
declare fn text;
begin
  foreach fn in array array[
    'public.my_notifications(integer)',
    'public.mark_notifications_read(uuid[])',
    'public.groups_list(text)',
    'public.create_group(jsonb)',
    'public.group_membership(uuid, boolean)',
    'public.events_upcoming(integer)',
    'public.create_event(jsonb)',
    'public.event_rsvp(uuid, text)'
  ]
  loop
    execute format('revoke all on function %s from public, anon', fn);
    execute format('grant execute on function %s to authenticated', fn);
  end loop;
end
$grants$;
