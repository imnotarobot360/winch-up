import { describe, expect, it } from "vitest";

import {
  includedMigrations,
  isMangledMetaCommand,
  unreferencedNewerMigrations,
  versionOf,
} from "./lib/driver-checks.mjs";

/**
 * The checks that stand between a stale driver and production.
 *
 * Written after 2026-10-05, when docs/apply-pending.sql was rewritten five times in a day, the
 * owner ran it from a working copy that predated the newest version, and nothing happened. From
 * the outside that is indistinguishable from a broken migration: the run succeeds, the banner
 * prints, and the thing you were fixing is still broken.
 *
 * Both directions throughout. A guard that refuses everything is an outage, not a guard.
 */

describe("a meta-command that lost its backslash", () => {
  it("is caught for every command the driver uses", () => {
    expect(isMangledMetaCommand("echo 'hello'")).toBe(true);
    expect(isMangledMetaCommand("i supabase/migrations/x.sql")).toBe(true);
    expect(isMangledMetaCommand("timing off")).toBe(true);
  });

  it("leaves healthy ones alone", () => {
    expect(isMangledMetaCommand("\\echo 'hello'")).toBe(false);
    expect(isMangledMetaCommand("\\i supabase/migrations/x.sql")).toBe(false);
    expect(isMangledMetaCommand("\\timing off")).toBe(false);
  });

  // The reason the pattern needs the trailing space and the line anchor.
  it("does not mistake ordinary SQL for a mangled command", () => {
    expect(isMangledMetaCommand("insert into requests values (1);")).toBe(false);
    expect(isMangledMetaCommand("  echo indented is not column zero")).toBe(false);
    expect(isMangledMetaCommand("-- echo in a comment")).toBe(false);
  });

  /**
   * `set` is deliberately NOT checked. `\set ON_ERROR_STOP on` losing its backslash becomes
   * `set ON_ERROR_STOP on`, which is indistinguishable from the `set search_path = ...` that
   * opens every migration in this repo — and flagging those would make the guard refuse every
   * healthy driver. The cost is named rather than hidden: a mangled `\set` is the one case this
   * does not catch, and ON_ERROR_STOP failing to apply shows up as the run not halting on error.
   */
  it("does not flag `set`, because real SQL starts with it", () => {
    expect(isMangledMetaCommand("set search_path = public, extensions;")).toBe(false);
  });
});

describe("reading what a driver applies", () => {
  const driver = [
    "\\set ON_ERROR_STOP on",
    "\\echo 'starting'",
    "\\i supabase/migrations/20261005000200_a.sql",
    "\\echo 'next'",
    "\\i supabase/migrations/20261005000300_b.sql",
    "notify pgrst, 'reload schema';",
  ].join("\n");

  it("lists the migrations in order", () => {
    expect(includedMigrations(driver)).toEqual([
      "supabase/migrations/20261005000200_a.sql",
      "supabase/migrations/20261005000300_b.sql",
    ]);
  });

  it("survives CRLF, which this repo produces on checkout", () => {
    expect(includedMigrations(driver.replace(/\n/g, "\r\n"))).toHaveLength(2);
  });

  it("pulls the version stamp out of a path", () => {
    expect(versionOf("supabase/migrations/20261005000400_x.sql")).toBe("20261005000400");
    expect(versionOf("supabase/seed.sql")).toBe("");
  });
});

describe("a migration the driver forgot", () => {
  const driver = "\\i supabase/migrations/20261005000300_b.sql";

  it("is reported when it is newer than anything included", () => {
    expect(
      unreferencedNewerMigrations(driver, [
        "supabase/migrations/20261005000300_b.sql",
        "supabase/migrations/20261005000400_c.sql",
      ]),
    ).toEqual(["20261005000400"]);
  });

  // The pairing: a repo full of already-applied history must not trip this on every run.
  it("ignores older ones, which are the normal state of the folder", () => {
    expect(
      unreferencedNewerMigrations(driver, [
        "supabase/migrations/20260920000400_tables.sql",
        "supabase/migrations/20261004000800_earlier.sql",
        "supabase/migrations/20261005000300_b.sql",
      ]),
    ).toEqual([]);
  });

  it("says nothing when the driver is current", () => {
    expect(
      unreferencedNewerMigrations(driver, ["supabase/migrations/20261005000300_b.sql"]),
    ).toEqual([]);
  });
});
