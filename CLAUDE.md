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
- **Recovery SMS sends only the dispatch call-out, and it takes TWO settings to send anything.**
  `app.queue_sms` is still the only writer to the outbox, and it now needs
  `sms.outbound_enabled` true AND the template named in `sms.enabled_templates` -- an
  ALLOWLIST, shipping `["responder.offer", "responder.already_covered"]`. A template nobody has
  thought about is silent, which is the right default for a list whose entries mean "text a real
  person and charge for it"; a blocklist would have new notification types texting everybody the
  day they ship. Everything else -- requester status, admin pages, chat -- is push and in-app,
  because paying per message to say something already on the screen is waste. The call-out is
  different: a volunteer is not looking at the app, and on iPhone has no push at all without the
  PWA installed. Turning the master switch on alone changes nothing.
- **The old rule, unchanged, about what a suppressed row keeps.**
  `sms.outbound_enabled` ships `false`; push and in-app carry recoveries now. A suppressed
  message still gets a row — "why did nobody get told" needs an answer — but with the phone
  redacted, the params dropped and a terminal state the drain cannot see, so turning the switch
  back on does not release a backlog of texts about recoveries that finished weeks ago. Phone OTP
  is a different path entirely and is unaffected. Do not add a second outbox writer.
- **Four separate things stop an SMS, and only the first is obvious.** `sms.outbound_enabled`
  (ships false, suppresses at `app.queue_sms`), `SMS_DRY_RUN` in Vercel, A2P 10DLC registration,
  and Twilio trial-account limits. Gate three is the cruel one: without an approved campaign US
  carriers DROP the message after Twilio accepts it, so the API returns success, the outbox row
  says `sent`, and nothing arrives. `npm run sms:check` reads the campaign status from Twilio's
  API because that is the only gate a successful send cannot tell you about. docs/twilio-setup.md.
- **Phone OTP and recovery SMS are two different Twilio integrations.** OTP is Supabase Auth
  sending its own SMS with credentials held in the SUPABASE dashboard; it does not read
  `TWILIO_ACCOUNT_SID` and was never affected by switching recovery SMS off. If nobody can sign
  in by phone, that is the Supabase dashboard, not this repo.
- **`TWILIO_WEBHOOK_URL` is load-bearing.** The inbound route recomputes Twilio's HMAC over the
  exact URL Twilio signed, so http vs https, a trailing slash or a preview domain makes every
  reply 403 with nothing else wrong.
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
  deploys on a push to main. THE MIGRATIONS DO NOT. For one day -- 2026-09-30 -- the Supabase
  GitHub integration applied them about 90 seconds after a push, schema ahead of frontend, which
  is the safe order. It stopped on 2026-10-01 and has applied nothing since; it was removed on
  2026-10-03 after sitting idle through a push of fifteen migrations while still reporting a
  queued check on every commit. The CI `migrate` job replaced it and was ALSO silently doing
  nothing -- three green runs, `secrets.SUPABASE_DB_URL` arriving empty, both working steps
  skipped. It fails loudly now instead of skipping.
  So the frontend leads the schema again, which is the dangerous order and the one this rule was
  written for. Until a push is OBSERVED applying migrations, treat every deploy as frontend-first
  and apply by hand with `docs/apply-pending.sql`, then prove it with
  `docs/probe-2026-10-03.sh` rather than reading a green badge. `data.team.length` on a database without
  20260923001600 is a TypeError on the one page a stranded driver is watching — verified by
  pointing a build at the older RPC and loading `/r/<token>`: `Cannot read properties of
  undefined`, blank page. Type it `field?:`, read it through a `?? []`, and the same window
  costs a missing panel instead of a dead page.
- **Supabase Auth sends the verification and reset emails, and must keep doing so.** It mints
  those single-use tokens; `src/app/auth/callback/route.ts` does the PKCE exchange server-side
  and validates `next` against open redirects. Branding them is an SMTP setting plus a pasted
  template in the Supabase dashboard, NOT code. `src/lib/email/send.ts` deliberately sends only
  the emails Supabase has no opinion about -- welcome, and the account-security notices -- because
  hand-rolling verification tokens in application code would mean minting credentials here.
- **Emails carry exactly one image and nothing depends on it.** Mail clients block images by
  default, so the logo's `alt` is the styled wordmark -- a blocked logo degrades to the text
  header rather than a broken-image icon, and the plain-text part carries the whole message
  regardless. A test pins this at one image per template. The `src` is built from the siteUrl the
  email was rendered for, so a staging render does not point at production.
- **`help@winch-up.com` does not exist.** As of 2026-09-24 the domain has no MX, no SPF and no
  DMARC: nothing can receive there and nothing is authorised to send as it. So `EMAIL_PROVIDER`
  is unset, the driver is `none`, and a send renders the message, records it as `skipped` with a
  reason, and returns without throwing. That last part is deliberate -- a signup must not fail
  because email is unconfigured. `docs/email-setup.md` has the DNS work, which needs the owner.
- **`email_deliveries` holds no address, no subject, no body and no action URL.** The action URL
  in a verification email IS a credential, so a log of them would be worth more than the mail it
  records; the body is reproducible from the template key and locale because the copy lives in
  TypeScript. The column list is pinned by a test for the same reason `ad_daily_stats`'s is.
  The FK is `on delete set null`, so deleting an account can never be blocked by a log row and
  can never erase the evidence that mail went out either.
- **The welcome email is fired by a trigger on `auth.users.email_confirmed_at`, not by the
  callback route.** Supabase owns verification and emits no server-side event this app can
  subscribe to, and both obvious workarounds lose people: sending from `/auth/callback` misses
  anyone whose redirect dies on one bar of signal, and sending on first authenticated page load
  never fires for somebody who verifies and walks away. The null-to-timestamp transition is
  written by Supabase inside the verifying transaction and cannot be skipped. There are TWO
  triggers -- one on that update, one on insert for accounts created already-confirmed, which is
  how the local stack and seeds behave, so a single trigger would work in one environment and
  not the other.
- **Anything the drain calls over supabase-js must live in `public`.** PostgREST is configured
  `db-schemas = "public"`, so an `app.*` function is invisible to it: the call 404s forever
  and the queue fills up silently while every test passes, because pgTAP calls it directly and
  never goes through PostgREST. `claim_email_deliveries` and `record_email_result` are in
  `public`, revoked from anon and authenticated and granted only to `service_role`, exactly
  like `claim_push_deliveries`. Only `app.queue_welcome_email` stays in `app`, because a
  trigger is called by Postgres and by nothing else.
- **A queued email with no provider goes back to `queued`, never `failed`.** Somebody who
  verified before the provider was bought still gets their welcome email on the first tick after
  it is configured. Marking it failed would burn the queue silently, which is the same mistake
  the push drain avoids by leaving rows alone when VAPID is unset.
- **A name typed at signup is dropped rather than allowed to fail the signup.**
  `profiles.display_name` has a CHECK (1-60 chars, no contact info) and `app.handle_new_user`
  runs INSIDE the transaction that creates the account -- so a name containing a phone number
  would abort the INSERT into auth.users and the signup would fail with a constraint error on a
  form whose only fault was somebody typing their number in the name box. The trigger validates
  and nulls it instead. A blank display name is a blank field; a failed signup is a member who
  never joined.
- **The phone collected at signup is NOT auth.users.phone and is never treated as verified.**
  It goes in `raw_user_meta_data.phone_unverified` and only prefills /join, where the one-time
  code still has to pass before anything is written to the responder record. Setting the real
  phone field would start Supabase's own SMS confirmation on top of the email one, and an
  unverified number is worse than none here -- the requester's phone is handed to whoever takes
  their recovery, so a number nobody proved they own is a volunteer calling a stranger.
- **Verifying a phone while signed in must LINK it, not sign you in as it.** `signInWithOtp` and
  `verifyOtp({type:'sms'})` authenticate the PHONE IDENTITY, so calling them from /join for somebody
  who already had a session handed them a SECOND account: the responder profile attached to the
  phone account while their waiver signature, vehicles and requests stayed on the first. It
  looked perfect from the UI -- a code arrives, it is accepted, the profile saves. With a
  session it is `updateUser({phone})` + `verifyOtp({type:'phone_change'})`, which attaches the
  number to the CURRENT user; `signInWithOtp` stays for somebody with no session, which is a
  legitimate way back in. A number already on another account must be REFUSED (`phone_exists`,
  422) and never silently moved -- moving it is the account-takeover version of this feature.
  Neither pgTAP nor Playwright can see this: the duplicate is created above the database by the
  auth API, and the UI is identical either way. `npm run linking:check` counts `auth.users`
  across the calls, which is the only thing that shows it. Three duplicates from before the fix
  were found and deleted in production on 2026-09-30; `docs/check-accounts.sql` is the standing
  check, editor-safe because the owner's psql access does not work.
- **Nobody may remove their last way into their account, and the count that decides it comes
  from the database.** `/account/security` lets a member remove a password, a phone or a
  provider, and there is no support desk behind this product -- an account locked out is locked
  out permanently, with its recovery history and its signed waiver. `my_security_state()`
  counts the methods in the same snapshot as the facts it counts, and the screen re-reads it
  after every change; a count taken from the browser's session object goes stale in another tab.
  **A confirmed email is deliberately NOT counted.** It looks like a way back in -- send yourself
  a reset link -- but a reset link sets a PASSWORD, and an account whose only email came from
  Google has neither a password to reset nor a way to prove the address once the provider is
  gone. Under-counting refuses a removal that might have been survivable; over-counting orphans
  an account. Guarded in three places on purpose: the button is not rendered, the handler
  refuses again, and GoTrue (and the local shim) refuse a last identity.
- **A STUB THAT IS KINDER THAN PRODUCTION IS A BUG WITH A DELAY ON IT.** Three in one day,
  2026-09-30, each passing locally and failing somewhere with a worse error: `auth.identities`
  missing from the stubs entirely; then its `created_at` declared `not null default now()`
  when the real column has NO default, so seeded rows landed NULL and GoTrue answered every
  sign-in with "Database error querying schema" (20 specs timing out on page.waitForURL, cause
  visible only in the auth container log); then `auth.mfa_factors.id` defaulted when GoTrue
  mints it, so a suite that had passed for months errored the first time it ran on CI. When
  adding anything to `scripts/local-stack/supabase-stubs.sql`, copy the real definition
  including what it does NOT give you.
- **Count exit codes, not just assertions, when running the suites by hand.** A pgTAP file that
  ERRORS mid-way reports zero failing assertions -- pg_prove calls it "Dubious ... exited 3" and
  the assertion tally looks perfect. The loop in the README passes `-v ON_ERROR_STOP=1` and
  checks `$?` for exactly that reason. "885 assertions, 0 failing" was true on a run where a
  whole suite had aborted.
- **The local stack models `auth.identities` now, and the demo seed writes the rows GoTrue
  would write.** Same class of gap as `auth.mfa_factors`: without them a demo account has zero
  identities, so "Disconnect" fails for a provider plainly on screen and the last-identity
  refusal can never be reached in the state it guards. A seed that makes a feature untestable is
  a seed that is wrong. `LOCAL_SOCIAL_PROVIDERS=google` on the gateway makes the connected-
  accounts card appear; the server caches that list for five minutes, so clear
  `.next/cache/fetch-cache` rather than concluding the card is broken.
- **Adding a defaulted parameter OVERLOADS a function, it does not replace it.** Both signatures
  then exist and PostgREST cannot choose between them for a call that matches the shorter one --
  the feed starts failing with an ambiguity error that says nothing about the change. Drop the old
  signature in the same migration, FIRST. Same family as the return-type trap, and just as quiet.
  And after any drop-and-recreate, `notify pgrst, 'reload schema'` or every call 404s until
  something restarts PostgREST.
- **The community feed tabs are not the design reference's tabs, on purpose.** The reference has
  Recent / Trails / Events / Tips; events were deferred in phase 8 and tips have never existed, so
  two of the four would open an empty list -- which reads as a broken feature rather than an
  absent one. The topics are what CLAUDE.md already says the feed is for: trail conditions, gear,
  recoveries, general. An unknown topic falls back to the whole feed and an unknown topic on a
  POST lands under general, because the frontend deploys ahead of the schema and the cost of
  being strict is somebody's gate-closure warning vanishing on submit.
- **A volunteer may have no phone, and that is a state the whole system already handled.**
  `upsert_responder_profile` used to refuse any signup without a verified OTP claim, which
  meant that with SMS unconfigured nobody could become a volunteer at all -- while "there are no
  volunteers" was the launch blocker. A phone is now optional; a phone that IS present still has
  to come from the verified claim, so nobody can register somebody else's number. Editing the
  profile from a session with no claim COALESCEs rather than blanking, or a member would lose a
  verified number by changing their radius. The cost, named: `blocklist` is keyed by phone, so
  a phoneless volunteer is banned with `approval = 'banned'` instead.
- **"DEFERRED" IN THIS FILE HAS MEANT "THE UI IS DEFERRED, THE BACKEND IS BUILT" TWICE.**
  Events and groups both had tables, RPCs and pgTAP coverage from phase 12 while the planning
  notes called them deferred, and on 2026-10-01 both got screens that were the only missing
  part. Worse, building events from scratch nearly clobbered the real thing: a
  `create or replace function public.events_upcoming(integer)` with the same signature
  REPLACED the existing one, and only data_model_test failing on `going_count` revealed it.
  **Before building anything the notes call deferred, grep the whole migrations folder for it.**
  `docs/built-but-unreachable.md` is the sweep that finds this class of thing, and it is worth
  re-running whenever the word appears.
- **A screen that nothing links to is a screen nobody sees.** /welcome -- screen 2 of the design
  reference -- was built, tested, deployed and then left unreachable for two days, so every new
  visitor landed on the marketing page and the reference was quietly not followed. Nothing caught
  it: every page rendered, every link resolved, and the missing screen was one no test navigated
  to. The home page now sends a first-time signed-out visitor there, with `wu_seen_welcome` set
  by the MIDDLEWARE on the response that serves /welcome -- a server component cannot set a
  cookie, and a client effect would pin anybody with JavaScript off to onboarding forever.
  Onboarding once is the reference; onboarding every visit is an obstacle, so both halves are
  asserted in public-pages.spec.
- **A redirect from a page under a `loading.tsx` boundary is not an HTTP 302.** Next streams a
  200 and the navigation arrives in the RSC payload, so `curl -w %{http_code}` reports 200 and
  no redirect_url and the redirect looks broken when it is working. Check it in a browser.
- **The local auth shim had no `/signup` route until 2026-09-25**, so the way every member
  actually arrives 404'd locally and every suite signed in as a seeded account instead. It also
  hard-coded `raw_user_meta_data` to `{}`, which meant nothing could tell "auth-form sends the
  locale" apart from "auth-form does not" -- and that field is the only record of a member's
  language, read by the welcome-email trigger long after the browser is gone. The shim now stores
  what the form sends and creates the account UNCONFIRMED, like production: auto-confirming would
  exercise the insert trigger and silently never test the update trigger that fires for real
  members. `e2e/signup.spec.ts` drives it in Spanish.
- **A migration is not in production because a session said it was.** CLAUDE.md claimed all 26
  were verified applied on 2026-09-24. On 2026-09-25 a run of `docs/verify-which-migrations.sql`
  found `20260923002700` missing and `20260924000100` never applied at all -- which meant
  `/members` and `/members/[userId]` were live in production calling `nearby_members()` and
  `member_profile()`, neither of which existed. The chat location card degraded quietly instead,
  because `request-thread.tsx` reads it through `?? null`; the directory pages had no such
  guard and errored. Run the verifier after every deploy that ships a migration, and read ALL of
  its rows -- it sorts failures first, so the top of the output is the bad news and the rest is
  the part that tells you whether anything else is wrong.
- **STORAGE CANNOT BE PROBED THE WAY POSTGREST CAN, and it answers as though every bucket is
  missing.** With the publishable key, `GET /storage/v1/bucket/<name>` returns
  `{"code":"NoSuchBucket"}` for a bucket that EXISTS -- `anon` cannot read `storage.buckets`, and
  the service reports the RLS miss as absence. `POST /storage/v1/object/list/<name>` returns `[]`
  for every name for the same reason. Tried on 2026-10-04 to settle whether `member-avatars` had
  been applied: a name that certainly does not exist answered IDENTICALLY to the real one, in both
  endpoints. Without that control the first answer reads as proof the migration never landed, which
  is a confident wrong conclusion about production.
  So the 42501-versus-PGRST202 trick does NOT extend to Storage. What settles a bucket is
  `supabase migration list` against the ledger, or `select id from storage.buckets` with the
  service role -- and a probe whose control matches its subject has measured nothing, whatever it
  printed.
- **PostgREST will say a function is missing when it is not.** `POST /rest/v1/rpc/<fn>` with the
  publishable key is a genuine unauthenticated way to check production without the database
  password: `42501` means it exists and the gate works, `PGRST202` means no such function. But
  the signature has to match -- calling `member_profile` with `{}` when it takes `p_user_id`
  returns PGRST202 and reads exactly like an unapplied migration. Anything in schema `app`
  (`app.coarse_miles`) is invisible to PostgREST by design and can never be probed this way.
- **The rate limits make the browser suite look flaky, and it is not flaky.** Three new groups a
  day per member, ten events, twenty posts an hour, five recoveries an hour from one IP. Those
  are human ceilings and they are correct. The suite files real recoveries, starts real groups
  and posts real events on every run, from 127.0.0.1, as the same four demo members -- so the
  fourth run of the day goes over. What you see is NOT a refusal: the RPC returns
  `{"ok": false, "error": "rate_limited_ip"}`, the UI prints the right sentence, and the spec
  dies thirty seconds later on `page.waitForURL` with nothing to explain it, in a different spec
  each run -- whichever one tipped over the edge. `e2e/global-setup.ts` clears `rate_limit_hits`
  and cancels stale open recoveries before the run, which is what
  `scripts/local-stack/README.md` already prescribes doing by hand. **Do not raise the setting
  instead** -- that README says why, and it is right: the suites are the only place the limiter
  is ever exercised against a real browser, so raising it retires the test along with the
  obstacle. I raised it in the demo seed on 2026-10-01 before reading that, and reverted it.
  If a request-filing spec starts failing at the submit, check
  `select bucket_key, count(*) from rate_limit_hits group by 1` before reading any product code.
- **`count()` right after a navigation is 0 on a page that is about to render the thing.** Most
  of this app renders client-side, so a cleanup written as "if the Cancel button is there, click
  it" silently does nothing and the state it was meant to clear survives into the next run. It
  cost four runs of `nearby-alerts.spec.ts`, presenting as a broken matcher. Always
  `await locator.waitFor({ state: "visible" })` before `count()`. A conditional cleanup that
  cannot fail is a cleanup you cannot trust.
- **An e2e spec that changes shared demo state must put it back, and say so where it does not.**
  The whole suite drives the same four accounts. `nearby-alerts.spec.ts` moved Rosa 145 miles to
  Austin and left her there, and `membership.spec.ts` then failed with "the request should be
  visible to another member" on a run where the location spec passed. The product was fine. The
  restore is asserted, not hoped for: a `.catch(() => {})` round a cleanup means the test goes
  green while restoring nothing.
- **EVERY MEMBER PROFILE IS VISIBLE, by the owner's decision (2026-10-01).** `profile_public` and
  `available_to_help` are no longer gates on the directory; availability is a FIELD shown when
  enabled. The separation that still matters: being listed is not being on call. `app.candidates()`
  and `app.may_see_request_photos()` read `available_to_help` and must keep doing so, or making
  profiles visible quietly signs every member up to be rung at 3am. `docs/member-directory-audit.md`
  has the whole audit; `profiles.profile_public` is dead and is dropped in a follow-up.
- **The directory's join must stay LEFT.** `app.ensure_recovery_profile()` runs only when somebody
  turns availability on, so a member who never did has no `responders` row — which is most of them.
  An inner join hides every one of them, and "every member appears" is then false with nothing on
  screen to say why. Same trap for anything else that joins `profiles` to `responders`.
- **A security predicate shared between a list and a single read must not contain "you are not
  yourself".** `app.member_is_listable()` is deliberately silent about the viewer being the subject:
  the list adds that itself. Putting it in the shared function made every member's OWN profile page
  404, and `rig_photos_test` was the only thing that noticed because it reads a profile as its owner.
- **`content_reports` treats a person differently from a post, and the indexes say so.** A post can
  be reported once per reporter forever (the words do not change); a MEMBER can be reported again
  once the last report is closed, because people reoffend. That is two partial unique indexes rather
  than one blanket constraint — and a partial index CANNOT be inferred by `on conflict (columns)`,
  which broke `community_report()` and stopped posts being reportable at all. Any `on conflict` on
  that table needs `where target_kind <> 'member'`.
- **A moderation queue keyed on open reports loses whoever you just acted on.** Suspending closes
  their reports, so the member vanished from the only screen that could lift it while the warning
  text promised "you can undo it". `moderation_reported_members()` is one row per MEMBER and keeps
  the suspended ones. Any "queue" of decisions has this shape: it has to include what is being
  served, not only what is pending.
- **`router.refresh()` did not repaint on WebKit, and the member saw nothing.** The signed-agreement
  confirmation is server-rendered, so an iPhone member signed a legal document, the row was written,
  and the form sat there unchanged with no error — reproducible in `[iphone] membership-agreement`.
  Settled by reading the table, not the test's exit code. A once-per-version action that also changes
  the home banner and what `/request` allows should do a full navigation anyway.
- **`$` in a JavaScript replacement string becomes one `$`.** Twice in one session, writing SQL
  through `String.replace`: dollar-quoted bodies came out as `$select ...$` and psql reported a
  syntax error pointing at the quote. Use a function replacer.
  **AND THIS BULLET IS WHY.** Writing it is what corrupted this file: the replacement string held
  ``$` `` twice -- in `` `$` `` and in `` ...$` `` -- and in a replacement that is not an escape, it
  is the SUBSTRING BEFORE THE MATCH. Each one spliced the whole file-so-far back in, so CLAUDE.md
  carried three copies of itself and a truncated sentence from roughly 2026-10-01 until it was
  repaired on 2026-10-03. Nothing read it, because the duplicates were below the fold of a file
  nobody scrolls. `$&`, `` $` ``, `$'` and `$1` are ALL special there. Use a function replacer:
  `s.replace(anchor, () => text)` passes the text through untouched.
- **`LIKE '%needle%'` IS A PATTERN, AND EVERY IDENTIFIER HERE CONTAINS AN UNDERSCORE.** `_` matches
  any single character, so `%profile_public%` matches `v_profile public.profiles%rowtype` -- which is
  how `app.notify` appeared to reference a column it has never named. `strpos(haystack, needle) > 0`
  is the literal search; both verifiers in `docs/` use it now. This bit twice on 2026-10-01, an hour
  apart: once in the member search box, where an unescaped `_` let somebody enumerate the directory,
  and once in the verifiers, where it could have reported a removal that had not happened. A string
  treated as a pattern when it was meant literally.
- **A verifier has to survive the absence it is looking for.** `select app.like_contains('a\b') = …`
  is better evidence than reading the function's source -- it asks what the code DOES -- but naming a
  function that does not exist fails when the statement is PARSED, so on the one database where the
  check mattered the whole query died and reported none of its other seventeen rows. Prove a verifier
  by breaking things in a transaction and checking it still answers; `docs/verify-2026-10-01.sql` was
  wrong in exactly this way until that was done.
- **The Supabase GitHub integration stopped on 2026-10-01 and applied nothing all day.** Twelve
  migrations went in by hand through the SQL editor; `docs/apply-2026-10-01.md` is the procedure and
  the traps. Two worth carrying forward: a migration that replaces a whole function can REVERT a later
  one when pasted out of order (20261001000500 now refuses to, and says so), and `tests/*_test.sql` is
  not a migration -- one was pasted into production by mistake, harmlessly, because pgTAP suites wrap
  themselves in begin/rollback. **Verify after every deploy that ships a migration** rather than
  assuming the integration ran; probing production over HTTP with the publishable key costs nothing.
- **PostgREST validates a COLUMN name before it checks the table grant.** So `GET
  /rest/v1/profiles?select=suspended_at` answers `42703` when the column is missing and `42501` when
  it exists but `anon` cannot read the table -- which makes column existence probeable from outside
  with no credentials at all. Control it with a name that certainly does not exist, as the only thing
  separating "present" from "the endpoint always says that".
- **NEVER NAME AN i18n NAMESPACE `messages`.** A top-level namespace called `messages` renders
  perfectly on the server through `getTranslations` and then kills the CLIENT subtree: the component
  never hydrates, its effects never run, no request is made, and NOTHING appears in the console or
  the server log. The direct-messages inbox sat on "Looking…" forever. Renaming it to `dm` fixed it,
  and renaming it back broke it again on the same server -- controlled in both directions, because
  one observation here would have been a guess. Presumably it collides with next-intl's own
  top-level `messages`; the mechanism is unconfirmed, the behaviour is not.
- **Two debugging instruments lie on this app, and both lied in the same hour.**
  `get_page_text` returns a stale snapshot -- it showed a profile with no Message button while a
  screenshot of the same page showed one. And checking for `__react*` keys on a DOM node is NOT a
  hydration test here: the Report button reported zero keys and clicked fine. Screenshots are ground
  truth for "is it on the screen", and clicking it is ground truth for "is it alive". I spent a long
  time chasing a hydration failure that only the first instrument believed in.
- **`Button` in the design system is unconditionally `w-full`.** Putting one in a horizontal flex row
  beside an input squashes the input to a sliver. Everything in this app stacks, which is also right
  for a phone held one-handed -- compose boxes go above the button, not beside it.
- **A flex child needs `min-w-0` or it will push past the viewport.** The thread page is a flex
  column, and `max-w-[85%]` on a message bubble does nothing while the parent's default
  `min-width:auto` lets it grow. The bubbles ran off the right edge on a phone and the DOM text read
  perfectly; only a screenshot showed it.
- **REPLAYING `20260920000600_rls.sql` OVER A LIVE DATABASE WIPES EVERY GRANT BEFORE IT.** Its second
  line is `revoke all on all tables in schema public from anon, authenticated` -- correct as the
  deny-by-default floor at the point in history where it sits, and a demolition charge anywhere else.
  Run it against a database carried forward for weeks and 45 of 48 tables lose their grants; only
  migrations numbered after it restore their own. What you then see is SIXTEEN suites failing at once
  with `permission denied for table vehicles` / `for function send_request_message`, which reads like
  a catastrophic regression in the product and is nothing of the kind.
  `select count(distinct table_name) from information_schema.role_table_grants where
  grantee='authenticated'` settles it in one query: 3 out of 48 is rot, not a bug. The cure is
  `node scripts/local-stack/rebuild.mjs`, which is also the only thing that proves the history still
  replays from empty.
- **A member with no stated location matches NO targeted campaign, by decision (2026-10-03).**
  `ads_for()` reads "untargeted, or we do not know where the reader is, or inside the radius", and
  `ad-slot.tsx` calls it with `p_lng: null, p_lat: null` -- so radius targeting has been in the
  schema for weeks and has never once narrowed anything. Section 6 of the owner's spec says only
  matching members see a campaign, so unknown is now a miss, and the visible cost is that targeted
  campaigns reach fewer people until members fill in a location. Asserted in `targeting_test.sql`
  so it stays a decision rather than becoming an accident. And `app.member_matches_target()` takes
  the member's FIELDS rather than a user id on purpose: a function taking a uuid could reach for
  `responders.home_location`, which is recovery data that section 7 forbids advertising from
  touching, and passing the values in makes that boundary visible at every call site.
- **Every exclusion assertion in a targeting suite needs an inclusion beside it.** A matching rule
  that matches nobody passes every "does not see the advert" test in the file, and the feature is
  then silently dead while the suite reads green -- which is exactly how radius targeting survived
  weeks of green suites. `targeting_test.sql` pairs them throughout, and tests two radii rather than
  one so a radius that happened to catch everything cannot pass as a radius.
- **A SOURCE-READING GUARD CANNOT TELL A COMMENT FROM A REFERENCE.** `targeting_test.sql` fails if
  any advertising function names `responders` or `home_location`, which is the dispatch-path guard
  pointed the other way -- and it failed first on a COMMENT inside `ads_for()` saying which column it
  deliberately does not read. The comment is reworded and says why; do not "improve" it back. A guard
  this blunt is what survives, and the cost of bluntness is a confusing failure message that gets the
  guard deleted rather than understood.
- **The same guard caught a join that was also simply wrong, which is the more useful half.**
  `app.target_audience_count()` joined `responders` to skip `redacted_at` rows. `redacted_at` marks a
  volunteer record scrubbed by RETENTION, not a deleted account -- those members still sign in and
  still see adverts, so the join under-counted every audience estimate. A genuinely deleted account
  has no `profiles` row to count, because the cascade from auth.users takes it. When a §7 smell and a
  correctness bug point the same way, that is usually not a coincidence.
- **An assertion can pin a bug as intended behaviour, and the wording tells you when.**
  `advertising_test.sql` asserted "a reader whose browser gave no position still sees it, rather than
  targeting quietly meaning nobody" -- and passed, for weeks, while every radius-targeted campaign
  went to everybody. The fear in that sentence was correct; the cure was a hole the size of the
  feature. An assertion whose name argues for itself ("rather than...") is one to re-read. It is
  inverted now, with the other half beside it: the same reader is served the campaign once they have
  STATED an area, and stops when that area moves.
- **`profiles.postal_center` is written only by the server, and only for the ZIP it was geocoded
  from.** `set_my_location()` clears it; `set_member_postal_center()` refills it afterwards and takes
  the postal code as an argument so a slow geocoder cannot pin a stale point onto a newer ZIP -- the
  exact failure clearing the column prevents, reintroduced one step later, with nothing wrong on any
  screen. `members_missing_postal_center()` is the retry queue, because a member whose geocode timed
  out would otherwise match no radius campaign until they next edited their profile. And Mapbox
  answers a bad five-digit string with a confident point somewhere else rather than nothing, so
  `forwardGeocodePostalCode()` checks the answer is about the postcode it asked for.
- **TARGETING HIDES AN ANNOUNCEMENT AND DOES NOT HIDE AN EVENT.** Same table, same matching rule,
  opposite answer, and the asymmetry is deliberate rather than an oversight. An event is BROWSED: a
  Dallas member who would happily drive to a Houston clinic has to be able to find it, and hiding
  community events is losing the thing this product replaces. An announcement is PUSHED at somebody
  who did not ask for it with no directory to browse, so one about a gate four hundred miles away is
  pure noise. `events_upcoming()` returns everything and carries `matches_my_area` for badging;
  `my_announcements()` filters. Both halves are asserted in both suites, because a filter that hides
  everything passes every "does not see it" test on its own.
- **Campaign lifecycle labels are DERIVED, and `ads_for()` calls the same function that prints them.**
  scheduled / active / expired are a function of status, starts_on and ends_on. Storing them needs a
  nightly job, and the morning it fails a campaign reads "active" while the serving query -- which
  reads the dates -- has already stopped showing it. `app.campaign_phase()` is the single answer and
  replaced four conditions in the serving WHERE; without that the derived-not-stored argument would
  have been aspirational and the two copies would have drifted. Archive is the one state nothing else
  implies, so it IS stored -- and it is not a status, because an archived campaign that was approved
  and ran for a month is still that and the reports have to say so.
- **A POSIX REPETITION COUNT ABOVE 255 IS INVALID, AND A CHECK COMPILES ITS PATTERN ON THE FIRST ROW.**
  `check (url ~* '^https?://[^[:space:]]{3,500}$')` creates cleanly, looks applied, and then refuses
  every insert with "invalid repetition count(s)" -- an error naming nothing that would help. Length
  belongs in `length()`, never in the pattern. Hit on 2026-10-03 and caught only because a test
  inserted a URL.
- **`app.require_admin()` RETURNS VOID.** `v_me uuid := app.require_admin();` compiles, because
  plpgsql does not check a body until it runs, and then fails on the first call. It is
  `perform app.require_admin();` and `auth.uid()` separately.
- **A LISTING THAT OMITS A FIELD MAKES THE EDITOR THAT USES IT SILENTLY DESTRUCTIVE.** The admin
  listings returned a radius target's distance and not its centre, which is sensible for a list. The
  editor loads targets, the admin adds a ZIP, the save sends the whole array, and the writer replaces
  targeting wholesale -- so a radius the editor could not represent is simply absent from what it
  sends back, and is deleted. Nothing errors; the campaign stops reaching the area it was bought for
  and the only evidence is a report getting smaller. Same shape for `events.meet_point`. Both now
  round-trip, and `targets_round_trip_test.sql` asserts it by reading and re-sending.
- **`ad_geo_daily_stats` uses `''` rather than NULL for "no stated area", and it is part of the key.**
  A key treats nulls as DISTINCT, so every anonymous impression would insert a new row instead of
  incrementing one -- the table growing per page view while the report read correctly. A unique index
  over `coalesce()` expressions cannot be the target of a plain `on conflict (columns)` (the same
  inference trap that stopped posts being reportable), and a primary key cannot hold an expression at
  all.
- **The geographic ad report suppresses small buckets and ROLLS THEM UP rather than dropping them.**
  Below `analytics.min_cohort` (default 5) a city or ZIP is folded into one labelled row with a
  bucket count. Dropping them would make the parts not add up to the total, and somebody reconciling
  a report by hand asks for the raw table -- which is the thing the suppression exists to avoid
  handing out. Totals come from `ad_daily_stats`, never by summing the geographic rows, so the
  headline number never depends on a privacy threshold. "No stated area" is its own row, not a
  suppressed one: it is usually the biggest row on the page and calling it suppressed is a lie about
  why. There is no unique-viewer count and there must not be one.
- **`/api/ads/event` has a HARDCODED surface set that goes stale silently.** Mounting an AdSlot on a
  new surface while that set still had three entries meant the slot rendered, a real advert was
  served, and every impression came back 400 bad_surface -- a working advert counting nothing, visible
  only as a report stuck at zero. If `ad_surface` grows, grow that set. The route also reads the
  member's stated area from the SESSION and passes it to the RPC: it holds the service-role key, so
  `auth.uid()` is null in the database, and a city taken from the request body would let anybody write
  into an advertiser's report.
- **`useCallback` for a loader must not depend on `t`.** next-intl does not promise a stable identity
  for the translator, so a callback depending on it can be rebuilt every render and an effect keyed on
  that callback re-runs every render. Store an error CODE in state and translate at render; the
  notification settings screen was already written this way and the location screen now matches.
- **`npx playwright test | tail` REPORTS TAIL'S EXIT CODE, NOT PLAYWRIGHT'S.** This file already
  says to count exit codes rather than assertion tallies, and a pipe defeats exactly that: on
  2026-10-03 a run quoted as "exit code 0" contained a real failure, and three runs before it had
  been judged the same worthless way. Redirect to a file and capture `$?` BEFORE reading it --
  `npx playwright test > log 2>&1; echo $?` -- or use `${PIPESTATUS[0]}`. The same trap applies to
  every `| grep`/`| head` wrapped around a test command.
- **`reuseExistingServer: !process.env.CI` MEANS AN ORPHANED `next start` POISONS EVERY LATER RUN.**
  Locally Playwright reuses whatever answers on 3101 and SKIPS its own `next build` entirely -- so a
  leftover server keeps serving a `.next` that the next run's build then overwrites underneath it.
  The symptom is not a failed assertion. It is `apiRequestContext.get: socket hang up` on a
  DIFFERENT, unrelated static page each run (`/es/trails`, then `/resources/etiquette`), and
  eventually a spec that took 1.6 minutes wedging past thirty.
  It accumulates silently: a killed or timed-out run leaves its server behind, and on 2026-10-03
  there were orphans from two separate runs alive at once.
  **Before reading any product code**, check it -- `Get-NetTCPConnection -State Listen -LocalPort
  3101` -- then kill the strays, `rm -rf .next`, and run again. Keep the gateway (54321), PostgREST
  (54322) and Postgres; killing those is a different afternoon. This is the same family as the
  existing warning about `next dev` and `next build` sharing `.next`, and it is worth checking
  first for the same reason: it presents as a broad, product-shaped failure and is neither.
- **Do not change the database while a browser suite is running against it.** Recreating three
  functions mid-run on 2026-10-03 confounded the one failure that mattered -- it had to be
  re-diagnosed from scratch because "my change" and "the environment" could not be separated. The
  suites share one database and one set of demo accounts; treat a running suite as holding a lock
  on both.
- **PRODUCTION ENFORCES ADMIN MFA, AND ONLY /signin CAN SATISFY IT.** `security.require_admin_mfa`
  is TRUE in production and false on the local stack, so this is a class of bug that cannot be
  reproduced by running the app locally without setting the flag. With it on and a session at aal1,
  every `admin_*` RPC raises `mfa_required` -- which is deliberately distinct from `forbidden` so
  the UI can tell "you are not an admin" from "you are, but this session has not been challenged".
  **The admin console's own phone-OTP form does NOT step up.** `signInWithOtp` returns a session at
  aal1 with `nextLevel: aal2`, so signing in there lands you right back at the refusal having done
  work. The only path that steps up is `/signin`, whose form calls
  `getAuthenticatorAssuranceLevel()` after the password and asks for the six-digit code.
  `AdminNeedsMfa` says exactly that and its button signs out and goes there.
  **The lockout to watch for:** enforcement on with NO verified TOTP factor means aal2 is
  unreachable and the console is gone for good. `/admin/security` enforces enrol-then-sign-in-then-
  enable precisely to prevent that, so it can only happen if the flag was set directly in SQL. The
  escape is `update app_settings set value = 'false'::jsonb where key = 'security.require_admin_mfa';`
- **A GATE THAT RAISES CANNOT ALSO DECIDE WHAT TO RENDER.** `app.require_admin()` raising is right
  for an RPC and useless for a page, which is why the admin layout asked only about the ROLE for
  months and an admin with an unchallenged session got the whole console full of empty lists.
  `admin_session_state()` is the one function in that surface that answers a refusal with DATA --
  signed_out / not_admin / mfa_required / ok -- and that is what makes it callable before you know
  whether the caller is an admin. Its MFA condition is a deliberate COPY of require_admin()'s rather
  than a call wrapped in an exception handler: swallowing would also swallow a genuine error and
  report it as "needs MFA". It still enforces nothing; every admin RPC checks for itself.
- **THE ADMIN IS A DIFFERENT RLS SUBJECT, SO THE ADMIN HAS TO OPEN THE MEMBER SCREENS TOO.**
  `profiles_self_read` is `user_id = auth.uid() OR app.is_admin()`, so an admin reads EVERY profile
  row. Four places selected from `profiles` with NO user_id filter and called `maybeSingle()`,
  which fails on more than one row -- so /account showed "we could not load your details",
  /account/location sat on "Loading...", /account/notifications showed every switch at its default,
  and /api/ads/event filed impressions under "no area given". All four were broken for exactly one
  person, the owner, and worked for everybody else. It also got WORSE AS THE MEMBERSHIP GREW: at one
  member the unfiltered select returned one row and looked perfect.
  Nothing could catch it. Every pgTAP suite and every browser test signs in as an ordinary member,
  so the whole class of "works unless you are an admin" was untestable by construction.
  `e2e/geo-targeting.spec.ts` now opens those three screens as the ADMIN, and that test was proven
  to fail on the unfixed code before being trusted.
  **Never rely on a policy to return one row.** Filter by `user_id` even when RLS "already" scopes
  it: the policy is a permission boundary, not a query.
- **A zero-row UPDATE through PostgREST is a silent success.** `/account` saved with
  `.not("user_id","is",null)` and no `.select()`, so an account whose `profiles` row was missing --
  which RLS cannot create, there being no INSERT policy on that table -- showed "Saved" and changed
  nothing, for ever. Ask for the written rows back and treat an empty array as a failure. The same
  shape hides in any `.update()` whose filter leans on RLS rather than naming the row.
- **A CONNECTION FAILURE AND A WRONG PASSWORD LOOK IDENTICAL, AND THERE ARE SIX WAYS TO GET THE
  STRING WRONG.** `SUPABASE_DB_URL` reached Actions for the first time on 2026-10-04 -- "Are the
  secrets here?" passed -- and `supabase migration list` still failed, because the string was the
  IPv6-only direct host. Two days went into guessing between candidates that all present as a
  timeout. `scripts/check-db-url.sh` now runs before anything authenticates and names the cause:
  direct host (AAAA only, and GitHub runners have no IPv6), port 6543 instead of 5432 (transaction
  mode hands out a different backend per statement, so a migration loses its advisory lock), a bare
  `postgres` username at the pooler (refused as "password authentication failed", a wrong username
  that reads as a wrong password), an unencoded `@` or `/` in the password (reparses the URL with
  nothing erroring), a missing password, the wrong database name. Then DNS per address family, then
  TCP -- so "cannot reach it" and "it refused me" stop looking alike.
  **It prints the host, port, username and database in full, deliberately.** Those four are where a
  typo hides; the ref is already in `NEXT_PUBLIC_SUPABASE_URL`, which ships in the browser bundle.
  Only the password is withheld, as a length. Do not "tighten" this by masking the host.
  Two things about how it is built, both of which were the second attempt: it is SHELL because the
  migrate job has no Node step, and it is a FILE rather than inline because an inline diagnostic
  cannot be tested -- the first draft was inline python, and there is no python on the owner's
  machine to syntax-check it with, so a diagnostic that failed for its own reasons would have been
  the next red herring. `scripts/check-db-url.test.ts` drives one good string and six bad ones;
  `vitest.config.ts` includes `scripts/` for it. And it detects a missing `getent` separately from
  a missing A record, because getent is Linux-only and the owner works in git-bash -- announcing
  "IPv6-only" about a perfectly good host is the exact bug class this script exists to stop.
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
| Account & Security | **done and live in the repo** (2026-09-30) — `/account/security`: every sign-in method in one place, set or change a password, add or change a phone, connect or disconnect a provider, sign out everywhere. The rule it enforces is that nobody can remove their last way in. Email change is deliberately absent (see `docs/account-security.md`). **The migration applied itself**, once: in production ~90s after the push, before Vercel finished building, via the Supabase GitHub integration. That integration stopped on 2026-10-01 and was removed on 2026-10-03, so this is history rather than how it works now. Probe rather than assume either way -- 42501 for the exact function name against PGRST202 for a near-miss name is how that was established |
| Recovery teams & group chat | **done and live** (2026-09-24) — `recovery_participants`, one thread per recovery for the whole team, per-participant unread and mute, notification settings screen, recovery SMS switched off, an offline send queue, Realtime broadcast over a polling floor. Migrations applied in production, but see the warning under Tests about what "verified" is worth |

**Proven working in production**, not just built: a signed-in person files a request, the tick
escalates it through all three rings, it reaches `unmatched` with nobody available, and the public
board shows it with no phone, no name and a blurred pin.

**Not launched.** Three things gate that and none are code: Twilio + A2P 10DLC registration, at
least one approved volunteer (there are none), and a lawyer reading /terms, /waiver and /privacy.

## Tests

Four layers. Run all of them before claiming anything works.

```
npm run verify      typecheck + lint + unit tests + build. Run this before pushing.
npm test            171 unit + component tests (vitest)
npm run test:e2e    213 Playwright tests — android, iphone, tablet, desktop
supabase test db    1002 pgTAP assertions across twenty-four suites
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

**Stop any dev server before running it.** `next dev` and `next build` share `.next`, so a
running preview corrupts the build mid-flight and the suite fails with things that look like
product bugs -- `Could not find files for /_error in .next/build-manifest.json`, then a pile of
unrelated pages failing to prerender. It cost 14 failures that were all one cause; with the dev
server stopped and `.next` cleared, the same run gave 4. If a run fails oddly and broadly, check
for a dev server before reading anything else.

**`workers: 1`, and do not raise it.** It was 2 and that was still too many. Two separate
failures came out of it, both of which cost a diagnosis each before being recognised as
contention: the link-crawl tests in `navigation.spec.ts` and `public-pages.spec.ts` intermittently
got `ECONNRESET` from `next start`, and `membership.spec.ts` and `recovery-team.spec.ts` -- both
serial state-machine suites driving the same demo accounts -- could run at the same time and
cancel each other's open request. Each file is serial internally; nothing made them serial with
respect to each other, and Playwright has no way to express that.

The whole suite is 3.0 minutes on one worker against 3.2 on two, because the build dominates and
the contention was costing retries. Parallelism here buys nothing and has never bought anything.

**The suite spends a rate limit, so two full passes in one hour exhaust it.** A run files 3
requests and `limits.max_requests_per_ip_per_hour` is 5. The next run then fails in a way that
does not read as a rate limit at all: the wizard never navigates and Playwright reports
`page.waitForURL: Timeout 30000ms exceeded` on the final step. The banner that names the cause is
in `test-results/<test>/error-context.md`, not in the terminal, so read that before diagnosing
anything. Clear the bucket between passes — `delete from rate_limit_hits where bucket_key like
'request:%'` — and do NOT raise the setting instead; the reasoning is in
`scripts/local-stack/README.md`, which is the detailed home for this.

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
statements that change a return type, which Postgres refuses),
and `privacy_rls_test` had come to depend on dispatch rows that only exist once somebody has run
the tick. That suite passed for weeks and failed the first time anybody built from scratch, on
the one assertion that would have gone quiet if the volunteer feed genuinely broke. It creates
its own invitation now.

**The history replays in plain filename order again, as of 2026-09-30.** That first finding was
worked around rather than fixed: rebuild.mjs carried a `DROPS_BEFORE` table that injected the
missing `drop function` for those two files, so THIS script worked while `supabase db reset`,
`supabase start` and anybody following the README still failed -- which is also why CI could
not run the suites at all. The drops now live at the top of 20260923000500 and 20260923001700,
where every replay gets them, and the table is gone. Editing two applied migrations was the
owner's decision; both files carry the reasoning, and neither changes anything it originally
did. **If this bites again, put the drop in the migration, never back in the script.**

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
