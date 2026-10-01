import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";

/**
 * Put the database into a known state before the suite runs.
 *
 * Two kinds of leftover make a run fail in a way that reads as a product bug, and both of them are
 * state the previous run left behind rather than anything the app got wrong.
 *
 * THE RATE-LIMIT COUNTERS. Several guards here are per-day and per-person: three new groups a day,
 * ten events, twenty posts an hour, five recoveries an hour from one connection. Those are human
 * ceilings and they are correct. A suite is not a human -- it files real recoveries, starts real
 * groups and posts real events every run, from 127.0.0.1, as the same four demo members. When it
 * goes over, the RPC answers {"ok": false, "error": "rate_limited_ip"}, the UI prints exactly the
 * right sentence, and the spec dies thirty seconds later on a waitForURL with nothing in the
 * terminal to say why -- in a different spec each run, whichever one tipped over the edge.
 *
 * Clearing the counters is what scripts/local-stack/README.md already prescribes by hand. This is
 * that, automated. The alternative -- raising limits.max_requests_per_ip_per_hour -- is explicitly
 * ruled out there, and rightly: the limiter is one of the few things standing between this app and
 * somebody filling the board with junk, and the suites are the only place it is ever exercised
 * against a real browser. Raising it would retire the test as well as the obstacle.
 *
 * OPEN RECOVERIES. A member may hold exactly one, and create_request answers a second attempt by
 * handing back the one that already exists -- deliberately, so a double submit on a bad connection
 * cannot open two. A run that died after filing therefore leaves the NEXT run filing nothing and
 * hunting for a note that was never written. Cancelling here is also what keeps the suite inside
 * the per-IP allowance: without it, nearby-alerts.spec had to file one request purely to find out
 * what it would get back, and five requests a run against a ceiling of five left no margin at all.
 *
 * Only rows with a requester_user_id are touched. The seeded board recoveries have none -- they
 * belong to no account -- and several specs read them.
 *
 * Allowed to fail silently: no psql means a freshly built stack, where there is nothing to clear.
 * That is also why CI has never seen either problem.
 */
export default function globalSetup() {
  const psql = process.env.PSQL ?? "C:/Users/jjser/tools/pgsql/bin/psql.exe";
  if (!existsSync(psql)) return;

  const sql = [
    "delete from public.rate_limit_hits",
    `update public.requests
        set status = 'cancelled', cancelled_at = now(), cancel_reason = 'stale test run'
      where requester_user_id is not null
        and status in ('submitted','dispatching','unmatched','accepted','on_site')`,
  ];

  for (const statement of sql) {
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
          "-v",
          "ON_ERROR_STOP=1",
          "-tAc",
          statement,
        ],
        {
          encoding: "utf8",
          stdio: ["ignore", "pipe", "pipe"],
          env: { ...process.env, PGPASSWORD: process.env.PGPASSWORD ?? "postgres" },
        },
      );
      const n = /(DELETE|UPDATE) (\d+)/.exec(out.trim());
      if (n && n[2] !== "0") console.log(`global setup: ${n[1].toLowerCase()} ${n[2]}`);
    } catch {
      // A database that is not there, or will not talk to us, is the webServer's problem to report
      // in a sentence the reader can act on. Saying it twice here adds nothing.
    }
  }
}
