# Account email: what is built, and what only the owner can do

Written 2026-09-24.

## The state of play

Winch Up sends account email today. Supabase Auth does it — the verification link at signup and
the password reset — from `noreply@mail.app.supabase.io`, unbranded, and rate-limited to a
handful an hour because that sender is shared by every project on the platform. It works well
enough for a project with no members and will not survive a launch.

Everything below is about replacing that sender, not about replacing the flow. **Supabase Auth
keeps minting and checking the tokens.** It is already doing that correctly, with PKCE and a
server-side exchange in `src/app/auth/callback/route.ts`, and hand-rolling verification tokens in
application code would be a downgrade dressed up as an integration.

## The blocker, stated plainly

`winch-up.com` cannot send or receive mail. Checked 2026-09-24 against Google's resolver:

| Record | Value |
|---|---|
| `A` | `216.150.16.193`, `216.150.1.1` — Vercel |
| `MX` | **none** |
| `TXT` (SPF) | **none** |
| `_dmarc` | **none** |

So `help@winch-up.com` is not a mailbox that exists. Nothing can be delivered to it, and no
service is authorised to send as it. An email sent from that address right now, by any provider,
fails SPF and DMARC alignment and goes to spam if it is accepted at all.

Re-check before assuming any of this is still true:

```bash
curl -s -H "accept: application/dns-json" "https://dns.google/resolve?name=winch-up.com&type=MX"
```

## What has to happen, in order

Steps 1, 2 and 4 need an account, a payment method and DNS access. They are the owner's to do.

### 1. Pick a provider and create the account

Resend is the recommendation: free to 3,000 messages a month, and it gives **both** an HTTP API
(for the emails this app sends) and SMTP credentials (for the ones Supabase sends), so one
account covers both halves. Amazon SES is cheaper at volume but starts sandboxed and needs a
production-access request approved before it can mail real addresses.

The code has a driver for Resend already (`src/lib/email/send.ts`). Another provider is one
function in `DRIVERS` — nothing else is provider-specific.

### 2. Verify the domain — the DNS work

**Verify the apex domain `winch-up.com`, not a subdomain.** Resend's own advice is to send
from a subdomain to isolate reputation, and that advice is good in general — but the brief
requires the sender to be `help@winch-up.com`, and a verified subdomain only lets you send as
`something@send.winch-up.com`. Verify the apex and you get the address the brief asks for.

That costs nothing, because Resend's records do not live on the apex anyway. Verifying
`winch-up.com` gives you three records, and only one of them is at the root:

| Type | Name | Value | Purpose |
|---|---|---|---|
| `TXT` | `resend._domainkey` | issued per account | DKIM — signs each message, so a recipient can prove it really came from this domain |
| `TXT` | `send` | `v=spf1 include:amazonses.com ~all` | SPF, on the bounce subdomain |
| `MX` | `send` | `feedback-smtp.<region>.amazonses.com`, priority 10 | Where bounces go |

The MX is on **`send.winch-up.com`**, not the apex. That is the bounce path, not the From
address, so it does not conflict with an inbox: you can still add apex MX records later to make
`help@` receive mail, and neither touches the other. Copy the values from Resend's dashboard
and **omit the domain from the name** — Vercel wants `send`, not `send.winch-up.com`.

DNS is on Vercel (`ns1.vercel-dns.com`), so these go in the Vercel dashboard under the domain.

DMARC is not one of Resend's required records, but add it — without one, a receiver decides for
itself what to do when SPF or DKIM fails, and you never find out. Start permissive:

| Type | Name | Value |
|---|---|---|
| `TXT` | `_dmarc` | `v=DMARC1; p=none; rua=mailto:<an address you read>` |

`p=none` means "tell me, don't block". Moving to `p=quarantine` before reading a week of
reports is how a launch loses its own verification emails.

### 2b. Google Workspace SMTP, if that is the route

`EMAIL_PROVIDER=smtp` uses any SMTP server, Workspace included:

```
EMAIL_PROVIDER=smtp
SMTP_HOST=smtp.gmail.com
SMTP_PORT=465                       # 465 implicit TLS, or 587 STARTTLS
SMTP_USER=help@winch-up.com
SMTP_PASSWORD=<app password>
EMAIL_FROM=Winch Up <help@winch-up.com>
```

The same four variables go in Supabase's SMTP Settings for the verification and reset emails.

Three things go wrong here, and none of them can be fixed in code:

**The password must be an app password.** Generating one needs 2-step verification on that
account, and Workspace policy can forbid app passwords outright. A normal account password is
refused. If they are blocked for your tenant, that is the case §2 of the brief anticipates —
use Resend, which is already verified on this domain.

**`EMAIL_FROM` must match `SMTP_USER`.** Gmail silently REWRITES a From address the
authenticated mailbox does not own. The mail sends, nothing errors, and it arrives from the wrong
sender. `npm run email:check` warns about this before you find out from a member.

**Roughly 2,000 recipients a day, with per-minute throttling**, and no delivery webhooks. A
signup spike hits the cap as a temporary block rather than a clear error, and a bounce is
invisible to this app: `email_deliveries` records that the server ACCEPTED the message, which
is not the same as it arriving.

That last point is the honest argument for keeping Resend as the sender and Google Workspace as
the mailbox. They do not conflict — Resend's MX lives on `send.winch-up.com` and Workspace's on
the apex — so you can have a real `help@` inbox and a transactional sender that reports bounces.
Switching between them is `EMAIL_PROVIDER` and a redeploy; nothing else in the app changes.

### 3. Point Supabase Auth at it

Dashboard → Project Settings → Authentication → SMTP Settings. Enter the provider's SMTP host,
port, username and password, and set the sender to `help@winch-up.com`.

This one change is what re-brands the verification and reset emails, because Supabase sends
those. It also lifts the shared-sender rate limit, which is the operational reason to do it
before launch rather than after.

Then Authentication → Email Templates. The rendered copy to paste in comes from the same module
the app uses, so the two halves cannot drift apart in tone:

```bash
npm run email:render
```

That writes every template, both languages, HTML and text, to `.tmp/email/`. Paste
`auth.verify.en.html` into **Confirm signup** and `auth.reset.en.html` into **Reset password**.

It renders against the production URL even when your `.env.local` points at localhost, and says
so when it overrides. The first version of this doc gave a one-line `node -e` instead, which did
not run at all -- and had it run, it would have baked `http://127.0.0.1:3100` into the footer of
every production email.

`{{ .ConfirmationURL }}` is Supabase's own placeholder and must be passed through untouched —
that is the single-use link, and substituting anything else produces an email that looks correct
and verifies nobody.

Supabase's template editor holds **one** template per email type, so it cannot serve English and
Spanish from the same project. Until that changes, those two emails go out in English regardless
of the member's language. The welcome and security emails this app sends are correctly bilingual.
That asymmetry is worth knowing about rather than discovering.

### 4. Decide whether `help@` should receive mail

Every one of these emails prints the address. With no MX, a member who replies is talking to
nobody and gets a bounce hours later.

Three ways out: add MX records and a real mailbox (Google Workspace, Fastmail); use a free
forwarder like ImprovMX pointing at an address you already read; or set `EMAIL_REPLY_TO` to an
inbox you have and leave `help@` send-only. The code supports the third today.

### 5. Set the environment variables

In Vercel, for production:

```
EMAIL_PROVIDER=resend
RESEND_API_KEY=<from the provider>
EMAIL_FROM=Winch Up <help@winch-up.com>
EMAIL_SUPPORT_ADDRESS=help@winch-up.com
EMAIL_REPLY_TO=<only if help@ cannot receive>
```

None of these is `NEXT_PUBLIC_`, so none is compiled into the browser bundle and a plain redeploy
picks them up — unlike `NEXT_PUBLIC_MAPBOX_TOKEN`, which needed a cache-off rebuild. `RESEND_API_KEY`
is a real secret: it belongs in Vercel's environment, never in a committed file and never in chat.

## What is already built and tested

- **Copy** — `src/lib/email/templates.ts`. Six templates, English and Spanish, HTML and plain
  text. Brand shell in table markup so Outlook renders it, charcoal on the orange button because
  white on that orange is 2.87:1, and no remote images so a client that blocks them still shows a
  complete email. 31 unit tests, including that Spanish is not English and that no template can
  leak a coordinate, a phone number or a recovery token.
- **Sending** — `src/lib/email/send.ts`. Driver interface, Resend adapter, and a `none` default
  that records the attempt and returns rather than throwing. A signup must not fail because email
  is unconfigured.
- **The log** — `email_deliveries` (migration `20260924000200`). Holds no address, no subject, no
  body and above all no action URL, because that URL is a credential and a table full of them
  would be worth more than what it records. 20 pgTAP assertions, including that the column list
  is exactly what was reasoned about.
- **Send-once** — a partial unique index on `idempotency_key`. §5 says the welcome email goes
  once per verified account; two tabs or a double webhook cannot produce two.

- **The welcome email fires** -- `20260924000300`. A trigger on `auth.users` catches
  `email_confirmed_at` going from null to a timestamp, which Supabase writes inside the
  transaction that verifies the link, so it happens whether or not the browser survived the
  redirect. A second trigger covers accounts created already-confirmed. The row is queued and
  sent by the drain at `/api/sms/drain`, on the same sixty-second clock as the other four
  queues. 13 more pgTAP assertions.
- **Language** -- `auth-form.tsx` now records the signup locale in user metadata, because there
  is nowhere else it is kept: profiles has no locale column and a new member has no responders
  row. Without it every welcome email would be English.

## What is not built

Nothing here has been tested against a real provider, because there is no account to test
against. Until one exists, "the emails work" means the rendering, the queueing and the logging
work -- all three are covered by tests, and none of them is delivery.

The queue is safe to leave in this state: with no provider the drain puts rows BACK to `queued`
rather than failing them, so anybody who verifies between now and the provider being bought still
gets their welcome email on the first tick afterwards.

Retries have no backoff. A provider that refuses a message marks it `failed` and it is not tried
again. That is deliberate for now -- a tight retry loop against an unhappy provider is worse than
a missed welcome email -- but it is the obvious next thing if delivery ever proves flaky.
