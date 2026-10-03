# Events, advertising and geo-targeting: what exists before anything is built

Audit done before writing a line, per the owner's spec ("do not remove or replace existing WINCH-UP
functionality") and per the rule in CLAUDE.md that has now caught me twice: something the notes call
missing often has a complete backend.

Read from the live database — `information_schema`, `pg_proc`, `pg_enum` — not from the migration
files, because several of these have been redefined.

## Most of the advertising system already exists

| table | columns |
|---|---|
| `businesses` | owner, name, slug, category, description, website, contact, logo, **service_counties**, **service_center**, **service_radius_miles**, status, approval fields |
| `ad_campaigns` | business, name, status, **surfaces[]**, **target_center**, **target_radius_miles**, **target_counties**, starts_on, ends_on, monthly_price_cents, approval fields |
| `ad_creatives` | campaign, headline, body, cta_label, cta_url, image_path, status, is_active, approval fields |
| `ad_daily_stats` | creative_id, surface, day, impressions, clicks |
| `events` | group, trail, title, description, starts_at, ends_at, **meet_point**, meet_note, capacity, status |
| `event_rsvps` | — |

With RPCs already in place: `ads_for`, `ad_record_event`, `admin_ad_queue`, `save_business`,
`save_campaign`, `set_campaign_running`, `create_event`, `events_upcoming`, `event_rsvp`,
`app.ad_slot_allowed`, `app.owns_business`.

So the spec's sections 5, 9 and 13 are largely **already built**: campaigns, creatives, per-advert
approval, labelled serving, counting, scheduling windows, and a business/sponsor model with its own
service area. Radius targeting is in the schema. What is missing is narrower than the spec implies,
and is listed at the bottom.

## Three findings that change what needs building

### 1. Radius targeting exists and does nothing

`ads_for()` takes the reader's location as a **parameter** rather than looking it up, and
`ad-slot.tsx` calls it with `p_lng: null, p_lat: null`. The function's own rule is "untargeted, **or
we do not know where the reader is**, or inside the radius" — so with no location passed, a
radius-targeted campaign is shown to everybody.

That is the opposite of section 6's "only members who match the targeting rules should receive or
display the campaign". The targeting column has been there for weeks and has never once narrowed
anything.

It is also, accidentally, the right architecture for section 7: the ad path cannot read a member's
recovery location because it does not know who the member is. That property is worth keeping
deliberately rather than by omission.

### 2. There is no member location to target on

`profiles` has `home_region` — one free-text field, "a town or county", typed by the member. There is
no city, state, postal code or country, which is exactly what section 11 says not to depend on.

The only structured location a member has is `responders.home_location`, a PostGIS point captured at
volunteer signup — and that is **recovery data**, which section 7 forbids using for advertising. So
ad targeting cannot reuse it, and this is the one place where the spec and the existing schema
genuinely disagree about where a member "is".

New structured fields on `profiles` are therefore the foundation everything else targets against:
city, state, postal code, country, member-declared, with their own purpose. Radius targeting for ads
then measures from the **postal code's centroid**, never from the recovery point.

### 3. Section 12 collides with a privacy property that has a test

CLAUDE.md states it as a rule: *"`ad_daily_stats` has no column that could identify a person and must
not grow one. That is the whole privacy position of the ad system — counts per creative per surface
per day, belonging to nobody — and a test asserts the exact column list."*

Section 12 asks for impressions and clicks broken down **by city and by ZIP code**. A ZIP with one
member turns "impressions: 1" into "that member saw this advert", which is precisely the
re-identification the existing rule exists to prevent. The two cannot both be taken literally.

**Proposed resolution, and the reason:** add the geographic dimension, but never report a bucket
below a minimum cohort size. Counts for a city or ZIP with fewer than a threshold of matching members
are suppressed and rolled into an "other" row, so the breakdown is useful at the scale an advertiser
actually cares about and useless for identifying anybody. The test that pins the column list gets
updated to pin the new list **and** to assert the suppression, rather than being deleted.

This is the one decision in the spec I would not make silently.

## What is actually missing

- **Member location**: structured city/state/postal_code/country on `profiles` (§11)
- **Normalized targeting**: `campaign_target_locations` and friends — state, city, ZIP, multi-city,
  multi-ZIP. Today there is only radius and a `target_counties` array (§2, §6, §10)
- **Targeting actually enforced** in `ads_for()` and anywhere else that serves (§6)
- **Events**: type, address/city/state/ZIP, latitude/longitude, cover and additional images,
  organizer, registration URL, website, contact, and targeting. Today an event is tied to a group or
  a trail with a meet point (§2)
- **Announcements**: no table, no concept (§1)
- **Ad surfaces**: `ad_surface` has `community_feed`, `trails`, `resources`. The spec wants home feed,
  map, events and business directory as well (§8)
- **Campaign lifecycle**: draft → scheduled → active → expired, with pause, resume, duplicate,
  archive (§9)
- **Analytics**: geographic breakdown, unique reach, CTA clicks, event views (§12)
- **Admin preview** with an estimated audience count before publishing (§14)
- **Super admin section**: Content & Marketing (§1, §16)

## What must not break

Three properties in this area are enforced by tests, and the new surfaces have to preserve all three.

1. **Ads cannot reach anything urgent, and the enum is what stops them.** There is no `ad_surface`
   value for the request wizard, a live recovery, or a message thread, and `ads_for()` refuses an
   unrecognised surface outright. Section 8 agrees with this; adding home feed, map, events and
   directory is compatible, and `app.ad_slot_allowed()` additionally refuses the two resource guides
   that are emergency guidance.
2. **Nothing in the dispatch path may ever read an advertising table.** A test reads the source of
   `app.candidates()`, `advance_dispatch()`, `app.decline_dispatch()` and `admin_manual_dispatch()`
   and fails if any of them so much as names one. Nobody buys priority at a roadside.
3. **Approval attaches to the words, not the row.** Editing an approved creative or business sends it
   back to pending. Any new targeting fields have to be inside that rule, or "approve the advert,
   then retarget it at a different city" becomes a way past review.

## Phases 1 and 2, built 2026-10-03

`20261003000100_member_location.sql` and `20261003000200_targeting.sql`, plus
`supabase/tests/targeting_test.sql` (32 assertions). Full suite: 1037 assertions, 24 suites, all
exit 0, from a database rebuilt out of the whole migration history.

### Departures from the spec, and why

**One `target_locations` table instead of three.** §10 names
`campaign_target_locations`, `event_target_locations` and `advertisement_target_locations`. Three
tables would be the same six columns three times and the matching rule written three times, which is
three places for "ZIP codes are text, not integers" to be wrong independently. What §10 actually asks
for is structured targeting rather than comma-separated strings, and a `scope` discriminator delivers
that with one rule to get right. The cost is no foreign key; it is paid by delete triggers on
`ad_campaigns` and `events`, asserted in section 10 of the suite.

**"All Members" is the absence of rows, not a row.** So adding a city to an all-members campaign
cannot leave a stale "everyone" rule behind that silently overrides it.

**A city target requires a state.** Houston TX is not Houston MO. Enforced by the shape CHECK rather
than by the form.

### The behaviour change the owner should know about

`ads_for()` today reads "untargeted, **or we do not know where the reader is**, or inside the
radius". `ad-slot.tsx` passes `p_lng: null, p_lat: null`, so every radius-targeted campaign is shown
to everybody — the targeting column has been in the schema for weeks and has never narrowed
anything.

§6 says only matching members should see a campaign, so unknown location is now a miss.
**Until members fill in a location, targeted campaigns reach fewer people.** That is targeting
working rather than targeting breaking, but it is a visible drop and it is asserted in section 6 of
the suite so it stays a decision rather than becoming an accident.

### Member location is deliberately not recovery location

`profiles.city/state/postal_code/postal_center` is new and separate from `responders.home_location`,
which is what `app.candidates()` measures a call-out from and which §7 forbids advertising from
touching. `app.member_matches_target()` takes the member's **fields** rather than a user id for that
reason: a function taking a uuid could reach for the recovery point, and passing the values in makes
the §7 boundary visible at every call site.

`postal_center` has no grant to `authenticated` and is cleared by `set_my_location()` on every write,
so radius targeting can never measure from where a member used to live.

## Phases 3 and 4, built 2026-10-03

`20261003000300_member_postal_center.sql` and `20261003000400_ads_enforce_targeting.sql`, the
`/account/location` screen, and `forwardGeocodePostalCode()`. Suite: 1057 assertions, 24 suites, all
exit 0, from a database rebuilt out of the whole migration history.

### Order mattered more than scope

Enforcing targeting first and capturing location second would have taken every targeted campaign
dark for everybody, because no member has a location until there is a screen to set one. So the
screen, the geocoder and the server-side writer shipped in the same change as the enforcement.

### The centroid is written by the server, from the ZIP it was asked about

`set_my_location()` clears `postal_center`; `set_member_postal_center()` refills it after the server
has geocoded, and it takes the postal code as an argument so it can refuse a late answer about a ZIP
the member has since changed. Writing it unconditionally would pin a stale point onto a current
postal code — the exact failure clearing the column prevents, reintroduced one step later, with no
symptom on any screen. `members_missing_postal_center()` is the retry queue for a geocode that
failed, so a member whose Mapbox call timed out does not silently match no radius campaign until they
next happen to edit their profile.

Mapbox falls back to the nearest thing it can match rather than returning nothing, so the geocoder
confirms the answer is about the postcode it asked for and discards it otherwise.

### Section 7 is now held on purpose rather than by accident

The previous architecture could not read a member's recovery location because it did not know who the
reader was. `ads_for()` looks up `auth.uid()` now, so that property had to be rebuilt deliberately:
the function reads the four stated location fields into locals and nothing else from the row,
`app.member_matches_target()` takes values rather than a user id, and `targeting_test.sql` reads the
advertising functions' own source and fails if any names `responders` or `home_location` — the guard
that stops the dispatch path reading an advertising table, pointed the other way.

That guard immediately failed on two things worth recording. `app.target_audience_count()` joined
`responders` to skip `redacted_at` rows; reading what the column means settled it in the guard's
favour, because `redacted_at` marks a volunteer record scrubbed by retention rather than a deleted
account, and those members still sign in and still see adverts — so the join was under-counting the
audience as well as being a §7 smell. It was removed. Then the guard failed on `ads_for()` itself,
because a *comment* in the body named both identifiers: a textual check cannot tell a comment from a
reference. The comment was reworded and says so, since the alternative is a confusing failure that
gets a blunt guard deleted instead of understood.

### One assertion in advertising_test.sql was inverted

It read "a reader whose browser gave no position still sees it, rather than targeting quietly meaning
nobody", and it passed. The fear behind it was right — targeting that matches nobody is worse than
none — but the cure was a hole the size of the feature. It now asserts the opposite, with the other
half beside it: the same reader, the same campaign, still no browser position, is served the campaign
once they have *stated* an area, and stops being served it when that area moves to Houston. A member
no longer needs to hand over a live GPS fix to be reachable by a local advertiser.

### Both targeting gates must pass

`target_center` / `target_radius_miles` predate `target_locations` and are still honoured, as an
intersection rather than a union: a campaign narrowed two ways reaches the overlap. The alternative
would let adding a city WIDEN an existing radius campaign, which is not what anybody adding a city
believes they are doing.

### Still outstanding from the spec

Events extension (§2), announcements (§1), the four new ad surfaces (§8), campaign lifecycle (§9),
analytics with the agreed suppression (§12), and the admin Content & Marketing screens (§1, §14, §16).
`target_counties` on `ad_campaigns` is dead in the serving path and was dead before this change.
