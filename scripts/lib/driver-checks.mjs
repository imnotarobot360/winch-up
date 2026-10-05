/**
 * The checks `scripts/apply-pending.mjs` runs on docs/apply-pending.sql.
 *
 * Extracted so they can be tested. The guard refuses to apply migrations to production, so "it
 * refuses when it should" and "it does NOT refuse when it should not" are both worth asserting --
 * a guard that refuses everything is an outage, and one that refuses nothing is decoration.
 */

/**
 * A psql meta-command that has lost its leading backslash.
 *
 * `\i` becomes `i`, which is bare SQL and a syntax error, and the run halts there looking like one
 * stray error in a wall of success. That silently applied nothing for days in September 2026, and
 * shell escaping did it twice again on 2026-10-05 -- once to an `\i` and once to an `\echo`.
 *
 * Anchored with no leading whitespace, because a meta-command only works at the start of a line,
 * and the word must be followed by a space so ordinary SQL starting with the same letters --
 * `insert into ...` for `i`, `set search_path ...` is a real risk and is why `set` is checked
 * only in this position -- is not swept up.
 */
export function isMangledMetaCommand(line) {
  return /^(echo|i|timing) /.test(String(line));
}

/** The migration paths a driver includes, in order. */
export function includedMigrations(text) {
  return text
    .replace(/\r\n/g, "\n")
    .split("\n")
    .filter((l) => /^\\i /.test(l))
    .map((l) => l.replace(/^\\i\s+/, "").trim());
}

/** The 14-digit version stamp in a migration path, or "" if there is not one. */
export function versionOf(path) {
  return (String(path).match(/(\d{14})/) ?? [])[1] ?? "";
}

/**
 * Migrations on disk that the driver never mentions.
 *
 * Only ones NEWER than everything it includes: older ones are presumed already applied, which is
 * the normal state of a repo with a hundred migrations behind it.
 *
 * THIS CANNOT CATCH A CHECKOUT THAT IS SIMPLY BEHIND, and that is the failure it was written
 * after. If you have not pulled, the driver and the migrations are both old and agree perfectly.
 * Only comparing against the remote answers that, which apply-pending.mjs does separately.
 */
export function unreferencedNewerMigrations(driverText, migrationPaths) {
  const newestIncluded = includedMigrations(driverText).map(versionOf).sort().at(-1) ?? "";
  return migrationPaths
    .filter((p) => p.endsWith(".sql"))
    .map(versionOf)
    .filter(Boolean)
    .filter((v) => v > newestIncluded)
    .sort();
}
