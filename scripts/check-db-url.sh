#!/usr/bin/env bash
#
# Is a Supabase connection string the right SHAPE, and can this machine reach it?
#
# WHY THIS EXISTS. On 2026-10-04 the CI migrate job finally received SUPABASE_DB_URL and still
# failed at the first step that connects. There are three ways to get that string wrong and a
# timeout looks the same for all three, so two days went into guessing between them. This asks the
# string and the network directly, before anything tries to authenticate.
#
# IT NEVER PRINTS THE PASSWORD. Host, port, username and database ARE printed, deliberately: the
# project ref is already inside NEXT_PUBLIC_SUPABASE_URL, which ships in the browser bundle, and
# the pooler host is a region. Those four fields are exactly where a typo hides, so masking them
# would defeat the whole point. The password is reported as a length plus a verdict on whether it
# needs percent-encoding. Do not "tighten" this by masking the host.
#
# USAGE
#   bash scripts/check-db-url.sh            # prompts, nothing reaches shell history
#   DB_URL='postgresql://...' bash scripts/check-db-url.sh
#
# Exit 0 means the shape is plausible and the port answered. It does NOT mean the password is
# right -- that is the next step's job, and the point of this script is that the two stop looking
# alike.

set -uo pipefail

RAW="${DB_URL:-}"
if [ -z "$RAW" ]; then
  # -s so it is not echoed, and read from the terminal rather than argv so it stays out of history.
  printf 'Connection string (Dashboard -> Connect -> Session pooler -> URI): '
  read -rs RAW
  printf '\n\n'
fi
RAW="$(printf '%s' "$RAW" | tr -d '[:space:]')"

fail=0
problems=()
note() { problems+=("$1"); fail=1; }

# --- parse ---------------------------------------------------------------------------------------
# Split on the LAST @, because a password may legitimately contain one once it is encoded -- and
# when it is NOT encoded, this is the count that reveals it.
case "$RAW" in
  *://*) scheme="${RAW%%://*}"; rest="${RAW#*://}" ;;
  *)     scheme=""; rest="$RAW" ;;
esac

ats=$(printf '%s' "$rest" | tr -cd '@' | wc -c | tr -d ' ')
[ "$ats" -gt 1 ] && note "More than one '@'. A password containing @ must be percent-encoded as %40, or everything after the LAST @ is read as the host."

if [ "$ats" -ge 1 ]; then
  creds="${rest%@*}"
  tail_="${rest##*@}"
else
  creds=""
  tail_="$rest"
fi

case "$creds" in
  *:*) user="${creds%%:*}"; pw="${creds#*:}" ;;
  *)   user="$creds";       pw="" ;;
esac

case "$tail_" in
  */*) hostport="${tail_%%/*}"; db="${tail_#*/}"; db="${db%%\?*}" ;;
  *)   hostport="$tail_";       db="" ;;
esac

case "$hostport" in
  *:*) host="${hostport%%:*}"; port="${hostport##*:}" ;;
  *)   host="$hostport";       port="" ;;
esac

# --- report --------------------------------------------------------------------------------------
echo "scheme   : ${scheme:-(none)}"
echo "host     : ${host:-(none)}"
echo "port     : ${port:-(none given -- libpq defaults to 5432)}"
echo "username : ${user:-(none)}"
echo "database : ${db:-(none given)}"
if [ -n "$pw" ]; then echo "password : ${#pw} characters"; else echo "password : ABSENT"; fi
echo ""

# --- judge ---------------------------------------------------------------------------------------
case "$scheme" in
  postgres|postgresql) ;;
  *) note "Scheme is '${scheme:-empty}', expected postgresql://" ;;
esac

[ -z "$pw" ] && note "No password in the string. psql would prompt for one; GitHub Actions cannot."
[ -n "$db" ] && [ "$db" != "postgres" ] && note "Database is '$db'. Supabase's is 'postgres'."

# Which characters in the password need encoding -- never the password itself. A literal @ or / is
# the one that silently reparses the URL rather than erroring.
bad=""
for ch in '@' '/' '?' '#' '[' ']'; do
  case "$pw" in *"$ch"*) bad="$bad $ch" ;; esac
done
[ -n "$bad" ] && note "The password contains$bad which must be percent-encoded in a URL (@ is %40, / is %2F, # is %23, ? is %3F)."

# AN UNREPLACED TEMPLATE, caught before DNS because that is what it is -- not a network fault.
# This is what the secret actually held on 2026-10-04: aws-0-REGION.pooler.supabase.com, straight
# out of a documentation example. DNS then found no A record, and the first version of this script
# reported "resolves only over IPv6" -- a confident wrong cause, in the one tool whose entire job is
# refusing to state a wrong cause. Checked case-sensitively on purpose: REGION is a placeholder,
# but a real host is lowercase, so "region" inside one is not a false positive waiting to happen.
# Scanned over the HOST AND USERNAME ONLY, never the whole string. A password is whatever somebody
# chose, so looking for PASSWORD or REGION across the lot would reject a real credential containing
# either -- and a false rejection here blocks a deploy, which is a worse failure than the one being
# caught. The angle brackets are checked everywhere because they are never valid unencoded in a URL.
for ph in REGION PROJECT PROJECT-REF PROJECT_REF YOUR PASSWORD HOST EXAMPLE abcdef; do
  case "$host$user" in
    *"$ph"*) note "The host or username still contains the placeholder '$ph'. This is a TEMPLATE rather than your connection string -- copy it from Dashboard -> Connect -> Session pooler -> URI, which fills in every field." ; break ;;
  esac
done

case "$RAW" in
  *'<'*|*'>'*) note "The string contains < or >, which is never valid unencoded in a URL. Angle brackets usually mean a placeholder was left in place." ;;
esac

case "$host" in
  db.*.supabase.co)
    note "THE DIRECT HOST. db.<ref>.supabase.co publishes only an AAAA record, and GitHub runners have no IPv6 -- so this can never connect from CI however correct the password is. Use the session pooler."
    ;;
  *pooler.supabase.com)
    [ "$port" = "6543" ] && note "PORT 6543 IS TRANSACTION MODE. Each statement may land on a different backend, so a migration loses the advisory lock it takes. Use 5432."
    case "$user" in
      *.*) ;;
      *) note "Username is '$user'. At the pooler it must be postgres.<project-ref> WITH THE DOT -- a bare 'postgres' is refused as 'password authentication failed', which reads as a wrong password." ;;
    esac
    ;;
esac

if [ "$fail" -ne 0 ]; then
  echo "::error title=The connection string cannot work::${problems[0]}"
  for p in "${problems[@]}"; do echo "  - $p"; done
  echo ""
  echo "Dashboard -> Connect -> Session pooler -> URI gives every field correctly."
  exit 1
fi

echo "Shape is plausible. Checking DNS and TCP."
echo ""

# --- reach ---------------------------------------------------------------------------------------
# NO_NETWORK lets the unit tests exercise every branch above without depending on DNS.
[ -n "${NO_NETWORK:-}" ] && { echo "NO_NETWORK set -- stopping before DNS."; exit 0; }

PORT="${port:-5432}"

# getent IS LINUX-ONLY, and "missing tool" must not read as "missing record". Run by hand from
# git-bash on Windows -- which is where the owner of this repo works -- there is no getent at all,
# and the IPv6-only verdict below would then be announced about a host that is perfectly fine. That
# is the precise shape of bug this script was written to stop, so it does not get to commit one.
if ! command -v getent > /dev/null 2>&1; then
  echo "DNS check skipped: no getent on this platform (it is Linux-only; CI has it)."
  echo "The IPv6-only trap can therefore not be ruled out from here -- only from CI."
  echo ""
  if timeout 15 bash -c "cat < /dev/null > /dev/tcp/$host/$PORT" 2>/dev/null; then
    echo "TCP $host:$PORT is open, so this machine reaches it. Anything that fails after this is authentication."
    exit 0
  fi
  echo "::error title=TCP connection failed::Could not open $host:$PORT within 15s from this machine."
  exit 1
fi

# An explicit if, not `getent | awk || echo`: a pipeline's status is the LAST command's, so sort
# succeeding on empty input would swallow the one answer this exists to give. Same shape as the
# `grep -c` trap in CLAUDE.md.
if V4="$(getent ahostsv4 "$host" 2>/dev/null)" && [ -n "$V4" ]; then
  echo "A records for $host:"
  printf '%s\n' "$V4" | awk '{print "  " $1}' | sort -u
else
  V4=""
  echo "A records for $host: NONE"
fi

if V6="$(getent ahostsv6 "$host" 2>/dev/null)" && [ -n "$V6" ]; then
  echo "AAAA records for $host:"
  printf '%s\n' "$V6" | awk '{print "  " $1}' | sort -u
else
  echo "AAAA records for $host: none"
fi
echo ""

# NO A RECORD HAS TWO CAUSES AND THEY NEED DIFFERENT CURES. With an AAAA record the host is real
# and simply unreachable from a runner, which is the direct-host trap. With NEITHER record the host
# does not exist -- a typo or an unreplaced placeholder -- and telling somebody to "use the session
# pooler" when they already named one sends them to check the wrong thing. The first version of
# this conflated them and was wrong the first time it ran.
if [ -z "$V4" ] && [ -n "${V6:-}" ]; then
  echo "::error title=The database host has no IPv4 address::$host publishes an AAAA record and no A record. GitHub runners have no IPv6, so nothing there can reach it however correct the credentials are. Use the SESSION POOLER host from Dashboard -> Connect, which is dual-stack."
  exit 1
fi

if [ -z "$V4" ]; then
  echo "::error title=The database host does not resolve at all::$host has no A and no AAAA record, so it is not a reachable name. That is a typo or an unreplaced placeholder in the connection string, NOT a network or IPv6 problem. Copy the URI from Dashboard -> Connect -> Session pooler."
  exit 1
fi

# TCP before credentials, so "cannot reach it" and "it refused me" stop looking alike.
if timeout 15 bash -c "cat < /dev/null > /dev/tcp/$host/$PORT" 2>/dev/null; then
  echo "TCP $host:$PORT is open. Anything that fails after this is authentication, not reachability."
else
  echo "::error title=TCP connection failed::Could not open $host:$PORT within 15s, although the host resolves over IPv4. That is a firewall, a wrong port, or a paused project."
  exit 1
fi
