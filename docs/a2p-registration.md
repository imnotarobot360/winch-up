# A2P 10DLC registration, field by field

Written 2026-09-25. This is the launch blocker with the longest lead time — start it before
anything else.

## What you are registering, and in what order

Three things, and they nest. Getting the order wrong means redoing work.

1. **A Brand** — who the business is. Verified against public records, so the details must match
   your filings exactly.
2. **A Campaign** — what you send and who consented to it. This is the one that gets rejected.
3. **A Messaging Service** — the sending pool. The campaign attaches here, and the app points at
   the *service*, not at a number.

Register the campaign against a Messaging Service, then put the number in that service's sender
pool. `TWILIO_MESSAGING_SERVICE_SID` is what the app should use; a bare `TWILIO_FROM_NUMBER`
bypasses the campaign and the messages get dropped.

## Brand

Use the legal entity exactly as registered — the EIN, the legal name and the address are checked
against public records, and a mismatch fails verification rather than asking you to correct it.

If this is not an incorporated business, register as a **Sole Proprietor**. That path exists, is
cheaper, and has a lower throughput limit (roughly one message per second), which is fine for a
dispatcher that rings ten volunteers at a time.

## Campaign

**Use case:** Mixed or Customer Care. This is notification traffic to people who signed up for
it. Not Marketing — nothing here promotes anything, and picking Marketing invites scrutiny the
traffic does not deserve.

**Campaign description.** Say what the product does and who gets messaged:

> Winch Up is a volunteer off-road vehicle recovery dispatcher for Texas. Members who have signed
> up as volunteers and confirmed their mobile number receive a text when somebody nearby needs
> recovery help, and reply 1 to offer or 2 to pass. Messages relate only to recovery requests the
> volunteer has opted in to receive.

**Sample messages.** Generate them, never write them by hand:

```bash
npm run a2p:samples
```

They are rendered from the templates the app actually sends. Carriers compare samples against
real traffic, and a mismatch is a rejection — sometimes months after approval, while the campaign
is carrying live call-outs. Regenerate and update the campaign whenever the copy changes.

Submit both the English and the Spanish samples.

**Opt-in.** This field fails more campaigns than everything else combined. It has to describe a
real flow you can evidence.

> Volunteers opt in on the Winch Up website at https://www.winch-up.com/join. They enter their
> mobile number and see the consent language immediately above the button that sends the
> confirmation code. They then receive a one-time code and enter it, which confirms both the
> number and the opt-in. Only numbers confirmed this way receive call-outs.

That is accurate: the consent text sits directly above the send button in
`src/components/responder/join-form.tsx`, and the number is not usable until the code is verified.
Screenshot that screen — reviewers ask for one.

**Opt-in message wording**, quoted verbatim from `join.smsConsent`:

> By giving us your number you agree to receive text messages from Winch Up: a code to confirm
> this number, and call-outs when somebody needs recovery help near you. Message frequency varies.
> Message and data rates may apply. Reply STOP to opt out, HELP for help. See our Terms and
> Privacy Policy.

If you change that string in `messages/en.json`, update the campaign too. They are supposed to be
the same sentence.

**Opt-out:** `STOP`. Also honoured: `UNSTOP`, `START`, `HELP`, and the Spanish `BAJA` and `AYUDA`.
Handled in `public.handle_inbound_sms`, not by Twilio's Advanced Opt-Out alone.

**Help:** `HELP` or `AYUDA` returns the `responder.help` sample above.

## Before you submit

- `/terms` and `/privacy` must be **live and readable**, because the campaign links to them and a
  reviewer will open them. They currently say **"PLACEHOLDER TEXT — REVIEW WITH LAWYER"**. A
  reviewer who opens that may well reject the campaign, and they would be right to. This is the
  one prerequisite that is not a form field.
- The consent language on `/join` must match what you submit, word for word.
- The number must have SMS capability.

## After approval

```bash
npm run sms:check
```

It reads the campaign status from Twilio's API, which is the only way to tell an approved campaign
from an unapproved one — an unapproved campaign accepts messages through the API and the carriers
drop them afterwards, so a successful send proves nothing.

Then, in order: set `TWILIO_MESSAGING_SERVICE_SID` in Vercel, send a real test with
`npm run sms:check -- +1…`, confirm in the Twilio console log that it was **delivered** and not
merely accepted, and only then unset `SMS_DRY_RUN`.

## Timing

Brand verification is usually same-day. Campaign review is days, and a rejection costs another
round. The registration fees are small and non-refundable per submission, which is the practical
reason to get the opt-in field right the first time rather than iterating.
