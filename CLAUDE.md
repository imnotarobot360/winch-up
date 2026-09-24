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
- **`.env.example` is checked against what the code reads, both directions.** It used to
  document `TWILIO_WEBHOOK_SECRET` and `ADMIN_ALERT_PHONES`; neither is read anywhere, and an
  owner following the guide would have believed the webhook was secured by the first and admins
  paged by the second. Neither was true. `npm run env:check` fails the build on drift now.
- **Nothing reaches the error tracker unscrubbed, and session replay stays off.** A crash here
  happens while somebody is stuck, which is when their phone number and coordinates are closest
  to the exception. `src/lib/observability/scrub.ts` redacts them plus the `/r/<token>` recovery
  link, and has eighteen tests. The path rules that redact `/r/<token>` run in `scrubText`, so
  **every** string gets them — they used to live in `scrubUrl`, which `scrubDeep` calls only for a
  key named `url`, and a token in an error message went out in plain text past a green test suite.
  Never move a redaction rule onto a path that depends on what Sentry happened to label a field.
  The Sentry browser SDK is imported **dynamically** on purpose: a static import cost +61 kB on
  every page, which the request wizard cannot afford.
- **`/api/health` is unauthenticated and must stay that way.** An uptime checker cannot hold a
  secret. That is only safe because `system_health_summary()` returns counts and ages — a test
  pins the exact key set. Adding anything about a person or a place turns a status page into a
  feed of who is stuck and where.
- **The demo seed refuses to run against production, and production is the default.**
  `deploy.environment` says what a database is, and anything unmarked counts as production.
  `scripts/local-stack/mark-local.sql` is the only way out, and there is deliberately no file
  that sets it back. Phase 15's rule is "never send test recovery alerts to real community
  members", and it used to be a comment.
- **Deleting an account scrubs the columns beside the foreign key, not just the key.** A
  `BEFORE DELETE` trigger on `auth.users` blanks phone, name, exact pin, home location and shared
  position, and cancels any live recovery. This was a real finding: the FKs were doing their job
  and the identifying data was never in them. Anything new that stores a phone, a name or a
  position must be added to `app.scrub_request` / `app.scrub_responder` and to
  `security_test.sql`.
- **Closed recoveries expire.** `privacy.request_retention_days` (default 180) scrubs the phone
  and exact pin through the same code path, called from `/api/sms/drain`. Zero turns it off
  rather than scrubbing everything, which is the safer way round for a setting somebody clears.
- **`scripts/check-claims.mjs` fails the build on copy that overclaims.** No string may promise
  emergency rescue, guaranteed help or location tracking, because none of the three is
  implemented. A match must be fixed or added to `REVIEWED` with a reason — that list is the
  point where somebody has to think about it.
- **Notification producers are triggers, never calls added to existing functions.** Every event
  worth telling somebody about is already written to `request_events`, `request_messages` or
  `community_comments`, so `app.notify_on_*` triggers read those. `advance_dispatch()` is not
  touched and must stay that way — notifications are not dispatch's job.
- **Notifications do not send SMS for anything the dispatch path already texts about.** A
  delivery with no `sms_template` param is recorded as `suppressed` with a reason. Email and push
  are not built and say so in `last_error` rather than vanishing.
- **Anything in the header runs on public pages.** `NotificationBell` checks for a session before
  calling `my_notifications`, because that RPC is granted only to `authenticated` and calling it
  signed out logs a console error on every public page. The E2E suite fails a page that logs
  console errors, which is how this was caught.
- **`supabase/tests/schema_audit_test.sql` is a property test over the whole catalogue.** Every
  table has RLS, every foreign key has an index, every geography column has a GiST index, every
  function pins `search_path`, every reference to `auth.users` has an ON DELETE, and `anon` can
  execute exactly four security definer functions — named, so a fifth fails the suite. A new table
  that skips one of these fails here rather than in a year.
- **One open request per account is a partial unique index, not a check in a function.** The
  application check in `create_request` reads then writes, which two concurrent submits both pass.
  `create_request` now catches that one constraint by name and hands back the request that won.
- **Ads cannot reach anything urgent, and it is the enum that stops them.** `ad_surface` has
  three values — community feed, trails, guides — and none of them is a request, a live recovery
  or a message thread. `app.ad_slot_allowed()` additionally refuses the two resource guides that
  are emergency guidance (`stuck`, `safety`). There is no TypeScript copy of that rule: the
  `AdSlot` component mounts everywhere and asks the database, so there is one place to change.
- **Nothing in the dispatch path may ever read an advertising table.** A test reads the source of
  `app.candidates()`, `advance_dispatch()`, `app.decline_dispatch()` and
  `admin_manual_dispatch()` and fails if any of them so much as names one. Nobody buys priority.
- **`ad_daily_stats` has no column that could identify a person** and must not grow one. That is
  the whole privacy position of the ad system — counts per creative per surface per day, belonging
  to nobody — and a test asserts the exact column list. IP is used for rate limiting in
  `/api/ads/event` and never stored.
- **Approval attaches to the words, not the row.** Editing an approved creative or business sends
  it straight back to pending and clears the verification note. Otherwise "approve the shop, then
  rename it to a tow company" is a two-step way past review.
- **The resources section is content, not a CMS.** The six guides live in `messages/{en,es}.json`
  and are rendered from `src/lib/resources.ts`. `check-messages.mjs` walks arrays **by index**, so
  an English checklist of seven items and a Spanish one of five fails the build — which matters
  when the two missing lines are the ones about what never to pull from. Move it to a table only
  if the owner needs to edit without deploying, and version it like the waiver if that happens.
- **A trail cannot claim to be open without naming a source.** `trails_access_needs_a_source`
  and `trails_published_is_verified` are CHECK constraints, not form validation, because the spec
  line they implement ("do not assume that a trail is open or legally accessible without reliable
  supporting information") is about somebody getting a trespassing charge or finding a locked gate
  forty miles out. The directory ships **empty** and is filled in by hand at `/admin/trails`;
  never seed it from a model's memory of Texas trails.
- **Trail listings and condition reports are different tables on purpose.** `trails` is what an
  admin checked; `trail_conditions` is what a member saw, always dated, and dropped from the page
  after 45 days. They are never rendered as the same kind of statement.
- **The community feed is members-only, and `/board` is not.** `/board` is the public surface and
  is deliberately thin — no names, no phones, a blurred pin. `/community` carries display names and
  conversation and is behind an account, `noindex`, and RPCs granted only to `authenticated`.
  `contains_contact_info()` **does** apply to posts and comments: this is the surface where a tow
  company would post its number.
- **Moderation lives at `/moderation`, not under `/admin`.** The admin shell gates on
  `role = 'admin'` and its tabs lead to volunteer phone numbers and the waiver. A moderator can
  hide content and nothing else; `app.is_moderator()` is the gate, and there is a test proving a
  moderator is refused at `admin_list_responders()`.
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
- **Recovery SMS is off at `app.queue_sms`, which is the only writer to the outbox.**
  `sms.outbound_enabled` ships `false`; push and in-app carry recoveries now. A suppressed
  message still gets a row — "why did nobody get told" needs an answer — but with the phone
  redacted, the params dropped and a terminal state the drain cannot see, so turning the switch
  back on does not release a backlog of texts about recoveries that finished weeks ago. Phone OTP
  is a different path entirely and is unaffected. Do not add a second outbox writer.
- **The scrub reaches `sms_messages.params`, and `scrub_responder` reaches the outbox at all.**
  Both were missing until 2026-09-23. `responder.assigned` params hold the requester's phone,
  their name and the pin to five decimals, so redacting `to_phone` and leaving `params` meant
  account deletion did not delete it. And `scrub_responder` never touched `sms_messages`, so a
  volunteer's number survived their own deletion unless a stranger later deleted theirs. Anything
  new that puts a phone, a name or a position in a jsonb column belongs in both functions.
- **Realtime is a broadcast, never `postgres_changes`, and `request_messages` stays shut.**
  That table has no policy and no grant to `authenticated` — it is served only through
  `request_thread()`, which returns a first name instead of a user id. A `postgres_changes`
  subscription therefore connects, reports SUBSCRIBED and delivers nothing, forever, which looks
  exactly like a working feature. Granting SELECT to fix that hands every participant the
  `sender_user_id` of everyone else. The database sends a nudge carrying only the request id,
  authorised by `app.is_request_participant()`, and the content is re-read through the RPC. The
  fifteen-second poll underneath is the floor and is not optional: the socket path cannot be
  tested against the local stack, which has no realtime server. Production DOES have the realtime
  schema -- 20260923002200's guarded block created `recovery_broadcast_listen` there rather than
  skipping -- so the authorisation half is live and only the end-to-end socket delivery is still
  unproven.
- **Every chat message carries an idempotency key minted by the browser before the first
  attempt.** A retry over one bar of signal cannot tell whether the first attempt landed, and both
  obvious answers are wrong. `request_messages_sender_client_idx` makes the second row
  impossible. The duplicate check is answered *before* the rate limit (the first attempt paid for
  it) and *before* the closed check (a message written while the recovery was live did happen, and
  answering `closed` would leave the phone retrying it forever).
- **`my_responder_profile()` resolves `current_job` through `recovery_participants`, not
  `accepted_responder_id`.** The dashboard renders the group chat and the arrival controls inside
  that card, so keying it on the lead meant a second helper was accepted onto a recovery and then
  had no route back to it. It returns ONE job, with the member's own lead job as the tie-break.
- **A team only forms if all three layers allow it.** `app.assign_responder` must accept a second
  helper, `get_request_by_token` must keep returning outstanding offers after the first
  acceptance, and the status page must keep rendering them. All three were gated on
  `accepted_responder_id is null` and fixing any one alone leaves the feature broken while
  looking fixed. An outstanding offer now survives an acceptance and is stood down when the
  recovery ends, by a trigger rather than by a line in each function that can end one.
- **pgTAP suites that build a team by inserting `recovery_participants` prove nothing about
  whether anyone can join one.** That is how the above survived a phase with 686 passing
  assertions. `e2e/recovery-team.spec.ts` drives four real accounts through four sign-in screens
  for exactly this reason, and it costs the local per-IP request budget — see
  `scripts/local-stack/README.md`.
- **A field an RPC has only just started returning is OPTIONAL in its TypeScript type.** The app
  deploys on a push to main and the migrations go across by hand, so there is always a window
  where the frontend is ahead of the schema. `data.team.length` on a database without
  20260923001600 is a TypeError on the one page a stranded driver is watching — verified by
  pointing a build at the older RPC and loading `/r/<token>`: `Cannot read properties of
  undefined`, blank page. Type it `field?:`, read it through a `?? []`, and the same window
  costs a missing panel instead of a dead page.
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
| 7 Messaging | done — one thread per request, requester and accepted volunteer only |
| 8 Community | done — feed, comments, reactions, blocking, reports, moderation queue. Groups, events and photo attachments deferred |
| 11 Super admin | done in part — admin MFA, system health, the `moderator` role now has powers |
| 13 Notifications | done — in-app inbox, producers as triggers, retry, dedupe, delivery log, consent and priority |
| 15 QA | done — the whole recovery lifecycle as one integration suite, error conditions, a navigation crawl, four viewports across Chromium and WebKit |
| 9 Trails & resources | done — trail directory with sourced access claims, condition reports, saved trails, member submissions; plus six public bilingual resource guides |
| 10 Advertising | mostly done — business accounts, campaigns, per-advert approval, labelled serving, real counting. **Stripe is not wired**: it needs the owner's account and keys |
| 12 Database & backend | done — schema audited and the findings fixed; the entities the spec names all exist |
| 14 Security, privacy & safety | done — full review in `docs/security-review.md`; account deletion actually deletes now, retention exists, a claims check guards the copy |
| 16 Deployment & production readiness | done — `/api/health`, CI on every push, env drift check, `docs/production-readiness.md`. What is left needs the owner's accounts, not code |
| Universal membership | done — every member can ask for help and offer it; no separate volunteer account, no approval gate, the requester picks from offers |
| Recovery teams & group chat | **done and live** (2026-09-24) — `recovery_participants`, one thread per recovery for the whole team, per-participant unread and mute, notification settings screen, recovery SMS switched off, an offline send queue, Realtime broadcast over a polling floor. All 26 migrations verified applied in production |

**Proven working in production**, not just built: a signed-in person files a request, the tick
escalates it through all three rings, it reaches `unmatched` with nobody available, and the public
board shows it with no phone, no name and a blurred pin.

**Not launched.** Three things gate that and none are code: Twilio + A2P 10DLC registration, at
least one approved volunteer (there are none), and a lawyer reading /terms, /waiver and /privacy.

## Tests

Four layers. Run all of them before claiming anything works.

```
npm run verify      typecheck + lint + unit tests + build. Run this before pushing.
npm test            128 unit + component tests (vitest)
npm run test:e2e    188 Playwright tests — android, iphone, tablet, desktop
supabase test db    732 pgTAP assertions across sixteen suites
```

`prebuild` runs four guards -- the i18n check, the contact-info parity check, the claims check
and the env check -- all plain node scripts with no runtime of their own. The test suite used to run there too, which meant any problem with the test
environment on Vercel blocked every deploy, and one did. A deploy should not be hostage to a test
runner; run `npm run verify` yourself instead, or wire it into CI.

Two things are generated rather than written: `supabase/tests/contact_info_parity_test.sql` comes
from `src/lib/__fixtures__/contact-info-cases.json` via `scripts/gen-contact-info-parity.mjs`,
so the SQL and TypeScript twins are tested against identical cases. Edit the fixtures, regenerate,
and the build gate's `--check` catches you if you forget.

E2E runs against `next build && next start`, not `next dev`, with `workers: 2`. Both are
explained in `playwright.config.ts` and both were learned the hard way.

Four projects: android and desktop on Chromium, iphone and tablet on real WebKit
(`npx playwright install webkit` once). WebKit is not decoration — it found two failures the
Chromium run did not, both of them in the tests rather than the product. Playwright's `fill()`
clears a sibling field on WebKit, so forms are typed with `pressSequentially`; and reading a
page before its client component resolves looks exactly like a blank-page bug.

`supabase/tests/lifecycle_test.sql` is the integration suite: one recovery from an account that
does not exist yet to a thank-you note, in order, through the functions the app actually calls.
Every other suite tests one thing in isolation, and in a dispatcher the sequence is the product.

The suites assume a database built the documented way: every migration in order, then
`supabase/seed.sql` and `supabase/seeds/demo.sql`. Five of them fail on migrations alone. Two
suites (community, trails) clear the rows they count at the top of their transaction, because
counting whatever happens to be in the database is how a test starts passing or failing on
yesterday's clicking about.

`node scripts/local-stack/rebuild.mjs` is that documented way, and it is worth actually running
now and then rather than carrying one database forward for weeks. It found two things the day it
was written: the migration history had stopped replaying at all (two `create or replace`
statements that change a return type, which Postgres refuses — see `DROPS_BEFORE` in the script),
and `privacy_rls_test` had come to depend on dispatch rows that only exist once somebody has run
the tick. That suite passed for weeks and failed the first time anybody built from scratch, on
the one assertion that would have gone quiet if the volunteer feed genuinely broke. It creates
its own invitation now.

Operational procedures are in `docs/runbook.md`. Keep it current: it is written for whoever is
holding the phone at 11pm, not for whoever wrote the code.

## Standing assumptions (change these when the owner decides otherwise, do not guess)

1. The repo root is `txrecover/`, its own git repo, because the parent folder holds unrelated
   projects.
2. ~~Requesters are never authenticated.~~ **Changed 2026-09-21 by the owner:** a request now
   requires an account. The `public_token` is still how the status page is reached — an account
   says who filed it, not who may read it.
3. Phone numbers are stored E.164, US only (`^\+1[0-9]{10}$`).
4. ~~One winning responder per request.~~ **Changed 2026-09-23:** a recovery is a TEAM. Any
   number of helpers can be accepted onto one, because a winch truck and a tractor turning up
   together is the normal case. `recovery_participants` is the team; `accepted_responder_id` is
   still there and still singular, maintained as the LEAD — the first helper accepted — so the
   sixty-odd places that read it keep working.

   "A double accept must be impossible" is unchanged as a rule but be exact about what it is a
   rule *about*: two people must never both believe they are the assigned lead. It never meant
   only one person may come out.
5. `/board` shows the blurred pin **even after acceptance**, controlled by the
   `board.reveal_exact_after_accept` setting (default `false`). Flip the setting if the owner wants
   the exact pin public once a volunteer is assigned.
6. Photos are uploaded through short-lived signed upload URLs minted by the server. The bucket has
   **no** anon policies.
7. Display timezone is `America/Chicago`.
