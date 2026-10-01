-- Winch Up :: a Tips topic for the community feed
--
-- The design reference's feed has Recent / Trails / Events / Tips. This app shipped Recent /
-- Trail conditions / Gear / Recoveries, and CLAUDE.md explains why: a tab that opens an empty
-- list reads as a broken feature rather than an absent one, so the tabs were the things the
-- feed already had something to hold.
--
-- Tips is different from Events. It needs no table, no dates and no RSVPs -- a tip is a post,
-- and this is one more label on a post. The tab is populated by the first person who files
-- something under it, which is also true of Gear and Recoveries today.
--
-- ON ITS OWN, AND WITH NOTHING ELSE IN THE FILE. A new enum label cannot be USED in the
-- transaction that adds it, so anything referencing 'tips' -- a default, a check, a function
-- body that casts to it -- has to wait for a later migration. Nothing here needs to: the feed
-- RPC takes text and casts at call time, so it starts accepting the new label the moment this
-- lands, with no other change.

set search_path = public, extensions;

alter type post_topic add value if not exists 'tips';
