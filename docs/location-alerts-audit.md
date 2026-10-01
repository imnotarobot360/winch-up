# Location and nearby-recovery alerts — audit against the owner's spec

2026-10-01. The spec's own first instruction for section 7 is "audit the existing database
before making changes", and that was the right instruction: most of this is built. Two real
bugs came out of the audit and are fixed; one decision is the owner's; one thing cannot be
proven from here.

**Everything below was checked against the LIVE database, not against the migration that first
created it.** That distinction mattered: an old migration shows `app.candidates()` gating on
`sms_opt_in`, which would mean nobody gets a push without agreeing to texts. The live function
has not done that for weeks — later migrations replaced it with `available_to_help` and
`notify_recovery`. Reading the first migration would have produced a confident, wrong bug
report.

## Fixed during the audit

**The requester was dispatched to their own recovery** (§3, "Exclude the requester").
`app.candidates()` had no such exclusion. Since universal membership this is not an edge case:
a member who offers help and then needs it is an available responder with a fresh position
sitting zero miles from their own request, so they sorted FIRST. Proven with a fixture before
being fixed, and guarded by two assertions — the requester is absent, and another member at the
same point is still returned. `20261001000500`.

**The first ring was 15 miles**, the spec says 10. Moved by `20261001000600`, guarded so it only
changes the shipped default and never overwrites a value an admin has tuned.

## Already built, verified

| Spec | Where it lives |
|---|---|
| §1 Enable/disable availability, radius, last-updated | `profiles.available_to_help`, `responders.radius_miles`, `update_my_location`, `forget_my_location`, the card on `/me` |
| §1 Stale positions ignored | `dispatch.location_freshness_minutes`, default 120, read by `app.candidates()` |
| §2 GPS with pin-drag, paste, photos, 911 gate | the request wizard; the confirmed pin is what is stored |
| §3 PostGIS distance, each member's own radius | `ST_DWithin(..., least(ring_radius, r.radius_miles))` |
| §3 Exclude opted-out / unavailable / stale / already-notified | `notify_recovery`, `available_to_help`, freshness, `dispatches` |
| §3 Configurable radii in the admin dashboard | `admin_list_settings` returns every row, `admin_update_setting` has no allowlist — editable at `/admin/settings` today |
| §4 Push first, SMS only on opt-in | push is the carrier; recovery SMS needs `sms.outbound_enabled` AND the template allowlist, both off |
| §4 No duplicate alerts | `and not exists (select 1 from dispatches ...)` |
| §5 Distances, details, offer assistance | `nearby_requests()` returns `distance_miles` and a blurred pin; `offer_assistance()` |
| §6 Multiple helpers, one group chat | `recovery_participants`, one thread per recovery, live since 2026-09-24 |
| §7 RLS, PostGIS, service role server-side only | throughout; `supabase/tests/privacy_rls_test.sql` |
| §8 Explicit permission, disable sharing, retention | the location card asks; `forget_my_location`; `privacy.request_retention_days` |

## One decision for the owner

**§5 says a member should be able to review photographs before offering help. Today they
cannot.** Photos reach the requester's own status page and the ACCEPTED helper
(`get_job_contact`); the public board shows a count and no images, and `/help` shows none.

That is a privacy posture, not an oversight: a photograph of a stuck vehicle shows where it is
and often who owns it, and releasing it to everybody browsing is a different promise from
releasing it to the person who has committed to driving out. Changing it is a product decision.

If the answer is yes, the narrow version is to release photos to members whose own position is
inside the request's current ring — people the system would have alerted anyway — rather than
to anyone with an account.

## What cannot be proven here

**That a push notification arrives on a real handset.** The local stack has no push service and
CI has no device. Everything up to the send is tested; the last hop is the owner installing the
PWA and filing a test request. On iPhone there is no push at all unless the PWA is installed,
which the copy has to keep saying.

§9's other cases — inside the radius, outside it, unavailable, stale, duplicates, multiple
helpers — are covered by `dispatch_test.sql` and `recovery-team.spec.ts`.
