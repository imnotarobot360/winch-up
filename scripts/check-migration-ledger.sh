#!/usr/bin/env bash
#
# Would `supabase db push` REPLAY HISTORY against production? Refuse if so.
#
# WHY THIS EXISTS. Nineteen migrations were applied to production by hand between 2026-10-01 and
# 2026-10-04, because both auto-apply paths were silently broken. Applying by hand leaves
# supabase_migrations.schema_migrations behind unless somebody remembers to insert the version, and
# the files that did that insert were overwritten batch by batch -- so the repo cannot say what the
# ledger holds.
#
# THE CATASTROPHE THIS GUARDS. `db push` applies every local migration the ledger does not list, in
# order. If the ledger is behind, that means re-running OLD migrations against a live database --
# and 20260920000600_rls.sql begins with `revoke all on all tables in schema public from anon,
# authenticated`. Correct as the deny-by-default floor at the point in history where it sits; a
# demolition charge anywhere else. CLAUDE.md records what that looks like: 45 of 48 tables lose
# their grants and sixteen test suites fail at once, reading like a catastrophic product regression.
#
# THE RULE. Applying migrations NEWER than everything the ledger knows is the normal, safe case, at
# any count. Applying one OLDER than the newest recorded version is a replay, and is refused. That
# distinction is the whole guard -- a count threshold would both block a legitimate large deploy and
# wave through a single dangerous old file.
#
# Set REMOTE_VERSIONS (newline-separated) to supply the ledger directly; the tests use it, and it is
# also how to dry-run this against a list pasted out of the SQL editor.

set -uo pipefail

MIGRATIONS_DIR="${MIGRATIONS_DIR:-supabase/migrations}"

local_versions="$(ls "$MIGRATIONS_DIR"/*.sql 2>/dev/null | sed -E 's#.*/([0-9]{14}).*#\1#' | sort -u)"
if [ -z "$local_versions" ]; then
  echo "::error title=No migrations found::$MIGRATIONS_DIR holds no .sql files. Wrong working directory?"
  exit 1
fi

if [ -n "${REMOTE_VERSIONS+x}" ]; then
  remote_versions="$(printf '%s\n' "$REMOTE_VERSIONS" | grep -E '^[0-9]{14}$' | sort -u)"
else
  if ! command -v psql > /dev/null 2>&1; then
    echo "::error title=Cannot read the migration ledger::psql is not on this machine, so whether db push would replay history cannot be checked. Refusing rather than guessing: a replay of 20260920000600_rls.sql revokes every grant in production."
    exit 1
  fi
  # `-At` for bare values. A missing table is an error, which is caught below as an empty ledger
  # rather than being allowed to read as "nothing to do".
  remote_versions="$(psql "${DB_URL:?DB_URL is unset}" -At \
    -c "select version from supabase_migrations.schema_migrations order by 1" 2>/dev/null \
    | grep -E '^[0-9]{14}$' | sort -u)"
fi

local_count=$(printf '%s\n' "$local_versions" | grep -c . || true)
remote_count=$(printf '%s\n' "$remote_versions" | grep -c . || true)

echo "local migration files : $local_count"
echo "recorded in production: $remote_count"
echo ""

if [ "$remote_count" -eq 0 ]; then
  echo "::error title=The migration ledger is empty or unreadable::supabase_migrations.schema_migrations lists nothing, so db push would replay the ENTIRE history against production -- including 20260920000600_rls.sql, which revokes every grant before it. Reconcile the ledger first: supabase migration repair --status applied <version> for each version already applied. docs/apply-2026-10-01.md has the procedure."
  exit 1
fi

to_apply="$(comm -23 <(printf '%s\n' "$local_versions") <(printf '%s\n' "$remote_versions"))"
newest_remote="$(printf '%s\n' "$remote_versions" | tail -n 1)"

if [ -z "$to_apply" ]; then
  echo "Nothing to apply: production's ledger lists every local migration."
  echo "Newest recorded version: $newest_remote"
  exit 0
fi

# A version lower than the newest recorded one is a REPLAY, whatever the count.
replays="$(printf '%s\n' "$to_apply" | awk -v n="$newest_remote" 'length($0) && $0 < n')"

echo "Would apply:"
printf '%s\n' "$to_apply" | sed 's/^/  /'
echo ""

if [ -n "$replays" ]; then
  echo "These are OLDER than the newest version production already records ($newest_remote):"
  printf '%s\n' "$replays" | sed 's/^/  /'
  echo ""
  echo "::error title=db push would replay history::$(printf '%s ' $replays)are older than the newest recorded version ($newest_remote), so they were almost certainly applied by hand and never recorded. Re-running them against production is how 20260920000600_rls.sql revokes every grant. Record them instead: supabase migration repair --status applied <version>"
  exit 1
fi

echo "All newer than $newest_remote, so this is a forward-only apply. Safe to push."
