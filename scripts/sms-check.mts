/**
 * Is Twilio actually set up, and would an SMS actually go out?
 *
 *   npm run sms:check                # configuration and Twilio account state
 *   npm run sms:check -- +15125550123  # ...and send one real message there
 *
 * There are THREE independent gates between "Twilio is configured" and "a volunteer gets a text",
 * and each one fails silently on its own:
 *
 *   1. The env vars here, which this checks.
 *   2. A2P 10DLC registration, without which US carriers drop the message AFTER Twilio accepts
 *      it — so the API returns success and nothing arrives.
 *   3. `sms.outbound_enabled` in app_settings, which ships false. With it off, app.queue_sms
 *      records the message as suppressed and never calls Twilio at all.
 *
 * Phone OTP sign-in is a FOURTH thing and is not checked here: that is Supabase Auth's own SMS,
 * configured with Twilio credentials in the Supabase dashboard, and it does not touch any of the
 * variables below.
 */
const SID = process.env.TWILIO_ACCOUNT_SID ?? "";
const TOKEN = process.env.TWILIO_AUTH_TOKEN ?? "";
const SERVICE = process.env.TWILIO_MESSAGING_SERVICE_SID ?? "";
const FROM = process.env.TWILIO_FROM_NUMBER ?? "";
const DRY = process.env.SMS_DRY_RUN;

const to = process.argv[2];

function line(label: string, value: string) {
  console.log(`  ${label.padEnd(30)} ${value}`);
}

const auth = "Basic " + Buffer.from(`${SID}:${TOKEN}`).toString("base64");

async function twilio(url: string) {
  const res = await fetch(url, { headers: { authorization: auth } });
  const body = await res.json().catch(() => ({}));
  return { ok: res.ok, status: res.status, body: body as Record<string, unknown> };
}

console.log("\nConfiguration\n");
line("TWILIO_ACCOUNT_SID", SID ? `set (${SID.slice(0, 6)}…)` : "NOT SET");
line("TWILIO_AUTH_TOKEN", TOKEN ? `set (${TOKEN.length} chars)` : "NOT SET");
line("TWILIO_MESSAGING_SERVICE_SID", SERVICE ? `set (${SERVICE.slice(0, 6)}…)` : "not set");
line("TWILIO_FROM_NUMBER", FROM || "not set");
line("SMS_DRY_RUN", DRY ? `${DRY} — nothing is really sent` : "not set");

if (!SERVICE && !FROM) {
  console.log("\n  One of TWILIO_MESSAGING_SERVICE_SID or TWILIO_FROM_NUMBER is required.");
  console.log("  Prefer the messaging service: A2P 10DLC registration attaches to it.\n");
}

if (!SID || !TOKEN) {
  console.log("\nNo credentials, so nothing to check against. See docs/runbook.md.\n");
  process.exit(0);
}

/* ------------------------------------------------------------- the account */

const account = await twilio(`https://api.twilio.com/2010-04-01/Accounts/${SID}.json`);

if (!account.ok) {
  console.error(`\n  Twilio refused the credentials: ${account.status}`);
  console.error(`  ${String(account.body.message ?? "")}\n`);
  process.exit(1);
}

console.log("\nAccount\n");
line("friendly name", String(account.body.friendly_name ?? "—"));
line("status", String(account.body.status ?? "—"));
line("type", String(account.body.type ?? "—"));

if (account.body.type === "Trial") {
  console.log("\n  TRIAL ACCOUNT. Twilio will only send to numbers you have verified in the");
  console.log("  console, and prefixes every message with a trial notice. Volunteers who have");
  console.log("  not been verified there simply do not receive anything.");
}

/* --------------------------------------------------- A2P 10DLC registration */

if (SERVICE) {
  const svc = await twilio(`https://messaging.twilio.com/v1/Services/${SERVICE}`);
  console.log("\nMessaging service\n");

  if (!svc.ok) {
    line("lookup", `FAILED ${svc.status} ${String(svc.body.message ?? "")}`);
  } else {
    line("friendly name", String(svc.body.friendly_name ?? "—"));

    const a2p = await twilio(
      `https://messaging.twilio.com/v1/Services/${SERVICE}/Compliance/Usa2p`,
    );

    if (a2p.ok) {
      const status = String(a2p.body.campaign_status ?? a2p.body.status ?? "unknown");
      line("A2P 10DLC campaign", status);
      if (status.toUpperCase() !== "VERIFIED" && status.toUpperCase() !== "APPROVED") {
        console.log("\n  The campaign is not approved. US carriers will DROP messages to mobile");
        console.log("  numbers even though Twilio's API accepts them, so a send looks successful");
        console.log("  here and arrives nowhere. This is the launch blocker, not the code.");
      }
    } else if (a2p.status === 404) {
      line("A2P 10DLC campaign", "NONE — not registered");
      console.log("\n  No campaign on this messaging service. US carriers will drop messages to");
      console.log("  mobile numbers. Register the brand and campaign in the Twilio console;");
      console.log("  approval takes days, not minutes.");
    } else {
      line("A2P 10DLC campaign", `could not read (${a2p.status})`);
    }
  }
}

/* ----------------------------------------------------- the gate in the app */

console.log("\nThe switch inside the app\n");
console.log("  Recovery SMS is off at app.queue_sms regardless of Twilio, and ships that way.");
console.log("  Check it, and turn it on only when the campaign is approved:\n");
console.log("    select value from app_settings where key = 'sms.outbound_enabled';");
console.log("    update app_settings set value = 'true' where key = 'sms.outbound_enabled';\n");
console.log("  Phone OTP sign-in is unaffected by that switch and by every variable above --");
console.log("  it is Supabase Auth's own SMS, configured in the Supabase dashboard.\n");

/* ------------------------------------------------------------- a real send */

if (!to) {
  console.log("Pass a number to send a real test:  npm run sms:check -- +15125550123\n");
  process.exit(0);
}

if (!/^\+1[0-9]{10}$/.test(to)) {
  console.error(`  "${to}" is not E.164 US (+1 then ten digits), which is what this app stores.\n`);
  process.exit(1);
}

const form = new URLSearchParams({
  To: to,
  Body: "Winch Up test message. If you did not expect this, ignore it.",
  ...(SERVICE ? { MessagingServiceSid: SERVICE } : { From: FROM }),
});

const sent = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${SID}/Messages.json`, {
  method: "POST",
  headers: { authorization: auth, "content-type": "application/x-www-form-urlencoded" },
  body: form,
});

const result = (await sent.json()) as Record<string, unknown>;

if (!sent.ok) {
  console.error(`  Send failed: ${sent.status} ${String(result.message ?? "")}`);
  console.error(`  Twilio error code ${String(result.code ?? "—")}\n`);
  process.exit(1);
}

console.log(`  Queued as ${String(result.sid)}, status "${String(result.status)}".`);
console.log("  ACCEPTED IS NOT DELIVERED. Check the Twilio console's message log for the final");
console.log("  status -- an unregistered campaign shows up there as a carrier rejection, minutes");
console.log("  later, and there is no way to see it from here.\n");
