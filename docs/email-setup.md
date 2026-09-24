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

The provider issues the exact records. They will be roughly:

| Type | Name | Purpose |
|---|---|---|
| `TXT` | `resend._domainkey` | DKIM — signs each message so the recipient can prove it is really from this domain |
| `TXT` | `send` (or apex) | SPF — lists who may send as this domain |
| `MX` | `send` | Bounce handling on the sending subdomain |
| `TXT` | `_dmarc` | What a recipient should do when the first two fail |

DNS is on Vercel (`ns1.vercel-dns.com`), so these go in the Vercel dashboard under the domain.

Start DMARC permissive and tighten it once you can see reports:

```
v=DMARC1; p=none; rua=mailto:<an address you read>
```

`p=none` means "tell me, don't block". Moving to `p=quarantine` before you have read a week of
reports is how a launch loses its own verification emails.

**Use a subdomain for sending** (`send.winch-up.com` or `mail.winch-up.com`) rather than the
apex. It keeps the reputation of transactional mail separate from anything the domain does
later, and it means the apex MX stays free for a real inbox.

### 3. Point Supabase Auth at it

Dashboard → Project Settings → Authentication → SMTP Settings. Enter the provider's SMTP host,
port, username and password, and set the sender to `help@winch-up.com`.

This one change is what re-brands the verification and reset emails, because Supabase sends
those. It also lifts the shared-sender rate limit, which is the operational reason to do it
before launch rather than after.

Then Authentication → Email Templates. The rendered copy to paste in comes from the same module
the app uses, so the two halves cannot drift apart in tone:

```bash
node -e "require('tsx/cjs'); const {renderEmail}=require('./src/lib/email/templates.ts'); \
  console.log(renderEmail('auth.verify',{locale:'en',actionUrl:'{{ .ConfirmationURL }}', \
  siteUrl:'https://www.winch-up.com',supportEmail:'help@winch-up.com'}).html)"
```

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

## What is not built

The welcome email has nowhere to fire from yet. Supabase does not emit a server-side event on
email confirmation that this app can subscribe to, so the trigger has to be either an Auth Hook
or a check on first authenticated page load. That decision is still open and is the next piece
of work, not an oversight.

Nothing here has been tested against a real provider, because there is no account to test
against. Until one exists, "the emails work" means the rendering and the logging work.
