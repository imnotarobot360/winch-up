-- Winch Up :: recovery SMS stops at the source, and the outbox stops keeping what it carried
--
-- Section 4 of the group-chat spec: push and in-app become the recovery channel, and recovery SMS
-- is switched off at one place that an admin can flip back without a deploy. Twilio, the outbox,
-- the sender and the inbound webhook all stay exactly where they are. Phone OTP sign-in is a
-- different path entirely (Supabase Auth, never app.queue_sms) and is untouched.
--
-- In practice nothing changes today, because there is no A2P 10DLC registration and not one of
-- these messages has ever been delivered. What changes is that the system stops pretending: it
-- no longer queues thousands of messages that will never leave, and the copy no longer promises
-- a text.
--
-- app.queue_sms is the single writer to the outbox -- every one of the eighteen call sites goes
-- through it -- so the switch belongs here and nowhere else. Putting it in the sender instead
-- would leave the rows piling up in 'queued' forever, which is indistinguishable from a broken
-- drain when somebody comes to look.
--
-- ---------------------------------------------------------------------------------------------
-- TWO PRIVACY FINDINGS, FIXED HERE BECAUSE THIS FILE IS WHY I FOUND THEM
--
-- Suppressing a message means deciding what a never-sent message may keep. Answering that meant
-- reading what a SENT one keeps, and the answer was more than it should be. Both of these are
-- pre-existing and neither is caused by this change:
--
-- 1. app.scrub_request redacted sms_messages.to_phone and body, and left params alone. The
--    'responder.assigned' params object holds requester_phone, requester_name and the exact
--    lat/lng to five decimal places. So after an account deletion or a retention expiry -- the
--    two moments the product promises the pin is destroyed -- the phone, the name and the
--    coordinates were still sitting in the outbox. Confirmed by scrubbing a request and reading
--    the row back: to_phone became +10000000000 and params still read +1512555xxxx, 30.12345.
--
-- 2. app.scrub_responder never touched sms_messages at all. A volunteer who deletes their account
--    left their phone number in to_phone on every offer they were ever texted. It was cleaned
--    only if the REQUESTER of that recovery also deleted, or the recovery aged past retention --
--    which is somebody else's decision about somebody else's data.
--
-- CLAUDE.md already says anything storing a phone, a name or a position belongs in both scrub
-- functions and in security_test.sql. These predate that line; they are in it now.
-- ---------------------------------------------------------------------------------------------

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- The switch
-- ---------------------------------------------------------------------------

-- Default false. A setting that arrives on and has to be turned off gets one deploy where it is
-- on, and this one's on-state texts real people.
insert into app_settings (key, value, description)
values (
  'sms.outbound_enabled',
  'false'::jsonb,
  'Whether recovery SMS is actually sent. Off: app.queue_sms records each message as suppressed '
  'with no phone and no payload, and the drain never sees it. Push and in-app notifications are '
  'unaffected, and so is phone OTP sign-in, which does not use this outbox. Turn on only once '
  'A2P 10DLC registration is approved -- before that Twilio rejects the traffic anyway.'
)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- app.queue_sms
--
-- Same signature, same return, one new branch. Callers do not change.
-- ---------------------------------------------------------------------------

create or replace function app.queue_sms(
  p_to_phone     text,
  p_template_key text,
  p_params       jsonb default '{}'::jsonb,
  p_locale       text default 'en',
  p_request_id   uuid default null,
  p_responder_id uuid default null,
  p_dispatch_id  uuid default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  new_id  uuid;
  v_send  boolean := app.setting_bool('sms.outbound_enabled', false);
begin
  if p_to_phone is null then
    return null;
  end if;

  if not v_send then
    -- What a suppressed row keeps is deliberate. It keeps enough to answer "who would have been
    -- told what, about which recovery" -- the template key, the three foreign keys, the language
    -- -- and none of the contents. The phone goes in redacted and the params are dropped, because
    -- 'responder.assigned' params carry the requester's phone, name and exact pin, and a message
    -- that is never sent has no business holding a durable copy of the most sensitive payload in
    -- the system. An audit trail that accumulates phone numbers is not a privacy improvement.
    insert into public.sms_messages (
      direction, state, to_phone, template_key, params, locale,
      request_id, responder_id, dispatch_id, error_message
    ) values (
      'outbound', 'suppressed', app.redacted_phone(), p_template_key, '{}'::jsonb,
      case when p_locale in ('en', 'es') then p_locale else 'en' end,
      p_request_id, p_responder_id, p_dispatch_id,
      'sms.outbound_enabled is off; sent by push and in-app instead'
    )
    returning id into new_id;

    return new_id;
  end if;

  insert into public.sms_messages (
    direction, state, to_phone, template_key, params, locale,
    request_id, responder_id, dispatch_id
  ) values (
    'outbound', 'queued', p_to_phone, p_template_key, coalesce(p_params, '{}'::jsonb),
    case when p_locale in ('en', 'es') then p_locale else 'en' end,
    p_request_id, p_responder_id, p_dispatch_id
  )
  returning id into new_id;

  return new_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Finding 1: the scrub reaches params
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

  -- The outbox holds the number it texted, the body it rendered, AND the params it rendered that
  -- body from. Dropping params wholesale rather than picking keys out of it: the set of keys
  -- that carry something identifying is the set of keys, and a new template that adds one would
  -- otherwise quietly survive the scrub. template_key stays, so the history is still readable as
  -- "we texted the assigned volunteer" without saying what.
  update sms_messages
     set to_phone = app.redacted_phone(),
         body     = null,
         params   = '{}'::jsonb
   where request_id = p_request_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Finding 2: a volunteer's own number leaves with them
-- ---------------------------------------------------------------------------

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

  -- Every message ever addressed to them. Until now this was reached only when the REQUESTER of
  -- that recovery deleted their own account or the recovery aged past retention -- so whether a
  -- volunteer's phone number survived their own deletion depended on somebody else's decision.
  -- params too, for the same reason as above: 'requester.accepted' carries their first name.
  update sms_messages
     set to_phone = app.redacted_phone(),
         body     = null,
         params   = '{}'::jsonb
   where responder_id = p_responder_id;
end;
$$;

comment on function app.queue_sms(text, text, jsonb, text, uuid, uuid, uuid) is
  'The only writer to the outbox. Honours sms.outbound_enabled: when off, records the message as '
  'suppressed with no phone and no payload rather than queueing it.';
