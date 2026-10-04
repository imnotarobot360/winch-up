#!/usr/bin/env bash
#
# Winch Up :: did the 2026-10-03 migrations actually reach production?
#
# Asks production directly over HTTPS with the PUBLISHABLE key, which is safe to put in a file --
# it is the key the browser already ships. No database password, no service key, no dashboard.
#
# HOW IT CAN TELL, and this is the whole trick:
#
#   A FUNCTION.  POST /rest/v1/rpc/<name> with the right argument names.
#                42501  -> it exists, and `anon` is correctly refused. APPLIED.
#                PGRST202 -> no such function. NOT APPLIED.
#                The signature has to match: calling a function that takes p_user_id with {}
#                answers PGRST202 and reads exactly like an unapplied migration.
#
#   A COLUMN.    GET /rest/v1/<table>?select=<column>
#                PostgREST validates the COLUMN NAME BEFORE it checks the table grant, so
#                42703  -> no such column. NOT APPLIED.
#                42501  -> the column is there, the table is gated. APPLIED.
#
# EVERY CHECK IS PAIRED WITH A CONTROL, because "it said 42501" means nothing unless something in
# the same run can still produce the other answer. The controls at the bottom are a function and a
# column that certainly do NOT exist, and one of each that certainly DO. If a control is wrong, the
# probe is wrong, and the rest of the output is not evidence.
#
# Anything in schema `app` -- app.member_matches_target, app.campaign_phase, app.target_list -- is
# invisible to PostgREST by design and CANNOT be probed this way. Their presence is inferred from
# the public functions that call them: ads_for() and admin_campaigns() would error rather than
# return if those were missing.

set -u

HOST="https://icpwyepfwkguaocbkawe.supabase.co"
KEY="sb_publishable_lOuLscGzdvjadp8tQkyLyg_6RV7i9gY"

code_of() {  # extract the postgres/postgrest error code from a response body
  node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{const j=JSON.parse(d);process.stdout.write(j.code||'(no code)')}catch(e){process.stdout.write('(not json)')}})"
}

fn() {  # fn <name> <json-args> <expect-applied-code>
  local name="$1" args="$2"
  local c
  c=$(curl -s -X POST "$HOST/rest/v1/rpc/$name" \
        -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
        -H "Content-Type: application/json" -d "$args" | code_of)
  case "$c" in
    42501)    printf '  APPLIED      %-32s (42501 -- exists, anon refused)\n' "$name" ;;
    PGRST202) printf '  MISSING      %-32s (PGRST202 -- no such function)\n' "$name" ;;
    *)        printf '  ?            %-32s (%s)\n' "$name" "$c" ;;
  esac
}

col() {  # col <table> <column>
  local t="$1" c="$2" r
  r=$(curl -s "$HOST/rest/v1/$t?select=$c&limit=1" \
        -H "apikey: $KEY" -H "Authorization: Bearer $KEY" | code_of)
  case "$r" in
    42501) printf '  APPLIED      %-32s (42501 -- column exists, table gated)\n' "$t.$c" ;;
    42703) printf '  MISSING      %-32s (42703 -- no such column)\n' "$t.$c" ;;
    # A column on a table that does not exist AT ALL answers PGRST205 ("could not find the table in
    # the schema cache") rather than 42703: PostgREST resolves the RELATION before the column name,
    # so a brand-new table short-circuits the column check. Measured 2026-10-03. Three codes, not two.
    PGRST205) printf '  MISSING      %-32s (PGRST205 -- no such table)\n' "$t.$c" ;;
    *)     printf '  ?            %-32s (%s)\n' "$t.$c" "$r" ;;
  esac
}

echo "=== 20261003000100  member location ==="
col profiles city
col profiles state
col profiles postal_code
col profiles country
col profiles location_set_at
fn set_my_location '{"p_city":"x","p_state":"TX","p_postal_code":"77429","p_country":"US"}'

echo "=== 20261003000300  the server-side centroid writer ==="
fn set_member_postal_center '{"p_user_id":"00000000-0000-4000-8000-000000000000","p_postal_code":"77429","p_lng":-95.6,"p_lat":29.9}'
fn members_missing_postal_center '{"p_limit":1}'

echo "=== 20261003000600  event detail columns ==="
col events event_type
col events city
col events postal_code
col events is_official
col events organizer_name
col events registration_url

# events.cover_image_path and events.image_paths are NOT checked here: 20261003001700 dropped
# them. They were columns with no uploader and no renderer, and checking for them would report
# MISSING for ever and read as a migration that failed.
echo "=== 20261003000700 / 001500  event admin RPCs ==="
fn admin_save_event '{"p_payload":{}}'
fn admin_events '{"p_status":null,"p_limit":1}'

echo "=== 20261003000900  campaign lifecycle ==="
col ad_campaigns archived_at
col ad_campaigns archived_by
fn admin_campaigns '{"p_phase":null,"p_include_archived":false,"p_limit":1}'
fn duplicate_campaign '{"p_id":"00000000-0000-4000-8000-000000000000","p_name":null}'
fn set_campaign_archived '{"p_id":"00000000-0000-4000-8000-000000000000","p_archived":true}'

echo "=== 20261003001000 / 001100  analytics and the report ==="
col ad_geo_daily_stats postal_code
col event_daily_stats views
fn ad_record_event_at '{"p_creative_id":"00000000-0000-4000-8000-000000000000","p_surface":"community_feed","p_kind":"impression","p_state":null,"p_city":null,"p_postal_code":null}'
fn record_event_view '{"p_event_id":"00000000-0000-4000-8000-000000000000"}'
fn admin_ad_report '{"p_campaign_id":null,"p_creative_id":null,"p_days":30}'
fn admin_event_report '{"p_days":30}'

echo "=== 20261003001300 / 001400  announcements ==="
col announcements title
col announcements category
col announcement_dismissals dismissed_at
fn my_announcements '{"p_limit":1}'
fn dismiss_announcement '{"p_id":"00000000-0000-4000-8000-000000000000"}'
fn admin_save_announcement '{"p_payload":{}}'
fn admin_announcements '{"p_status":null,"p_limit":1}'

echo "=== 20261003001500  targeting round-trip ==="
col target_locations kind
fn admin_save_campaign_targets '{"p_campaign_id":"00000000-0000-4000-8000-000000000000","p_targets":[]}'

echo "=== CONTROLS -- if any of these is wrong, ignore everything above ==="
echo "  these two MUST say APPLIED (they predate today):"
fn events_upcoming '{"p_limit":1}'
col profiles display_name
echo "  these two MUST say MISSING (they have never existed):"
fn winchup_probe_no_such_function '{}'
col profiles winchup_probe_no_such_column
