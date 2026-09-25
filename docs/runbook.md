# Winch Up runbook

What to do when something is wrong, written for whoever is holding the phone at 11pm — not
necessarily the person who built it.

---

## The one-minute triage

| Symptom | First thing to check |
|---|---|
| Nobody is getting texts | `SMS_DRY_RUN` is still `1`, or 10DLC was rejected |
| Requests sit at "Sent" forever | the `pg_cron` job is not running |
| A volunteer says they got nothing | they are `pending`, `paused`, opted out, or outside their own radius |
| The status page says "no volunteer yet" too fast | `dispatch.unmatched_after_minutes` was edited |
| Photos do not load | signed URLs expire in ten minutes; reload the page |

---

## Nobody is getting texts

1. **Check the switch in the database first.** Since 2026-09-23 this stops messages before
   anything else does, and it ships off. Recovery SMS is carried by push and in-app instead.

```sql
select value from app_settings where key = 'sms.outbound_enabled';
```

   `false` means `app.queue_sms` recorded the message as `suppressed` and never called Twilio.
   That is the intended state today, so "nobody is getting texts" is usually not a fault. Look for
   `state = 'suppressed'` in the outbox to confirm that is what happened.

2. **Check the dry run.** In Vercel, `SMS_DRY_RUN=1` means every message is logged and none are
   sent. This is the correct setting until A2P 10DLC is approved. Unset it to go live.
3. **Check the outbox.** In Supabase SQL:

```sql
select state, count(*), max(created_at) from sms_messages
 where direction = 'outbound' group by state;
```

   - Rows stuck in `queued` with `attempts = 0` → the drain is not running. See below.
   - Rows in `failed` → read `error_message`. A Twilio 21610 is a recipient who texted STOP;
     that is working as intended, not a bug.
4. **Check the drain.** It runs two ways: inline after a request is created, and from the
   dispatch tick. Fire it by hand:

```bash
curl -X POST "$SITE_URL/api/sms/drain" -H "Authorization: Bearer $DISPATCH_TICK_SECRET"
```

   A 401 means `DISPATCH_TICK_SECRET` differs between Vercel and the Supabase function secrets.

---

## Requests are not advancing

The state machine only moves when something calls it. Check the cron job:

```sql
select jobid, schedule, active, jobname from cron.job;
```

```sql
select start_time, status, return_message
  from cron.job_run_details order by start_time desc limit 20;
```

To advance by hand right now:

```sql
select advance_dispatch(50);
```

That is safe to run at any time and as often as you like — it only touches requests whose
`next_action_at` has passed, and it takes row locks so it cannot collide with the scheduled run.

---

## A request has been sitting too long

The `/admin` queue flags anything past the unmatched threshold with no volunteer. From there:

- **Text somebody specific** — "Dispatch by hand" → *Text*. Sends them the normal offer; they
  can still reply 1 or 2.
- **Assign somebody** — *Assign*. Skips the ring and hands them the job, releasing whoever had
  it. Use this when you have already spoken to them on the phone.
- **Call the requester.** Their number is on the queue card as a tap-to-call link. Sometimes the
  right answer is to tell them to call a tow truck, and the paid-options panel on their status
  page is already showing them that list.

---

## A volunteer says they never got a call-out

Work down this list — the first one is nearly always it:

1. Are they **approved**? `/admin` → Volunteers → Pending.
2. Are they **active** rather than paused? They may have paused themselves in `/me`.
3. Did they **text STOP**? That sets `sms_opt_in = false` and pauses them. They fix it by texting
   START; an admin cannot opt them back in, and should not be able to.
4. Is the job **inside their own radius**? A volunteer who set 15 miles will never be texted about
   something 20 miles away, even in ring 3.
5. Does their **equipment** match? A request that needs a tractor only goes to people who listed
   a tractor.
6. Were they **already holding a job**? `max_active_jobs` defaults to 1.
7. Was it **night**, and did they turn night calls off?

```sql
select first_name, approval, availability, sms_opt_in, sms_opt_out_at,
       radius_miles, equipment, night_ok, last_notified_at
  from responders where phone = '+1XXXXXXXXXX';
```

---

## Somebody is abusing it

- **Block a number**: `/admin` → Settings → Blocked numbers. They can no longer create requests
  or sign up as a volunteer.
- **Ban a volunteer**: `/admin` → Volunteers → Ban. This also pauses them immediately.
- Both actions are written to the audit log with who did it and when.

---

## Rotating a secret

`SUPABASE_SERVICE_ROLE_KEY`, `TWILIO_AUTH_TOKEN` and `DISPATCH_TICK_SECRET` each live in two
places. Change both or things break in ways that look unrelated:

| Secret | Set in |
|---|---|
| `SUPABASE_SERVICE_ROLE_KEY` | Vercel |
| `TWILIO_AUTH_TOKEN` | Vercel (also Supabase Auth, for phone OTP) |
| `DISPATCH_TICK_SECRET` | Vercel **and** `supabase secrets set` **and** the cron job's SQL |

After rotating `DISPATCH_TICK_SECRET`, re-schedule the cron job — the token is baked into the
`cron.schedule` call.

---

## Before you change a dispatch setting

`/admin` → Settings edits `app_settings` live, and the state machine reads it on the next tick.
That is the point, but two of them deserve care:

- **`dispatch.ring_radii_miles`** — widening ring 1 means more people get woken up for every
  request. Narrowing it means slower coverage in the countryside, which is most of the service
  area.
- **`board.reveal_exact_after_accept`** — `false` by default. Setting it to `true` publishes the
  exact location of a stranded stranger on a page anyone can read. There is a reason it ships off.

Every change is in the audit log with the old and new value.

---

## Restoring the legal text

Waivers are versioned and never edited in place. If a bad version is published:

```sql
update waivers set is_current = false where slug = 'requester_waiver' and version = <bad>;
update waivers set is_current = true  where slug = 'requester_waiver' and version = <good>;
```

Requests that were accepted under the bad version keep pointing at it, which is correct — that
is what those people actually agreed to.
