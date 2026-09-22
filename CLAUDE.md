# Winch Up — project guide for Claude sessions

**Working name.** The product name lives in exactly one place: `APP_NAME` in `src/config/app.ts`.
Never hard-code the name anywhere else (UI strings use the i18n key `app.name`, which reads that constant).

## What this is

A dispatcher that replaces the Facebook-group workflow of *Texas Off-Road Recovery* (6.8K members)
and *Houston Area Off-Road Recovery*.

Today: a stuck driver posts a map pin + photo in the group, volunteers with 4x4s/winches/tractors
comment or call, someone drives out, and the poster edits the post to `#### Recovered ####`.

With Winch Up: a stuck driver fills in one request page, the system texts the nearest matching
volunteers, the first to reply wins, the requester gets a name + ETA, and a status page closes the
loop. **Nobody installs anything.**

## Users

- **Requesters** — stuck, on a phone, weak signal, possibly panicking. **They now need an account**
  (owner's decision, 2026-09-21): `create_request` refuses without one. They still reach their
  status page through an unguessable link (`/r/[token]`) rather than by signing in, because by the
  time help arrives they may be on somebody else's phone. Optimize every decision for them.
- **Responders** — volunteers with equipment. Phone OTP auth. Must be approved by an admin before
  they are dispatched to.
- **Admins** — the owner + the Facebook group admins.

## Stack (fixed — do not re-litigate)

| Concern | Choice |
|---|---|
| App | Next.js App Router + TypeScript + Tailwind + shadcn/ui |
| Data | Supabase Postgres + PostGIS, RLS on **every** table, migrations committed in `/supabase` |
| Auth | Supabase Auth: **email/password** (verification + reset) **and phone OTP**, both kept. Google/Apple deferred. |
| Files | Supabase Storage (private bucket, signed URLs only) |
| SMS | Twilio Programmable SMS — outbound + inbound webhook |
| Maps | Mapbox GL (pin drag + admin map) |
| i18n | `next-intl`, **English + Spanish, both from day one** |
| PWA | manifest, icons, installable, offline shell |
| Scheduler | **Supabase `pg_cron` calling an Edge Function, every 60 s.** Not Vercel cron. |
| Hosting | Vercel, deployed from GitHub |

No other paid services without asking the owner first.

## Core flow

1. **`/request`** — one question per screen, thumb-friendly, works on 1 bar of signal.
   - 911 gate: "Is anyone hurt or in danger? Call 911. We are volunteers, not emergency services."
     Must be acknowledged (`requests.emergency_ack_at`).
   - GPS auto-capture with accuracy shown. Fallbacks: drag a pin, paste coordinates, paste a
     Google Maps link, or what3words (`requests.location_source`).
   - 1–3 photos, compressed client-side, **EXIF stripped client-side**.
   - Vehicle (type, make/model, 2WD/4WD), how stuck (mud/sand/water/ditch/rollover/mechanical),
     how deep (hubs/frame/buried), needs a tractor or second truck?, land type
     (public / off-road park / private with permission).
   - Name + phone. **The phone is never public.** It is released only to the accepting responder.
   - Waiver + rules checkboxes. Waiver text is versioned in the DB; each acceptance stores the
     waiver row id, timestamp, IP and user agent.
   - Submit → SMS the requester a link to `/r/[token]`.

2. **Dispatch** — a server-side state machine in Postgres, advanced by a job every 60 s.
   - Ring 1 = approved + active responders within **15 mi** whose equipment matches. SMS up to
     **10** of them: short summary + distance + "Reply 1 to take it, 2 to pass".
   - No acceptance after **7 min** → ring 2 (**30 mi**) → 7 min → ring 3 (**60 mi**).
   - **25 min** with no acceptance → status `unmatched`: alert admins, show the requester a
     "No volunteer yet" panel with the admin-editable paid recovery/tow list (`pro_options`).
   - First `1` reply wins, enforced by a row lock — **a double accept must be impossible**.
   - Winner gets the requester's phone, the exact pin and the photo links. The requester gets the
     responder's first name, vehicle and ETA. Everyone else gets "Already covered, thanks".
   - The inbound webhook handles `1`, `2`, `YES`, `SI`, `NO`, `STOP` and unknown replies.

3. **`/r/[token]`** — requester status page. Timeline (Sent → Notifying volunteers (N within 30 mi)
   → Accepted by Mike, ETA 40 min → On site → Recovered), "Call responder" once accepted, Cancel,
   Mark recovered (+ optional thank-you note, texted to the responder). Shareable link.

4. **`/join`** — responder signup: phone OTP, name, home location (geocoded) + radius (15/30/60 mi),
   equipment checkboxes, vehicle, hours available, active/paused toggle. New responders are
   `pending` until an admin approves them (keeps out scammers and tow companies posing as
   volunteers).

5. **`/me`** — responder dashboard: active/paused, current job, past recoveries, stats.

6. **`/board`** — public feed of open requests. No phones; pin blurred to ~1 mi. For people who
   do not want texts but want to watch it like the Facebook group.

7. **`/post/[id]`** — auto-formatted Facebook post text in the format the group admins already
   require (location, vehicle, situation, photo, `#### Recovered ####` when done) with a Copy button
   and the `/r` link. **Facebook's Groups API is gone — never try to auto-post.** Also an admin
   "intake" form to create a request from a Facebook post.

8. **`/admin`** — live map of open requests + responders, queue, manual dispatch/reassign,
   approve/ban responders, edit waiver text and the `pro_options` list, audit log.

## Rules (non-negotiable)

- **Phones and exact pins are private until acceptance.** RLS enforces it; there are tests that
  prove it (`supabase/tests/`). Any new table or column that touches contact info or coordinates
  needs a matching test.
- Rate-limit request creation per phone and per IP. Block phone numbers and URLs in public free-text
  fields (`public.contains_contact_info()` is used in CHECK constraints — use it on every new public
  text column).
- **One Postgres function owns the dispatch transitions.** Unit-test ring escalation, double accept,
  cancel mid-dispatch, and expiry.
- **Every user-facing string exists in EN and ES.** `messages/en.json` and `messages/es.json` must
  stay key-for-key identical. Spanish is not an afterthought.
- Mobile first, large tap targets, high contrast — it has to work on a 3-year-old Android in bright
  Texas sun.
- `/terms`, `/waiver`, `/privacy` exist with placeholder text clearly marked
  **"REVIEW WITH LAWYER"**.
- Commit after each milestone with a clear message. Keep `README.md` accurate: the exact manual
  setup steps (Supabase project, Twilio number + A2P 10DLC registration, Mapbox token, Vercel env
  vars) and a current `.env.example`.

## Database conventions

- Tables live in `public`. **Internal helpers live in schema `app`** so PostgREST can never reach
  them. Only deliberate RPCs go in `public`, and each one is granted to `anon`/`authenticated`
  explicitly.
- Every function is `security definer` with a pinned `set search_path`.
- PostGIS is installed in schema `extensions`. Migrations start with
  `set search_path = public, extensions;`.
- RLS is deny-by-default: `revoke all` first, then narrow grants. Sensitive columns
  (`requests.requester_phone`, `requests.location`) additionally have **column-level** privileges
  revoked, so a policy mistake alone cannot leak them.
- Requesters are anonymous. They reach their data only through token-scoped `security definer`
  RPCs — never through direct table access.
- Writes from the app go through RPCs or the service-role server client, never from the browser.
- Migrations are append-only once applied to production. Fix forward with a new migration.

## Repo layout

```
src/app/[locale]/...      routes (next-intl locale segment)
src/app/actions/          server actions — the only write path from the browser
src/app/api/              route handlers (photo signing, geo resolve, status poll, SMS drain)
src/components/           request wizard, status page, ui primitives
src/config/app.ts         APP_NAME + dispatch tuning mirrored from app_settings
src/i18n/                 next-intl routing, request config, navigation helpers
src/lib/                  supabase admin client, sms templates, geo helpers, validation
messages/{en,es}.json     every user-facing string
scripts/check-messages.mjs  CI guard: en and es must stay key-for-key identical
supabase/migrations/      numbered, committed, never edited after being applied to prod
supabase/tests/           pgTAP — RLS proofs and dispatch state-machine unit tests
supabase/functions/       Edge Functions (dispatch tick, sms sender, twilio inbound)
docs/                     decisions + runbooks
```

### Things that are easy to get wrong here

- **Write RPCs are service-role only.** `create_request`, `cancel_request_by_token`,
  `mark_recovered_by_token` and `thank_responder_by_token` are not granted to `anon`. They are
  called from server actions, because the caller supplies the IP used for rate limiting and
  stored with the waiver acceptance — that has to be a value the server derived.
- **SMS copy lives in `src/lib/sms/templates.ts`, never in SQL.** The database queues a
  `template_key` plus params; the sender renders it in the recipient's language.
- **Photos are stripped client-side.** `createImageBitmap(file, {imageOrientation: "from-image"})`
  then canvas then JPEG. The re-encode is what drops EXIF, including GPS. Never add a path that
  uploads the original file.
- **`public.contains_contact_info()` has a TypeScript twin** in `src/lib/contact-info.ts`. Change
  one, change both.
- **The service worker caches almost nothing.** `/_next/static` and the offline shell, full stop.
  `/api/`, `/r/`, `/post/`, `/me` and `/admin` are on a never-cache list, because a cached
  recovery status is a wrong recovery status. Do not "improve" this by adding pages to it.
- **`public/offline.html` has no build step.** No framework, no fonts, no network calls — it is
  shown when nothing can be fetched. Both languages are on screen at once, deliberately.
- **Admin RPCs are granted to `authenticated`, not `service_role`.** The gate is `auth.uid()` via
  `app.require_admin()`, so there is no shared key that grants admin. Every mutating admin RPC
  writes an audit row; keep that true for new ones.
- **`npm run build` runs the i18n check first** (`prebuild`). A missing Spanish key fails the
  build rather than silently falling back to English.

## Where this actually is

Built, deployed and verified in production at **https://www.winch-up.com**. The original M1–M5 are
long done. Work since then has followed the owner's 16-phase spec:

| Phase | State |
|---|---|
| 1 Audit | done — see the audit in the session log |
| 2 Brand & design system | done — dark theme, Trail Green/Recovery Orange, Bebas + Inter, icon set |
| 3 Auth & user management | done — roles, profiles, email/password, account deletion |
| 4 Vehicles & equipment | done — members register rigs; matching unions rig equipment |
| 5 Recovery requests | done — one open request per account, incident reporting + admin triage |
| 6 GPS & matching | done — matches from a shared recent position, falling back to home |
| 15 QA | partly done — unit, component and E2E suites exist; no integration tests yet |
| 7–14, 16 | not started (messaging, community, trails, ads, super admin, notifications) |

**Proven working in production**, not just built: a signed-in person files a request, the tick
escalates it through all three rings, it reaches `unmatched` with nobody available, and the public
board shows it with no phone, no name and a blurred pin.

**Not launched.** Three things gate that and none are code: Twilio + A2P 10DLC registration, at
least one approved volunteer (there are none), and a lawyer reading /terms, /waiver and /privacy.

## Tests

Four layers. Run all of them before claiming anything works.

```
npm run verify      typecheck + lint + unit tests + build. Run this before pushing.
npm test            94 unit + component tests (vitest)
npm run test:e2e    38 Playwright tests, mobile + desktop
supabase test db    227 pgTAP assertions across six suites
```

`prebuild` runs the i18n and contact-info parity checks only -- two plain node scripts with no
runtime of their own. The test suite used to run there too, which meant any problem with the test
environment on Vercel blocked every deploy, and one did. A deploy should not be hostage to a test
runner; run `npm run verify` yourself instead, or wire it into CI.

Two things are generated rather than written: `supabase/tests/contact_info_parity_test.sql` comes
from `src/lib/__fixtures__/contact-info-cases.json` via `scripts/gen-contact-info-parity.mjs`,
so the SQL and TypeScript twins are tested against identical cases. Edit the fixtures, regenerate,
and the build gate's `--check` catches you if you forget.

E2E runs against `next build && next start`, not `next dev`, with `workers: 2`. Both are
explained in `playwright.config.ts` and both were learned the hard way.

Operational procedures are in `docs/runbook.md`. Keep it current: it is written for whoever is
holding the phone at 11pm, not for whoever wrote the code.

## Standing assumptions (change these when the owner decides otherwise, do not guess)

1. The repo root is `txrecover/`, its own git repo, because the parent folder holds unrelated
   projects.
2. ~~Requesters are never authenticated.~~ **Changed 2026-09-21 by the owner:** a request now
   requires an account. The `public_token` is still how the status page is reached — an account
   says who filed it, not who may read it.
3. Phone numbers are stored E.164, US only (`^\+1[0-9]{10}$`).
4. One winning responder per request. The schema allows additional "assist" dispatches later, but
   there is only one `accepted_responder_id`.
5. `/board` shows the blurred pin **even after acceptance**, controlled by the
   `board.reveal_exact_after_accept` setting (default `false`). Flip the setting if the owner wants
   the exact pin public once a volunteer is assigned.
6. Photos are uploaded through short-lived signed upload URLs minted by the server. The bucket has
   **no** anon policies.
7. Display timezone is `America/Chicago`.
