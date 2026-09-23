-- Winch Up :: the labels a recovery team needs
--
-- ALTER TYPE ... ADD VALUE only, and therefore its own file: Postgres will accept the statement
-- inside a transaction but will not let the new label be USED until that transaction commits, and
-- everything in 20260923001100 uses these. This is the same reason 20260923000150 ships alone.
--
-- New enum TYPES are not affected by that rule -- a type created and used in one transaction is
-- fine -- so participant_role, participant_status and message_kind live in the next file beside
-- the table that needs them.
--
-- WHAT THESE ARE FOR
--
-- A recovery used to be one person coming. It is now a team, and three things can happen that the
-- timeline and the notification system previously had no words for: somebody joins the team,
-- somebody leaves it, and somebody says where they have got to.
--
-- request_event_type is a closed enum because the timeline is rendered from it and an unknown
-- value shows a member a blank row. notification_kind is closed because the drain sorts by it --
-- an unrecognised kind would fall to the bottom of the priority list, which for a recovery is the
-- wrong end.

set search_path = public, extensions;

-- The timeline, and the system messages in the chat that mirror it.
alter type request_event_type add value if not exists 'helper_joined';
alter type request_event_type add value if not exists 'helper_withdrew';
alter type request_event_type add value if not exists 'helper_status';

-- Notifications. These sort with the other recovery kinds in app.drain_notifications, above
-- community and marketing: a helper saying "on site" matters more than a reply to a post.
alter type notification_kind add value if not exists 'helper_joined';
alter type notification_kind add value if not exists 'helper_status';
