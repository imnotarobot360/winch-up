-- Winch Up :: four more places an advert may appear
--
-- Section 8 of the owner's spec asks for the home feed, the map, events and the business directory
-- alongside the three surfaces that already exist.
--
-- ITS OWN MIGRATION, CONTAINING FOUR STATEMENTS, because a new enum label cannot be USED in the
-- transaction that adds it and `supabase db push` wraps each file in a transaction. Anything that
-- names one of these -- app.ad_slot_allowed(), a seed, a test -- has to come afterwards.
--
-- THE ENUM IS THE SAFETY PROPERTY, NOT A CONVENIENCE. There is no label here for the request wizard,
-- a live recovery, or a message thread, and there must never be one: ads_for() refuses a surface it
-- cannot cast and that refusal is what stops an advert appearing beside somebody who is stuck. Adding
-- a label is therefore a deliberate decision about where money may be taken, which is why these four
-- are named one at a time rather than generated.
--
--   home_feed   the signed-in home screen
--   map         the map view
--   events      the events tab and an event page
--   directory   the business directory, where a reader is already looking for a business
--
-- All four are browsing surfaces. None of them is somebody waiting for help.

set search_path = public, extensions;

alter type ad_surface add value if not exists 'home_feed';
alter type ad_surface add value if not exists 'map';
alter type ad_surface add value if not exists 'events';
alter type ad_surface add value if not exists 'directory';

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- WHICH OF THESE ACTUALLY HAVE A PAGE, as of 2026-10-03
-- ---------------------------------------------------------------------------
--
-- Recorded here rather than left to be discovered, because a label with nothing mounted on it reads
-- like a working surface in the admin campaign form and sells space on a page that does not exist.
--
--   events      MOUNTED. The events tab on /community.
--   home_feed   no page. src/app/[locale]/page.tsx is the signed-out marketing page, and putting a
--               paid advert on the first thing a stranded driver sees is not a decision to make in
--               passing. A signed-in home feed does not exist yet.
--   directory   no page. /business is the ADVERTISER's own dashboard -- where somebody registers
--               their business -- not a directory members browse. There is no such directory.
--   map         no page. The only map is inside /admin.
--
-- The labels are added anyway, deliberately: they are the permission to sell space there, and getting
-- the enum right is a separate job from building three pages. They are inert until something mounts
-- an AdSlot, and ads_for() serves nothing for a surface nothing asks about.
