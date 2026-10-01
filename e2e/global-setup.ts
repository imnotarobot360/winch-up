import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";

/**
 * Clear the rate-limit counters before the suite runs.
 *
 * Several of the guards this app ships are DAILY and per-person: three new groups a day, ten
 * events, five recoveries an hour from one connection. Those are human ceilings and they are
 * right. A test suite is not a human -- it files real recoveries, starts real groups and posts
 * real events, every run, from one IP address, as the same four demo members.
 *
 * So the fourth run of the day fails, and it fails in the most misleading way available. The
 * RPC answers {"ok": false, "error": "rate_limited_ip"}, the UI prints exactly what it should,
 * and the spec dies thirty seconds later on a waitForURL or a missing row with nothing to say
 * about why. It presents as flake: a different spec each run, whichever one happened to tip
 * over the edge -- groups.spec on one run, nearby-alerts.spec and recovery-team.spec together
 * on the next. Both products were correct. Hours went into the wrong half of this.
 *
 * CI never saw it, because CI builds the database from scratch and the table starts empty.
 * That is also why this is allowed to fail silently: no psql means a fresh stack, which means
 * nothing to clear.
 *
 * Deliberately NOT a workaround in the specs. The counters are state, like the request rows
 * and the shared positions, and a run that starts from unknown state finds unknown results.
 */
export default function globalSetup() {
  const psql = process.env.PSQL ?? "C:/Users/jjser/tools/pgsql/bin/psql.exe";
  if (!existsSync(psql)) return;

  try {
    const out = execFileSync(
      psql,
      [
        "-h",
        "127.0.0.1",
        "-p",
        process.env.PGPORT ?? "55432",
        "-U",
        process.env.PGUSER ?? "postgres",
        "-d",
        process.env.PGDATABASE ?? "winchup",
        "-tAc",
        "delete from public.rate_limit_hits",
      ],
      {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
        env: { ...process.env, PGPASSWORD: process.env.PGPASSWORD ?? "postgres" },
      },
    );
    const cleared = /DELETE (\d+)/.exec(out.trim())?.[1];
    if (cleared && cleared !== "0") console.log(`cleared ${cleared} rate-limit counters`);
  } catch {
    // A database that is not there, or one that will not talk to us, is the webServer's problem
    // to report in a sentence the reader can act on. Saying it twice here adds nothing.
  }
}
