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
| **M1** | schema + migrations + RLS + seed data | **code complete, not yet run** |
| M2 | `/request` + `/r` status page + requester SMS | not started |
| M3 | responder signup + dispatch engine + inbound webhook + tests | not started |
| M4 | `/board`, `/post`, `/admin` | not started |
| M5 | PWA polish, i18n pass, README, deploy to Vercel | not started |

> **M1 has never been executed.** It was written on a machine with no Node.js, no Docker and no
> Supabase CLI, so `supabase db reset` and `supabase test db` have not been run against it.
> The first task of M2 is step 3 below: apply the migrations locally and fix whatever the first
> run turns up.

The Next.js app itself is not scaffolded yet — only the pieces that are independent of it:
`src/config/app.ts` (the one place the product name lives) and `messages/{en,es}.json`.

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

---

## 4. Supabase cloud project (one time)

1. Create a project at https://supabase.com/dashboard — pick a region close to Texas
   (`us-east-1` or `us-west-1`). Save the database password.
2. **Database → Extensions**: enable `postgis`, `pg_cron` and `pg_net`.
   `pg_cron` is what advances the dispatch state machine every 60 s. Vercel cron is not used.
3. **Project Settings → API**: copy the project URL, the `anon` key and the `service_role` key.
4. **Project Settings → API → Exposed schemas**: confirm it lists `public` only.
   Schema `app` must never appear there.
5. **Authentication → Providers → Phone**: enable it, set the provider to Twilio, and paste the
   Twilio credentials from step 5 below.
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

## 5. Twilio (one time, and start early — 10DLC takes days)

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
   `https://YOUR_DOMAIN/api/twilio/inbound`, method POST. (That route arrives in M3.)
5. Copy the Account SID, Auth Token and Messaging Service SID into `.env.local` and Vercel.

## 6. Mapbox (one time)

1. Create an account at https://account.mapbox.com.
2. Create a **public** token (`pk.…`) and restrict it to your domains, including
   `localhost` for development. That is `NEXT_PUBLIC_MAPBOX_TOKEN`.
3. Optionally create a secret token (`sk.…`) with `geocoding:read` for server-side geocoding of
   volunteer home addresses. That is `MAPBOX_SECRET_TOKEN`.
4. Set a spending limit on the account. The free tier is generous; a loop in a map component is
   not.

## 7. Vercel

1. Push this repo to GitHub, then import it at https://vercel.com/new.
2. Add every variable from `.env.example` to **Production** and **Preview**.
   `NEXT_PUBLIC_SITE_URL` must be the real public origin: it is what goes into the link texted to
   a stranded driver.
3. `SUPABASE_SERVICE_ROLE_KEY`, `TWILIO_AUTH_TOKEN`, `TWILIO_WEBHOOK_SECRET`,
   `DISPATCH_TICK_SECRET` and `MAPBOX_SECRET_TOKEN` are server-only. Never give any of them a
   `NEXT_PUBLIC_` prefix.
4. After the first deploy, update the Twilio inbound webhook to the production domain and add the
   domain to the Supabase Auth redirect list.

## 8. The dispatch tick (M3)

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
CLAUDE.md                 stack, rules, flow — read first
src/config/app.ts         APP_NAME and the tuning mirrored from app_settings
messages/{en,es}.json     every user-facing string, key-for-key identical
supabase/config.toml      local stack config, incl. pinned test OTPs
supabase/migrations/      numbered, append-only once applied to production
supabase/seed.sql         reference data, safe to run anywhere, idempotent
supabase/seeds/demo.sql   demo volunteers and requests, local only
supabase/tests/           pgTAP — the privacy rules, proven
docs/                     milestone plan and decisions
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

## Legal

`/terms`, `/waiver` and `/privacy` ship with placeholder text marked
**REVIEW WITH LAWYER**, and the same marker is on the waiver rows in the database
(`app_settings.legal.review_status`). Do not launch publicly until a Texas attorney has reviewed
them. The waiver is versioned: every acceptance records which version, when, from what IP and with
what user agent.
