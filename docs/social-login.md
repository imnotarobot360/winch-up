# Social login: what is built, and what only the owner can do

Written 2026-09-28.

## Status, 2026-09-29

| provider | state |
|---|---|
| **Google** | **LIVE** — configured, consent screen published, account linking verified |
| **Apple** | not started; needs a paid Apple Developer membership |
| ~~Facebook~~ | **removed** by the owner — see below |

Auth runs on a Supabase **custom domain, `auth.winch-up.com`**, so every OAuth redirect URI
here uses that host and not the project's `*.supabase.co` one. That is what puts a branded
domain on the consent screen, and it also keeps verification-email links off a hostname that
reads like phishing.

### Facebook was removed, not deferred

`SOCIAL_PROVIDERS` in `lib/auth/social-providers.ts` lists Apple and Google only. It is absent
from that list rather than merely left unconfigured, so enabling it in the Supabase dashboard —
by accident or by a future hand — cannot make a button appear that nobody intended.

The blocker was never code. Meta requires **App Review** before the button works for anyone but
the developer, and possibly Business Verification on top; the submission form also kept
reporting saved fields as missing. It buys one more sign-in button while Google and
email/password both work, so it was not worth the cost.

Two artefacts from that attempt are still useful and were kept:
`public/brand/icon-1024-tight.png` (the project had no 1024px square icon, and any app store
will want one) and `/data-deletion`, which is a genuinely good public page to have regardless.

## The short version

The app side is done. Sign-in and sign-up render Apple and Google buttons *only for providers
that are actually configured in Supabase*, discovered at runtime — so Google appears and Apple
does not, without either being named in a page.
Nothing is configured, so today nothing renders and the pages look exactly as they did.

The moment you enable a provider in the Supabase dashboard, its button appears. **No deploy, no
code change, no env var in this repo.**

Everything below is account setup in three developer consoles. None of it is something I can do:
it needs your identity, your company details, and in Apple's case your credit card.

## Why the button list is not in this repo

A provider works only if its client id and secret are in the Supabase dashboard. If the app kept
its own list, the two would drift, and the failure is a "Continue with Google" button that
bounces the member to an error page. The project's brief says no button may be decorative, and a
button that cannot work is worse than decorative.

So `lib/auth/social-providers.ts` reads `/auth/v1/settings` — a public endpoint that returns no
secrets — and draws only what is really there.

## The waiver cannot be bypassed by any of this

The spec's one hard rule. It is already true, and not by accident:

Every provider lands on `/auth/callback`, the same PKCE callback the emailed verification link
uses. That route checks the membership agreement and diverts to `/agreement` before anything
else. It was written for email verification and covers OAuth for free, because the check is on
the **session**, not on how the session was obtained.

Behind that, `create_request` and `offer_assistance` consult `app.membership_gate_blocks()` in
the database. Even a member who somehow reached the app without passing the callback cannot file
a request or offer help once the gate is armed. That is the server-side enforcement the spec
asks for, and it does not care which provider you used.

## Still blocked on an attorney

Unchanged, and the spec agrees with it: *"Do not publish an unapproved legal draft."*

There is no attorney-approved membership agreement, so `membership.required` is `false` and no
agreement is published. Social login will work fine before the text exists — members simply are
not asked to sign anything yet, exactly as now. See `docs/membership-agreement.md`.

## Google

1. Google Cloud Console → **APIs & Services → Credentials → Create OAuth client ID → Web
   application**.
2. Authorised redirect URI — this is the **Supabase** callback, not the app's:
   ```
   https://auth.winch-up.com/auth/v1/callback
   ```
3. OAuth consent screen: app name, support email (`help@winch-up.com`), and
   `winch-up.com` as an authorised domain.
4. Supabase → **Authentication → Providers → Google** → paste the client ID and secret, enable.

Google is the easiest of the three and needs no review for basic email/profile scopes.

## Apple

The expensive one.

1. **Apple Developer Program membership, $99/year.** There is no free path for Sign in with
   Apple.
2. Identifiers → an **App ID**, then a **Services ID** (this is the OAuth client id).
3. On the Services ID, configure **Sign in with Apple**:
   - Domain: `winch-up.com`
   - Return URL: the Supabase callback above
4. Keys → create a key with Sign in with Apple, download the `.p8` **once** — Apple will not let
   you download it again.
5. Supabase → **Authentication → Providers → Apple** → Services ID, Team ID, Key ID, and the
   `.p8` contents.

**Private relay.** Apple lets members hide their address behind
`something@privaterelay.appleid.com`. Mail to it only reaches them if the sending domain is
registered in Apple's console, so add `winch-up.com` and the Resend sending identity there, or
every welcome email to an Apple member bounces silently.

**If you ever ship the iOS app** (spec §9): Apple requires Sign in with Apple to be offered
wherever you offer any other social login. Google is live, so shipping an iOS app without
Apple sign-in is a review rejection — which is the main reason Apple is still on the list at
all.

## Account linking, and the trap the spec names

> *Do not automatically merge accounts based solely on an unverified email address.*

Supabase links a new provider identity to an existing user when the email matches **and is
verified**. The setting that governs this is in **Authentication → Providers**; leave email
confirmation ON, which it currently is (`mailer_autoconfirm: false`).

If it were off, anybody could create a Google account with your email address and land inside
your Winch Up account. That is the account-takeover route §8 is warning about, and the defence
is a checkbox that is already set correctly — worth not un-setting.

**Duplicate welcome emails** are already handled: the trigger keys on
`welcome:<user id>`, and a linked identity is the same user id, so a second provider sign-in
queues nothing. A member who ends up with a genuinely separate account is a different problem —
that is the linking question above, not the email.

## Testing locally without any of this

The local auth shim implements `/auth/v1/settings`, so you can see the buttons and the layout
without a single real OAuth client:

```bash
LOCAL_SOCIAL_PROVIDERS=google,apple npm run stack
```

The buttons then render and start a flow the shim cannot finish, which is the point: it
exercises discovery and layout, not the provider handshake. Leave the variable unset and you get
the shipped state, which is no buttons at all.

## What is NOT done

- **Apple** is not configured and has never run against a real OAuth handshake. Google has:
  configured, published, and account linking verified against an existing account.
- Spec §10 asks that no provider be marked operational until the full registration and waiver
  path is tested. Google passes that today only in the trivial sense — no agreement is
  published, so the waiver step is a pass-through. It needs re-testing once the attorney's text
  is live.
- Account **linking** has no UI. Supabase links matching verified emails by itself; a member who
  signs in with a provider using a *different* address gets a second account, and merging the
  two is a manual database job today.
- Native mobile SDKs (§9) are not built, because there is no mobile app. The signature record is
  already platform-agnostic — keyed by user id, with a `signed_via` column — so an agreement
  signed on the web counts everywhere, which is what §9 actually requires.
