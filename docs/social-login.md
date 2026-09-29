# Social login: what is built, and what only the owner can do

Written 2026-09-28.

## The short version

The app side is done and **inert**. Sign-in and sign-up render Apple, Google and Facebook
buttons *only for providers that are actually configured in Supabase*, discovered at runtime.
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
   https://icpwyepfwkguaocbkawe.supabase.co/auth/v1/callback
   ```
3. OAuth consent screen: app name, support email (`help@winch-up.com`), and
   `winch-up.com` as an authorised domain.
4. Supabase → **Authentication → Providers → Google** → paste the client ID and secret, enable.

Google is the easiest of the three and needs no review for basic email/profile scopes.

## Facebook

1. Meta for Developers → **Create App** → *Consumer* → add **Facebook Login**.
2. Valid OAuth Redirect URI: the same Supabase callback as above.
3. Supabase → **Authentication → Providers → Facebook** → App ID and App Secret, enable.

**Expect the A2P problem again.** A Meta app starts in Development mode and only works for
accounts listed as developers or testers. Public use of the `email` permission needs **App
Review**, which takes days and asks for a screencast and a privacy policy URL. Use
`https://winch-up.com/privacy`, which is live and real.

Until that review passes, the Facebook button will work for you and fail for everybody else —
the same shape of silent failure as the 10DLC campaign, and worth remembering before announcing
it.

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
wherever you offer Google or Facebook login. Shipping the other two without it is a review
rejection.

## Account linking, and the trap the spec names

> *Do not automatically merge accounts based solely on an unverified email address.*

Supabase links a new provider identity to an existing user when the email matches **and is
verified**. The setting that governs this is in **Authentication → Providers**; leave email
confirmation ON, which it currently is (`mailer_autoconfirm: false`).

If it were off, anybody could create a Facebook account with your email address and land inside
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
LOCAL_SOCIAL_PROVIDERS=google,apple,facebook npm run stack
```

The buttons then render and start a flow the shim cannot finish, which is the point: it
exercises discovery and layout, not the provider handshake. Leave the variable unset and you get
the shipped state, which is no buttons at all.

## What is NOT done

- No provider is configured, so none of this has ever run against a real OAuth handshake.
- Spec §10 asks that no provider be marked operational until the full registration and waiver
  path is tested. None is marked operational, because none is enabled.
- Account **linking** has no UI. Supabase links matching verified emails by itself; a member who
  signs in with a provider using a *different* address gets a second account, and merging the
  two is a manual database job today.
- Native mobile SDKs (§9) are not built, because there is no mobile app. The signature record is
  already platform-agnostic — keyed by user id, with a `signed_via` column — so an agreement
  signed on the web counts everywhere, which is what §9 actually requires.
