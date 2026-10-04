import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * Tests for `scripts/check-migration-ledger.sh`, which refuses a `db push` that would replay
 * history against production.
 *
 * THE THING IT GUARDS. 20260920000600_rls.sql begins by revoking every grant in schema public --
 * correct as the deny-by-default floor where it sits in history, a demolition charge if re-run
 * against a live database. Nineteen migrations were applied by hand in October 2026, and a ledger
 * that did not record them makes `db push` re-run exactly that file.
 *
 * REMOTE_VERSIONS supplies the ledger, so nothing here needs a database. Forward-only must be
 * ACCEPTED at any count -- a guard that refuses every push is not a guard, it is an outage, and
 * that pairing is what the three safe cases below are for.
 */

function dir(versions: string[]): string {
  const d = mkdtempSync(join(tmpdir(), "ledger-"));
  for (const v of versions) writeFileSync(join(d, `${v}_thing.sql`), "-- test\n");
  return d;
}

function check(localVersions: string[], remote: string[]): { code: number; out: string } {
  try {
    const out = execFileSync("bash", ["scripts/check-migration-ledger.sh"], {
      env: {
        ...process.env,
        MIGRATIONS_DIR: dir(localVersions),
        REMOTE_VERSIONS: remote.join("\n"),
      },
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    return { code: 0, out };
  } catch (error) {
    const e = error as { status?: number; stdout?: string; stderr?: string };
    return { code: e.status ?? 1, out: (e.stdout ?? "") + (e.stderr ?? "") };
  }
}

const A = "20260101000100";
const B = "20260101000200";
const C = "20260101000300";
const D = "20260101000400";

describe("check-migration-ledger.sh", () => {
  it("allows a forward-only apply", () => {
    const { code, out } = check([A, B, C, D], [A, B, C]);
    expect(code, out).toBe(0);
    expect(out).toContain("forward-only");
  });

  it("allows a LARGE forward-only apply, because the count is not the danger", () => {
    const { code, out } = check([A, B, C, D], [A]);
    expect(code, out).toBe(0);
    expect(out).toContain("forward-only");
  });

  it("allows a push with nothing to apply", () => {
    const { code, out } = check([A, B, C, D], [A, B, C, D]);
    expect(code, out).toBe(0);
    expect(out).toContain("Nothing to apply");
  });

  it("refuses a gap in the middle, which is a hand-applied migration never recorded", () => {
    const { code, out } = check([A, B, C, D], [A, C, D]);
    expect(code).toBe(1);
    expect(out).toContain("would replay history");
    expect(out).toContain(B);
  });

  it("refuses an empty ledger, which would replay the entire history", () => {
    const { code, out } = check([A, B, C, D], []);
    expect(code).toBe(1);
    expect(out).toContain("ledger is empty");
  });

  it("names the newest recorded version, so the verdict can be checked by hand", () => {
    const { out } = check([A, B, C, D], [A, B, C]);
    expect(out).toContain(C);
  });
});
