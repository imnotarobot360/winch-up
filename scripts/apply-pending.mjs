#!/usr/bin/env node
/**
 * Apply docs/apply-pending.sql to production, after checking it is worth applying.
 *
 * WHY THIS EXISTS. The driver is run from a working copy, and it gets rewritten on most days it is
 * used -- five times on 2026-10-05 alone. On that day a migration was pushed, the owner ran "the
 * driver", nothing changed in production, and it took a round trip to work out that their copy
 * predated the file. From the outside a stale driver and a broken migration look identical: the
 * run succeeds, the banner prints, and the thing you were fixing is still broken.
 *
 * COMPARING THE DRIVER TO THE MIGRATIONS ON DISK WOULD NOT HAVE CAUGHT IT. If you have not
 * pulled, BOTH are old, and they agree with each other perfectly. The only question worth asking
 * is whether this checkout matches the remote, which is why this fetches.
 *
 * It then re-checks what the driver's own header has always asked a human to check, because a
 * comment that says "this must print 2" is only as good as the reader:
 *   - every psql meta-command still begins with a backslash (shell escaping ate two on 2026-10-05,
 *     and the same fault silently applied nothing for days in September)
 *   - every file the driver includes actually exists
 *   - no migration newer than the newest one the driver mentions is sitting unreferenced
 *
 * Then it runs psql with the connection string you give it. Paste the URI WITHOUT the password --
 * psql prompts for that itself and reads it without echoing, so it never reaches a shell history
 * or this script's memory.
 *
 *   node scripts/apply-pending.mjs
 *   node scripts/apply-pending.mjs --dry-run     # check everything, run nothing
 */

import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { createInterface } from "node:readline/promises";
import { stdin, stdout } from "node:process";

// Extracted so they can be unit-tested; see scripts/apply-pending.test.ts. A guard that refuses to
// apply migrations to production is worth more than an untested one by exactly the margin of the
// day it refuses wrongly.
import {
  includedMigrations,
  isMangledMetaCommand,
  unreferencedNewerMigrations,
  versionOf,
} from "./lib/driver-checks.mjs";

const DRIVER = "docs/apply-pending.sql";
const DRY = process.argv.includes("--dry-run");

const problems = [];
const notes = [];

function git(args) {
  return execFileSync("git", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}

// --- 1. is this checkout current? ---------------------------------------------------------------
//
// The one that matters. Everything else is a nicety.
try {
  git(["fetch", "--quiet"]);
  const local = git(["rev-parse", "HEAD"]);
  const remote = git(["rev-parse", "@{upstream}"]);
  if (local !== remote) {
    const behind = Number(git(["rev-list", "--count", "HEAD..@{upstream}"]));
    const ahead = Number(git(["rev-list", "--count", "@{upstream}..HEAD"]));
    if (behind > 0) {
      problems.push(
        `This checkout is ${behind} commit${behind === 1 ? "" : "s"} BEHIND the remote. ` +
          `${DRIVER} and the migrations it names may both be out of date — they would agree with ` +
          `each other and still be wrong. Run: git pull`,
      );
    }
    if (ahead > 0) {
      notes.push(
        `${ahead} local commit${ahead === 1 ? "" : "s"} not pushed. Fine for applying, but the ` +
          `migrations you are about to run are not on the remote yet.`,
      );
    }
  }
} catch {
  notes.push("Could not compare against the remote (no upstream, or git unavailable).");
}

// --- 2. is the driver intact? --------------------------------------------------------------------
if (!existsSync(DRIVER)) {
  problems.push(`${DRIVER} does not exist. Are you in the repo root?`);
} else {
  const text = readFileSync(DRIVER, "utf8").replace(/\r\n/g, "\n");
  const lines = text.split("\n");

  // A meta-command that lost its backslash is bare SQL and a syntax error. In September eight of
  // them did, and the driver silently applied nothing for days because each run looked like one
  // stray error in a wall of success.
  const mangled = lines
    .map((line, i) => [i + 1, line])
    .filter(([, line]) => isMangledMetaCommand(line));
  for (const [n, line] of mangled) {
    problems.push(`Line ${n} is missing its backslash: "${String(line).slice(0, 60)}"`);
  }

  const included = lines
    .filter((l) => /^\\i /.test(l))
    .map((l) => l.replace(/^\\i\s+/, "").trim());

  if (included.length === 0) {
    problems.push(`${DRIVER} includes no migrations at all.`);
  }

  for (const file of included) {
    if (!existsSync(file)) problems.push(`${DRIVER} includes a file that does not exist: ${file}`);
  }

  // Anything newer on disk than the newest file the driver names is a migration somebody forgot to
  // add to it. This cannot catch a checkout that is simply behind -- see the header -- but it does
  // catch the version where the migration was written and the driver was not updated.
  const versionOf = (p) => (p.match(/(\d{14})/) ?? [])[1] ?? "";
  const newestIncluded = included.map(versionOf).sort().at(-1) ?? "";
  const onDisk = execFileSync("git", ["ls-files", "supabase/migrations"], { encoding: "utf8" })
    .trim()
    .split("\n")
    .filter((p) => p.endsWith(".sql"))
    .map(versionOf)
    .filter(Boolean)
    .sort();
  const newer = onDisk.filter((v) => v > newestIncluded);
  if (newer.length) {
    problems.push(
      `${newer.length} migration${newer.length === 1 ? "" : "s"} newer than anything the driver ` +
        `includes: ${newer.join(", ")}. Either add them to ${DRIVER} or they will not be applied.`,
    );
  }

  notes.push(`${DRIVER} applies ${included.length} migration(s): ${included.map(versionOf).join(", ")}`);
}

// --- report --------------------------------------------------------------------------------------
for (const n of notes) console.log(`  · ${n}`);
if (problems.length) {
  console.error("\nRefusing to apply:\n");
  for (const p of problems) console.error(`  ✗ ${p}`);
  console.error("");
  process.exit(1);
}
console.log("\nChecks passed.\n");

if (DRY) {
  console.log("--dry-run: stopping before psql.");
  process.exit(0);
}

// --- run it ----------------------------------------------------------------------------------------
const psql =
  process.env.PSQL ??
  ["C:/Users/jjser/tools/pgsql/bin/psql.exe", "/usr/bin/psql", "psql"].find(
    (p) => p === "psql" || existsSync(p),
  );

const rl = createInterface({ input: stdin, output: stdout });
console.log("Connection URI from the Supabase dashboard: Connect -> Session pooler -> URI.");
console.log("SESSION pooler, port 5432. DELETE THE PASSWORD out of it, colon and all --");
console.log("psql prompts for it and reads it without echoing, so it stays out of your history.\n");
const uri = (await rl.question("URI: ")).trim();
rl.close();

if (!uri) {
  console.error("No URI given.");
  process.exit(1);
}
if (/:[^@/]*@/.test(uri.replace(/^[a-z]+:\/\//, ""))) {
  console.error(
    "\nThat URI still contains a password. Delete it, colon and all, and let psql prompt --" +
      "\notherwise it lands in your shell history and in this terminal's scrollback.\n",
  );
  process.exit(1);
}

// stdio inherited so psql's own hidden password prompt works and the banner is printed live.
const result = spawnSync(psql, [uri, "-v", "ON_ERROR_STOP=1", "-f", DRIVER], { stdio: "inherit" });
process.exit(result.status ?? 1);
