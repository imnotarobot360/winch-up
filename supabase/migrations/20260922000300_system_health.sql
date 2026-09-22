-- Winch Up :: know whether the dispatch tick is alive
--
-- Phase 11 asks for system health, Phase 13 for delivery logging. Both come back to one
-- question an admin cannot currently answer: is anything still running?
--
-- If pg_cron stops, or the Edge Function's secret rotates, or Supabase pauses the project,
-- dispatch dies silently. No request escalates, no volunteer is texted, and the admin dashboard
-- looks completely normal -- because an idle system and a dead one produce identical output. The
-- first sign would be somebody sitting in a ditch wondering why nobody came.
--
-- A heartbeat written on every tick, before any work, makes the difference visible.

set search_path = public, extensions;

create table if not exists system_heartbeats (
  key     text primary key,
  beat_at timestamptz not null default now()
);

alter table system_heartbeats enable row level security;
revoke all on system_heartbeats from anon, authenticated;

comment on table system_heartbeats is
  'Liveness, not config. Written by advance_dispatch() on every run so an admin can tell a quiet '
  'afternoon from a scheduler that stopped. No grants: read through admin_system_health().';

create or replace function public.advance_dispatch(p_limit integer default 50)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  target  uuid;
  results jsonb := '[]'::jsonb;
  outcome jsonb;
  seen    integer := 0;
begin
  -- Heartbeat first, before any work and regardless of whether there is any.
  --
  -- This is the only way to tell "nothing to dispatch" from "the scheduler stopped". Without it
  -- a dead pg_cron job looks exactly like a quiet afternoon: no requests move, no texts go out,
  -- and the dashboard shows nothing wrong because nothing wrong is visible from the inside.
  insert into public.system_heartbeats (key, beat_at)
  values ('dispatch_tick', clock_timestamp())
  on conflict (key) do update set beat_at = excluded.beat_at;

  for target in
    select id from public.requests
     where status in ('submitted', 'dispatching', 'unmatched')
       and next_action_at is not null
       and next_action_at <= now()
     order by next_action_at
     limit greatest(1, least(coalesce(p_limit, 50), 200))
     for update skip locked
  loop
    outcome := app.advance_one(target);
    results := results || jsonb_build_array(jsonb_build_object('request_id', target) || outcome);
    seen := seen + 1;
  end loop;

  return jsonb_build_object('processed', seen, 'results', results);
end;
$$;

-- ---------------------------------------------------------------------------
-- What an admin needs to know at a glance when something feels wrong
-- ---------------------------------------------------------------------------

create or replace function public.admin_system_health()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_last_tick timestamptz;
begin
  perform app.require_admin();

  select beat_at into v_last_tick from system_heartbeats where key = 'dispatch_tick';

  return jsonb_build_object(
    'ok', true,
    'dispatch', jsonb_build_object(
      'last_tick_at', v_last_tick,
      'seconds_since_tick',
        case when v_last_tick is null then null
             else extract(epoch from (now() - v_last_tick))::integer end,
      -- The tick runs every 60s. Three misses is the point at which this is a problem rather
      -- than a slow minute.
      'stalled', v_last_tick is null or v_last_tick < now() - interval '3 minutes'
    ),
    'sms', jsonb_build_object(
      'queued', (select count(*) from sms_messages
                  where direction = 'outbound' and state = 'queued'),
      'failed', (select count(*) from sms_messages where state = 'failed'),
      'sent_24h', (select count(*) from sms_messages
                    where state = 'sent' and sent_at > now() - interval '24 hours'),
      -- Queued, retried to the cap, and still sitting there. These are the ones nobody received.
      'exhausted', (select count(*) from sms_messages
                     where direction = 'outbound' and state = 'queued' and attempts >= 4)
    ),
    -- The dead letters themselves, with enough to act on and no message bodies: an admin
    -- debugging a delivery problem does not need to read what a requester wrote.
    'recent_failures', coalesce((
      select jsonb_agg(to_jsonb(f) order by f.created_at desc)
        from (
          select m.template_key, m.locale, m.attempts, m.error_message, m.created_at,
                 r.short_code
            from sms_messages m
            left join requests r on r.id = m.request_id
           where m.state = 'failed'
           order by m.created_at desc
           limit 20
        ) f
    ), '[]'::jsonb),
    'requests', jsonb_build_object(
      'open', (select count(*) from requests
                where status in ('submitted', 'dispatching', 'unmatched')),
      -- Dispatching for a while with nobody contacted at all. Usually means no volunteer
      -- matches, which is worth knowing before the requester works it out themselves.
      'dispatching_with_no_contact', (select count(*) from requests q
                                       where q.status = 'dispatching'
                                         and q.dispatch_started_at < now() - interval '10 minutes'
                                         and not exists (select 1 from dispatches d
                                                          where d.request_id = q.id))
    ),
    'volunteers', jsonb_build_object(
      'approved_active', (select count(*) from responders
                           where approval = 'approved' and availability = 'active'),
      'pending', (select count(*) from responders where approval = 'pending'),
      -- The number that decides whether any of this works at all.
      'reachable', (select count(*) from responders r
                     where r.approval = 'approved'
                       and r.availability = 'active'
                       and r.sms_opt_in
                       and r.sms_opt_out_at is null
                       and coalesce((select p.notify_recovery from profiles p
                                      where p.user_id = r.user_id), true))
    )
  );
end;
$$;

revoke execute on function public.admin_system_health() from public, anon;
grant execute on function public.admin_system_health() to authenticated, service_role;
