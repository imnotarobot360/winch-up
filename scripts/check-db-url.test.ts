import { execFileSync } from "node:child_process";
import { describe, expect, it } from "vitest";

/**
 * Tests for `scripts/check-db-url.sh`, the thing CI uses to tell "cannot reach the database" apart
 * from "the database refused me".
 *
 * WHY A SHELL SCRIPT IS TESTED FROM VITEST. The migrate job has no Node step -- it is checkout,
 * the Supabase CLI and nothing else -- so the checker has to be shell. One implementation, tested
 * in the runner this repo already has, beats a TypeScript twin that drifts from it; CLAUDE.md has
 * two separate rules about twins for a reason.
 *
 * EVERY REJECTION IS PAIRED WITH THE ACCEPTANCE BESIDE IT. A checker that rejects everything
 * passes all six negative cases on its own and is useless, which is the same trap that let radius
 * targeting sit dead through weeks of green suites.
 *
 * NO_NETWORK stops the script before DNS, so these never touch the network. The password values
 * here are obvious fakes.
 */

const REF = "icpwyepfwkguaocbkawe";
const POOLER = "aws-1-us-east-1.pooler.supabase.com";
const GOOD = `postgresql://postgres.${REF}:fake-password@${POOLER}:5432/postgres`;

function check(dbUrl: string): { code: number; out: string } {
  try {
    const out = execFileSync("bash", ["scripts/check-db-url.sh"], {
      env: { ...process.env, DB_URL: dbUrl, NO_NETWORK: "1" },
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    return { code: 0, out };
  } catch (error) {
    const e = error as { status?: number; stdout?: string; stderr?: string };
    return { code: e.status ?? 1, out: (e.stdout ?? "") + (e.stderr ?? "") };
  }
}

describe("check-db-url.sh", () => {
  it("accepts a session-pooler URI", () => {
    const { code, out } = check(GOOD);
    expect(code, out).toBe(0);
    expect(out).toContain("Shape is plausible");
  });

  it("never prints the password, only its length", () => {
    const { out } = check(GOOD);
    expect(out).not.toContain("fake-password");
    expect(out).toContain("password : 13 characters");
  });

  it("does print the host, port, user and database, which is where a typo hides", () => {
    const { out } = check(GOOD);
    expect(out).toContain(POOLER);
    expect(out).toContain("port     : 5432");
    expect(out).toContain(`username : postgres.${REF}`);
    expect(out).toContain("database : postgres");
  });

  it("rejects the IPv6-only direct host", () => {
    const { code, out } = check(`postgresql://postgres:fake@db.${REF}.supabase.co:5432/postgres`);
    expect(code).toBe(1);
    expect(out).toContain("THE DIRECT HOST");
  });

  it("rejects the transaction pooler, which loses the migration lock", () => {
    const { code, out } = check(`postgresql://postgres.${REF}:fake@${POOLER}:6543/postgres`);
    expect(code).toBe(1);
    expect(out).toContain("TRANSACTION MODE");
  });

  it("rejects a bare postgres username at the pooler", () => {
    const { code, out } = check(`postgresql://postgres:fake@${POOLER}:5432/postgres`);
    expect(code).toBe(1);
    expect(out).toContain("WITH THE DOT");
  });

  it("rejects an unencoded @ in the password, which silently reparses the host", () => {
    const { code, out } = check(`postgresql://postgres.${REF}:pw@word@${POOLER}:5432/postgres`);
    expect(code).toBe(1);
    expect(out).toContain("More than one '@'");
  });

  it("rejects a missing password, because Actions cannot be prompted", () => {
    const { code, out } = check(`postgresql://postgres.${REF}@${POOLER}:5432/postgres`);
    expect(code).toBe(1);
    expect(out).toContain("password : ABSENT");
  });

  // THE ONE THAT WAS ACTUALLY IN THE SECRET on 2026-10-04. DNS found no A record and the first
  // version of this script announced "resolves only over IPv6" -- a confident wrong cause from the
  // one tool whose job is refusing to state one. The host simply did not exist.
  it("rejects an unreplaced placeholder in the host", () => {
    const { code, out } = check(`postgresql://postgres.${REF}:realpw@aws-0-REGION.pooler.supabase.com:5432/postgres`);
    expect(code).toBe(1);
    expect(out).toContain("placeholder 'REGION'");
    expect(out).toContain("TEMPLATE");
  });

  // The pairing for it. The placeholder scan covers the host and username ONLY, because a password
  // is whatever somebody chose -- and a false rejection here blocks a deploy, which is worse than
  // the fault being caught.
  it("accepts a real password that happens to contain the word PASSWORD", () => {
    const { code, out } = check(`postgresql://postgres.${REF}:MYPASSWORD123@${POOLER}:5432/postgres`);
    expect(code, out).toBe(0);
    expect(out).toContain("Shape is plausible");
  });

  it("rejects angle brackets, which are never valid unencoded in a URL", () => {
    const { code, out } = check(`postgresql://postgres.${REF}:pw@<host>:5432/postgres`);
    expect(code).toBe(1);
    expect(out).toContain("< or >");
  });

  it("rejects the wrong database name", () => {
    const { code, out } = check(`postgresql://postgres.${REF}:fake@${POOLER}:5432/winchup`);
    expect(code).toBe(1);
    expect(out).toContain("Supabase's is 'postgres'");
  });
});
