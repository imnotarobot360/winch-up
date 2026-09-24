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
 *     node scripts/local-stack/rebuild.mjs --restart-stack     # also restart PostgREST + gateway
 *
 * DROPPING THE DATABASE TAKES THE API STACK WITH IT
 *
 * PostgREST and the gateway hold connections to the database being dropped, and `(force)`
 * disconnects them. Neither comes back on its own, so after a plain rebuild the ports are dead
 * and the app gets connection refused from a stack that was running a minute ago.
 *
 * --restart-stack fixes that, and the reason it is a flag rather than the default is the failure
 * it has to avoid: starting a second PostgREST while the first is still holding 54322 gives you
 * two of them, one serving a schema cache from a database that no longer exists. So it kills
 * whatever is listening FIRST, waits for the port to actually clear, then starts and polls until
 * each one answers. It never assumes a spawn succeeded.
 */
import { execFileSync, spawn } from "node:child_process";
import { readdirSync, existsSync, openSync, readFileSync } from "node:fs";
import { join } from "node:path";

const PSQL = process.env.PSQL ?? "C:/Users/jjser/tools/pgsql/bin/psql.exe";
const HOST = process.env.PGHOST ?? "127.0.0.1";
const PORT = process.env.PGPORT ?? "55432";
const USER = process.env.PGUSER ?? "postgres";

const args = process.argv.slice(2);
const dbIndex = args.indexOf("--db");
const DB = dbIndex === -1 ? "winchup" : args[dbIndex + 1];
const WITH_DEMO = !args.includes("--no-demo");
const RESTART_STACK = args.includes("--restart-stack");

const POSTGREST = process.env.POSTGREST ?? "C:/Users/jjser/tools/postgrest/postgrest.exe";
const PSQL_BIN_DIR = PSQL.replace(/[\\/][^\\/]+$/, "");
const LOG_DIR = process.env.LOCAL_STACK_LOG_DIR ?? "C:/Users/jjser/tools";

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

/** PIDs listening on a port. Empty when nothing is, including when the lookup itself fails. */
function listenersOn(port) {
  try {
    const out = execFileSync(
      "powershell",
      [
        "-NoProfile",
        "-Command",
        `(Get-NetTCPConnection -LocalPort ${port} -State Listen -ErrorAction SilentlyContinue).OwningProcess`,
      ],
      { encoding: "utf8" },
    );
    // 0 and 4 are System; killing those is never what anyone meant.
    return [...new Set(out.split(/\s+/).filter((x) => /^\d+$/.test(x) && x !== "0" && x !== "4"))];
  } catch {
    return [];
  }
}

function killListeners(port) {
  for (const pid of listenersOn(port)) {
    try {
      execFileSync("taskkill", ["/PID", pid, "/F", "/T"], { stdio: "ignore" });
    } catch {
      // Already gone between the lookup and the kill, which is fine.
    }
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Wait for a port to have no listener. Returns false if it never clears. */
async function waitForPortClear(port, timeoutMs = 10_000) {
  const until = Date.now() + timeoutMs;
  while (Date.now() < until) {
    if (listenersOn(port).length === 0) return true;
    await sleep(250);
  }
  return false;
}

/**
 * Wait for a URL to answer at all. Any status counts -- it is aliveness, not correctness.
 *
 * `hasDied` lets it give up the moment the process it is waiting for exits, instead of spending
 * the whole timeout waiting for something that is never coming back.
 */
async function waitForHttp(url, timeoutMs = 20_000, hasDied = () => null) {
  const until = Date.now() + timeoutMs;
  while (Date.now() < until) {
    if (hasDied()) return false;
    try {
      const controller = new AbortController();
      const t = setTimeout(() => controller.abort(), 2_000);
      await fetch(url, { signal: controller.signal });
      clearTimeout(t);
      return true;
    } catch {
      await sleep(400);
    }
  }
  return false;
}

/**
 * Start a long-running process that outlives this script.
 *
 * Returns a handle whose `exit` is set if the process dies on its own. Without that, a binary
 * that cannot start at all looks identical to one that is merely slow, and the caller sits
 * through the full HTTP timeout before reporting something unhelpful.
 *
 * PATH matters more than it looks. postgrest.exe links against libpq and its OpenSSL DLLs, which
 * on this machine live in pgsql/bin and are not on the system PATH. Started without them it exits
 * immediately with 0xC0000135 (STATUS_DLL_NOT_FOUND) and writes NOTHING to its log, so the only
 * evidence is the exit code. The gateway needs the same directory for a different reason -- it
 * shells out to psql.
 */
function startDetached(cmd, cmdArgs, logPath, extraEnv = {}) {
  const fd = openSync(logPath, "a");
  const handle = { exit: null, pid: null };
  const child = spawn(cmd, cmdArgs, {
    detached: true,
    stdio: ["ignore", fd, fd],
    env: { ...process.env, PATH: `${PSQL_BIN_DIR};${process.env.PATH}`, ...extraEnv },
    windowsHide: true,
  });
  handle.pid = child.pid;
  child.on("error", (e) => {
    handle.exit = { code: null, message: e.message };
  });
  child.on("exit", (code) => {
    handle.exit = { code, message: null };
  });
  child.unref();
  return handle;
}

/** Turn the exit codes that actually happen here into something a person can act on. */
function explainExit(exit, logPath) {
  if (!exit) return `It is not answering. Last lines of ${logPath}:`;
  if (exit.message) return `It could not be started at all: ${exit.message}`;
  // 0xC0000135. Cost half an hour the first time, because the log file stays completely empty.
  if (exit.code === 3221225781) {
    return (
      "It exited immediately with 0xC0000135, STATUS_DLL_NOT_FOUND -- a DLL it links against is\n" +
      `  missing from PATH. postgrest.exe needs libpq and its OpenSSL DLLs, which live in\n  ${PSQL_BIN_DIR}. Check that directory exists and holds libpq.dll.`
    );
  }
  return `It exited straight away with code ${exit.code}. Last lines of ${logPath}:`;
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

if (RESTART_STACK) {
  console.log("\n  restarting the API stack\n");

  // Down first, both of them, before either goes up. The gateway proxies to PostgREST, so a
  // half-restarted pair is briefly a gateway pointing at a dead backend -- and worse, starting
  // PostgREST while the old one still holds 54322 leaves two processes, one of them serving a
  // schema cache for a database that has been dropped.
  process.stdout.write("    stopping gateway (54321) and postgrest (54322) … ");
  killListeners(54321);
  killListeners(54322);
  const clear21 = await waitForPortClear(54321);
  const clear22 = await waitForPortClear(54322);
  if (!clear21 || !clear22) {
    process.stdout.write("FAILED\n");
    console.error(
      `\n  Port ${!clear21 ? 54321 : 54322} still has a listener after 10s. Something is holding it\n` +
        "  that taskkill could not stop. Find it and stop it by hand rather than starting a second:\n" +
        "    Get-NetTCPConnection -LocalPort 54322 -State Listen | Select OwningProcess\n",
    );
    process.exit(1);
  }
  process.stdout.write("ok\n");

  if (!existsSync(POSTGREST)) {
    console.error(`\n  PostgREST not found at ${POSTGREST}. Set POSTGREST to its path.\n`);
    process.exit(1);
  }

  process.stdout.write("    starting postgrest … ");
  const pgLog = join(LOG_DIR, "postgrest.log");
  const pg = startDetached(POSTGREST, ["scripts/local-stack/postgrest.conf"], pgLog);
  if (!(await waitForHttp("http://127.0.0.1:54322/", 20_000, () => pg.exit))) {
    process.stdout.write("FAILED\n");
    console.error(`\n  PostgREST is not up. ${explainExit(pg.exit, pgLog)}\n`);
    if (!pg.exit || pg.exit.code !== 3221225781) {
      try {
        console.error(readFileSync(pgLog, "utf8").split("\n").slice(-8).join("\n"));
      } catch {}
    }
    process.exit(1);
  }
  process.stdout.write("ok\n");

  // The gateway shells out to psql, so it needs pgsql/bin on the PATH of the process that starts
  // it. Without that it fails with spawn psql ENOENT, which reads as an auth problem rather than
  // a missing binary.
  process.stdout.write("    starting gateway … ");
  const gwLog = join(LOG_DIR, "gateway.log");
  const gw = startDetached("node", ["scripts/local-stack/gateway.mjs"], gwLog);
  if (!(await waitForHttp("http://127.0.0.1:54321/rest/v1/", 20_000, () => gw.exit))) {
    process.stdout.write("FAILED\n");
    console.error(`\n  Gateway is not up. ${explainExit(gw.exit, gwLog)}\n`);
    try {
      console.error(readFileSync(gwLog, "utf8").split("\n").slice(-8).join("\n"));
    } catch {}
    process.exit(1);
  }
  process.stdout.write("ok\n");

  // Proves the whole path rather than two open ports: gateway -> postgrest -> postgres -> an RPC
  // that only exists if the migrations actually applied.
  process.stdout.write("    an RPC end to end … ");
  const res = await fetch("http://127.0.0.1:54321/rest/v1/rpc/get_public_settings", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: "{}",
  });
  if (!res.ok) {
    process.stdout.write(`FAILED (${res.status})\n`);
    process.exit(1);
  }
  process.stdout.write("ok\n");
}

console.log(`\nDone. ${DB} is built from the full migration history.\n`);
if (!RESTART_STACK) {
  console.log("PostgREST and the gateway were disconnected when the database was dropped and are");
  console.log("NOT running. Restart them yourself, or use --restart-stack next time.\n");
}
console.log("Run the suites:  for f in supabase/tests/*.sql; do psql ... -f \"$f\"; done\n");
