-- A recovery call-out reaches a volunteer's phone, not only the app.
--
-- app.notify_on_request_event sent the volunteer's call-out with array['in_app'] -- so the one
-- notification this product exists to deliver was the only one that never buzzed a handset, while
-- chat messages (20260923001700), helper status changes (20260923001400) and direct messages
-- (20261001002300) have all pushed since September. Somebody got a phone alert for a chat reply and
-- silence for a rig stuck two miles away.
--
-- It mattered on 2026-10-05. SMS was dead -- Twilio refusing the account's auth token -- and email
-- was the only channel that landed. Push was built, deployed, subscribed and idle. The owner's spec
-- that morning asked for "a COMBINATION of all notification channels available for each member";
-- this is the missing third.
--
-- Also adds the distance to the payload, because "somebody near you needs a hand" does not tell a
-- volunteer whether to put boots on. What is deliberately NOT added is the vehicle and the
-- situation: src/lib/push/send.ts's own rule is that a push payload stays thin because a lock
-- screen is readable by anyone standing nearby, and widening that is the owner's call, not a
-- side effect of a notification fix.
--
-- Body read out of the live database, not reconstructed from these files.

set search_path = public, extensions;

CREATE OR REPLACE FUNCTION app.notify_on_request_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
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
        -- A SEPARATE KEY FOR THE CALL-OUT, so that enriching the copy cannot break what is already
        -- in the inbox. The in-app list renders title_key through next-intl WITH the stored params,
        -- and next-intl throws on a missing interpolation value -- so pointing the old key at copy
        -- that needs {miles} would break the notification bell for every call-out written before
        -- today, which includes the owner's. Old rows keep the old key and the old words; only new
        -- ones carry a distance. The renderer already falls back to the kind for a key it does not
        -- know, so a database ahead of a deploy degrades to "Recovery request" rather than breaking.
        case when new.event_type = 'responder_notified'
             then 'notify.responder.responder_notified_near'
             else 'notify.responder.' || new.event_type::text end,
        -- Enough for a volunteer to decide, and nothing more. The distance is already public on
        -- /board, rounded. The exact pin and the requester's phone are NOT here and must never be:
        -- a push is rendered on a lock screen anybody standing nearby can read, which is why the
        -- payload in src/lib/push/send.ts is deliberately thin.
        jsonb_build_object(
          'short_code', v_request.short_code,
          -- Kept as a JSON number, not ->> text: numeric 2.80 renders as "2.80" through ->> and as
          -- 2.8 through the JSON number, and the second is what belongs on a lock screen.
          'miles',      new.data -> 'miles'
        ),
        '/me',
        -- PUSH, not in-app alone.
        --
        -- Being told a rig is stuck two miles away is the most urgent thing this app sends, and it
        -- was the ONLY notification that never buzzed a phone -- chat messages, helper status
        -- changes and direct messages have all had push since September. A volunteer is by
        -- definition not looking at the app, which is the entire premise of alerting them.
        --
        -- A thank-you stays in-app on purpose. Push is a tap on the shoulder, and spending one on
        -- "somebody said thanks" is how a person turns notifications off for good -- taking the
        -- call-outs with them.
        --
        -- Consent and de-duplication are app.notify's job and were already right, which is why
        -- this is a one-word change rather than a subsystem: it gates the 'recovery_request' kind
        -- on profiles.notify_recovery PER CHANNEL, records a refusal as 'suppressed' with a reason
        -- instead of dropping it, and keys dedupe on (dedupe_key, channel). That last part is
        -- already the spec's "each channel only once per wave" -- the key below carries the request
        -- and the responder, and app.candidates() cannot offer the same recovery to the same
        -- person twice, so a helper belongs to exactly one wave.
        case when new.event_type = 'responder_notified'
             then array['in_app', 'push']::notification_channel[]
             else array['in_app']::notification_channel[] end,
        'resp:' || new.request_id::text || ':' || v_responder.id::text
          || ':' || new.event_type::text
      );
    end if;
  end if;

  return null;
end;
$function$;

select
  -- The call-out pushes.
  strpos(pg_get_functiondef('app.notify_on_request_event()'::regprocedure),
         'array[''in_app'', ''push'']') > 0                        as callout_pushes,
  -- And a thank-you still does not, which is the half a blunt change would have got wrong.
  strpos(pg_get_functiondef('app.notify_on_request_event()'::regprocedure),
         'responder_notified''
             then array') > 0                                      as only_the_callout,
  -- The distance reaches the copy.
  strpos(pg_get_functiondef('app.notify_on_request_event()'::regprocedure),
         'new.data -> ''miles''') > 0                              as carries_distance,
  -- What must NOT have appeared. A push payload naming the pin or the phone is the one change in
  -- this area that cannot be walked back once it is on somebody's lock screen.
  strpos(pg_get_functiondef('app.notify_on_request_event()'::regprocedure),
         'requester_phone') = 0                                    as no_phone_in_payload,
  strpos(pg_get_functiondef('app.notify_on_request_event()'::regprocedure),
         'v_request.location') = 0                                 as no_pin_in_payload;
