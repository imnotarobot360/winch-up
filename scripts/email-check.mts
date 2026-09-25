/**
 * Is the email provider actually configured and working?
 *
 *   npm run email:check                 # configuration and domain status only
 *   npm run email:check -- you@you.com  # ...and send one real message there
 *
 * This exists because every other signal is ambiguous. With no provider the app records sends as
 * `skipped` and carries on, which is correct behaviour and looks identical to a provider that is
 * configured but rejecting everything. Nothing in the UI distinguishes them, and the first time
 * anybody would notice is a member not getting a welcome email.
 *
 * It reads the key from the environment and never prints it.
 */
import { renderEmail } from "../src/lib/email/templates";

const KEY = process.env.RESEND_API_KEY ?? "";
const PROVIDER = (process.env.EMAIL_PROVIDER ?? "none").toLowerCase();
const FROM = process.env.EMAIL_FROM ?? "Winch Up <help@winch-up.com>";
const SUPPORT = process.env.EMAIL_SUPPORT_ADDRESS || "help@winch-up.com";
const SITE = "https://www.winch-up.com";

const to = process.argv[2];

function line(label: string, value: string) {
  console.log(`  ${label.padEnd(22)} ${value}`);
}

console.log("\nConfiguration\n");
line("EMAIL_PROVIDER", PROVIDER === "none" ? "not set — nothing will send" : PROVIDER);
line("RESEND_API_KEY", KEY ? `set (${KEY.length} chars, starts "${KEY.slice(0, 3)}")` : "NOT SET");
line("EMAIL_FROM", FROM);
line("EMAIL_SUPPORT_ADDRESS", SUPPORT);
line("EMAIL_REPLY_TO", process.env.EMAIL_REPLY_TO || "not set (replies bounce if help@ has no MX)");

/* ------------------------------------------------------------------- SMTP */

if (PROVIDER === "smtp") {
  const host = process.env.SMTP_HOST ?? "smtp.gmail.com";
  const port = Number(process.env.SMTP_PORT ?? 465);
  const user = process.env.SMTP_USER ?? "";
  const pass = process.env.SMTP_PASSWORD ?? "";

  line("SMTP_HOST", host);
  line("SMTP_PORT", `${port} (${port === 465 ? "implicit TLS" : "STARTTLS"})`);
  line("SMTP_USER", user || "NOT SET");
  line("SMTP_PASSWORD", pass ? `set (${pass.length} chars)` : "NOT SET");

  if (!user || !pass) {
    console.log("\n  SMTP_USER and SMTP_PASSWORD are both required.\n");
    process.exit(1);
  }

  // Gmail rewrites a From it does not own, silently. Catching that here is the difference
  // between finding out now and finding out from a member asking who "winchup.help" is.
  const sender = FROM.match(/<([^>]+)>/)?.[1] ?? FROM;
  if (host.includes("gmail") && sender.toLowerCase() !== user.toLowerCase()) {
    console.log(`\n  WARNING: EMAIL_FROM sends as ${sender} but SMTP_USER is ${user}.`);
    console.log("  Gmail will rewrite the From header unless that address is an alias this");
    console.log("  mailbox owns. Mail will arrive from the wrong sender and nothing will error.\n");
  }

  const nodemailer = (await import("nodemailer")).default;
  const transport = nodemailer.createTransport({
    host,
    port,
    secure: port === 465,
    auth: { user, pass },
  });

  try {
    await transport.verify();
    console.log("\n  The server accepted the credentials.\n");
  } catch (cause) {
    console.error(`\n  Connection or login failed: ${cause instanceof Error ? cause.message : cause}`);
    console.error("  With Gmail this is almost always an app password: a normal account password");
    console.error("  is refused, and generating one needs 2-step verification switched on.\n");
    process.exit(1);
  }

  if (!to) {
    console.log("Pass an address to send a real test message:  npm run email:check -- you@you.com\n");
    process.exit(0);
  }

  const mail = renderEmail("auth.welcome", {
    locale: "en",
    siteUrl: SITE,
    supportEmail: SUPPORT,
    actionUrl: SITE,
  });

  const info = await transport.sendMail({
    from: FROM,
    to,
    subject: `[test] ${mail.subject}`,
    html: mail.html,
    text: mail.text,
    ...(process.env.EMAIL_REPLY_TO ? { replyTo: process.env.EMAIL_REPLY_TO } : {}),
  });

  console.log(`  Sent to ${to}. Message-ID ${info.messageId}.`);
  console.log("  Check it arrived, check the spam folder, and check WHO it says it is from --");
  console.log("  a rewritten From is the failure this cannot detect for you.\n");
  process.exit(0);
}

/* ----------------------------------------------------------------- Resend */

if (PROVIDER !== "resend" || !KEY) {
  console.log("\nNothing to check against yet. See docs/email-setup.md.\n");
  process.exit(0);
}

/* ------------------------------------------------------- domain verification */

const domains = await fetch("https://api.resend.com/domains", {
  headers: { authorization: `Bearer ${KEY}` },
});

if (!domains.ok) {
  const body = await domains.text().catch(() => "");
  console.error(`\n  Resend refused the key: ${domains.status} ${body.slice(0, 200)}\n`);
  process.exit(1);
}

const list = (await domains.json()) as { data?: { name: string; status: string; region?: string }[] };

console.log("\nDomains on this Resend account\n");

if (!list.data?.length) {
  console.log("  none — the key works, but no domain is added yet, so nothing can be sent\n");
  process.exit(1);
}

for (const d of list.data) {
  const ok = d.status === "verified";
  line(d.name, `${ok ? "verified" : d.status.toUpperCase()}${d.region ? ` (${d.region})` : ""}`);
}

const sender = FROM.match(/<([^>]+)>/)?.[1] ?? FROM;
const senderDomain = sender.split("@")[1] ?? "";
const match = list.data.find((d) => senderDomain === d.name || senderDomain.endsWith(`.${d.name}`));

console.log("");
if (!match) {
  console.log(`  EMAIL_FROM sends as @${senderDomain}, which is not on this account.`);
  console.log("  Resend will reject every message. Add and verify that domain.\n");
  process.exit(1);
}
if (match.status !== "verified") {
  console.log(`  @${senderDomain} is "${match.status}", not verified. DNS is probably not live yet.\n`);
  process.exit(1);
}
console.log(`  EMAIL_FROM (@${senderDomain}) matches a verified domain.\n`);

/* ---------------------------------------------------------------- live send */

if (!to) {
  console.log("Pass an address to send a real test message:  npm run email:check -- you@you.com\n");
  process.exit(0);
}

const mail = renderEmail("auth.welcome", {
  locale: "en",
  siteUrl: SITE,
  supportEmail: SUPPORT,
  actionUrl: SITE,
});

const sent = await fetch("https://api.resend.com/emails", {
  method: "POST",
  headers: { authorization: `Bearer ${KEY}`, "content-type": "application/json" },
  body: JSON.stringify({
    from: FROM,
    to: [to],
    subject: `[test] ${mail.subject}`,
    html: mail.html,
    text: mail.text,
    ...(process.env.EMAIL_REPLY_TO ? { reply_to: process.env.EMAIL_REPLY_TO } : {}),
  }),
});

if (!sent.ok) {
  console.error(`  Send failed: ${sent.status} ${(await sent.text()).slice(0, 300)}\n`);
  process.exit(1);
}

const { id } = (await sent.json()) as { id?: string };
console.log(`  Sent to ${to}. Resend id ${id}.`);
console.log("  Check it arrived, and check the spam folder — that is the part this cannot tell you.\n");
