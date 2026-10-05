# Automatic SMS alerts to closest helpers — audit before building

**Date:** 2026-10-04. **Spec:** "WINCH-UP — AUTOMATIC SMS ALERTS TO CLOSEST HELPERS", 14 sections.

Section 10 of that spec says "audit the existing schema first". This is that audit, and it changes
what the work is: **most of this system already exists and has been live for weeks.** The spec reads
as though it is describing something to be built from nothing. It is not. Writing it from scratch
would have produced a second dispatch engine beside the working one — and CLAUDE.md records what
that nearly cost once already, when a `create or replace` with a matching signature silently
replaced `events_upcoming()` and only one failing assertion revealed it.

So the deliverable is the GAP, not the system.

## Already built, live, and tested — no work needed

| Spec | Where it already lives |
|---|---|
| §1 helper = any member, `available_to_help` | `profiles.available_to_help`, universal membership (2026-09-23) |
| §1 latest permitted location, private | `responders.last_location` + `share_location` + `last_location_at` |
| §2 freshness threshold, configurable | `dispatch.location_freshness_minutes` (default 120) in `app.candidates()` |
| §2 stale → fallback rules | falls back to `home_location`, which §2 explicitly permits |
| §3 server-side geographic matching | `app.candidates()`: PostGIS `st_distance` / `st_dwithin`, `security definer` |
| §3 exclusions 4–7 | availability, `available_to_help`, `notify_recovery`, `paused_until`, night-hours, equipment match, `max_active_jobs` |
| §3 sort closest → farthest | `order by st_distance(...)` |
| §5 waves, configurable radii | `dispatch.ring_radii_miles`, `app.ring_radius_miles(ring)`, `app.notify_ring()` |
| §5 never resend to the same helper | `not exists (… dispatches …)` AND `unique (request_id, responder_id)` |
| §5 store every attempt | `dispatches` rows, plus `request_events` timeline |
| §4 separate SMS consent field + STOP/START | `responders.sms_opt_in` / `sms_opt_out_at`, enforced in `app.notify_ring()` — but see gap A for its default |
| §6 message content | `responder.offer` in `src/lib/sms/templates.ts`: distance, vehicle, situation, STOP — **no phone, no coordinates**, already compliant |
| §8 offer → accept → group | `recovery_participants`, group chat, per-participant unread (live 2026-09-24) |
| §8 multiple helpers | a recovery is a TEAM; `accepted_responder_id` is the retained lead |
| §10 `recovery_alerts` table | **`dispatches` IS this table** — id, request_id, responder_id, ring (= wave), distance_miles, sent_at, delivery state, twilio_sid, error_message |
| §10 unique constraint | `unique (request_id, responder_id)` — the exact requirement |
| §11 privacy, RLS | column-level revokes on `requests.location`/`requester_phone`; coordinates never leave through a member-facing RPC |
| §12 not "live" tracking | the product already says last reported location, and freshness is in the matcher |

`dispatches` is the spec's `recovery_alerts` under an older name. **Do not create
`recovery_alerts`** — it would be a second, competing ledger of who was texted, and the uniqueness
guarantee would then protect nothing.

## The actual gaps

### A. SMS consent EXISTS, defaults to yes, and no member can see it (§4)

**Corrected after reading the code rather than the spec.** My first pass said "add
`sms_recovery_opt_in`". That would have been a duplicate column. The separate consent field §4 asks
for is already there and already enforced:

- `responders.sms_opt_in boolean not null **default true**` and `responders.sms_opt_out_at`
- `app.notify_ring()` gates the SMS — and ONLY the SMS — on
  `resp.phone is not null and resp.sms_opt_in and resp.sms_opt_out_at is null`
- STOP sets `sms_opt_in = false, sms_opt_out_at = now(), availability = 'paused'`; START reverses it;
  a trigger keeps the two columns consistent

So the mechanism is complete. **Two things are wrong with it, and neither is a missing column.**

1. **`default true` is precisely the inference §4 forbids.** "A verified phone number does NOT
   automatically mean the member has consented" — but a row is born consenting, so proving a phone
   is exactly what grants consent today.
2. **No screen exposes it.** `notification-settings.tsx` offers seven preferences and not this one,
   so the only way a member can decline recovery SMS is to receive one first and reply STOP. Opting
   out by being texted is not consent.

**The window to fix this cheaply is now, and it closes the moment SMS is switched on.**
`sms.outbound_enabled` ships `false`, so **no recovery SMS has ever been sent to anybody**. There is
no reliance interest to protect and no backlog to reconcile, which means flipping the default to
`false` today costs nothing. Doing it after the switch is thrown means silently muting members who
had been receiving alerts.

Note for whichever screen gains the toggle: `profiles` has an **enumerated** column grant list, so
any new preference column there needs its own `grant select (…) / grant update (…)` or the screen
shows a default and saves nothing. `sms_opt_in` lives on `responders`, so check that table's grants
rather than assuming.

### B. Per-wave counts and waits are single values (§5, §13)
`dispatch.max_per_ring` (10) and `dispatch.ring_wait_minutes` (7) apply to *every* ring. The spec
wants wave 1 = 5 helpers / 2 min and wave 2 = 10 helpers / 3 min. The radii are already an array, so
this is making two scalars match that shape, with the scalar honoured as a fallback.

### C. Default radii differ (§13)
Shipping: `[15, 30, 60]`. Spec: `[5, 10, 25]`. A settings change, not code — but it is a **live
behaviour change** and it narrows the first wave considerably, so it is called out rather than done
quietly. Worth the owner's eye: 5 miles in rural Texas may reach nobody.

### D. Expansion stops at the FIRST acceptance (§9)
`advance_dispatch()` returns `action: none` once status is `accepted`. §9 wants a configurable
`helpers_needed`, continuing until that many are confirmed. The team model already supports multiple
helpers, so this is the dispatch loop learning what the data model already allows.

### E. No admin RECOVERY ALERT SETTINGS screen or stats (§13)
The settings exist in `app_settings` and are editable only by hand. §13 wants a screen plus: sent,
delivered, failed, notified, offers, accepted, average response time. Every number is derivable from
`dispatches` — none of it needs new storage.

### F. No §14 test
Five helpers at 1.2 / 2.8 / 4.7 / 8.4 / 18 miles, asserting distance ORDER, wave boundaries,
expansion, stop-on-satisfied, no duplicates, opt-out respected. This is the test that would catch a
matcher that silently matches everybody — the failure mode CLAUDE.md has already seen twice, where
every "does not get it" assertion passes because nothing matches at all.

### G. The SMS carries no secure link (§6, §7)
Today it is "Reply 1 to offer, 2 to pass", and the inbound webhook handles it. §6 asks for a
`[SECURE LINK]` to an authenticated page with I CAN HELP / CAN'T HELP buttons. Both can coexist —
reply-by-text works with no data connection and on any handset, which for a volunteer standing in a
field is not a small thing. **Recommendation: add the link, keep the reply.**

## What gates this working at all, which is not code

`sms.outbound_enabled` ships **false**, and `sms.enabled_templates` is an allowlist currently
holding `responder.offer` and `responder.already_covered`. So the call-out template is already
allowed, and the master switch is the one thing still off. A2P 10DLC was approved 2026-09-28. Until
that switch is turned on, everything below is exercised by tests and by `sms_messages` rows marked
suppressed — which is the correct default for a feature whose unit of action is "text a real person
and charge for it", and it is a decision for the owner rather than a migration.
