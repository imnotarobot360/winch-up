/**
 * Rebuild a LOCAL Winch Up database from the migration history.
 *
 * WHY THIS EXISTS
 *
 * CLAUDE.md says the test suites assume "a database built the documented way: every migration in
 * order, then seed.sql and demo.sql". That stopped being true and nobody noticed, because nobody
 * rebuilds from scratch -- the local database has been carried forward for weeks and production
 * was migrated by hand, file by file, in an order that happened to work.
 *
 * Run the files in filename order against an empty database today and it fails at
 * 20260923000500, because `create or replace function` refuses to change a function's return
 * type and that file adds a column to nearby_requests' RETURNS TABLE:
 *
 *     ERROR:  cannot change return type of existing function
 *
 * The fix is a `drop function` first. It cannot go in the migration that needs it -- editing an
 * applied migration rewrites history, and a file numbered later runs after the failure -- so the
 * knowledge lives here, in the thing that does the building, as a small registry keyed by the
 * file that needs the drop.
 *
 * This is deliberately NOT how production is migrated. Production takes docs/apply-pending.sql,
 * which applies only the outstanding batch. This script drops and recreates a whole database and
 * will refuse to run against anything that does not look local.
 *
 * Usage, from the repo root:
 *
 *     node scripts/local-stack/rebuild.mjs                    # rebuilds `winchup`
 *     node scripts/local-stack/rebuild.mjs --db winchup_test  # some other local database
 *     node scripts/local-stack/rebuild.mjs --no-demo          # schema and seed only
 */
import { execFileSync } from "node:child_process";
import { readdirSync, existsSync } from "node:fs";
import { join } from "node:path";

const PSQL = process.env.PSQL ?? "C:/Users/jjser/tools/pgsql/bin/psql.exe";
const HOST = process.env.PGHOST ?? "127.0.0.1";
const PORT = process.env.PGPORT ?? "55432";
const USER = process.env.PGUSER ?? "postgres";

const args = process.argv.slice(2);
const dbIndex = args.indexOf("--db");
const DB = dbIndex === -1 ? "winchup" : args[dbIndex + 1];
const WITH_DEMO = !args.includes("--no-demo");

/**
 * Statements to run immediately BEFORE a given migration file.
 *
 * Every entry here is the same bug: a `create or replace function` that changes a return type,
 * which Postgres refuses. Dropping first is safe because the very next thing that runs recreates
 * the function, and nothing holds a reference across the gap -- these are all called by the app
 * over PostgREST by name, not by a stored dependency.
 *
 * Add to this list rather than editing a migration. If a rebuild fails with "cannot change
 * return type of existing function", the message names the file; find the function it redefines
 * and put it here.
 */
const DROPS_BEFORE = {
  // nearby_requests gains a `notes` column in its RETURNS TABLE.
  "20260923000500_help_feed_notes.sql": [
    "drop function if exists public.nearby_requests(double precision, double precision, integer, integer);",
  ],
  // claim_push_deliveries gains `url`. 20260923002600 is the production fix for the same thing;
  // here the drop has to happen before the file rather than after it.
  "20260923001700_chat_notifications.sql": [
    "drop function if exists public.claim_push_deliveries(integer);",
  ],
};

function psql(database, args_, { input } = {}) {
  return execFileSync(
    PSQL,
    ["-h", HOST, "-p", PORT, "-U", USER, "-d", database, "-v", "ON_ERROR_STOP=1", "-q", ...args_],
    { encoding: "utf8", input, env: { ...process.env, PGPASSWORD: process.env.PGPASSWORD ?? "postgres" } },
  );
}

function step(label, fn) {
  process.stdout.write(`  ${label} … `);
  try {
    fn();
    process.stdout.write("ok\n");
  } catch (err) {
    process.stdout.write("FAILED\n\n");
    const text = String(err.stderr || err.stdout || err.message);
    console.error(text.split("\n").filter((l) => l.includes("ERROR")).slice(0, 3).join("\n") || text);
    if (text.includes("cannot change return type")) {
      console.error(
        "\nThat is the return-type bug. Add a `drop function if exists ...` for the function this\n" +
          "file redefines to DROPS_BEFORE at the top of scripts/local-stack/rebuild.mjs, then\n" +
          "run this again. Do not edit the migration.",
      );
    }
    process.exit(1);
  }
}

console.log(`\nRebuilding ${DB} at ${HOST}:${PORT}\n`);

// A guard, not a formality. This drops a database; the one thing it must never be pointed at is
// production, and the port is the only hint available before the database exists.
if (HOST !== "127.0.0.1" && HOST !== "localhost") {
  console.error(`Refusing to run: host is ${HOST}, which is not local.`);
  process.exit(1);
}

step("drop and create the database", () => {
  psql("postgres", ["-c", `drop database if exists ${DB} (force);`, "-c", `create database ${DB};`]);
});

step("supabase stubs (auth schema, roles)", () => {
  psql(DB, ["-f", "scripts/local-stack/supabase-stubs.sql"]);
});

const files = readdirSync("supabase/migrations").filter((f) => f.endsWith(".sql")).sort();
console.log(`\n  ${files.length} migrations\n`);

for (const file of files) {
  const drops = DROPS_BEFORE[file];
  if (drops) {
    step(`  (drop first, see DROPS_BEFORE) ${file}`, () => {
      for (const sql of drops) psql(DB, ["-c", sql]);
    });
  }
  step(`  ${file}`, () => psql(DB, ["-f", join("supabase/migrations", file)]));
}

console.log("");
step("seed.sql", () => psql(DB, ["-f", "supabase/seed.sql"]));

if (WITH_DEMO) {
  // demo.sql refuses to run unless the database has been marked local. That refusal is the
  // safety rail described in CLAUDE.md and is not worked around here -- it is satisfied.
  step("mark-local.sql", () => psql(DB, ["-f", "scripts/local-stack/mark-local.sql"]));
  if (existsSync("supabase/seeds/demo.sql")) {
    step("seeds/demo.sql", () => psql(DB, ["-f", "supabase/seeds/demo.sql"]));
  }
}

step("tell PostgREST the schema changed", () => psql(DB, ["-c", "notify pgrst, 'reload schema';"]));

console.log(`\nDone. ${DB} is built from the full migration history.\n`);
console.log("Run the suites:  for f in supabase/tests/*.sql; do psql ... -f \"$f\"; done\n");
