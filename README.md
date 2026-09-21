# TxRecover

A dispatcher for volunteer off-road vehicle recovery in Texas. It replaces the Facebook-group
workflow used by *Texas Off-Road Recovery* and *Houston Area Off-Road Recovery*: a stuck driver
fills in one page, the nearest matching volunteers get a text, the first to reply wins, and a
status page closes the loop. Nobody installs anything.

Product rules, flow and conventions live in [CLAUDE.md](./CLAUDE.md). Read that first.

---

## Current state

| Milestone | Scope | Status |
|---|---|---|
| **M1** | schema + migrations + RLS + seed data | built and verified |
| **M2** | `/request` + `/r` status page + requester SMS | built, partly verified |
| **M3** | responder signup + dispatch engine + inbound webhook + tests | built and verified |
| **M4** | `/board`, `/post`, `/admin` | built, partly verified |
| **M5** | PWA polish, i18n pass, README, deploy to Vercel | built, partly verified |

### What has actually been run

| | |
|---|---|
| `npm install` | 367 packages, every version in `package.json` resolved |
| `tsc --noEmit` | clean |
| `next lint` | no warnings or errors |
| `next build` | compiles, 32 pages generated — **with no `.env.local` present**, which proves nothing privileged runs at build time |
| `check-messages.mjs` | 472 keys, EN and ES in step |
| all 11 migrations + both seeds | apply clean from an empty database |
| `privacy_rls_test.sql` | **58 / 58** |
| `dispatch_test.sql` | **59 / 59** |
| Browser | landing, `/request` (through the 911 gate into the location step, resolving a pasted Google Maps URL), `/board`, `/es`, and the offline page |

The database work was verified against a local PostgreSQL 17.7 + PostGIS 3.6 + pgTAP, with the
Supabase-specific objects (`auth.uid()`, `auth.users`, `storage.*`, the `anon` /`authenticated` /
`service_role` roles and Supabase's default privileges) stubbed in. That is close but **not
identical** to a real Supabase instance.

### Still unverified

- `supabase start` / `db reset` / `test db` through the real CLI — needs Docker, which needs
  admin rights this machine does not have.
- Anything that talks to the Supabase REST API at runtime: submitting a request end to end,
  phone OTP, Storage uploads, `/me`, `/admin`.
- Twilio, Mapbox, and the `pg_cron` → Edge Function tick — all need live third-party accounts.

Day-to-day operations — what to do when texts stop going out, when a request sits too long,
when a volunteer says they never got called — live in [docs/runbook.md](./docs/runbook.md).

---

## What you need before anything works

| Tool | Version | Why |
|---|---|---|
| Node.js | 20 LTS or newer | Next.js 15 |
| Docker Desktop | current | the Supabase CLI runs Postgres, Storage and Auth in containers |
| Supabase CLI | 1.200 or newer | migrations, local stack, `supabase test db` |
| Git | any | you have it |

Install on Windows:

```bash
winget install OpenJS.NodeJS.LTS
```

```bash
winget install Supabase.CLI
```

Docker Desktop: https://www.docker.com/products/docker-desktop/ — install it, launch it once, and
leave it running before any `supabase start`.

---

## 1. Local setup

```bash
npm install
```

```bash
cp .env.example .env.local
```

```bash
supabase start
```

`supabase start` prints an API URL, an `anon key` and a `service_role key`. Paste them into
`.env.local` as `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` and
`SUPABASE_SERVICE_ROLE_KEY`.

## 2. Build the database

```bash
supabase db reset
```

That applies every migration in `supabase/migrations/` in order, then loads
`supabase/seed.sql` (settings, versioned waiver text, the paid-options placeholder) followed by
`supabase/seeds/demo.sql` (demo volunteers and five demo requests, local only).

Demo logins created by the seed — **local only**, password `recovery-demo-2026`:

| Who | Email | Phone | Role |
|---|---|---|---|
| Admin | admin@txrecover.test | +1 713 555 0100 | admin |
| Mike | mike@txrecover.test | +1 281 555 0101 | approved volunteer |
| Rosa | rosa@txrecover.test | +1 936 555 0102 | approved volunteer (Spanish) |
| Trey | pending@txrecover.test | +1 409 555 0103 | volunteer awaiting approval |

Local phone OTP codes are pinned to `123456` in `supabase/config.toml`, so signing in locally
never sends a real text.

## 3. Prove the privacy rules still hold

```bash
supabase test db
```

`supabase/tests/privacy_rls_test.sql` asserts the things that must never regress: anon cannot read
requests or the volunteer roster, `authenticated` has no column privilege on `requester_phone`,
`location` or `public_token`, the public board never emits a real coordinate, the responder phone
appears on the status page only after acceptance, and a volunteer who was merely *notified* cannot
pull the requester's contact details.

Run it before every deploy. If one of these fails, the fix is the code, not the test.

Also keep the two message catalogues in step:

```bash
npm run i18n:check
```

It fails on any key that exists in one language and not the other, and on any translation that
dropped an ICU placeholder like `{count}` or `{url}`.

## 4. Run the app

```bash
npm run dev
```

Open http://127.0.0.1:3000. With `SMS_DRY_RUN=1` (the default in `.env.example`) no real text is
sent — the message is printed to the terminal instead:

```
[sms:dry-run] to=+12815550123 body="TxRecover TX-8K4M: we got it. ..."
```

Copy the `/r/...` link out of that line to reach the status page, the same way a requester would.

Walking the flow end to end locally:

1. `/request` → answer the eight screens. GPS will not work over plain HTTP on a phone; on the
   desktop, use the **Paste** tab with something like `29.7604, -95.3698`.
2. Submit. The terminal prints the SMS with the status link.
3. Open the link. The status page polls every 15 seconds.
4. Nothing advances on its own locally unless you run the tick. Fire it by hand:

```bash
curl -X POST http://127.0.0.1:54321/functions/v1/dispatch-tick -H "Authorization: Bearer $DISPATCH_TICK_SECRET"
```

   Or call the SQL directly in Studio: `select advance_dispatch(50);` then drain the outbox.

To drain the SMS outbox by hand:

```bash
curl -X POST http://127.0.0.1:3000/api/sms/drain -H "Authorization: Bearer $DISPATCH_TICK_SECRET"
```

---

## 5. Supabase cloud project (one time)

1. Create a project at https://supabase.com/dashboard — pick a region close to Texas
   (`us-east-1` or `us-west-1`). Save the database password.
2. **Database → Extensions**: enable `postgis`, `pg_cron` and `pg_net`.
   `pg_cron` is what advances the dispatch state machine every 60 s. Vercel cron is not used.
3. **Project Settings → API**: copy the project URL, the `anon` key and the `service_role` key.
4. **Project Settings → API → Exposed schemas**: confirm it lists `public` only.
   Schema `app` must never appear there.
5. **Authentication → Providers → Phone**: enable it, set the provider to Twilio, and paste the
   Twilio credentials from step 6 below.
6. Link and push:

```bash
supabase link --project-ref YOUR_PROJECT_REF
```

```bash
supabase db push
```

7. Load the reference seed once (it is idempotent, and it does **not** include demo data):

```bash
supabase db execute --file supabase/seed.sql --linked
```

## 6. Twilio (one time, and start early — 10DLC takes days)

1. Create an account at https://twilio.com and buy a **local US long code** in a Texas area code.
   Toll-free is an option but 10DLC is the right fit for this traffic.
2. **Messaging → Services**: create a Messaging Service, add the number to its sender pool, and
   copy the Messaging Service SID.
3. **A2P 10DLC registration** — required before any volume of messages will be delivered:
   - Register a Brand (the entity sending the messages: your LLC, or a sole proprietor brand).
   - Register a Campaign. Use case: *Public Service Announcement* or *Mixed*, whichever the
     reviewer accepts for a volunteer dispatch service.
   - Sample messages to submit — they must match what the app actually sends:
     - `TxRecover: stuck truck 12 mi from you, mud to the frame, FM 1097 area. Reply 1 to take it, 2 to pass. Reply STOP to opt out.`
     - `TxRecover: Mike is on the way, ETA 40 min. Call (281) 555-0101. Track: https://example.com/r/abc123`
   - Describe opt-in honestly: volunteers opt in at `/join` by entering their phone and confirming
     an OTP, and every message carries STOP instructions. Screenshot `/join` for the submission.
   - Expect 1–10 business days. Until it is approved, leave `SMS_DRY_RUN=1`.
4. **Phone Numbers → your number → Messaging**: set the inbound webhook to
   `https://YOUR_DOMAIN/api/twilio/inbound`, method POST.
5. Copy the Account SID, Auth Token and Messaging Service SID into `.env.local` and Vercel.

## 7. Mapbox (one time)

1. Create an account at https://account.mapbox.com.
2. Create a **public** token (`pk.…`) and restrict it to your domains, including
   `localhost` for development. That is `NEXT_PUBLIC_MAPBOX_TOKEN`.
3. Optionally create a secret token (`sk.…`) with `geocoding:read` for server-side geocoding of
   volunteer home addresses. That is `MAPBOX_SECRET_TOKEN`.
4. Set a spending limit on the account. The free tier is generous; a loop in a map component is
   not.

## 8. Vercel

1. Push this repo to GitHub, then import it at https://vercel.com/new.
2. Add every variable from `.env.example` to **Production** and **Preview**.
   `NEXT_PUBLIC_SITE_URL` must be the real public origin: it is what goes into the link texted to
   a stranded driver.
3. `SUPABASE_SERVICE_ROLE_KEY`, `TWILIO_AUTH_TOKEN`, `TWILIO_WEBHOOK_SECRET`,
   `DISPATCH_TICK_SECRET` and `MAPBOX_SECRET_TOKEN` are server-only. Never give any of them a
   `NEXT_PUBLIC_` prefix.
4. After the first deploy, update the Twilio inbound webhook to the production domain and add the
   domain to the Supabase Auth redirect list.

## 9. The dispatch tick

Scheduled from Postgres, not Vercel:

```sql
select cron.schedule(
  'txrecover-dispatch-tick',
  '* * * * *',
  $$select net.http_post(
      url := 'https://YOUR_PROJECT_REF.supabase.co/functions/v1/dispatch-tick',
      headers := '{"Content-Type":"application/json","Authorization":"Bearer YOUR_DISPATCH_TICK_SECRET"}'::jsonb
    )$$
);
```

The Edge Function only calls the Postgres function that owns the transitions; it does not contain
dispatch logic of its own.

---

## Repository layout

```
CLAUDE.md                     stack, rules, flow — read first
src/app/[locale]/             pages: landing, /request, /r/[token], legal
src/app/actions/              server actions — the only write path from the browser
src/app/api/                  route handlers: photo signing, geo resolve, status poll, SMS drain
src/components/request/       the one-question-per-screen wizard
src/components/status/        the /r/[token] status page
src/components/ui/            the small primitive set everything is built from
src/config/app.ts             APP_NAME and the tuning mirrored from app_settings
src/i18n/                     next-intl routing, request config, navigation helpers
src/components/admin/         the admin console
src/components/responder/     /join and /me
src/lib/                      supabase clients, geo parsing, photos, SMS, validation
messages/{en,es}.json         every user-facing string, key-for-key identical
scripts/check-messages.mjs    fails the build when en and es drift apart
supabase/config.toml          local stack config, incl. pinned test OTPs
supabase/migrations/          numbered, append-only once applied to production
supabase/seed.sql             reference data, safe to run anywhere, idempotent
supabase/seeds/demo.sql       demo volunteers and requests, local only
supabase/tests/               pgTAP — the privacy rules, proven
public/sw.js                   service worker: static assets and the offline shell, nothing else
public/offline.html           standalone offline page, no framework, both languages
docs/                         milestone plan, decisions and the operational runbook
```

## Database at a glance

| Table | What it holds |
|---|---|
| `requests` | one recovery request, its consent record, and its dispatch state |
| `request_photos` | storage paths, 3 max, private bucket |
| `request_events` | the timeline `/r/[token]` renders |
| `responders` | volunteers, their equipment, radius and approval state |
| `dispatches` | one row per offer made to one volunteer |
| `sms_messages` | outbox and inbound log, the whole SMS conversation |
| `pro_options` | admin-editable paid recovery/tow fallback list |
| `waivers` | versioned legal copy, EN + ES |
| `app_settings` | ring radii, timers, limits — read at runtime, not hard-coded |
| `blocklist`, `rate_limit_hits` | abuse controls, service-role only |
| `audit_log` | admin actions |

Three layers protect the private fields: RLS policies choose rows, column-level `GRANT`s mean
`requester_phone`, `location` and `public_token` do not exist at all for `anon` and
`authenticated`, and anonymous requesters reach their own data only through token-scoped
`security definer` RPCs.

## Installable on a phone

The app is a PWA: `src/app/manifest.ts` serves the manifest, `src/app/icons/[size]/route.tsx`
generates the icons at request time with `next/og` (no binary assets in the repo), and
`public/sw.js` is the service worker.

The service worker is deliberately narrow. It caches the content-hashed build output under
`/_next/static` and the offline shell, and **nothing else**. `/api/`, `/r/`, `/post/`, `/me` and
`/admin` are on a never-cache list: this app exists for people with one bar of signal, and a
cache that serves a stale recovery status is worse than no cache at all.

`public/offline.html` is standalone HTML with no framework, no fonts and no network calls,
because it is shown at exactly the moment nothing can be fetched. It leads with "call 911" and
carries both languages at once, since there is nothing available to detect a preference.

`start_url` is `/request`, not the landing page. Somebody who installed this did it because they
expect to need it in a hurry.

## Launch checklist

Work down this list before telling 6,800 people the link exists.

- [ ] `npm install && npm run typecheck && npm run build` all pass
- [ ] `supabase db reset` applies every migration cleanly
- [ ] `supabase test db` — both suites green. **Do not deploy on a red privacy test.**
- [ ] `npm run i18n:check` passes (it also runs automatically before every build)
- [ ] Migrations pushed to the cloud project, reference seed loaded, demo seed **not** loaded
- [ ] `postgis`, `pg_cron` and `pg_net` enabled on the cloud project
- [ ] Exposed schemas list `public` only — never `app`
- [ ] A2P 10DLC brand and campaign **approved**, not just submitted
- [ ] `SMS_DRY_RUN` unset in production, still `1` in preview
- [ ] Twilio inbound webhook points at the production domain
- [ ] `TWILIO_AUTH_TOKEN` set in production, so the webhook rejects unsigned requests
- [ ] The cron job is scheduled and `cron.job_run_details` shows it succeeding
- [ ] `contact.admin_phones` has at least one real number in it
- [ ] `pro_options` has real operators, and the placeholder row is deleted or hidden
- [ ] At least one admin exists in `user_roles`
- [ ] `/terms`, `/waiver`, `/privacy` reviewed by a Texas attorney and the placeholder banners
      removed
- [ ] Two phones tested against one request, and exactly one of them won
- [ ] Tested on a real mid-range Android outdoors, in sunlight

## Legal

`/terms`, `/waiver` and `/privacy` ship with placeholder text marked
**REVIEW WITH LAWYER**, and the same marker is on the waiver rows in the database
(`app_settings.legal.review_status`). Do not launch publicly until a Texas attorney has reviewed
them. The waiver is versioned: every acceptance records which version, when, from what IP and with
what user agent.
