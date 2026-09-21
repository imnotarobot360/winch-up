# Deploying

Written so it can be followed top to bottom. Steps 1–3 need your accounts and cannot be done for
you: creating a Supabase project, a GitHub repo and a Vercel project are all actions taken as
you, with your credentials.

---

## Before you put a public URL on this

This app tells a stranded person that volunteers are on the way. Two things are not ready:

- **The legal text is placeholder.** `/terms`, `/waiver` and `/privacy` still carry
  **REVIEW WITH LAWYER** banners, and the waiver rows in the database say the same. People will
  accept that waiver by tapping a checkbox, and `requests.waiver_id` will record that they agreed
  to text no attorney has read.
- **SMS does not work until A2P 10DLC is approved.** Until then carriers drop the messages.
  The app will look like it is working — requests get created, the dispatch state machine
  advances — and nobody will ever receive a text. That failure is silent from the requester's
  side.

Deploying to a private preview URL to check the plumbing is a different thing and is fine. The
full launch checklist is at the bottom of the main README.

---

## 1. Supabase project

**This project:** `icpwyepfwkguaocbkawe` — <https://icpwyepfwkguaocbkawe.supabase.co>

1. <https://supabase.com/dashboard> → new project. Pick the region closest to Texas
   (`us-east-1`). **Note which one** — step 3 matches Vercel's functions to it.
2. **Database → Extensions**: enable `postgis`, `pg_cron`, `pg_net`.
3. **Project Settings → API**: copy the URL, the `anon` key and the `service_role` key.
4. **Project Settings → API → Exposed schemas**: it must list `public` only. If `app` is there,
   remove it — that schema holds the internal helpers and is not meant to be reachable.
5. **Authentication → Providers → Phone**: enable, provider Twilio, credentials from step 4.

```bash
supabase link --project-ref icpwyepfwkguaocbkawe
```

```bash
supabase db push
```

```bash
supabase db execute --file supabase/seed.sql --linked
```

> `supabase/seeds/demo.sql` is **local only**. It creates auth users with a known password.
> Never run it against the project you just made.

Then prove the privacy rules hold on the real thing, not just locally:

```bash
supabase test db --linked
```

## 2. GitHub — <https://github.com/imnotarobot360/winch-up>

```bash
git remote add origin https://github.com/imnotarobot360/winch-up.git
```

```bash
git push -u origin main
```

The repo has no secrets in it: `.env.local` and `scripts/local-stack/keys.json` are ignored, and
the only committed secret is the local-development JWT secret in
`scripts/local-stack/postgrest.conf`, which exists so the no-Docker stack works and is useless
anywhere else.

## 3. Vercel

Import the repo at <https://vercel.com/new>. Framework detection handles the rest — the build
command is `npm run build`, which runs the i18n check first and fails the build if EN and ES have
drifted.

Set **`regions` in `vercel.json` to match your Supabase region** before the first deploy. It
ships as `iad1` (Washington DC), which pairs with a `us-east-1` Supabase. Every server action in
this app makes at least one database round trip; putting the functions on the other side of the
country adds latency to the one page where it matters.

### Environment variables

Add all of these to **Production** and **Preview**. Anything without the `NEXT_PUBLIC_` prefix is
server-only and must never gain one.

| Variable | Where it comes from | Notes |
|---|---|---|
| `NEXT_PUBLIC_SITE_URL` | your domain | No trailing slash. This is what goes in the link texted to a stranded driver — if it is wrong, the status link is wrong. |
| `NEXT_PUBLIC_SUPABASE_URL` | Supabase → API | |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Supabase → API | |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase → API | Bypasses RLS. Server only. |
| `SUPABASE_PROJECT_REF` | Supabase | |
| `TWILIO_ACCOUNT_SID` | Twilio console | |
| `TWILIO_AUTH_TOKEN` | Twilio console | Also what makes the inbound webhook verify signatures. **Without it, in production, the webhook refuses every request** — which is the safe failure, but it means inbound SMS does nothing. |
| `TWILIO_MESSAGING_SERVICE_SID` | Twilio → Messaging → Services | |
| `TWILIO_WEBHOOK_URL` | your domain + `/api/twilio/inbound` | Only needed if signature checks fail behind the proxy. |
| `DISPATCH_TICK_SECRET` | generate one | Must match the Supabase function secret and the cron job SQL. |
| `NEXT_PUBLIC_MAPBOX_TOKEN` | Mapbox | URL-restricted to your domain. Without it the map picker and the `/join` address lookup do not work. |
| `MAPBOX_SECRET_TOKEN` | Mapbox | Optional. Used for the county lookup on new requests. |
| `SMS_DRY_RUN` | `1` until 10DLC is approved | Leave it at `1` in Preview permanently. |
| `W3W_API_KEY` | optional | Without it the what3words paste option says so instead of failing oddly. |

```bash
openssl rand -hex 32
```

## 4. The dispatch tick

Nothing advances without this. Deploy the Edge Function:

```bash
supabase functions deploy dispatch-tick --no-verify-jwt
```

```bash
supabase secrets set DISPATCH_TICK_SECRET=... SITE_URL=https://your-domain
```

Then schedule it, in the Supabase SQL editor:

```sql
select cron.schedule(
  'txrecover-dispatch-tick',
  '* * * * *',
  $$select net.http_post(
      url := 'https://icpwyepfwkguaocbkawe.supabase.co/functions/v1/dispatch-tick',
      headers := '{"Content-Type":"application/json","Authorization":"Bearer YOUR_DISPATCH_TICK_SECRET"}'::jsonb
    )$$
);
```

Confirm it is actually running, rather than assuming:

```sql
select start_time, status, return_message
  from cron.job_run_details order by start_time desc limit 5;
```

## 5. Twilio inbound

**Phone Numbers → your number → Messaging**: webhook to
`https://YOUR_DOMAIN/api/twilio/inbound`, method POST.

## 6. First admin

There is no bootstrap UI — the first admin is made by hand, on purpose.

1. Sign in once at `/join` with your own phone so an `auth.users` row exists.
2. In the SQL editor:

```sql
insert into user_roles (user_id, role)
select id, 'admin' from auth.users where phone = '1XXXXXXXXXX';
```

3. `/admin` should now open for you.

## 7. Before announcing it

Work down the launch checklist in the main README. The ones people skip:

- `supabase test db --linked` green **against the production project**
- 10DLC **approved**, not merely submitted
- `SMS_DRY_RUN` unset in Production
- `contact.admin_phones` holds a real number, or nobody hears about unmatched requests
- `pro_options` has real operators and the placeholder row is gone
- the legal text has been read by a Texas attorney and the banners removed
- two phones raced against one request and exactly one won

---

## Rolling back

Vercel keeps every deployment; promote a previous one from the dashboard. The database does not
roll back with it — migrations are append-only, so a bad migration is fixed by writing another
one, not by reverting. `docs/runbook.md` covers restoring a bad waiver version.
