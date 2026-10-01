-- Winch Up :: app.notify learns what a direct message is
--
-- Rebuilt from the LIVE definition out of pg_proc, not from 20260923001700 -- this function has been
-- redefined more than once and taking the oldest file as the base would revert the rest.
--
-- One branch added. Nothing else changed.

set search_path = public, extensions;
CREATE OR REPLACE FUNCTION app.notify(p_user_id uuid, p_kind notification_kind, p_title_key text, p_params jsonb DEFAULT '{}'::jsonb, p_url text DEFAULT NULL::text, p_channels notification_channel[] DEFAULT ARRAY['in_app'::notification_channel], p_dedupe text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
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
      when p_kind = 'marketing' then coalesce(v_profile.notify_marketing, false)
      when p_kind = 'community' or p_kind = 'event_reminder'
        then coalesce(v_profile.notify_community, true)
      -- The in-app record is always written. It is what happened; the switches govern whether a
      -- phone buzzes about it.
      when v_channel = 'in_app' then true
      -- Chatter in a RECOVERY.
      when p_kind = 'message' then coalesce(v_profile.notify_chat, true)
      -- A DIRECT MESSAGE, which is a different switch on purpose. Recovery chatter is operational --
      -- "which gate are you at" from the volunteer driving toward you -- and a direct message is
      -- social. Somebody who wants fewer of the second must not thereby silence the first, which is
      -- what sharing notify_chat between them would have done.
      --
      -- Added 20261001002200. Note what the else below does with an unmapped kind: it falls through to
      -- notify_recovery, so adding the enum label without touching this function would have governed
      -- direct messages by the RECOVERY preference. That is the quiet half of adding a notification
      -- kind, and it is why this file rebuilds a function it otherwise has no business in.
      when p_kind = 'direct_message'
        then coalesce(v_profile.notify_direct_messages, true)
      -- The recovery itself moving: somebody joined, arrived, withdrew, it was cancelled.
      when p_kind in ('recovery_status', 'helper_joined', 'helper_status')
        then coalesce(v_profile.notify_recovery_status, true)
      else coalesce(v_profile.notify_recovery, true)
    end;

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
$function$;
