-- Winch Up :: a recovery is a team, not a person
--
-- Until now a recovery had exactly one helper: requests.accepted_responder_id, referenced 66
-- times across 27 files, and "a double accept must be impossible" enforced by a row lock.
--
-- Real recoveries are not like that. A winch truck and a tractor turn up together, and the app
-- had nowhere to put the second one -- so they coordinated in a Facebook comment thread, which is
-- the thing this product exists to replace.
--
-- WHY accepted_responder_id SURVIVES
--
-- It becomes "the first helper still on the team", maintained by trigger. Owner's decision, and
-- the right one: 66 references keep working, get_job_contact still has one person to hand the
-- requester's number to, and the SMS handoff still has somebody to name. The row lock still makes
-- a double LEAD impossible. What changes is that a second acceptance no longer collides with the
-- first -- it joins.
--
-- The dual source of truth is real and worth naming. recovery_participants is authoritative;
-- accepted_responder_id is derived and must never be written by hand again. The trigger below is
-- the only thing that sets it.
--
-- THE RULE THAT MATTERS MOST
--
-- A helper who withdraws keeps their history and loses the future. Every access check reads
-- `left_at is null`, not merely "has a row" -- somebody who walked away at 11pm must not keep
-- receiving a stranded driver's messages and position, and must not lose the record of what was
-- said while they were helping.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------
--
-- Created here rather than in the enum file on purpose: a NEW type can be created and used in the
-- same transaction. Only ALTER TYPE ADD VALUE cannot, which is why that file is separate.

do $do$
begin
  if not exists (select 1 from pg_type where typname = 'participant_role') then
    create type participant_role as enum ('requester', 'helper');
  end if;
end
$do$;

-- The spec's list, in the order a recovery actually moves through. 'accepted' is where somebody
-- starts; it deliberately does NOT mean they have set off, which is the distinction section 4
-- asks for -- accepting an offer is not arriving.
do $do$
begin
  if not exists (select 1 from pg_type where typname = 'participant_status') then
    create type participant_status as enum (
      'accepted', 'preparing', 'en_route', 'on_site', 'assisting', 'finished', 'withdrawn'
    );
  end if;
end
$do$;

-- ---------------------------------------------------------------------------
-- The team
-- ---------------------------------------------------------------------------

create table if not exists public.recovery_participants (
  id           uuid primary key default gen_random_uuid(),
  request_id   uuid not null references public.requests (id) on delete cascade,

  -- Nullable for the same reason request_messages.sender_user_id is: deleting an account must not
  -- delete the recovery the other people were part of. role survives and is what renders.
  user_id      uuid references auth.users (id) on delete set null,

  -- The responders row, when they have one. A requester may not: filing a request never needed a
  -- recovery profile. Helpers always do -- offer_assistance creates it.
  responder_id uuid references public.responders (id) on delete set null,

  role         participant_role   not null,
  status       participant_status not null default 'accepted',

  joined_at    timestamptz not null default now(),
  -- The single thing every access check reads. Set, never deleted: the row is the history.
  left_at      timestamptz,
  status_at    timestamptz not null default now(),

  -- Per-recovery mute (spec section 7). Separate from the account-level preference because
  -- "stop pinging me about THIS one" is a different request from "stop pinging me".
  muted        boolean not null default false,

  -- Where their unread count starts from. Cheaper and more honest than a read receipt per
  -- message: it answers "what have I not seen" without storing a row per person per message.
  last_read_at timestamptz,

  created_at   timestamptz not null default now()
);

-- One row per person per recovery. A helper who withdraws and is re-accepted reuses their row,
-- which is what keeps their history attached to them.
create unique index if not exists recovery_participants_one_per_person
  on public.recovery_participants (request_id, user_id)
  where user_id is not null;

create index if not exists recovery_participants_request_idx
  on public.recovery_participants (request_id) where left_at is null;
create index if not exists recovery_participants_user_idx
  on public.recovery_participants (user_id) where left_at is null;
create index if not exists recovery_participants_responder_idx
  on public.recovery_participants (responder_id);

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
--
-- Every new table in this repo is born leaky, so the policy ships in the same file as the table.
-- A participant may see who else is on their own recovery -- that is the Recovery Team panel --
-- and nothing about any other recovery.
--
-- Writes go through RPCs. There is no insert or update policy at all, which is what stops
-- somebody adding themselves to a conversation by guessing a request id (spec section 9).

alter table public.recovery_participants enable row level security;

revoke all on public.recovery_participants from public, anon, authenticated;
grant select on public.recovery_participants to authenticated;

drop policy if exists recovery_participants_read_own_team on public.recovery_participants;
create policy recovery_participants_read_own_team on public.recovery_participants
  for select to authenticated
  using (
    exists (
      select 1 from public.recovery_participants me
       where me.request_id = recovery_participants.request_id
         and me.user_id = auth.uid()
         and me.left_at is null
    )
  );

-- ---------------------------------------------------------------------------
-- The lead, kept in step
-- ---------------------------------------------------------------------------
--
-- accepted_responder_id becomes derived: the earliest-joined helper who has not left. Nothing
-- else may write it.
--
-- When the last helper withdraws it goes back to null and the request returns to 'unmatched',
-- which is truthful -- nobody is coming -- and puts the request back in front of other members on
-- /help rather than leaving a stranded driver on a page that says somebody is on the way.

create or replace function app.sync_recovery_lead(p_request_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
as $fn$
declare
  v_lead uuid;
  v_req  public.requests%rowtype;
begin
  select p.responder_id into v_lead
    from public.recovery_participants p
   where p.request_id = p_request_id
     and p.role = 'helper'
     and p.left_at is null
     and p.responder_id is not null
   order by p.joined_at, p.created_at
   limit 1;

  select * into v_req from public.requests where id = p_request_id for update;
  if not found then
    return;
  end if;

  if v_lead is not null then
    update public.requests
       set accepted_responder_id = v_lead,
           accepted_at = coalesce(accepted_at, now()),
           status = case when status in ('submitted', 'dispatching', 'unmatched')
                         then 'accepted' else status end
     where id = p_request_id;

  -- Everybody left. Only rewind a request that is still live: a recovery already marked recovered
  -- or cancelled keeps its record of who was there.
  elsif v_req.status in ('accepted', 'on_site') then
    update public.requests
       set accepted_responder_id = null,
           accepted_at           = null,
           eta_minutes           = null,
           status                = 'unmatched',
           unmatched_at          = coalesce(unmatched_at, now())
     where id = p_request_id;
  end if;
end;
$fn$;

revoke all on function app.sync_recovery_lead(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Backfill
-- ---------------------------------------------------------------------------
--
-- Every existing recovery becomes a team of the people it already had: the requester, and the one
-- accepted helper if there was one. Without this, every recovery that predates this migration has
-- an empty team and its participants lose access to their own conversation.

insert into public.recovery_participants (request_id, user_id, responder_id, role, status, joined_at)
select r.id, r.requester_user_id, null, 'requester',
       case when r.status in ('recovered') then 'finished'
            when r.status in ('cancelled', 'expired') then 'withdrawn'
            else 'accepted' end::participant_status,
       r.created_at
  from public.requests r
 where r.requester_user_id is not null
on conflict do nothing;

insert into public.recovery_participants (request_id, user_id, responder_id, role, status, joined_at)
select r.id, resp.user_id, resp.id, 'helper',
       case when r.status = 'recovered' then 'finished'
            when r.status = 'on_site'   then 'on_site'
            when r.status in ('cancelled', 'expired') then 'withdrawn'
            else 'accepted' end::participant_status,
       coalesce(r.accepted_at, r.created_at)
  from public.requests r
  join public.responders resp on resp.id = r.accepted_responder_id
 where r.accepted_responder_id is not null
on conflict do nothing;
