-- Winch Up :: the two new preference columns are readable and writable by their owner
--
-- A REGRESSION I SHIPPED TWO FILES AGO, caught by a test rather than by reading.
--
-- public.profiles does not have a blanket grant to `authenticated`. It has an ENUMERATED column list
-- -- twenty entries, select on some, select and update on others -- and a column added later is in
-- none of them. So 20261001002000 added allow_direct_messages and notify_direct_messages, the
-- notification screen started selecting them, and PostgREST refused the whole statement.
--
-- WHAT THAT LOOKED LIKE, and why it is worth the long comment: nothing errored. The select returned no
-- row, the component fell back to DEFAULTS, and every switch on /account/notifications rendered its
-- default value instead of the member's actual preference. Somebody who had turned marketing on, or
-- availability off, would have seen the opposite and not known. It is a read failure that presents as
-- a confident wrong answer, which is the worst shape a bug can have on a preferences screen.
--
-- It surfaced as nearby-alerts.spec failing on "available to help survived a reload" -- an assertion
-- added that morning for an unrelated reason, which asserts the DATABASE agrees rather than trusting
-- an optimistic control. Without it the suite would have gone green: the switch flips, the click
-- lands, and only a reload shows the preference was never read in the first place.
--
-- THE LESSON FOR THE NEXT PREFERENCE COLUMN: adding it to profiles is two steps, not one. The column,
-- and the grant. There is a pgTAP assertion over this now so the second step cannot be forgotten
-- quietly.

set search_path = public, extensions;

-- Select, so the screen can show the member what they chose.
grant select (allow_direct_messages, notify_direct_messages) on public.profiles to authenticated;

-- Update, because both of these are the member's own switches. Contrast suspended_at and friends,
-- which are deliberately granted NEITHER: a member must not be able to read or lift their own
-- suspension, and that is enforced here rather than by hoping no UI offers it.
grant update (allow_direct_messages, notify_direct_messages) on public.profiles to authenticated;
