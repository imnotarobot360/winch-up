-- Winch Up :: two tables for member-to-member conversations
--
-- Built on the shape request_messages already proved (20260922000400): no table access at all, RLS
-- enabled with no policy and no grant, and every read and write through a security definer RPC that
-- derives participation rather than trusting a parameter. That is not caution for its own sake -- it
-- is what makes "users must not be able to add themselves by manipulating ids" a property instead of
-- a promise.
--
-- TWO PARTIES, NOT N. A direct message is between two members. Group conversations already exist and
-- are attached to a recovery, where the membership is the team and the access rule is
-- recovery_participants. Generalising this to N would mean a participants table, an invite concept and
-- a second place for the thread-access rule to be wrong. The spec asks to "send messages"; this sends
-- messages.
--
-- ONE THREAD PER PAIR, enforced by the database rather than by a query. The pair is stored in a
-- canonical order -- the lower uuid in member_a -- with a CHECK and a unique index, so "open a
-- conversation with Rosa" cannot produce a second thread when Rosa has already opened one with you.
-- Doing that with an application-side read-then-insert is the same race that made
-- requests_one_open_per_account a partial unique index instead of a check in a function.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. The thread
-- ---------------------------------------------------------------------------

create table if not exists public.dm_threads (
  id            uuid primary key default gen_random_uuid(),

  -- NOT NULL, unlike request_messages.sender_user_id. A thread with nobody on one side is not a
  -- conversation anybody can read, and the cascade below deletes it when an account goes. The
  -- MESSAGES keep a nullable sender for the same reason request_messages does -- see below.
  member_a      uuid not null references auth.users (id) on delete cascade,
  member_b      uuid not null references auth.users (id) on delete cascade,

  -- Maintained by the send RPC so the inbox can sort without touching dm_messages.
  last_message_at timestamptz,
  created_at      timestamptz not null default now(),

  -- Canonical order, so the pair is one value and not two.
  constraint dm_threads_ordered check (member_a < member_b)
);

create unique index if not exists dm_threads_pair_idx
  on public.dm_threads (member_a, member_b);

-- Both directions, because the inbox asks "threads I am in" and neither column alone answers that.
create index if not exists dm_threads_member_a_idx on public.dm_threads (member_a, last_message_at desc);
create index if not exists dm_threads_member_b_idx on public.dm_threads (member_b, last_message_at desc);

comment on table public.dm_threads is
  'One direct conversation between two members, the pair held in canonical order so it cannot be '
  'duplicated. No table access: everything goes through the dm_* RPCs.';

-- ---------------------------------------------------------------------------
-- 2. The messages
-- ---------------------------------------------------------------------------

create table if not exists public.dm_messages (
  id            uuid primary key default gen_random_uuid(),
  thread_id     uuid not null references public.dm_threads (id) on delete cascade,

  -- Nullable, exactly as request_messages does it: deleting an account must not delete the
  -- conversation the OTHER person still has. They keep what was said to them; the name goes.
  sender_user_id uuid references auth.users (id) on delete set null,

  body          text not null check (length(btrim(body)) between 1 and 2000),

  -- THE IDEMPOTENCY KEY, minted by the browser before the first attempt. A retry on one bar of
  -- signal cannot tell whether the first attempt landed, and both obvious answers are wrong: send
  -- again and the recipient sees it twice, do not and the member believes they said something they
  -- did not. The unique index makes the second row impossible, and the send RPC answers the
  -- duplicate with the message that already exists. Same reasoning as
  -- request_messages_sender_client_idx (20260923002100).
  client_id     text not null check (length(btrim(client_id)) between 8 and 64),

  -- Set when the OTHER party reads the thread. Two participants, so one column is enough.
  read_at       timestamptz,
  created_at    timestamptz not null default now()
);

create index if not exists dm_messages_thread_idx
  on public.dm_messages (thread_id, created_at);

create unique index if not exists dm_messages_sender_client_idx
  on public.dm_messages (sender_user_id, client_id)
  where sender_user_id is not null;

-- Unread counting per thread, for the inbox badge.
create index if not exists dm_messages_unread_idx
  on public.dm_messages (thread_id, sender_user_id)
  where read_at is null;

-- NO attachment column, and that is a decision. request_messages carries one because a recovery needs
-- a photograph of the stuck vehicle, and it rides on a private bucket with signed URLs and a ring-based
-- access rule. A direct message between strangers is the one surface in this app where an image upload
-- is a vector rather than a feature, and adding it means a second bucket policy, a second signing path
-- and a report route for pictures. Text first. If the owner wants pictures here it is its own phase.

-- DELIBERATELY NOT applying contains_contact_info() to the body -- the same decision request_messages
-- made, and worth restating because the reasoning is NOT identical.
--
-- There, the two people already have each other's numbers; acceptance exchanged them. Here they may be
-- strangers, so the tow-company case this product exists to escape is live: somebody could DM the
-- membership one at a time offering paid recovery.
--
-- It still does not belong in a CHECK. A constraint that rejects a phone number in a private message
-- between two people who chose to talk breaks the legitimate case -- "ring me on the way, the gate
-- code changes" -- and the illegitimate one is not solved by it either, since a determined spammer
-- writes the number in words. What answers soliciting is the part that already exists: report the
-- member, block them, and an admin suspends the account out of the directory and the ring at once.
-- report_reason already carries 'soliciting_payment'.
--
-- The honest cost of that choice: the first DM from a stranger can contain anything. The rate limit in
-- the send RPC is what stops it being automated, and it is low on purpose.

alter table public.dm_threads enable row level security;
alter table public.dm_messages enable row level security;

revoke all on public.dm_threads from anon, authenticated;
revoke all on public.dm_messages from anon, authenticated;

comment on table public.dm_messages is
  'Messages in a direct conversation. No table access; read and written only through the dm_* RPCs, '
  'which derive participation from auth.uid() rather than trusting a thread id.';
