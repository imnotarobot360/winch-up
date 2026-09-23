#!/usr/bin/env node
/**
 * Fails if .env.example has drifted from what the code actually reads.
 *
 * Both directions matter, and the second one is why this exists. Before Phase 16, .env.example
 * documented `TWILIO_WEBHOOK_SECRET` and `ADMIN_ALERT_PHONES`. Neither is read anywhere. An
 * owner following the deployment guide would have set both, believed the inbound webhook was
 * secured by the first and that admins were being paged by the second, and been wrong twice —
 * the webhook is secured by Twilio's signature over the auth token, and admin alerts come from
 * the `contact.admin_phones` setting in the database. Meanwhile `TWILIO_WEBHOOK_URL`, which the
 * code does read, was not documented at all.
 *
 * A stale example file is worse than none: it is a list of things somebody will configure and
 * then trust.
 *
 * Run with: npm run env:check  (and as part of prebuild)
 */

import { readFileSync, readdirSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");

/**
 * Set by the platform, not by a person. Nobody puts NODE_ENV in .env.example.
 */
const PLATFORM = new Set(["NODE_ENV", "NEXT_RUNTIME", "VERCEL_ENV", "VERCEL_URL", "CI"]);

/**
 * Documented for a human, read by something other than the app: the Supabase CLI, the SQL
 * editor, a runbook. Each one needs a reason, because "it is probably used somewhere" is how
 * the two dead variables survived.
 */
const DOCUMENTED_BUT_NOT_READ_BY_THE_APP = new Map([
  ["SUPABASE_PROJECT_REF", "used by the Supabase CLI, not by the running app"],
  ["SUPABASE_DB_URL", "used to push schema from a terminal, never by the app"],
  ["SENTRY_ORG", "read by next.config.ts at build time to upload source maps"],
  ["SENTRY_PROJECT", "read by next.config.ts at build time to upload source maps"],
  ["SENTRY_AUTH_TOKEN", "read by next.config.ts at build time to upload source maps"],
]);

function walk(dir, files = []) {
  for (const entry of readdirSync(dir)) {
    if (entry === "node_modules" || entry === ".next" || entry.startsWith(".")) continue;
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) walk(full, files);
    else if (/\.(ts|tsx|mjs|js)$/.test(entry)) files.push(full);
  }
  return files;
}

// Only the app. The local stack's own variables (LOCAL_PG_URI, PSQL_BIN and friends) belong to
// scripts that never run in production and are not part of a deployment.
const read = new Set();
for (const file of walk(join(root, "src"))) {
  const source = readFileSync(file, "utf8");
  for (const match of source.matchAll(/process\.env\.([A-Z0-9_]+)/g)) {
    if (!PLATFORM.has(match[1])) read.add(match[1]);
  }
}

const example = readFileSync(join(root, ".env.example"), "utf8");
const documented = new Set(
  [...example.matchAll(/^([A-Z0-9_]+)=/gm)].map((match) => match[1]),
);

const problems = [];

for (const name of [...read].sort()) {
  if (!documented.has(name)) {
    problems.push(`${name} is read by the app but is not in .env.example`);
  }
}

for (const name of [...documented].sort()) {
  if (read.has(name) || DOCUMENTED_BUT_NOT_READ_BY_THE_APP.has(name)) continue;
  problems.push(
    `${name} is in .env.example but nothing reads it — remove it, or add it to ` +
      `DOCUMENTED_BUT_NOT_READ_BY_THE_APP in scripts/check-env.mjs with the reason`,
  );
}

if (problems.length > 0) {
  console.error(`env check failed (${problems.length} problem(s)):\n`);
  for (const problem of problems) console.error(`  - ${problem}`);
  process.exit(1);
}

console.log(
  `env check passed: ${read.size} variables read by the app, all documented; ` +
    `${documented.size} documented, none dead.`,
);
