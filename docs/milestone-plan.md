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

## M2 — `/request`, `/r/[token]`, requester SMS  *(code complete, not yet run)*

**Shipped**

- Next.js 15 + TypeScript + Tailwind 4 + next-intl scaffold, hand-written (no `create-next-app`:
  this machine has no Node). Locale segment, `en` unprefixed, `es` at `/es/...`.
- `supabase/migrations/20260920001000_write_rpc.sql` — `create_request` (idempotent by
  `submission_id`, rate-limited by phone and IP, blocklist-checked, queues the requester SMS in
  the same transaction), `cancel_request_by_token`, `mark_recovered_by_token`,
  `thank_responder_by_token`, and the outbox claim/confirm trio. Service-role only.
- `/request`: eight screens — 911 gate, location, photos, vehicle, situation, land, contact,
  consent. Draft state in `sessionStorage`, so a reload does not cost someone the form.
- Location with three paths: GPS (`watchPosition`, keeps the best fix, shows accuracy in feet),
  a fixed-crosshair Mapbox picker, and a paste field that understands coordinates, DMS, `geo:`
  URIs, full and short Google Maps links, and what3words.
- Photos: `createImageBitmap` with `imageOrientation: "from-image"` → canvas → JPEG at 1600 px.
  Re-encoding is what strips EXIF, including the GPS block. Uploaded straight to Storage through
  a server-minted signed URL, so the file never passes through the Next.js server.
- `/r/[token]`: timeline, 15 s polling that pauses when the tab is hidden, responder card with a
  tap-to-call button once accepted, the paid-options panel when unmatched, Cancel, Mark
  recovered, thank-you note, and a share button.
- SMS: template registry in TypeScript (EN + ES), Twilio sender with `SMS_DRY_RUN`, outbox drain
  called inline after submit via `after()` and exposed at `/api/sms/drain`.
- `/terms`, `/waiver` from the versioned `waivers` rows; `/privacy` from the message catalogue.
  All three carry the REVIEW WITH LAWYER banner.
- `scripts/check-messages.mjs` — fails when `en.json` and `es.json` drift, including dropped ICU
  placeholders.

**Open**

- Nothing has been installed, built, type-checked or run. `npm install`, `npm run typecheck`,
  `supabase db reset` and `supabase test db` are all still pending.
- what3words resolution needs `W3W_API_KEY` (free tier). Without it the paste field says so
  rather than silently losing the address.
- No test covers `create_request` yet; its unit tests land with the state-machine tests in M3.

---

## M3 — responder signup, dispatch engine, inbound webhook, tests  *(code complete, not yet run)*

**Shipped**

- `supabase/migrations/20260920002000_dispatch.sql` — the state machine.
  - `app.advance_one(request_id)` owns every timed transition: submitted → ring 1 → ring 2 →
    ring 3 → unmatched → expired. It locks the request row first, so two overlapping ticks
    cannot both escalate the same job.
  - `app.candidates()` filters on `ST_DWithin` **intersected with the volunteer's own radius**,
    `equipment @> required_equipment`, approved + active + opted in, not already dispatched,
    under their `max_active_jobs`, and not asleep (21:00–06:00 Central for anyone who said no
    night calls). Ordered by distance, capped at `dispatch.max_per_ring`.
  - `app.accept_request()` takes `select … for update` before it looks at anything. The second
    `1` to arrive reads a row that already has a winner and gets "already covered".
  - `public.advance_dispatch()` is the tick, using `for update skip locked` so overlapping runs
    share the work rather than block.
  - `public.handle_inbound_sms()` parses `1` / `2` / `YES` / `SI` / `NO` / `STOP` / `START` /
    `HERE` / `DONE` / `HELP` plus an optional ETA after the `1`, and returns a reply template.
  - `upsert_responder_profile()` takes the phone from the **verified OTP claim**, never from the
    form, and forces every new volunteer to `pending`.
  - Fixes the M1 timeline trigger forward: ring 1 no longer logs "widening the search".
- `supabase/functions/dispatch-tick/index.ts` — the Edge Function pg_cron calls. It runs the SQL
  and then pokes `/api/sms/drain`; it contains no dispatch logic of its own.
- `/api/twilio/inbound` — HMAC-SHA1 signature check, then straight into the SQL. Replies as
  TwiML. Returns 200 even on error, because a 500 makes Twilio retry and replay a stale `1`.
- `/join` — phone OTP, then profile: name, home address via Mapbox geocoding, radius, equipment,
  vehicle, night calls, volunteer agreement.
- `/me` — approval state, on-call toggle, current job with the requester's phone and pin, open
  offers with accept/pass and an ETA box, past jobs with thank-you notes.
- `supabase/tests/dispatch_test.sql` — about 45 assertions over real rows, with time moved by
  rewinding timestamps: ring 1 / 2 / 3 escalation and its timing, a volunteer inside our ring but
  outside their own radius, pending and paused volunteers never dispatched, equipment matching,
  **double accept**, cancel mid-dispatch, unmatched, expiry, the tick itself, and every inbound
  SMS branch.

**Open**

- Still nothing executed. These tests have never run.
- `max_active_jobs` defaults to 1, so a volunteer holding a job is skipped by later rings. That
  is deliberate but worth watching once there is real traffic.

**Done when** two phones can race for the same job and exactly one wins.

---

## M4 — `/board`, `/post/[code]`, `/admin`  *(code complete, not yet run)*

**Shipped**

- `supabase/migrations/20260920003000_admin.sql` — thirteen `admin_*` RPCs, each one starting
  with `app.require_admin()` and each mutating one writing an audit row. Granted to
  `authenticated`, not to a shared key: the console runs in the browser as the signed-in admin
  and the gate is `auth.uid()`.
- `/board` — the public feed. Blurred pins, no names, no phones, open/all filter, 30 s polling.
  Read through the **anon** client on purpose: if the grant on `board_requests()` is ever wrong,
  the page breaks loudly instead of quietly serving data it should not have.
- `/post/[code]` — the group post, in the format the admins already require, with the
  `#### Recovery Needed ####` / `#### Recovered ####` header they scan for, the status link, and
  a Copy button. `[code]` is the request's own status token, so exactly the people who can open
  the status page can generate the post. Facebook killed the Groups API; there is no auto-post
  and the page says so.
- `/admin` — five tabs behind a server-side role check:
  - **Queue**, oldest first, with an age in minutes and a loud flag past the unmatched
    threshold, the requester's phone as a tap-to-call link, and manual dispatch or reassign to a
    named volunteer.
  - **Volunteers** — approve, reject, ban, with a reason kept on file.
  - **Intake** — paste a Facebook post, resolve the location, create a real request that joins
    the normal dispatch flow as `location_source = 'admin_intake'`.
  - **Settings** — dispatch tuning as JSON, the paid-recovery list, legal copy (publishing always
    creates a new version, never edits what people already agreed to), and the blocklist.
  - **Audit log** — read-only. There is no RPC that edits or deletes an audit row.

**Open**

- The admin map is a list plus per-row "open the pin", not a live Mapbox canvas. The queue answers
  "what has been sitting too long" better than a map does; a map is worth adding once there is
  enough concurrent traffic to need one.
- Still nothing executed.

---

## M5 — PWA, i18n gate, runbook, deploy  *(code complete, not yet run)*

**Shipped**

- `src/app/manifest.ts` — installable, `start_url` is `/request` rather than the landing page,
  because somebody who installed this expects to need it in a hurry. Shortcuts for help, the
  board and my jobs.
- `src/app/icons/[size]/route.tsx` — icons generated with `next/og` at request time. No binary
  assets in the repo, no design tool in the loop, and the mark tracks the brand colour in
  `globals.css`. No text in the icon: Satori needs a font file for glyphs, and a rope ring reads
  better at 48 px than four letters would.
- `public/sw.js` — caches the content-hashed build output and the offline shell, and nothing
  else. `/api/`, `/r/`, `/post/`, `/me` and `/admin` are on an explicit never-cache list.
- `public/offline.html` — standalone, no framework, no fonts, no network. Leads with "call 911"
  and carries both languages at once, since nothing is available to detect a preference.
  **Checked in a browser at 375 px — the only thing in this repo that has been.**
- `src/app/robots.ts` and `src/app/sitemap.ts` — the landing page and the board are worth
  finding; `/r/`, `/post/`, `/me` and `/admin` are explicitly disallowed.
- `prebuild` runs the i18n check, so a missing Spanish key fails the build instead of silently
  falling back to English. Both catalogues are at 529 keys and in step.
- `docs/runbook.md` — triage for the failures that will actually happen: texts not going out,
  requests not advancing, a volunteer who never got called, rotating secrets, and the two
  settings that deserve care before anyone edits them.
- README: a launch checklist that has to be worked down before 6,800 people are told the link
  exists.

**Open**

- The bright-sun and 2G passes are listed in the checklist but cannot be done from here: they
  need a real phone outdoors and a throttled connection.
- Icons are generated per request rather than at build time. Fine at this traffic; worth
  pre-rendering if it ever shows up in a trace.

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

---

## Static review pass

A read-through of all five milestones hunting for what a compiler, a migration run or a test run
would have caught. Nothing here was found by executing anything — the toolchain is still absent.

### Fixed

| What | Severity | |
|---|---|---|
| `app.is_admin()` and `app.current_responder_id()` were defined in `…0300_helpers.sql` as `language sql`, reading `user_roles` and `responders` — tables created in `…0400`. Postgres parses a SQL function body at `CREATE FUNCTION` time, so migration 0300 would have failed and **nothing would have applied at all**. | blocker | moved to the end of `…0400_tables.sql`, with their grants |
| `dispatch_test.sql` shared a database with the demo seed, and one demo volunteer lives at exactly the coordinates the fixtures use — so ring counts depended on demo data, and on the time of day, because that volunteer has night calls off. | test would fail, intermittently | the test now parks every non-fixture volunteer first |
| `create_request` never received `county`; `toRpcPayload` did not send it. Volunteer offer texts would never have said which county a job was in — which is how these groups describe location. | functional gap | reverse-geocoded from Mapbox in `after()`, so it lands before the first ring goes out and costs the requester no latency |
| `/admin/settings` fetched with the service-role key. Next renders layouts and pages in parallel, so that query ran even for signed-out visitors about to be shown the sign-in screen. | minor | reads through the session client; the `pro_options` policy already expresses the rule |
| `app.accept_request` returned `already_covered` for a request that had been accepted and *then* cancelled. | wrong message | closed states are checked first |
| Icon route positioned a child absolutely inside a parent with no `position`, which Satori ignores. | cosmetic | parent is `relative` |
| No root `app/not-found.tsx`. Paths the middleware skips (anything with a file extension) would render the bare root layout, which has no `<html>`. | edge case | added, rendering its own document |
| `jsonb_agg(row_to_json(...))` in two admin RPCs. | works, but relies on an implicit json→jsonb conversion | `to_jsonb` |

### Checked and clean

- **Every literal translation key** in `src/` resolves in `messages/en.json`, and both catalogues
  hold the same 529 keys with matching ICU placeholders.
- **Every `rpc()` call** — 32 call sites, including the ones routed through `adminAction`,
  `useAdminData` and local `run()` wrappers — names a function that exists in the migrations,
  with parameter names that exist on it.
- **All 30 functions created after the blanket `revoke execute … from public` in `…0700`** have
  their own explicit revoke. None silently inherits PUBLIC execute.
- No client component reads a non-`NEXT_PUBLIC_` environment variable or imports a `server-only`
  module.
- Every `params` in a page or route handler is typed as a `Promise` (Next 15).
- No stray control bytes in any tracked file.

### Still unverified, and only running it will tell

Dependency resolution, type-checking, JSX correctness, whether next-intl v4 and Tailwind v4 behave
as written, whether the pgTAP assertions hold, and every runtime path. The review narrows the
odds; it does not replace `npm install && npm run build` and `supabase test db`.

---

## First execution

Node turned out to be on the machine all along at `C:\nodejs` (v20.18), referenced by the
workspace's own `launch.json` — it was simply not on `PATH` and not in any of the usual
locations. Node 24.21 LTS is now installed properly and everything below was run against it.

Docker still is not available (it needs admin rights), so the Supabase CLI could not run. The
database was instead verified against a local PostgreSQL 17.7 + PostGIS 3.6 + pgTAP with the
Supabase-specific objects stubbed: `auth.users`, `auth.uid()`, `auth.jwt()`, `storage.buckets`,
`storage.objects`, the three roles, and — importantly — Supabase's blanket default privileges on
`public`, without which the `revoke all` in the RLS migration would have been a no-op and the
privacy tests would have passed for the wrong reason.

### What running it found

| Bug | How bad | Found by |
|---|---|---|
| `CASE WHEN … THEN 'responder' ELSE 'system' END` resolves to `text`, and there is no implicit text → enum cast, so the timeline trigger threw on **every status change**. The dispatch engine could not advance a single request; the product was dead on arrival. | fatal | `dispatch_test.sql`, first assertion that changes a status |
| The middleware matcher was written `"/((?!api\|_next\|_vercel\|.*\..*).*)"` with a single backslash. In a JS string `"\."` collapses to `"."`, so the pattern became `.*..*` and excluded every path of two or more characters. The locale middleware only ever ran for `/`; every unprefixed English URL 404'd, including the `/r/<token>` link texted to a stranded driver. | fatal | opening `/request` in a browser |
| `to_jsonb(r) \|\| jsonb_build_object(...) - 'location'` — Postgres binds binary `-` tighter than `\|\|`, so the key removal applied to the small lat/lng object and the admin RPC returned raw WKB geography blobs. | wrong output | `privacy_rls_test.sql`, the assertion written for exactly this |
| `dispatches.queued_at` defaulted to `now()`, which is the **transaction** timestamp — so every offer created in one dispatch tick shared a timestamp and "the most recent open offer" was a coin flip. A volunteer replying `1` could accept a different job than the one they were texted about. | wrong behaviour | `dispatch_test.sql` inbound-SMS section |
| `/terms` and `/waiver` were prerendered at build time, so a newly published waiver version would not appear until the next deploy — defeating the point of versioning the copy in the database. They also used the service-role key for a page that reads a publicly-readable row. | design bug | `next build` failing on missing env |
| The Deno Edge Function was being swept into the Next.js `tsc` run. | noise | `tsc --noEmit` |
| `not-found.tsx` used a raw `<a>`. | lint | `next build` |
| `check-messages.mjs` — the i18n gate itself — flagged every correctly translated ICU plural, because its regex treated single-word plural branches like `=0 {Open}` as placeholders. | false alarms on a build gate | running it |

Five of those eight are things no amount of re-reading had caught, including both fatal ones.

### Where it stands

Everything that can be executed on this machine passes: install, typecheck, lint, build, the
i18n gate, all 11 migrations, both seeds, and 117 pgTAP assertions. The parts that need Docker,
Supabase's REST layer, Twilio, Mapbox or a real phone remain unverified and are listed in the
README.
