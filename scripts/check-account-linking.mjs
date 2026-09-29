#!/usr/bin/env node
/**
 * One member, one account: does linking a phone to a signed-in member keep it that way?
 *
 *   npm run linking:check      (needs the local stack running)
 *
 * WHY A SCRIPT RATHER THAN pgTAP OR PLAYWRIGHT
 *
 * pgTAP cannot see this: the duplicate is created by the AUTH API, above the database, and a
 * SQL test that inserts its own users proves nothing about which user GoTrue hands back.
 * Playwright cannot see it either -- the UI looks identical whether the phone linked or a
 * second account was born, which is exactly why this shipped. The only thing that shows it is
 * counting auth.users across the calls, which is what this does.
 *
 * WHAT WENT WRONG, so the next person understands what is being guarded
 *
 * /join used to call signInWithOtp({ phone }) then verifyOtp({ type: "sms" }) unconditionally.
 * Those AUTHENTICATE THE PHONE IDENTITY. A member who joined with email or Google and then
 * verified their number was not linking it -- they were handed a second, separate user, and
 * their responder profile attached to that one while their waiver signature, vehicles and
 * requests stayed on the first.
 *
 * The fix uses updateUser({ phone }) + verifyOtp({ type: "phone_change" }) when a session
 * exists, which attaches the number to the CURRENT user. signInWithOtp remains for somebody
 * with no session, which is a legitimate way back in.
 *
 * This script asserts three things, and the third is the one people forget:
 *   1. linking adds no new user
 *   2. the number lands on the account that already had the email
 *   3. a number already on ANOTHER account is refused, not quietly moved
 */
import { execFileSync } from "node:child_process";

const BASE = process.env.LINKING_CHECK_AUTH ?? "http://127.0.0.1:54321/auth/v1";
const PSQL = process.env.LINKING_CHECK_PSQL ?? "C:/Users/jjser/tools/pgsql/bin/psql.exe";
const PHONE = "+15125557788";
const PASSWORD = "recovery-demo-2026";

const sql = (q) =>
  execFileSync(
    PSQL,
    ["-h", "127.0.0.1", "-p", "55432", "-U", "postgres", "-d", "winchup", "-X", "-A", "-t", "-c", q],
    { env: { ...process.env, PGPASSWORD: "postgres" }, encoding: "utf8" },
  ).trim();

async function api(path, opts = {}) {
  const res = await fetch(`${BASE}${path}`, {
    ...opts,
    headers: { "content-type": "application/json", apikey: "x", ...(opts.headers ?? {}) },
  });
  let body = {};
  try {
    body = await res.json();
  } catch {
    /* empty bodies are fine */
  }
  return { status: res.status, body };
}

const failures = [];
const check = (ok, label) => {
  console.log(`  ${ok ? "ok  " : "FAIL"}  ${label}`);
  if (!ok) failures.push(label);
};

console.log("\nAccount linking\n");

// A clean slate, so a previous run cannot make this pass or fail for the wrong reason.
sql(`delete from auth.users where phone = '${PHONE}' or email like 'linking-check-%'`);

const email = `linking-check-${Date.now()}@example.invalid`;
await api("/signup", {
  method: "POST",
  body: JSON.stringify({ email, password: PASSWORD, data: {} }),
});
const confirmed = await api("/verify", {
  method: "POST",
  body: JSON.stringify({ email, token: "123456", type: "signup" }),
});

const token = confirmed.body.access_token;
const userId = confirmed.body.user?.id;
const auth = { authorization: `Bearer ${token}` };

if (!token || !userId) {
  console.error("\ncould not create a test account -- is the local stack running?\n");
  process.exit(1);
}

const beforeLink = Number(sql("select count(*) from auth.users"));

await api("/user", { method: "PUT", headers: auth, body: JSON.stringify({ phone: PHONE }) });
const verified = await api("/verify", {
  method: "POST",
  headers: auth,
  body: JSON.stringify({ phone: PHONE, token: "123456", type: "phone_change" }),
});

const afterLink = Number(sql("select count(*) from auth.users"));

check(afterLink === beforeLink, `linking a phone creates no second account (${beforeLink} -> ${afterLink})`);
check(verified.body.user?.id === userId, "the session still belongs to the account that had the email");
check(
  sql(`select coalesce(phone,'') from auth.users where id = '${userId}'`) === PHONE,
  "the number is on that same account",
);

// Somebody else's number must be refused rather than moved -- moving it silently would be the
// account-takeover version of this feature.
const other = `linking-check-other-${Date.now()}@example.invalid`;
await api("/signup", { method: "POST", body: JSON.stringify({ email: other, password: PASSWORD, data: {} }) });
const otherSession = await api("/verify", {
  method: "POST",
  body: JSON.stringify({ email: other, token: "123456", type: "signup" }),
});
const steal = await api("/user", {
  method: "PUT",
  headers: { authorization: `Bearer ${otherSession.body.access_token}` },
  body: JSON.stringify({ phone: PHONE }),
});

check(steal.status === 422, `a number on another account is refused (got ${steal.status})`);
check(
  sql(`select coalesce(phone,'') from auth.users where id = '${userId}'`) === PHONE,
  "and the original owner keeps it",
);

sql(`delete from auth.users where email like 'linking-check-%'`);

console.log("");
if (failures.length) {
  console.error(`account linking check FAILED: ${failures.length} problem(s)\n`);
  process.exit(1);
}
console.log("account linking check passed: one member, one account.\n");
