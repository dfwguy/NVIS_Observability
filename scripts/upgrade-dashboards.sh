#!/usr/bin/env bash
# upgrade-dashboards.sh — Push NVIS-managed Grafana dashboards via HTTP API.
# Only touches dashboards in grafana/dashboards/NVIS/; Lilly's own dashboards
# are never modified.
#
# Usage:
#   bash scripts/upgrade-dashboards.sh [--grafana-url URL] [--user USER] [--pass PASS] [--dry-run]
#
# Env vars (lower priority than CLI flags):
#   GRAFANA_USER  (default: admin)
#   GRAFANA_PASS  (default: admin)

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
GRAFANA_URL="http://localhost:30300"
GF_USER="${GRAFANA_USER:-admin}"
GF_PASS="${GRAFANA_PASS:-admin}"
DRY_RUN=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_DIR="${SCRIPT_DIR}/../grafana/dashboards/NVIS"

NVIS_FOLDER_TITLE="NVIS"

# ---------------------------------------------------------------------------
# Color helpers (only when stdout is a terminal)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  GREEN="\033[0;32m"
  RED="\033[0;31m"
  YELLOW="\033[0;33m"
  RESET="\033[0m"
else
  GREEN="" RED="" YELLOW="" RESET=""
fi

info()  { printf "%b%s%b\n" "${YELLOW}" "$*" "${RESET}"; }
ok()    { printf "%b%s%b\n" "${GREEN}"  "$*" "${RESET}"; }
fail()  { printf "%b%s%b\n" "${RED}"    "$*" "${RESET}" >&2; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --grafana-url) GRAFANA_URL="$2"; shift 2 ;;
    --user)        GF_USER="$2";     shift 2 ;;
    --pass)        GF_PASS="$2";     shift 2 ;;
    --dry-run)     DRY_RUN=true;     shift   ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--grafana-url URL] [--user USER] [--pass PASS] [--dry-run]" >&2
      exit 1
      ;;
  esac
done

# Strip trailing slash from URL
GRAFANA_URL="${GRAFANA_URL%/}"

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
missing=()
command -v curl &>/dev/null || missing+=("curl")
command -v jq   &>/dev/null || missing+=("jq")
if [[ ${#missing[@]} -gt 0 ]]; then
  fail "Required tools not found: ${missing[*]}"
  fail "Install them and retry (e.g. apt install curl jq / brew install curl jq)."
  exit 1
fi

# ---------------------------------------------------------------------------
# Locate dashboard files
# ---------------------------------------------------------------------------
if [[ ! -d "$DASHBOARD_DIR" ]]; then
  fail "Dashboard directory not found: $DASHBOARD_DIR"
  exit 1
fi

mapfile -t DASHBOARD_FILES < <(find "$DASHBOARD_DIR" -maxdepth 1 -name '*.json' | sort)

if [[ ${#DASHBOARD_FILES[@]} -eq 0 ]]; then
  fail "No *.json files found in $DASHBOARD_DIR"
  exit 1
fi

info "Grafana: ${GRAFANA_URL}"
info "Dashboards: ${DASHBOARD_DIR} (${#DASHBOARD_FILES[@]} files)"
$DRY_RUN && info "[DRY-RUN] No requests will be made."
echo ""

# ---------------------------------------------------------------------------
# Helper: curl wrapper (returns body; exits with 0 even on HTTP errors)
# ---------------------------------------------------------------------------
gf_curl() {
  # $1 = method, $2 = path, rest = extra curl args
  local method="$1" path="$2"; shift 2
  curl --silent --show-error \
    --user "${GF_USER}:${GF_PASS}" \
    --header "Content-Type: application/json" \
    --request "$method" \
    "${GRAFANA_URL}${path}" \
    "$@"
}

# ---------------------------------------------------------------------------
# Resolve or create the NVIS folder
# ---------------------------------------------------------------------------
get_folder_id() {
  local title="$1"
  # GET /api/folders returns an array; find by title
  local body
  body=$(gf_curl GET "/api/folders?limit=100")

  local folder_id
  folder_id=$(printf '%s' "$body" | jq -r --arg t "$title" \
    '.[] | select(.title == $t) | .id // empty' | head -1)

  if [[ -n "$folder_id" ]]; then
    echo "$folder_id"
    return 0
  fi

  # Folder doesn't exist — create it
  local create_body
  create_body=$(printf '{"title": "%s"}' "$title")
  local resp
  resp=$(gf_curl POST "/api/folders" --data "$create_body")
  folder_id=$(printf '%s' "$resp" | jq -r '.id // empty')

  if [[ -z "$folder_id" ]]; then
    fail "Could not create folder '${title}'. Response: ${resp}"
    return 1
  fi

  ok "Created folder '${title}' (folderId=${folder_id})"
  echo "$folder_id"
}

# ---------------------------------------------------------------------------
# Resolve folder (skip in dry-run)
# ---------------------------------------------------------------------------
FOLDER_ID=""
if $DRY_RUN; then
  FOLDER_ID="<dry-run>"
else
  FOLDER_ID=$(get_folder_id "$NVIS_FOLDER_TITLE")
  info "NVIS folderId=${FOLDER_ID}"
fi
echo ""

# ---------------------------------------------------------------------------
# Push dashboards
# ---------------------------------------------------------------------------
pushed=0
failed=()

for file in "${DASHBOARD_FILES[@]}"; do
  fname="$(basename "$file")"

  # Parse title and uid from the file for display / error messages
  dash_title=$(jq -r '.title // "<unknown>"' "$file")
  dash_uid=$(jq -r '.uid // "<no-uid>"' "$file")

  if $DRY_RUN; then
    ok "[DRY-RUN] would push  uid=${dash_uid}  title=${dash_title}  (${fname})"
    (( pushed++ )) || true
    continue
  fi

  # Build the import payload:
  #   - set id to null (Grafana assigns)
  #   - preserve uid (so existing dashboards are updated in-place)
  #   - set version to null (Grafana manages)
  payload=$(jq -n \
    --argjson dash "$(jq '. + {"id": null, "version": null}' "$file")" \
    --argjson folder_id "$FOLDER_ID" \
    '{
      "dashboard": $dash,
      "overwrite": true,
      "folderId": $folder_id
    }')

  http_status=$(gf_curl POST "/api/dashboards/import" \
    --data "$payload" \
    --output /tmp/gf_resp_body.json \
    --write-out "%{http_code}" 2>/dev/null) || true

  resp_body=$(cat /tmp/gf_resp_body.json 2>/dev/null || echo "")

  if [[ "$http_status" =~ ^2 ]]; then
    ok "[OK] pushed  uid=${dash_uid}  title=${dash_title}"
    (( pushed++ )) || true
  else
    fail "[FAIL] uid=${dash_uid}  title=${dash_title}  (HTTP ${http_status})"
    fail "       ${resp_body}"
    failed+=("${dash_uid}")
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if $DRY_RUN; then
  info "Dry-run complete. Would push ${pushed} dashboards to '${NVIS_FOLDER_TITLE}' folder."
else
  info "Pushed ${pushed} dashboard(s) to '${NVIS_FOLDER_TITLE}' folder (folderId=${FOLDER_ID})."
fi

if [[ ${#failed[@]} -gt 0 ]]; then
  fail ""
  fail "Failed dashboards (${#failed[@]}):"
  for uid in "${failed[@]}"; do
    fail "  - ${uid}"
  done
  exit 1
fi

exit 0
