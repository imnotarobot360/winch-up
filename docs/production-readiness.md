# Production readiness

Phase 16. What is configured, what is not, who has to do it, and what is still in the way of
launch.

Written to be read by the owner, not by a developer. Where something needs an account, a card or
a decision, it says so and stops — I cannot create accounts, enter payment details, or change
DNS or infrastructure.

---

## The short version

The application is deployed, green, and covered by 626 database assertions, 168 browser tests
and 94 unit tests. Every one of the sixteen phases has work in it.

**It still cannot launch, and none of the three reasons is code:**

1. **No lawyer has read `/terms`, `/waiver` or `/privacy`.** They carry
   `REVIEW WITH LAWYER` placeholders and have since the first milestone. `docs/security-review.md`
   is written to be handed over alongside them.
2. **A2P 10DLC is not registered.** Nothing can text anybody until it is approved, and approval
   takes days. `docs/10dlc-registration.md` has the answers drafted.
3. **There are zero approved volunteers.** The dispatcher works perfectly and reaches nobody.
   `/api/health` reports this as a warning for exactly that reason.

The first two are waiting on somebody being asked. The third is waiting on a conversation with
the people already in the Facebook groups; `docs/volunteer-recruitment.md` has the post.

---

## Configuration, item by item

The list Phase 16 asks for, with the honest state of each.

| | State | Who |
|---|---|---|
| Production environment variables | **Done.** Fourteen read by the app, all documented, checked by `npm run env:check` in the build | — |
| Database migrations | **Done.** 39 applied, in order, verified from scratch before each release | — |
| Authentication providers | **Done.** Email/password with verification and reset, phone OTP. Google and Apple deferred by decision | — |
| Production domain | **Done.** `www.winch-up.com`, apex 308s to it | — |
| HTTPS | **Done.** Vercel-managed | — |
| Email delivery | **Partly.** Supabase SMTP sends auth mail. The app sends no application email, and the notification system records that honestly rather than pretending | Owner, if application email is ever wanted |
| Push notification credentials | **Not built.** No service worker push, no VAPID keys, no mobile app. The delivery log records a push request as suppressed with the reason | Owner decision |
| Map provider credentials | **Done.** Mapbox token set, and `e2e/resilience.spec.ts` proves a dead tile server does not take the board down | — |
| Stripe configuration | **Not wired.** Needs the owner's Stripe account and keys. The schema is ready: every Stripe identifier is unique, so a replayed webhook is a no-op by construction | **Owner** |
| Monitoring and error tracking | **Done, inert until configured.** `/api/health` needs no credentials; Sentry is wired and does nothing until `NEXT_PUBLIC_SENTRY_DSN` is set | **Owner** sets the DSN |
| Database backups | **Not confirmed.** Supabase's automatic backups depend on the plan. Check what the project is actually on | **Owner** |
| Rate limiting | **Done.** Surveyed across all 34 member-callable write RPCs in Phase 14; the reasoning is in `docs/security-review.md` | — |
| Health checks | **Done.** `/api/health` | — |
| CI/CD | **Done.** `.github/workflows/ci.yml` runs on every push and pull request and needs no secrets | — |
| Staging environment | **Not created.** Needs a second Supabase project | **Owner** — see below |

---

## `/api/health`

Unauthenticated, cacheless, and returns counts and ages only — no names, no numbers, no
locations, no request ids. That is what makes it safe to hand to an uptime checker, and a test
asserts the exact set of keys so it stays that way.

```
200  {"status":"ok",       "checks":{"database":true,"schedulerAgeSeconds":12, ...}}
503  {"status":"degraded", "problems":["scheduler last ran 12262s ago"]}
```

It answers the question that matters for this product, which is not "is the web server up" —
Vercel answers that — but **is the dispatcher alive**. A dead `pg_cron` job looks exactly like a
quiet afternoon: nothing moves, no texts go out, and the site serves perfectly.

It returns 503 when the database is unreachable, when the scheduler has not run for five
minutes, or when more than 200 texts are waiting. Point any free uptime checker at it — UptimeRobot,
Better Stack, Pingdom — at five-minute intervals, alerting on non-200.

**Zero approved volunteers appears as a warning, not a failure**, because it is the current
state and not a fault. It is still the quietest possible way for this product to fail.

## Error tracking

Wired, and doing nothing until you set a DSN. Until then there are no requests, no overhead and
no behaviour change — verified by building with no environment at all.

**To turn it on**

1. Create a free Sentry account and a project of type **Next.js**. I cannot create accounts.
2. Copy the DSN it gives you.
3. In Vercel, set `NEXT_PUBLIC_SENTRY_DSN` for Production and Preview.
4. **Redeploy.** Vercel injects environment variables when a deployment is created, not when it
   serves — this project has been caught by that before.

Optionally, for stack traces that name a line of TypeScript rather than a column in a minified
chunk, also set `SENTRY_ORG`, `SENTRY_PROJECT` and `SENTRY_AUTH_TOKEN`. The auth token is a real
secret; the DSN is not, and is shipped to every browser by design.

**What it will never send**

This app handles phone numbers, exact coordinates and live recovery links, so an error report is
a privacy surface — a crash happens while somebody is stuck, which is exactly when their data is
closest to the exception.

- `sendDefaultPii` is off: no IP addresses, no request bodies.
- **Session replay is off, and should stay off.** It records what a person did on screen. Here
  that is a video of somebody's worst evening, including the pin they dropped on their own
  location.
- Performance tracing is off: a large amount of data about a small number of people, in exchange
  for knowing a page took 800ms.
- Every event passes through `src/lib/observability/scrub.ts` first, which redacts phone numbers
  in six formats, coordinates precise enough to drive to, email addresses, anything shaped like a
  key or token, long digit runs, and the `/r/<token>` recovery link — the worst of them, because
  it is the key to a live recovery and anyone with dashboard access could paste it into a browser
  and watch.
- Cookies, headers, request bodies and the user object are deleted outright.

There are eighteen tests for the scrubber. Two of them exist because of defects that were real,
and the difference between how the two were found is the useful part.

The first was caught by a unit test while the scrubber was being written: with the patterns in the
wrong order a fourteen-digit string came out as `id [redacted]9876`, leaking its tail.

The second could not have been caught that way. The path rules — the ones that turn `/r/<token>`
into `/r/[token]` — lived in `scrubUrl`, and `scrubDeep` calls `scrubUrl` only for a key literally
named `url`. Every test passed, because each one asked whether `scrubUrl` redacted a token and it
always did. What no test asked was how often a real event puts a token under a key named `url`,
and the answer is almost never: it arrives as a thrown message, a fetch breadcrumb, a stack frame
filename. This was found by pointing a real DSN at a local build, throwing an error containing a
phone number, a token and a set of coordinates, and reading the payload off the wire before it
left the browser. The phone and the coordinates were redacted. The token was sitting in plain
text, in the one field the tests never looked at.

The path rules now run in `scrubText`, so every string gets them. The lesson worth keeping is that
a unit test proves a function does what it says, and proves nothing about whether that function is
on the path the data actually takes. For a privacy control, read the wire.

**The bundle cost, and what was done about it**

Adding the SDK with a normal import put **+61 kB on every page**, taking the shared bundle from
103 kB to 164 kB. That cost lands hardest on the request wizard, which is opened by somebody
sitting in a field on one bar of signal — the exact person this product exists for.

The browser SDK is therefore imported dynamically, inside the check for a DSN. With no DSN it is
never fetched; with one it loads after the page is interactive. The shared bundle is **106 kB**,
so the standing cost is +3 kB rather than +61, and the request wizard's first load went from
214 kB back to 156 kB.

The trade: an error thrown in the first moments of page load, before the SDK resolves, is missed
in the browser. Server-rendered failures are caught regardless, and those are most of the ones
that matter here.

## Backups

Supabase takes daily backups on paid plans; the free tier's retention is short or absent. **Check
which plan this project is on before launch**, because the answer changes what "we can recover"
means. A volunteer recovery group losing its waiver acceptances would be a legal problem, not
just an operational one.

If the plan does not include backups worth relying on, a nightly `pg_dump` from a machine you
control is enough at this size, and the runbook should say where it lands.

## Staging

Not created. Doing it properly costs a second Supabase project and a Vercel preview environment
pointed at it.

The rule that must hold if it is created: **no production payment credentials and no live
recovery notifications in staging.** `SMS_DRY_RUN=1` covers the second, and the database now
refuses demo data unless explicitly marked non-production, which covers the class of mistake
where a test seed lands somewhere real.

Until there is a staging project, the honest position is that `main` deploys to production and
the safety net is the test suite plus the fact that migrations are applied by hand, deliberately,
one paste at a time.

---

## Rollback

**The application** rolls back in one click. Vercel keeps every deployment; promote a previous
one from the dashboard.

**The database does not roll back with it**, and must not be made to. Migrations are append-only
once applied: a bad one is fixed by writing another. `docs/runbook.md` covers restoring a bad
waiver version, which is the case most likely to need it.

The two are coupled in one direction: an older deployment against a newer schema is usually fine,
because every migration this project has shipped is additive. A newer deployment against an older
schema is not — which is why the schema goes first, always, and why each release here has been
"paste the SQL, confirm it landed, then push".

---

## Mobile applications

Phase 16 asks for the architecture to be prepared for App Store and Google Play distribution.

It already is, in the only sense that costs nothing today: the app is a PWA with a manifest, an
icon set, an installable shell and an offline page, and every surface is built mobile-first and
tested at four viewports on two engines. Somebody can add it to a home screen now.

Native distribution is a different project — a wrapper, two developer accounts, review processes,
and AdMob, which Phase 10 explicitly defers until the apps exist. Nothing has been built that
would have to be undone.

---

## The twelve final deliverables

Where each one lives.

1. **Verified repository audit** — `docs/security-review.md`, plus the Phase 12 schema audit in
   `supabase/migrations/20260922002000_schema_audit.sql`.
2. **Prioritised defects and missing functionality** — the bottom of this document.
3. **Core recovery workflows, tested** — `supabase/tests/lifecycle_test.sql` walks all sixteen
   steps in order.
4. **Responsive design** — four viewports, two engines, 168 browser tests.
5. **Community features** — feed, comments, reactions, blocking, reports, moderation queue.
6. **Business advertising portal** — `/business`, `/admin/ads`, everything except Stripe.
7. **Super admin dashboard** — `/admin`, with MFA, system health, audit log. Partly done; the
   remaining modules are listed below.
8. **Migrations and access policies** — 39 migrations, RLS on every table, asserted by
   `supabase/tests/schema_audit_test.sql`.
9. **Automated test results** — 626 pgTAP, 168 Playwright, 94 unit. `npm run verify` and
   `npm run test:e2e`.
10. **Security and privacy review** — `docs/security-review.md`.
11. **Production deployment documentation** — `docs/deploy.md` and this file.
12. **Remaining launch blockers** — below.

---

## What is left, in the order I would do it

**Blocking launch**

1. A Texas attorney reads `/terms`, `/waiver`, `/privacy`. Oldest and cheapest.
2. Submit A2P 10DLC. Days of lead time.
3. Recruit and approve volunteers. Without this the product reaches nobody.
4. Confirm the Supabase plan's backup retention.

**Worth doing before it matters**

5. Point an uptime checker at `/api/health`.
6. Decide on error tracking.
7. Fill in `contact.admin_phones` at `/admin/settings`, or nobody is told when a request goes
   twenty-five minutes without a volunteer.
8. Add trails at `/admin/trails`. The directory ships empty on purpose and stays empty until
   somebody with a source fills it in.

**Built but not finished**

9. Stripe: checkout, webhook signature verification, billing history. Needs keys.
10. Screens for groups, events and the notification preferences beyond the three existing
    toggles. The data model is in production waiting for them.
11. Trail photos and a map view.
12. The remaining super admin modules: billing reporting, system analytics, feature flags.

**Deliberately not built, with reasons in the commits**

Google AdMob (no mobile app), push notifications (no credentials, no app), a public directory of
paid businesses (reads as endorsement by a volunteer group), a group-by-group feed (splits a
6,800-member community into quiet rooms).
