# Account & Security

`/account/security`. Every way into an account, in one place, plus the one rule the screen
exists to enforce.

## The rule

**Nobody may remove their last way in.** There is no support desk behind this product. No one
can restore an account by checking a driving licence, so a member who locks themselves out is
locked out permanently — along with their recovery history and their signed waiver.

The count comes from `public.my_security_state()`, in the database, and is re-read after every
change. A count computed from the browser's session object would go stale the moment anything
changed in another tab, and a stale count is exactly what locks somebody out.

**A confirmed email is deliberately NOT counted as a way in.** It looks like it should be — you
can always send yourself a reset link — but a reset link sets a *password*, and an account whose
only email came from Google has no password to reset and no way to prove the address once the
provider is disconnected. Under-counting refuses a removal that might have been survivable;
over-counting orphans an account permanently. Those costs are not symmetrical.

Two guards, not one: the Disconnect button is not rendered when it would be the last method, and
the handler refuses again on click. GoTrue refuses a last identity as well, and so does the local
shim — a client-only guard would have shipped looking tested.

## What it does

| Section | What a member can do |
|---|---|
| Email | See the address and whether it is confirmed. **Cannot change it here** — see below. |
| Password | Set one (no password yet) or change one. |
| Phone | Add or change a mobile number, confirmed by a code. |
| Connected accounts | Connect or disconnect Google / Apple, subject to the rule above. |
| Signed in elsewhere | Sign out on every device, including this one. |

Deleting the account stayed on `/account`, where it already was, linked from the bottom of this
screen.

### Changing the password

A member who **has** a password must enter it first, and it is checked by signing in with it.
Supabase has a "secure password change" setting that would do this server-side, but it is a
dashboard toggle this repo cannot see or set, and protection that depends on a switch nobody here
can verify is not protection.

A member with **no** password is not asked for one. They proved who they are with Google, or with
a code to their handset — that is the session they are holding.

### Changing the email address — not here, on purpose

`supabase.auth.updateUser({ email })` is one line. The confirmation link it sends lands on
`/auth/callback`, which today understands only the PKCE `code` parameter. An email-change link
that dead-ends leaves somebody unable to sign in with either address, which is worse than not
offering it. The screen says so rather than showing a button that half-works.

To add it: teach `/auth/callback` the `token_hash` + `type=email_change` shape, prove it against
a real Supabase project (the local shim cannot model it), then add the field.

## Connected accounts

The provider list is read from Supabase at request time via `enabledSocialProviders()`, the same
rule the sign-in page follows: the dashboard decides what is usable, this repo decides what is
offered, and a button never appears for something that would fail. Production today has Google
and email/password. Apple is in `SOCIAL_PROVIDERS` but not yet configured, so it correctly does
not render.

**Connecting requires "Manual linking" to be ENABLED** in the Supabase dashboard
(Authentication → Sign In / Providers). It is off by default. With it off, `linkIdentity()`
returns `manual_linking_disabled` and the screen says connecting is turned off rather than "try
again", which somebody could retry forever. The branch keys on that error CODE, not on the
wording of the message beside it.

**Enabled in production on 2026-10-01, and the flow is verified end to end there**: the owner
pressed Connect on Google, came back through the consent screen, and the row reads Connected
with the ways-to-sign-in count one higher. That is the only proof available from outside --
`/auth/v1/settings` does not publish the manual-linking flag, so nothing here can check it.

**After connecting you land on `/me`, not back on this screen.** The callback sends everyone to
`/me` because Supabase matches `redirect_to` against an exact allowlist and a `?next=` query
string stops it matching, falling back to the Site URL. Fixable without touching the allowlist by
setting a short-lived cookie before starting the link and reading it in the callback -- a cookie
survives the round trip where a query string cannot. Not done yet.

The cached provider list has a five-minute TTL, so turning a provider on in the dashboard takes
up to five minutes to show up. That is deliberate — see the comment in `social-providers.ts`.

## The pieces

| File | What it is |
|---|---|
| `supabase/migrations/20260930000100_security_state.sql` | `my_security_state()` — the caller's own methods, never another account, never the hash |
| `supabase/tests/security_state_test.sql` | 19 assertions, including that the email is not counted |
| `src/app/[locale]/account/security/page.tsx` | The route; reads the provider list server-side |
| `src/components/account/security-panel.tsx` | The screen |
| `src/lib/auth/link-phone.ts` | Sending and confirming a phone code — **shared with /join** |
| `src/lib/auth/link-phone.test.ts` | 9 assertions pinning which auth primitive is used |

### Why the phone logic is shared

`signInWithOtp` + `verifyOtp({type:'sms'})` authenticate the *phone identity*.
`updateUser({phone})` + `verifyOtp({type:'phone_change'})` attach a number to the *current user*.
They look interchangeable. Using the first pair for somebody who is already signed in hands them
a second account — that shipped, and three duplicate accounts had to be deleted from production
by hand on 2026-09-30.

So the decision is made once, in `sendPhoneCode`, and **carried** to the confirm step rather than
re-derived there. Re-deriving is its own trap: signing in by phone *creates* a session, so a
second `getSession()` can answer differently from the first.

Guarded by `npm run linking:check`, which counts `auth.users` across the calls. Nothing else can
see this: pgTAP cannot, because the duplicate is created above the database by the auth API, and
Playwright cannot, because the UI is identical either way.

## Testing it locally

The local stack now models `auth.identities` (`scripts/local-stack/supabase-stubs.sql`), and the
demo seed writes the `email` and `phone` identity rows GoTrue would write. Without those rows a
demo account has zero identities, "Disconnect" fails on a provider that is plainly on screen, and
the last-identity refusal can never be reached in the state it guards.

Show the connected-accounts card:

```bash
LOCAL_SOCIAL_PROVIDERS=google node scripts/local-stack/gateway.mjs
```

Then give an account a provider:

```sql
insert into auth.identities (provider_id, user_id, provider, identity_data)
values ('google-test', '<user id>', 'google', '{"sub":"google-test"}');
```

The server caches the provider list for five minutes, so after enabling it locally either wait or
`rm -rf .next/cache/fetch-cache`.

To reach the state the rule guards — one way in, and it is Google:

```sql
update auth.users set encrypted_password = '', phone = null, phone_confirmed_at = null
 where email = 'mike@winchup.test';
delete from auth.identities i using auth.users u
 where i.user_id = u.id and u.email = 'mike@winchup.test' and i.provider in ('email','phone');
```

The screen should then show "You have one way to sign in", no Disconnect button, and the reason
in its place. Verified on 2026-09-30, including the way out: setting a password from that state
takes it to two methods and Disconnect appears.

## Still to do

- **Apple**, once the developer account is paid for. It needs no code here — the button appears
  when the dashboard has it.
- **Manual linking** must be turned on in the dashboard before Connect can work at all.
- **Changing the email address**, which needs the callback work above.
- **Passkeys.** Production's `/auth/v1/settings` reports `passkeys_enabled`, so the option exists.
- An e2e spec driving this screen. It is covered by unit tests, 19 pgTAP assertions and a manual
  pass; what is missing is the regression net.
