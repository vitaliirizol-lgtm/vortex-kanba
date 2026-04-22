#!/usr/bin/env bash
# Applies supabase/migrations/*.sql to a Supabase project via Management API.
#
# Required env vars:
#   SUPABASE_PAT  — Personal Access Token from https://supabase.com/dashboard/account/tokens
#   SUPABASE_REF  — Project ref (20 lowercase chars)
#
# Usage:
#   SUPABASE_PAT=sbp_... SUPABASE_REF=abcd... scripts/apply-migrations.sh
#   SUPABASE_PAT=sbp_... SUPABASE_REF=abcd... scripts/apply-migrations.sh 20250621180724_heavy_darkness.sql   # resume
#
# Why this exists instead of `supabase db push`:
#   Upstream migrations are broken on fresh DBs — the 20240710 and 20250101
#   timestamps ALTER tables that aren't created until 20250621152739_winter_tower.
#   This script applies them in corrected order and bypasses the CLI's DB
#   password handling, which has SCRAM caching issues after resets.
#
# Exits nonzero on any SQL failure with the offending migration name so you can
# patch it and resume.

set -euo pipefail

: "${SUPABASE_PAT:?SUPABASE_PAT required}"
: "${SUPABASE_REF:?SUPABASE_REF required}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIG_DIR="$REPO_DIR/supabase/migrations"
API="https://api.supabase.com/v1/projects/$SUPABASE_REF/database/query"

# Corrected apply order: winter_tower first (creates base tables), then the
# rest of the 20250621 series, then the orphaned 2024-07 and 2025-01 migrations
# that ALTER those tables, then the 2025-07 fix-ups. All 27 migrations covered.
ORDER=(
  "20250621152739_winter_tower.sql"
  "20250621155615_ivory_thunder.sql"
  "20250621172000_round_crystal.sql"
  "20250621172836_icy_marsh.sql"
  "20250621174320_raspy_flower.sql"
  "20250621175727_fierce_butterfly.sql"
  "20250621180115_spring_moon.sql"
  "20250621180532_snowy_lodge.sql"
  "20250621180641_misty_math.sql"
  "20250621180724_heavy_darkness.sql"
  "20250621180815_bronze_castle.sql"
  "20250621181905_winter_wildflower.sql"
  "20250621182216_billowing_grass.sql"
  "20250621182248_pale_peak.sql"
  "20250621182413_blue_delta.sql"
  "20250621182625_patient_boat.sql"
  "20250621182708_precious_credit.sql"
  "20250621182829_divine_butterfly.sql"
  "20250621183000_add_slug_to_projects.sql"
  "20250621183128_mellow_dune.sql"
  "20240710120000_add_public_share_token_to_projects.sql"
  "20240710180000_create_bookmarks_table.sql"
  "20250101000000_emergency_fix_profiles_security.sql"
  "20250101000001_add_is_done_to_tasks.sql"
  "20250722000000_fix_profiles_security.sql"
  "20250722000001_check_and_fix_rls.sql"
  "20250731160000_fix_user_search_auth.sql"
)

run_sql() {
  local file="$1" resp http_code body tmp
  tmp=$(mktemp)
  jq -Rs '{query: .}' < "$MIG_DIR/$file" > "$tmp"
  resp=$(curl -sS -w "\n%{http_code}" -X POST "$API" \
    -H "Authorization: Bearer $SUPABASE_PAT" \
    -H "Content-Type: application/json" \
    --data-binary "@$tmp")
  rm -f "$tmp"
  http_code=$(echo "$resp" | tail -n1)
  body=$(echo "$resp" | sed '$d')
  if [[ "$http_code" != "200" && "$http_code" != "201" ]]; then
    echo "  FAIL HTTP $http_code"
    echo "    $body" | head -5
    return 1
  fi
  echo "  OK"
}

i=0
total=${#ORDER[@]}
START_FROM="${1:-}"
skip=false
[[ -n "$START_FROM" ]] && skip=true

for file in "${ORDER[@]}"; do
  i=$((i + 1))
  if $skip; then
    if [[ "$file" == "$START_FROM" ]]; then
      skip=false
    else
      printf "[%2d/%2d] %s  (skipped)\n" "$i" "$total" "$file"
      continue
    fi
  fi
  printf "[%2d/%2d] %s\n" "$i" "$total" "$file"
  if ! run_sql "$file"; then
    echo ""
    echo "STOPPED at $file. Patch the file and rerun:"
    echo "  $0 $file"
    exit 1
  fi
done

echo ""
echo "All $total migrations applied."
