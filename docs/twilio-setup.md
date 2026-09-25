# Twilio: what is built, and the four gates between it and a delivered text

Written 2026-09-25.

The code is done and has been for months: `src/lib/sms/twilio.ts` sends, `src/lib/sms/drain.ts`
drains the outbox, and `src/app/api/twilio/inbound/route.ts` handles replies with Twilio's own
HMAC-SHA1 signature check and a 403 for anything that fails it. None of what follows is code.

## There are two Twilio integrations, and they are configured in different places

Conflating these wastes an afternoon, so be explicit about which one is broken.

| | Configured in | Used by | Affected by `sms.outbound_enabled`? |
|---|---|---|---|
| **Phone OTP sign-in** | the **Supabase dashboard** | `/join`, admin sign-in | **No** |
| **Recovery dispatch SMS** | **Vercel** env vars | the dispatch tick | Yes |

Phone OTP is Supabase Auth sending its own SMS with credentials you give Supabase. It does not
read `TWILIO_ACCOUNT_SID` or anything else below, and switching recovery SMS off never touched it.
If people cannot sign in with a phone, that is the Supabase dashboard, not this app.

## The four gates

A message has to pass all four. Each one fails quietly on its own, and only the first is obvious.

**1. `sms.outbound_enabled` in `app_settings`.** Ships `false`. With it off, `app.queue_sms` —
the only writer to the outbox — records the message as `suppressed`, with the phone redacted and
the params dropped, and never calls Twilio. This is deliberate: push and in-app carry recoveries
now. Turning Twilio on does not flip this, and it should stay off until gate 3 is done.

```sql
select value from app_settings where key = 'sms.outbound_enabled';
update app_settings set value = 'true' where key = 'sms.outbound_enabled';
```

Because suppressed is a terminal state the drain cannot see, flipping this to `true` does **not**
release a backlog of texts about recoveries that finished weeks ago. That was designed in.

**2. `SMS_DRY_RUN`.** Set to `1` in Vercel today. Everything is logged, nothing is sent. Unset it
to go live.

**3. A2P 10DLC registration.** This is the real launch blocker. Without an approved campaign, US
carriers **drop** messages to mobile numbers *after* Twilio has accepted them — the API returns
success, the outbox row says `sent`, and nothing arrives. Register the brand and the campaign in
the Twilio console and attach the campaign to a **Messaging Service**; approval takes days.

Prefer `TWILIO_MESSAGING_SERVICE_SID` over `TWILIO_FROM_NUMBER` for exactly this reason: the
campaign attaches to the service, not to a bare number.

**4. Trial account limits.** A trial Twilio account sends only to numbers verified in the console
and prefixes every message with a trial notice. A volunteer who is not on that list receives
nothing at all.

## The variables

In Vercel, server-side only — none of these is `NEXT_PUBLIC_`:

```
TWILIO_ACCOUNT_SID=
TWILIO_AUTH_TOKEN=
TWILIO_MESSAGING_SERVICE_SID=      # preferred; the A2P campaign attaches here
TWILIO_FROM_NUMBER=                # only if there is no messaging service
TWILIO_WEBHOOK_URL=                # the public URL Twilio posts replies to
```

`TWILIO_WEBHOOK_URL` is not decoration. The inbound route recomputes Twilio's signature over the
exact URL Twilio signed, so a mismatch — http vs https, a trailing slash, a preview domain —
makes every reply 403. Set it to precisely what is in the Twilio console.

Point the messaging service's inbound webhook at `https://www.winch-up.com/api/twilio/inbound`.

## Checking it

```bash
npm run sms:check                     # config, credentials, A2P campaign status
npm run sms:check -- +15125550123     # ...and send one real message
```

It reads the credentials from the environment and never prints them. It reports the A2P campaign
status straight from Twilio's API, which is the one gate you cannot infer from a successful send.

**Accepted is not delivered.** A queued message with an unregistered campaign comes back from the
API as a success and is rejected by the carrier minutes later. The Twilio console's message log
is the only place that shows the final status; nothing in this app can see it.

## What to do, in order

1. Buy a number and create a Messaging Service.
2. Register the A2P 10DLC brand and campaign, attach the campaign to the service. Wait.
3. Set the variables in Vercel. Set the inbound webhook URL in the console and in
   `TWILIO_WEBHOOK_URL`.
4. `npm run sms:check` until the campaign reads approved.
5. Send a real test to your own phone with `npm run sms:check -- +1…`, and confirm in the console
   log that it was **delivered**, not merely accepted.
6. Unset `SMS_DRY_RUN`.
7. Only then decide whether to flip `sms.outbound_enabled`. That is a product decision, not a
   configuration step — see below.

## Whether recovery SMS should come back on at all

It was switched off on 2026-09-23 because push and in-app took over, and the switch exists so it
can come back without a deploy. Worth thinking about before flipping it:

- SMS costs money per message and reaches people with no app installed and no data.
- Push reaches nobody on iPhone unless they have installed the PWA, which is a real gap for a
  product used by people who are stranded.
- Running both means a volunteer gets told twice about the same call-out.

The honest position is that SMS is the more reliable channel for the actual use case and push is
the cheaper one. Turning SMS back on for dispatch call-outs only — not for chat, not for status
updates — is probably right, but it is the owner's call and nothing in the code assumes either way.
