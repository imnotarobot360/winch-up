# A2P 10DLC registration

Everything needed to register the Winch Up messaging campaign, with the answers already drafted.

Nothing in this app can send a text until this is approved, and approval takes days. It is the
longest lead time in the whole project — start it before anything else.

> **Fix this first.** Until 2026-09-22 `/join` collected a phone number and enabled SMS with no
> consent language at all. Carriers ask for a screenshot of the screen where the number is
> entered, and a campaign without visible consent is rejected. It now shows the notice quoted
> below, directly above the button that triggers the first message. Make sure the fix is deployed
> before you submit, because the screenshot has to match what is live.

---

## 1. Gather these before you start

Registration stalls on missing paperwork more than anything else.

| Field | Notes |
|---|---|
| Legal business name | Exactly as registered. Not the trading name. |
| Business type | Sole Proprietor, LLC, Corporation, Non-profit |
| EIN / Tax ID | **No EIN?** See the Sole Proprietor note below. |
| Business address | Must match the EIN registration |
| Website | `https://www.winch-up.com` |
| Business email | On the domain if possible — a Gmail address raises scrutiny |
| Authorised representative | Name, title, email, mobile. Expect a verification code to that mobile. |

**No EIN.** Twilio has a **Sole Proprietor** brand type that needs no EIN. It is throttled hard —
roughly 15–75 message segments per minute and one campaign — but for a volunteer recovery group
in two counties that is likely enough to start, and it is far faster to approve. If this grows
past those two Facebook groups, register properly then.

**Cost.** A one-off brand registration fee and a small monthly campaign fee, both charged by the
carriers through Twilio, plus per-message cost. Budget a few dollars a month at this volume.

---

## 2. Brand registration

Straightforward: the table above, entered in Twilio under **Messaging → Regulatory Compliance →
Brand**. Verification of the authorised representative usually completes in minutes.

---

## 3. Campaign registration

This is the part that gets rejected. Draft answers:

**Use case:** `Mixed` or `Customer Care`. Not Marketing — nothing here promotes anything, and
declaring Marketing invites scrutiny this campaign does not need.

**Campaign description:**

> Winch Up connects drivers whose vehicles are stuck off-road in Texas with nearby volunteers who
> have recovery equipment. When someone submits a request on winch-up.com, we text volunteers
> within a set radius who have opted in, with a short summary and distance. The volunteer replies
> 1 to take the job or 2 to pass. The person who is stuck receives status updates about their own
> request. All volunteers opt in on our website and can reply STOP at any time. This is a free
> community service. No marketing or promotional messages are sent.

**How do end users consent?**

> Volunteers enter their own phone number at https://www.winch-up.com/join and are shown this
> notice directly above the button that sends the first message:
>
> "By giving us your number you agree to receive text messages from Winch Up about recovery
> requests near you and the jobs you take. Message frequency varies — you'll only hear from us
> when somebody nearby is stuck. Message and data rates may apply. Reply STOP to opt out, HELP
> for help. See our Terms and Privacy Policy."
>
> People requesting recovery enter their number on the request form and receive messages only
> about the request they submitted.

Attach a screenshot of `/join` showing that notice. Take it after the fix is deployed.

**Opt-in keywords:** `START`, `UNSTOP` (and `ALTA` for Spanish speakers)
**Opt-out keywords:** `STOP`, `STOPALL`, `UNSUBSCRIBE`, `CANCEL`, `END`, `QUIT` (and `BAJA`)
**Help keywords:** `HELP`, `INFO` (and `AYUDA`)

All of these are already handled by the inbound webhook — see `handle_inbound_sms()` in
`supabase/migrations/20260920002000_dispatch.sql`. Spanish keywords are handled because roughly
half the audience uses Spanish, which is worth mentioning if a reviewer queries them.

**Sample messages.** These are rendered from the live templates, not paraphrased — carriers
compare submissions against real traffic:

```
Winch Up TX-AB12: Truck stuck 13.3 mi from you. Mud, To the frame, needs a second truck,
Travis County. Reply 1 to take it, 2 to pass. STOP to opt out.

Winch Up TX-AB12: we got it. Texting volunteers near you now. Watch for a call.
Status: https://www.winch-up.com/r/abcd1234

Winch Up TX-AB12: Mike is coming, about 40 min out. White F-250. Call (512) 555-0134.

Winch Up: reply 1 to take a job, 2 to pass, HERE when you arrive, DONE when they are out,
STOP to opt out.
```

Submit the Spanish variants too if the form allows more samples — a reviewer who sees unexpected
Spanish traffic later may flag the campaign.

---

## 4. Why campaigns get rejected

Worth reading before submitting, not after.

- **Vague use case.** "Notifications" or "alerts" gets rejected. The description above is specific
  about who texts whom and why.
- **No visible opt-in.** The single most common cause. The screenshot must show the consent
  language on the same screen as the phone field.
- **Samples that do not match the description.** If you describe recovery dispatch, the samples
  must be recovery dispatch.
- **A website that does not explain the service.** `winch-up.com` must be live and describe what
  it does. It does.
- **Missing STOP/HELP in the samples.** Ours carry them.
- **Public URL shorteners** (bit.ly and similar) are treated as spam. We send full
  `winch-up.com` links.

---

## 5. After approval

In order:

1. Buy a number and attach it to a Messaging Service tied to the approved campaign.
2. Set the Twilio env vars in Vercel: `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`,
   `TWILIO_MESSAGING_SERVICE_SID`, `TWILIO_FROM_NUMBER`, `TWILIO_WEBHOOK_SECRET`. **Redeploy** —
   Vercel injects env vars when a deployment is created, not when it serves.
3. Point the number's inbound webhook at `https://www.winch-up.com/api/twilio/inbound`, POST.
4. Add Twilio as the SMS provider under Supabase → Authentication, so `/join` phone verification
   works. Volunteers cannot sign up until this is done.
5. Set `ADMIN_ALERT_PHONES`, or nobody is told when a request goes unmatched.
6. **Leave `SMS_DRY_RUN=1` for one test run.** File a request, watch `/admin/system` drain the
   outbox, confirm the bodies look right. Then set it to `0`.
7. Only then post the recruitment message in `docs/volunteer-recruitment.md`.

**Do not skip step 6.** The first real text goes to a volunteer deciding whether to drive out at
night. It should not be the first one anybody has looked at.
