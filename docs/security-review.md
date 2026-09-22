# Security, privacy and safety review

Phase 14. Carried out 2026-09-22 against the live schema and the deployed app, not against a
description of them. Every "checked" below means a query was run or a request was made.

What turned into code is in `supabase/migrations/20260922003500_privacy.sql` and
`scripts/check-claims.mjs`. What turned into an assertion is in `supabase/tests/security_test.sql`
and `supabase/tests/schema_audit_test.sql`. This document is the rest: the areas where the answer
was "already fine", and the judgement calls where it was "fine enough, and here is why".

---

## The finding

**Deleting an account did not delete the account.** Measured, by creating a user with a volunteer
profile, a recovery and a post, deleting the user, and looking at what was left:

```
responders: phone=+15125559999  name=Gone      user_id=(null)
requests:   phone=+15125559999  name=Gone      user_id=(null)
requests:   exact location still stored: true
```

The foreign keys were doing exactly what Phase 3 set them up to do — `SET NULL`, so history
survives with attribution removed. What nobody checked is that the identifying data was never in
the foreign key. It was in the columns beside it: a mobile number, a first name, and the exact
coordinates of somewhere a person got stuck at night.

Fixed with a `BEFORE DELETE` trigger on `auth.users`, so it runs whoever does the deleting and
from wherever — the account screen, an admin, the Supabase dashboard. The account deletion screen
now lists what goes and what stays, in both languages, before the button.

**Nothing expired, either.** A recovery from 2026 kept a phone number and an exact pin forever,
for no reason: the job was done the same evening. Closed requests are now scrubbed after
`privacy.request_retention_days` (default 180), through the same code path, on the schedule that
already runs every minute.

---

## The thirteen areas

### 1. Authentication — fine
Supabase Auth, email/password with verification and phone OTP. Admin MFA exists and is enforced at
`app.require_admin()` rather than `app.is_admin()`, so turning it on cannot lock an admin out of
the enrolment page. Checked that `security.require_admin_mfa` still defaults false and that
`admin_set_mfa_required(true)` refuses from an `aal1` session.

### 2. Authorization — fine, and asserted
Every admin RPC gates on `app.require_admin()`; moderation gates on `app.is_moderator()`; the
advertiser surface gates on `app.owns_business()`. `schema_audit_test.sql` pins the list of
security-definer functions `anon` may execute to exactly four, by name, so a fifth fails the suite.

### 3. Database access — fine, audited in Phase 12
RLS on every table; 18 tables have no policies and no grants at all and are reachable only through
functions. Column privileges on `requests.requester_phone` and `requests.location` are revoked
separately, so a policy mistake alone cannot leak either.

### 4. File uploads — fine
Signed upload URLs only; the bucket has no anon policies. The route validates the draft id as a
UUID (so no path traversal), bounds the index, allows three image MIME types, and rate limits 30
URLs an hour per address. The bucket itself carries `file_size_limit` and `allowed_mime_types`, so
the size cap does not depend on the route. EXIF is stripped client-side by re-encoding through a
canvas; there is no code path that uploads an original file.

### 5. Location privacy — fine, and now better
Exact pins reach only the accepted volunteer. `/board` shows a blurred pin about a mile off, and
keeps doing so after acceptance unless `board.reveal_exact_after_accept` is flipped. Volunteer
position sharing is off by default, is one point stored on a button press, expires after
`dispatch.location_freshness_minutes`, and `forget_my_location()` clears it. After this phase, the
exact pin is also destroyed when the account goes or when retention catches up with it.

### 6. Messaging permissions — fine
Membership is derived from the request, never stored, so reassigning a job moves the conversation
with it. Deliberately **not** reachable with the status token, because that token is meant to be
shared with family. 18 assertions cover it.

### 7. API rate limiting — judged, not changed
Surveyed all 34 member-callable write RPCs. Ten rate limit; the rest do not, and on inspection
that is right rather than an oversight:

- **Toggles** (`community_react`, `trail_save`, `event_rsvp`, `group_membership`,
  `set_my_availability`, `set_primary_vehicle`, `mark_notifications_read`) can only flip a row
  that already exists. The worst case is row churn, and a limit would cost a `rate_limit_hits`
  write on every press.
- **State transitions** (`accept_request`, `decline_request`, `report_on_site`,
  `report_complete`) are bounded by the dispatch row they act on.
- **Advertiser writes** (`save_campaign`, `save_creative`, `submit_for_review`) are reachable only
  by the owner of an approved business, and `save_business` — the function that creates those — is
  limited to five a day.

The two worth watching if usage ever justifies it: `update_my_location`, which a modified client
could call in a loop, and `upsert_responder_profile`. Neither creates unbounded rows. Recorded here
rather than fixed, because adding limits to a dozen working functions during a security review is
how a security review introduces a bug.

### 8. Input validation — fine
CHECK constraints on every user-supplied text column, with `contains_contact_info()` on the public
ones. Lengths bounded. Enums parsed inside an exception block so an invalid value returns a named
error rather than a 22P02. Route handlers validate shape before touching the database.

### 9. Payment webhook verification — not applicable yet, and prepared
No webhook exists: Stripe needs the owner's account and keys. The shape that makes one safe does
exist — `stripe_webhook_events.id` is the event id Stripe sends and is the primary key, so a
replayed webhook inserts nothing and the handler stops. Payment intents and invoice ids are unique
for the same reason. **When the handler is written, it must verify the signature before it trusts
the body**; the table cannot do that part.

### 10. Administrative permissions — fine
Admin RPCs are granted to `authenticated`, not `service_role`, so there is no shared key that
grants admin; the gate is `auth.uid()`. Every mutating admin RPC writes an audit row. A moderator
is refused by `admin_list_responders()`, which is the screen carrying phone numbers, and there is
a test that proves it.

### 11. Account deletion — **was broken, now fixed.** See above.

### 12. Data retention — **was absent, now exists.** See above.

### 13. Abuse reporting — fine
Two separate routes, deliberately: `safety_incidents` for what happened at a recovery (its subject
must never see it, and does not — the notification goes only to the reporter) and `content_reports`
for a piece of content. Blocking is symmetric, is never announced to the person blocked, and as of
Phase 13 closes the notification channel too.

---

## The claims rule

> Do not claim the app provides emergency rescue, guaranteed assistance, or continuous location
> monitoring unless those capabilities are actually implemented and supported.

None of the three is implemented and none is claimed. All 2,596 user-facing strings in both
languages were scanned; the only matches were sentences saying the *opposite* — "nobody here is an
emergency service", "nothing runs in the background and nothing tracks you".

`scripts/check-claims.mjs` now runs in `prebuild`. A new string that promises a guarantee,
round-the-clock availability, or location tracking fails the build. The check was verified by
planting `"We guarantee a rescue, 24/7, and we track your location live."` and confirming three
separate patterns caught it.

## Poor coverage

Documented where somebody will actually read it rather than in a policy: the **Before you go**
guide tells people to assume there is no signal, download the offline map, screenshot it, and write
coordinates on paper. **When you are the one stuck** tells them to call 911 first for injury, water
or traffic, that nobody is on shift, and how to make a phone last. The request wizard shows GPS
accuracy and offers four fallbacks when it is poor.

## Still outstanding, and not code

- `/terms`, `/waiver` and `/privacy` carry **REVIEW WITH LAWYER** placeholders. This has been open
  since the first milestone and is the cheapest launch blocker to start.
- A Stripe webhook handler, when there is a Stripe account, must verify the signature.
- Push notifications do not exist; if they are ever added, the consent story changes and this
  document needs revisiting.
