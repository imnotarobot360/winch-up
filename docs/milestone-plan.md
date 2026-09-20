# TxRecover milestone plan

Each milestone ends with a commit and something you can actually look at or run.

---

## M1 — schema, migrations, RLS, seed  *(code complete, not yet executed)*

**Shipped**

- `supabase/migrations/20260920000100_extensions.sql` — PostGIS + pgcrypto in `extensions`,
  private `app` schema.
- `…0200_enums.sql` — 14 enums. Every value has an EN and ES label in `messages/`.
- `…0300_helpers.sql` — token and short-code generation, the deterministic ~1 mile blur,
  `contains_contact_info()` for CHECK constraints, rate limiting, identity helpers.
- `…0400_tables.sql` — 13 tables, PostGIS indexes, the `requests_due_idx` the 60 s tick scans.
- `…0500_triggers.sql` — derived columns, immutable identifiers, blocklist enforcement,
  timeline events, the 3-photo cap.
- `…0600_rls.sql` — deny-by-default, then narrow row policies **and** column-level grants.
- `…0700_rpc.sql` — the four read doors: `get_request_by_token`, `board_requests`,
  `responder_feed` / `get_job_contact`, `admin_request_detail`. Everything else is revoked.
- `…0800_storage.sql` — private photo bucket, no anon policies.
- `seed.sql` (reference, idempotent) and `seeds/demo.sql` (local demo).
- `tests/privacy_rls_test.sql` — the privacy rules, asserted.

**Open**

- Nothing has been run: this machine has no Node, no Docker and no Supabase CLI.
  First action of M2 is `supabase db reset` + `supabase test db` and fixing the fallout.

---

## M2 — `/request`, `/r/[token]`, requester SMS

1. Scaffold Next.js 15 + TypeScript + Tailwind + shadcn/ui + next-intl (locale segment,
   `en` default, `es` prefixed). Wire `messages/{en,es}.json`.
2. `/request` as one question per screen, state held in `sessionStorage` so a dropped connection
   does not lose the form:
   - 911 gate → GPS capture with live accuracy → Mapbox pin fallback → paste coordinates /
     Google Maps link / what3words → photos → vehicle → how stuck → land type → name + phone →
     waiver + rules.
   - Photos: canvas downscale to ~1600 px, re-encode to JPEG (which drops EXIF), 3 max.
   - Submit posts once, idempotently, to a server action.
3. `create_request()` RPC: rate-limit by phone and IP, blocklist check, insert, mint the token,
   queue the requester SMS. Everything in one transaction.
4. Photo upload through server-minted signed upload URLs; move `incoming/<draft>` →
   `<request_id>/` on submit.
5. `/r/[token]` rendering `get_request_by_token()`: timeline, live-ish polling, Cancel,
   Mark recovered, thank-you note.
6. SMS sender: drain `sms_messages` where `state = 'queued'`, render the template in the
   recipient's locale, send through Twilio, honour `SMS_DRY_RUN`.
7. `/terms`, `/waiver`, `/privacy` from the `waivers` table with the REVIEW WITH LAWYER banner.

**Done when** a request submitted on a phone produces a text with a working status link.

---

## M3 — responder signup, dispatch engine, inbound webhook, tests

1. `/join`: phone OTP, name, home address → Mapbox geocode, radius, equipment, vehicle, hours,
   waiver. Lands as `pending`.
2. `/me`: active/paused toggle, current job, history, stats.
3. **`app.advance_dispatch()`** — the one function that owns every transition:
   start → ring 1 → ring 2 → ring 3 → unmatched → expired, and accept / decline / cancel /
   on-site / recovered. Candidate selection is `ST_DWithin` on `home_location`, intersected with
   the volunteer's own radius, `equipment @> required_equipment`, approved + active + opted in,
   not already dispatched, capped at `dispatch.max_per_ring`, ordered by distance.
   Accept takes `select … for update` on the request row, so a second `1` reply loses and gets
   "already covered".
4. `dispatch-tick` Edge Function + `pg_cron` every 60 s. The function calls the SQL and sends
   whatever landed in the outbox; it holds no logic.
5. `/api/twilio/inbound`: verify the Twilio signature, match the sender to a responder and their
   most recent open dispatch, handle `1` / `2` / `YES` / `SI` / `NO` / `STOP`, and reply usefully
   to anything else.
6. pgTAP unit tests for the state machine: ring escalation timing, double accept, accept after
   cancel, cancel mid-dispatch, expiry, STOP mid-ring, a responder outside their own radius.

**Done when** two phones can race for the same job and exactly one wins.

---

## M4 — `/board`, `/post/[id]`, `/admin`

1. `/board` from `board_requests()`: blurred pins, no names, no phones, live counts, filterable
   by county. Works logged out.
2. `/post/[id]`: the Facebook post text the group admins already require, with a Copy button, the
   `/r` link, and the `#### Recovered ####` variant once closed. No API posting — ever.
3. Admin intake form: create a request from a pasted Facebook post, `location_source =
   'admin_intake'`.
4. `/admin`: live Mapbox map of open requests + volunteers, queue with SLA timers, manual dispatch
   and reassign, approve/reject/ban volunteers, edit waiver versions and `pro_options`, audit log.

---

## M5 — PWA, i18n pass, README, deploy

1. Manifest, maskable icons, installable, offline shell that still shows "call 911" and the last
   known status page.
2. Full i18n sweep: a CI check that `en.json` and `es.json` have identical key sets, and a native
   read-through of the Spanish. No machine-translated leftovers.
3. Bright-sun pass: contrast, 48 px tap targets, no hover-only affordances, test on a mid-range
   Android.
4. Slow-network pass: throttle to 2G, confirm the form still submits and the status page still
   renders.
5. README final, `.env.example` final, deploy to Vercel, point Twilio at production, schedule the
   cron job, run `supabase test db` against the live schema.

---

## Decisions taken without asking (reverse any of these by saying so)

| Decision | Why |
|---|---|
| Own repo at `txrecover/` | the parent folder holds a dozen unrelated projects |
| Requesters stay anonymous | "nobody installs anything" — the token is the credential |
| `/board` keeps the blurred pin even after acceptance | publishing a stranded stranger's exact address felt worse than the spec's convenience; it is a one-line setting flip |
| One winner per request | matches "first to reply wins"; the schema already allows assist dispatches later |
| Admin reads of private columns go through an RPC | Supabase gives admins the same `authenticated` DB role as volunteers, so column grants cannot tell them apart |
| SMS copy lives in TypeScript, not SQL | the state machine queues a template key and params; the sender renders EN or ES |
| US-only E.164 phone format | the two Facebook groups are Texas-only |
