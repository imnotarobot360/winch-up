-- Winch Up :: the labels and switches direct messages need
--
-- Member-to-member messaging. The design reference has a Message button on a member's profile and this
-- product has never had one: the only conversation that exists is attached to a recovery and scoped to
-- its participants. The owner asked for it on 2026-10-01.
--
-- GREPPED FIRST. CLAUDE.md records two occasions where something the notes called "not built" had a
-- complete backend, so before writing a line: every match for direct_message, conversation,
-- member_messages and dm_ across the whole migrations folder is the word "conversation" in a comment
-- about request_messages. There is no table, no RPC and no enum label. This really is new.
--
-- THIS FILE EXISTS SEPARATELY FOR ONE REASON. A new enum label cannot be USED in the transaction that
-- adds it, and the Supabase SQL editor wraps a script in one. So the label lands here, alone, and is
-- first used two files later. Splitting it is not tidiness -- doing it in one file produces
-- "unsafe use of new value of enum type", which reads like a broken migration.
--
-- WHY A SEPARATE KIND FROM `message`, which already exists and already maps to notify_chat:
--
-- Recovery chatter and a direct message are different in kind, and the switch has to be able to tell
-- them apart. "Which gate are you at?" from the volunteer driving toward you is operational and
-- urgent; "fancy a trip to Barnwell next weekend?" from somebody you have never met is social. A
-- member who wants fewer of the second must not thereby silence the first -- that would be a
-- notification preference that costs somebody a recovery.
--
-- Note what app.notify does with an UNMAPPED kind: it falls through to `else coalesce(notify_recovery,
-- true)`, so a direct_message would have been governed by the recovery switch. Adding the label
-- without extending that function would be worse than not adding it, which is why the third file in
-- this set rebuilds app.notify.

set search_path = public, extensions;

-- ---------------------------------------------------------------------------
-- 1. The notification kind
-- ---------------------------------------------------------------------------

alter type notification_kind add value if not exists 'direct_message';

-- ---------------------------------------------------------------------------
-- 2. The two switches, which are deliberately not one
-- ---------------------------------------------------------------------------
--
-- allow_direct_messages is "may a member start a conversation with me at all" -- the spec's "send
-- messages where messaging is enabled". notify_direct_messages is "and should my phone buzz about it".
-- Somebody who wants to be reachable but not interrupted needs both, separately.

alter table public.profiles
  add column if not exists allow_direct_messages  boolean not null default true,
  add column if not exists notify_direct_messages boolean not null default true;

-- DEFAULT TRUE, and this is a judgement rather than an oversight.
--
-- The argument for default-off is real: an open inbox is a harassment surface, and §6 of the owner's
-- spec is entirely about safety. The argument against is the one this whole phase has already paid
-- for -- the member directory shipped behind two default-off switches and sat empty for weeks, which
-- is not privacy, it is a feature nobody could use. This product exists to replace a Facebook group
-- where anybody can message anybody, so default-off would be a step backwards from the thing being
-- replaced, and members would not know the switch was there to find.
--
-- What carries the safety instead, and all three already exist: blocking is symmetric and stops a
-- conversation in both directions, a member can be reported from the thread, and an admin can suspend
-- an account out of the directory and the dispatcher at once. Plus the switch itself, for anybody who
-- wants it off.
--
-- If the owner would rather it shipped off, it is this one word.

comment on column public.profiles.allow_direct_messages is
  'Whether other members may start a direct conversation. Blocking and suspension override it; a '
  'conversation that already exists stays readable so nobody loses their own history.';

comment on column public.profiles.notify_direct_messages is
  'Whether a direct message buzzes the phone. Separate from notify_chat, which is recovery chatter -- '
  'turning off social pings must not silence the volunteer who is driving toward you.';
