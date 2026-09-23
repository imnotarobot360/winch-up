# Running without Docker

`supabase start` needs Docker, and Docker Desktop needs admin rights. On a machine that does not
have them, this assembles enough of Supabase to develop and test against:

```
Next.js  ->  gateway.mjs (54321)  ->  PostgREST (54322)  ->  Postgres (55432)
                  |
                  +-- /auth/v1    -> a small OTP shim over the real auth.users
                  +-- /storage/v1 -> 501, honestly
```

PostgREST is the same binary Supabase runs, pointed at the same schema, doing the same JWT role
switching against the same RLS policies.

The `/auth/v1` shim is NOT GoTrue. It implements only the four endpoints supabase-js calls during
a phone-OTP sign-in, against the real `auth.users` table, so `/join`, `/me` and `/admin` run their
actual code paths. It accepts one fixed code and does no rate limiting, so it belongs nowhere
near production. storage-api is not here at all and returns `501 not_implemented_locally` rather
than a fake success, so a test that needs it fails loudly instead of passing for the wrong reason.

## What works

The whole requester and dispatch path: submit a request, get the status link, run the tick, ring
escalation, a volunteer accepting by SMS, the status page updating, mark recovered, the
thank-you. Plus `/board`, and — with the auth shim — `/join` sign-in, `/me` end to end, and the
whole of `/admin`.

## What does not

- **Photo upload**, which needs storage-api.
- **The address lookup on `/join`**, which calls Mapbox from the browser and needs a real
  `NEXT_PUBLIC_MAPBOX_TOKEN`. Without one the field says "We could not find that place", which is
  the correct degradation but does block finishing the signup form.

For those, use a real Supabase project and a Mapbox token — see step 5 of the main README.

## One-time setup

1. **Postgres 17 + PostGIS**, no installer needed:
   - <https://get.enterprisedb.com/postgresql/postgresql-17.7-1-windows-x64-binaries.zip>
   - <https://download.osgeo.org/postgis/windows/pg17/> — unzip the bundle over the pgsql folder
2. **pgTAP** (pure SQL, no build step): take `sql/pgtap.sql.in` from
   <https://api.pgxn.org/dist/pgtap/1.3.3/pgtap-1.3.3.zip>, substitute `__OS__` and `__VERSION__`,
   and drop it plus `pgtap.control` into `pgsql/share/extension/` as `pgtap--1.3.3.sql`.
3. **PostgREST**: <https://github.com/PostgREST/postgrest/releases>. On Windows it needs
   `pgsql/bin` on `PATH` to find its runtime DLLs.

```bash
initdb -D "$PGDATA" -U postgres --pwfile=... --encoding=UTF8 --locale=C
pg_ctl -D "$PGDATA" -l pg.log -o "-p 55432 -c listen_addresses=127.0.0.1" start
```

## Every time

```bash
node scripts/local-stack/mint-keys.mjs
```

Rebuild the database — stubs, every migration in order, both seeds:

```bash
psql -h 127.0.0.1 -p 55432 -U postgres -d postgres -c "drop database if exists winchup (force);" -c "create database winchup;"
```

```bash
psql -h 127.0.0.1 -p 55432 -U postgres -d winchup -v ON_ERROR_STOP=1 -f scripts/local-stack/supabase-stubs.sql
```

**Mark the database as local before seeding demo data**, or the demo seed refuses:

```bash
psql -h 127.0.0.1 -p 55432 -U postgres -d winchup -f scripts/local-stack/mark-local.sql
```

A database that has not been marked calls itself production and will not accept demo data,
which creates accounts with known passwords and recovery requests that would text real
volunteers. Production is the default on purpose; there is no file that sets it back.

Then apply `supabase/migrations/*.sql` in filename order, followed by `supabase/seed.sql` and
`supabase/seeds/demo.sql`.

Start the API:

```bash
postgrest scripts/local-stack/postgrest.conf
```

```bash
node scripts/local-stack/gateway.mjs
```

Put the minted keys in `.env.local` with `NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321`, then
`npm run dev`.

## Driving the flow by hand

The tick, which `pg_cron` would run every 60 s:

```sql
select advance_dispatch(50);
```

Send whatever that queued (`SMS_DRY_RUN=1` prints it to the dev server console):

```bash
curl -X POST http://127.0.0.1:3100/api/sms/drain -H "Authorization: Bearer $DISPATCH_TICK_SECRET"
```

A volunteer replying `1` with a 45-minute ETA, as Twilio would post it:

```bash
curl -X POST http://127.0.0.1:3100/api/twilio/inbound -d "From=%2B19365550102" -d "To=%2B15125550000" -d "Body=1+45" -d "MessageSid=SMlocal1"
```

> The inbound route only skips Twilio signature verification when `TWILIO_AUTH_TOKEN` is unset
> **and** `NODE_ENV` is not production. In production an unsigned webhook is refused.

## Signing in

The shim accepts one code: `123456`. Any phone works; an unknown one creates an `auth.users` row
the way a first sign-in would.

| Who | Phone | Gets you |
|---|---|---|
| Admin | `(713) 555-0100` | the whole of `/admin` |
| Mike | `(281) 555-0101` | an approved volunteer on `/me` |
| Rosa | `(936) 555-0102` | an approved volunteer, Spanish |
| anything else | — | a new signup, landing as `pending` |

## Honesty about what this proves

Real Postgres, real PostGIS, real RLS, real PostgREST, real JWT role switching. The Supabase
pieces standing in for the real thing are in `supabase-stubs.sql`: `auth.users`, `auth.uid()`,
`auth.jwt()`, `storage.buckets`, `storage.objects`, the four roles, and Supabase's blanket
default privileges on `public` — that last one matters, because without it the `revoke all` in
the RLS migration would be a no-op and the privacy tests would pass for the wrong reason.

It is close. It is not a Supabase instance. Run the suites against a real project before launch.

## After adding an RPC

PostgREST caches the schema at startup. A function added while it is running is invisible to it,
and the call fails the way a missing grant does — `supabase-js` returns no rows and no error worth
reading, so it looks like the function ran and found nothing. Nudge it rather than restarting:

```bash
psql -h 127.0.0.1 -p 55432 -U postgres -d winchup -c "notify pgrst, 'reload schema';"
```

This cost a confusing half hour on the push work: `claim_push_deliveries` returned zero rows
against a queue that demonstrably had one in it.

## Web push locally

`npm run push:keys` prints a VAPID pair. Put it in `.env.local`, which is gitignored. Without the
keys the drain reports `skipped: true` and leaves the deliveries queued rather than burning their
attempts, so nothing is lost by developing with push off.

A real end-to-end push needs a browser subscription against a real push service; headless
Chromium will not give you one. What can be proved locally is everything up to the network hop —
register a subscription with a genuine P-256 key and an unreachable endpoint, drain, and the
delivery comes back `failed` with `getaddrinfo ENOTFOUND`, which means the payload encrypted and
the VAPID JWT signed.
