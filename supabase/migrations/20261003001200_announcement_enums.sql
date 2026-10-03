-- Winch Up :: the two things an announcement has to declare about itself
--
-- Section 1 of the owner's spec. Its own migration, because a new enum label cannot be USED in the
-- transaction that adds it and the table below defaults to one.
--
-- WHY `category` EXISTS AT ALL, AND WHY IT IS HERE RATHER THAN ADDED LATER.
--
-- An announcement is the one feature in this spec that can reach every member with words an admin
-- chose. Some of those words are operational -- "the gate at the pits is locked, do not drive out
-- there" -- and some are marketing. `profiles.notify_marketing` ships FALSE and is the only consent
-- flag in this app that does, deliberately.
--
-- Nothing in this phase sends a notification, and that is recorded in the announcements migration. But
-- the distinction is a SCHEMA decision, not a messaging one: adding it after a hundred announcements
-- exist means guessing retrospectively which of them somebody had consented to. Declared on the row
-- from the first one, the day notifications are wired the routing is already decided.
--
--   operational   a gate closure, a safety notice, a change to how the app works. Not marketing, and
--                 must never be gated on a marketing consent flag.
--   marketing     a sponsor, a promotion, anything selling. Gated on notify_marketing when it is ever
--                 sent anywhere, and the default is off.
--
-- `operational` is the default because it is the safe direction for a field somebody forgets: an
-- operational announcement shown to somebody who did not want marketing is a notice they can dismiss,
-- while a marketing announcement mislabelled operational is consent quietly ignored.

set search_path = public, extensions;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'announcement_category') then
    create type announcement_category as enum ('operational', 'marketing');
  end if;

  -- Not reusing event_status: that one is draft / published / cancelled, and "cancelled" is wrong for
  -- an announcement -- one that ran and is finished was not cancelled. Archived is the honest word and
  -- matches what archiving means for a campaign.
  if not exists (select 1 from pg_type where typname = 'announcement_status') then
    create type announcement_status as enum ('draft', 'published', 'archived');
  end if;
end
$$;

notify pgrst, 'reload schema';
