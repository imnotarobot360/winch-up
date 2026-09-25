-- Winch Up :: recovery SMS back on, but only the part that actually needs a text
--
-- 20260923002000 switched recovery SMS off wholesale because push and in-app had taken over.
-- That was one boolean over every message the app sends, which was right for "off" and is wrong
-- for "on": turning it back on would also restore the requester status updates, the admin pages
-- and the already-covered replies, and those are carried perfectly well by push and the status
-- page. Paying per message to tell somebody something they can already see is waste.
--
-- The one that genuinely needs SMS is the call-out. A volunteer is not looking at the app, may
-- not have installed the PWA -- which on iPhone is the difference between getting a push and not
-- getting one at all -- and the entire product depends on them seeing it within minutes.
--
-- So the switch grows a scope: a master boolean AND an allowlist of template keys.
--
-- AN ALLOWLIST, NOT A BLOCKLIST. A template added later is silent until somebody decides it
-- should cost money and wakes somebody's phone. That is the right default for a list whose
-- entries are "text a real person", and the opposite default would mean a new notification type
-- starts texting everybody the day it ships.

set search_path = public, extensions;

insert into public.app_settings (key, value, description)
values (
  'sms.enabled_templates',
  '["responder.offer", "responder.already_covered"]'::jsonb,
  'Which SMS templates are actually sent when sms.outbound_enabled is on. An allowlist: anything '
  'not named here is suppressed and carried by push and in-app instead. Ships with the dispatch '
  'call-out and its closing reply, because those go to a volunteer who is not looking at the app.'
)
on conflict (key) do update set
  value = excluded.value,
  description = excluded.description;

-- responder.already_covered is in the list with the call-out on purpose. It only fires for
-- volunteers whose call-out was actually sent, and it is the other half of that conversation --
-- somebody who replied to a text and then heard nothing would reasonably drive out anyway.

update public.app_settings
   set value = 'true'::jsonb
 where key = 'sms.outbound_enabled';

-- ---------------------------------------------------------------------------
-- app.queue_sms
--
-- Same signature, same return, one more condition. Callers still do not change.
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
  new_id    uuid;
  v_master  boolean := app.setting_bool('sms.outbound_enabled', false);
  v_allowed boolean;
  v_reason  text;
begin
  if p_to_phone is null then
    return null;
  end if;

  -- Missing setting means an empty allowlist, which means nothing sends. A misconfiguration
  -- should cost a missing text, never a surprise bill and a phone buzzing at 3am.
  select coalesce(
           (select value from public.app_settings where key = 'sms.enabled_templates')
             ? p_template_key,
           false)
    into v_allowed;

  if not v_master then
    v_reason := 'sms.outbound_enabled is off; sent by push and in-app instead';
  elsif not v_allowed then
    v_reason := 'not in sms.enabled_templates; sent by push and in-app instead';
  end if;

  if v_reason is not null then
    -- Unchanged from 20260923002000, and for the same reasons: the row keeps who would have been
    -- told what about which recovery, and none of the contents. The phone goes in redacted and
    -- the params are dropped, because 'responder.assigned' params carry the requester's phone,
    -- their name and the exact pin, and a message that is never sent has no business holding a
    -- durable copy of the most sensitive payload in the system.
    insert into public.sms_messages (
      direction, state, to_phone, template_key, params, locale,
      request_id, responder_id, dispatch_id, error_message
    ) values (
      'outbound', 'suppressed', app.redacted_phone(), p_template_key, '{}'::jsonb,
      case when p_locale in ('en', 'es') then p_locale else 'en' end,
      p_request_id, p_responder_id, p_dispatch_id,
      v_reason
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

comment on function app.queue_sms(text, text, jsonb, text, uuid, uuid, uuid) is
  'The only writer to the SMS outbox. Sends only when sms.outbound_enabled is true AND the '
  'template is named in sms.enabled_templates; otherwise records a suppressed row with the '
  'reason, the phone redacted and the params dropped.';
