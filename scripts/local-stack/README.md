# Running without Docker

`supabase start` needs Docker, and Docker Desktop needs admin rights. On a machine that does not
have them, this assembles enough of Supabase to develop and test against:

```
Next.js  ->  gateway.mjs (54321)  ->  PostgREST (54322)  ->  Postgres (55432)
                  |
                  +-- /auth/v1 and /storage/v1 answer 501, honestly
```

PostgREST is the same binary Supabase runs, pointed at the same schema, doing the same JWT role
switching against the same RLS policies. What is **not** here is GoTrue (phone OTP) and
storage-api, so anything that needs sign-in or photo upload cannot be tested this way. Those two
return `501 not_implemented_locally` rather than a fake success, so a test that needs them fails
loudly instead of passing for the wrong reason.

## What works

The whole requester and dispatch path: submit a request, get the status link, run the tick, ring
escalation, a volunteer accepting by SMS, the status page updating, mark recovered, the
thank-you. Plus `/board` and every RPC.

## What does not

`/join`, `/me` and `/admin` (all need auth), and photo upload (needs storage). For those, use a
real Supabase project — see step 5 of the main README.

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
psql -h 127.0.0.1 -p 55432 -U postgres -d postgres -c "drop database if exists txrecover (force);" -c "create database txrecover;"
```

```bash
psql -h 127.0.0.1 -p 55432 -U postgres -d txrecover -v ON_ERROR_STOP=1 -f scripts/local-stack/supabase-stubs.sql
```

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

## Honesty about what this proves

Real Postgres, real PostGIS, real RLS, real PostgREST, real JWT role switching. The Supabase
pieces standing in for the real thing are in `supabase-stubs.sql`: `auth.users`, `auth.uid()`,
`auth.jwt()`, `storage.buckets`, `storage.objects`, the four roles, and Supabase's blanket
default privileges on `public` — that last one matters, because without it the `revoke all` in
the RLS migration would be a no-op and the privacy tests would pass for the wrong reason.

It is close. It is not a Supabase instance. Run the suites against a real project before launch.
