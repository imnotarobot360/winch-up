-- Winch Up :: notifications
--
-- Phase 13. The tables went in with Phase 12; this is what fills them and what empties them.
--
-- THE PRODUCERS ARE TRIGGERS, NOT CALLS ADDED TO EXISTING FUNCTIONS.
--
-- Every event this phase needs to notify about is already written down somewhere: the dispatch
-- state machine writes request_events for every transition, request_messages holds the thread,
-- community_comments holds replies. Putting the notification calls inside those functions would
-- mean editing advance_dispatch -- seventy-eight assertions of proven behaviour -- to add
-- something that is not dispatch's job. Triggers get the same result and leave the state machine
-- exactly as it is, and anything that writes those rows in future gets notifications for free.
--
-- WHAT IS ACTUALLY DELIVERABLE TODAY, stated plainly rather than implied:
--
--   in_app   works. It is the notification itself.
--   sms      works only where a template exists. The dispatch path already texts people about
--            recoveries through the outbox in app.queue_sms, and this does not duplicate that --
--            it would be a second text about the same thing. A notification may opt into SMS by
--            carrying an `sms_template` param; without one the delivery is suppressed with a
--            reason rather than silently dropped.
--   email    not built. Supabase SMTP sends auth mail; nothing here sends application mail.
--   push     not built. No service worker push, no VAPID keys, no mobile app.
--
-- The enum carries all four because the delivery log should be able to say "we did not send
-- this, and here is why". A channel that cannot be recorded cannot be audited.
--
-- RETRY AND FALLBACK. Deliveries get attempts and a next attempt time, backed off 1, 5 and 25
-- minutes, then failed for good. The fallback for a failed channel is the in_app notification,
-- which was written first and does not depend on anything: a volunteer whose text did not go
-- through still sees it when they open the app. That is a real fallback rather than a chain of
-- channels that are all equally unbuilt.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- Retry scheduling
-- ---------------------------------------------------------------------------

alter table notification_deliveries
  add column if not exists next_attempt_at timestamptz not null default now();

drop index if exists notification_deliveries_pending_idx;

create index notification_deliveries_pending_idx
  on notification_deliveries (next_attempt_at)
  where state in ('queued', 'failed');

comment on column notification_deliveries.next_attempt_at is
  'When the drain may next pick this up. Backed off 1, 5 then 25 minutes; after three attempts '
  'it stays failed and the in_app notification is the fallback.';

-- ---------------------------------------------------------------------------
-- Producers
--
-- One trigger per source table. Each one is deliberately quiet about anything the person did
-- themselves -- nobody needs telling that they replied to their own post.
-- ---------------------------------------------------------------------------

-- A recovery moved. The dispatch state machine writes one of these for every transition, so this
-- covers "new recovery request alerts", "volunteer acceptance", and "recovery status updates"
-- without dispatch knowing that notifications exist.
create or replace function app.notify_on_request_event()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_request     public.requests%rowtype;
  v_responder   public.responders%rowtype;
  v_kind        notification_kind;
  v_url         text;
begin
  select * into v_request from public.requests where id = new.request_id;
  if not found then
    return null;
  end if;

  v_url := '/r/' || v_request.public_token;

  -- Which of the requester's notifications this is. Anything not listed is an internal
  -- transition the person who is stuck does not need telling about.
  v_kind := case new.event_type
              when 'accepted'  then 'recovery_accepted'::notification_kind
              when 'on_site'   then 'recovery_status'::notification_kind
              when 'recovered' then 'recovery_status'::notification_kind
              when 'cancelled' then 'recovery_status'::notification_kind
              when 'expired'   then 'recovery_status'::notification_kind
              when 'unmatched' then 'recovery_status'::notification_kind
              when 'reassigned' then 'recovery_status'::notification_kind
              else null
            end;

  if v_kind is not null and v_request.requester_user_id is not null then
    perform app.notify(
      v_request.requester_user_id,
      v_kind,
      'notify.request.' || new.event_type::text,
      jsonb_build_object('short_code', v_request.short_code),
      v_url,
      array['in_app']::notification_channel[],
      -- One per request per transition. A tick that re-runs does not notify twice.
      'req:' || new.request_id::text || ':' || new.event_type::text
    );
  end if;

  -- The volunteer's side. Being told about a job, and being thanked for one.
  if new.event_type in ('responder_notified', 'thanked') and new.actor_responder_id is not null
  then
    select * into v_responder from public.responders where id = new.actor_responder_id;

    if found and v_responder.user_id is not null then
      perform app.notify(
        v_responder.user_id,
        case when new.event_type = 'thanked' then 'recovery_status'::notification_kind
             else 'recovery_request'::notification_kind end,
        'notify.responder.' || new.event_type::text,
        jsonb_build_object('short_code', v_request.short_code),
        '/me',
        array['in_app']::notification_channel[],
        'resp:' || new.request_id::text || ':' || v_responder.id::text
          || ':' || new.event_type::text
      );
    end if;
  end if;

  return null;
end;
$$;

create trigger request_events_notify
  after insert on request_events
  for each row execute function app.notify_on_request_event();

-- A message on a recovery. Two participants, so the recipient is whichever one did not send it.
create or replace function app.notify_on_request_message()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_request   public.requests%rowtype;
  v_responder public.responders%rowtype;
  v_target    uuid;
begin
  select * into v_request from public.requests where id = new.request_id;
  if not found then
    return null;
  end if;

  select * into v_responder from public.responders where id = v_request.accepted_responder_id;

  v_target := case
                when new.sender_user_id is distinct from v_request.requester_user_id
                  then v_request.requester_user_id
                else v_responder.user_id
              end;

  if v_target is not null and v_target is distinct from new.sender_user_id then
    perform app.notify(
      v_target,
      'message',
      'notify.message.new',
      jsonb_build_object('short_code', v_request.short_code),
      '/r/' || v_request.public_token,
      array['in_app']::notification_channel[],
      'msg:' || new.id::text
    );
  end if;

  return null;
end;
$$;

create trigger request_messages_notify
  after insert on request_messages
  for each row execute function app.notify_on_request_message();

-- Somebody replied to your post. Not sent to you for your own reply, and not sent at all if
-- either of you has blocked the other -- a notification is a way for a blocked person to keep
-- reaching somebody, and blocking has to close that door too.
create or replace function app.notify_on_community_comment()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare v_author uuid;
begin
  select author_user_id into v_author from public.community_posts
   where id = new.post_id and status = 'visible';

  if v_author is null
     or v_author = new.author_user_id
     or app.blocks_between(v_author, new.author_user_id) then
    return null;
  end if;

  perform app.notify(
    v_author, 'community', 'notify.community.reply',
    '{}'::jsonb, '/community',
    array['in_app']::notification_channel[],
    'comment:' || new.id::text
  );

  return null;
end;
$$;

create trigger community_comments_notify
  after insert on community_comments
  for each row execute function app.notify_on_community_comment();

-- The outcome of a safety report goes to whoever filed it, and to nobody else. The subject of a
-- report must never learn that one exists, which is why this reads reporter_user_id and never
-- subject_user_id.
create or replace function app.notify_on_incident_review()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if new.status = old.status or new.reporter_user_id is null then
    return null;
  end if;

  if new.status not in ('actioned', 'dismissed') then
    return null;
  end if;

  perform app.notify(
    new.reporter_user_id, 'safety', 'notify.safety.reviewed',
    jsonb_build_object('status', new.status::text), null,
    array['in_app']::notification_channel[],
    'incident:' || new.id::text || ':' || new.status::text
  );

  return null;
end;
$$;

create trigger safety_incidents_notify
  after update on safety_incidents
  for each row execute function app.notify_on_incident_review();

-- ---------------------------------------------------------------------------
-- Event reminders
--
-- Called from the drain. Anybody who said they were going to something starting in the next
-- day gets told once -- the dedupe key is the event and the person, so running this every
-- minute for a day sends exactly one.
-- ---------------------------------------------------------------------------

create or replace function app.send_event_reminders()
returns integer
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_row   record;
  v_count integer := 0;
begin
  for v_row in
    select e.id, e.title, e.starts_at, r.user_id
      from public.events e
      join public.event_rsvps r on r.event_id = e.id and r.response = 'going'
     where e.status = 'published'
       and e.starts_at between now() and now() + interval '24 hours'
  loop
    perform app.notify(
      v_row.user_id, 'event_reminder', 'notify.event.soon',
      jsonb_build_object('title', v_row.title, 'starts_at', v_row.starts_at),
      '/community',
      array['in_app']::notification_channel[],
      'event:' || v_row.id::text || ':' || v_row.user_id::text || ':24h'
    );
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- The drain
--
-- Runs beside the SMS outbox on the same schedule. Takes whatever is due, tries it, and either
-- marks it delivered or backs it off.
-- ---------------------------------------------------------------------------

create or replace function public.drain_notifications(p_limit integer default 100)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_row       record;
  v_delivered integer := 0;
  v_queued    integer := 0;
  v_failed    integer := 0;
  v_skipped   integer := 0;
  v_phone     text;
  v_template  text;
  v_reminders integer;
begin
  v_reminders := app.send_event_reminders();

  for v_row in
    select d.id, d.channel, d.attempts, n.user_id, n.kind, n.title_key, n.params
      from notification_deliveries d
      join notifications n on n.id = d.notification_id
     where d.state in ('queued', 'failed')
       and d.attempts < 3
       and d.next_attempt_at <= now()
     order by
       -- The priority the spec asks for, expressed where it actually matters: what gets sent
       -- first when there is a backlog. Somebody stuck outranks somebody's reply.
       case n.kind
         when 'recovery_request'  then 0
         when 'recovery_offer'    then 0
         when 'recovery_accepted' then 0
         when 'recovery_status'   then 1
         when 'safety'            then 1
         when 'message'           then 2
         when 'event_reminder'    then 3
         when 'community'         then 4
         else 5
       end,
       d.created_at
     limit greatest(1, least(coalesce(p_limit, 100), 500))
    for update of d skip locked
  loop
    if v_row.channel = 'in_app' then
      -- Already visible the moment the notification row was written. Nothing to send.
      update notification_deliveries
         set state = 'delivered', attempts = attempts + 1, updated_at = now()
       where id = v_row.id;
      v_delivered := v_delivered + 1;

    elsif v_row.channel = 'sms' then
      v_template := v_row.params ->> 'sms_template';
      select phone into v_phone from auth.users where id = v_row.user_id;

      if v_template is null then
        -- Deliberate, and recorded. Recovery texts go through the dispatch outbox; a second
        -- path would text somebody twice about the same thing.
        update notification_deliveries
           set state = 'suppressed', attempts = attempts + 1,
               last_error = 'no sms template on this notification', updated_at = now()
         where id = v_row.id;
        v_skipped := v_skipped + 1;

      elsif v_phone is null then
        update notification_deliveries
           set state = 'suppressed', attempts = attempts + 1,
               last_error = 'no phone number on the account', updated_at = now()
         where id = v_row.id;
        v_skipped := v_skipped + 1;

      else
        perform app.queue_sms(v_phone, v_template, v_row.params, 'en');
        update notification_deliveries
           set state = 'sent', attempts = attempts + 1, updated_at = now()
         where id = v_row.id;
        v_queued := v_queued + 1;
      end if;

    else
      -- email and push. The enum carries them so the log can say we did not send, and why,
      -- rather than the request vanishing.
      update notification_deliveries
         set state = 'suppressed', attempts = attempts + 1,
             last_error = v_row.channel::text || ' delivery is not built yet',
             updated_at = now()
       where id = v_row.id;
      v_skipped := v_skipped + 1;
    end if;
  end loop;

  -- Anything that has burned its three attempts stops being retried. The in_app notification is
  -- still there, which is the fallback.
  update notification_deliveries
     set state = 'failed', updated_at = now()
   where state = 'queued' and attempts >= 3;

  get diagnostics v_failed = row_count;

  return jsonb_build_object(
    'ok', true,
    'delivered', v_delivered,
    'queued_sms', v_queued,
    'suppressed', v_skipped,
    'gave_up', v_failed,
    'event_reminders', v_reminders
  );
end;
$$;

-- Back off a failed attempt rather than hammering it. Called by whatever sender fails.
create or replace function app.defer_delivery(p_id uuid, p_error text)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
begin
  update notification_deliveries
     set state = 'queued',
         attempts = attempts + 1,
         last_error = left(coalesce(p_error, ''), 500),
         -- One minute, then five, then twenty-five.
         next_attempt_at = now() + (interval '1 minute' * power(5, least(attempts, 2))),
         updated_at = now()
   where id = p_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
--
-- drain_notifications is service-role only: it is called by the scheduled job that already
-- drains the SMS outbox, on the same secret.
-- ---------------------------------------------------------------------------

revoke all on function public.drain_notifications(integer) from public, anon, authenticated;
