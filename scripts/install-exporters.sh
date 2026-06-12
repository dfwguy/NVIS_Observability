#!/usr/bin/env bash
# install-exporters.sh — Install or upgrade NVIS ObsVM-side Python exporters (systemd services).
#
# Usage:
#   sudo bash scripts/install-exporters.sh [--exporter NAME|all] [--src-dir DIR] [--dry-run]
#
# Options:
#   --exporter NAME   Install only the named exporter (see names below). Default: all
#   --src-dir DIR     Override source directory for Python scripts
#   --dry-run         Print what would happen; do not execute any changes
#
# Exporter names: dgx-ping  nvlink  spx-metrics  lldpq-bridge  cmdaemon
#                 redfish-dgx  redfish-head  runai
#
# This script is IDEMPOTENT. Re-running upgrades the installed script without
# touching /etc/nvis/*.env files (site-specific credentials/targets).

set -uo pipefail

# ---------------------------------------------------------------------------
# Colour / formatting helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { printf "${CYAN}[INFO]${RESET}  %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
err()     { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
ok()      { printf "${GREEN}[OK]${RESET}    %s\n" "$*"; }
dryrun()  { printf "${BOLD}[DRY-RUN]${RESET} %s\n" "$*"; }

# ---------------------------------------------------------------------------
# Exporter table
# Columns (pipe-separated):
#   short-name | python-script | port | env-file | service-name
# ---------------------------------------------------------------------------
# Two Redfish instances share the same script but different ports/env/service.
EXPORTERS=(
  "dgx-ping|dgx_ping_exporter.py|9113|/etc/nvis/dgx-ping.env|nvis-dgx-ping"
  "nvlink|nvlink_exporter.py|9106|/etc/nvis/nvlink.env|nvis-nvlink"
  "spx-metrics|spx_metrics_exporter.py|9111|/etc/nvis/spx-metrics.env|nvis-spx-metrics"
  "lldpq-bridge|lldpq_bridge.py|9112|/etc/nvis/lldpq-bridge.env|nvis-lldpq-bridge"
  "cmdaemon|cmdaemon_exporter.py|9108|/etc/nvis/cmdaemon.env|nvis-cmdaemon"
  "redfish-dgx|redfish_exporter.py|9102|/etc/nvis/redfish-dgx.env|nvis-redfish-dgx"
  "redfish-head|redfish_exporter.py|9103|/etc/nvis/redfish-head.env|nvis-redfish-head"
  "runai|runai_exporter.py|9105|/etc/nvis/runai.env|nvis-runai"
)

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_DIR="/opt/nvis"
SYSTEMD_DIR="/etc/systemd/system"
DRY_RUN=false
TARGET_EXPORTER="all"

# Will be resolved after arg parsing
SRC_DIR=""        # empty means "auto-detect"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --exporter)
      TARGET_EXPORTER="${2:-all}"
      shift 2
      ;;
    --src-dir)
      SRC_DIR="${2:?--src-dir requires an argument}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      sed -n '3,20p' "$0"    # print the header comment block
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

# 1. systemd availability
if ! command -v systemctl &>/dev/null; then
  err "systemctl not found — this host does not appear to run systemd."
  err "These exporters require systemd. Aborting."
  exit 1
fi

# 2. Privilege / sudo
RUN_AS_ROOT=false
if [[ $EUID -eq 0 ]]; then
  RUN_AS_ROOT=true
  SUDO=""
else
  if ! command -v sudo &>/dev/null; then
    err "Not running as root and 'sudo' is not available."
    err "Re-run as root or install sudo."
    exit 1
  fi
  SUDO="sudo"
fi

# 3. Install directory
if $DRY_RUN; then
  info "Dry-run mode — no changes will be made."
else
  if [[ ! -d "${INSTALL_DIR}" ]]; then
    info "Creating ${INSTALL_DIR}"
    $SUDO mkdir -p "${INSTALL_DIR}"
  fi
fi

# ---------------------------------------------------------------------------
# Execution helpers (all honour --dry-run)
# ---------------------------------------------------------------------------
run() {
  # run CMD [ARGS...] — execute or print depending on DRY_RUN
  if $DRY_RUN; then
    dryrun "Would run: $*"
  else
    "$@"
  fi
}

run_ignore_err() {
  # Like run but swallow non-zero exits (used for stop-before-upgrade)
  if $DRY_RUN; then
    dryrun "Would run (ignore errors): $*"
  else
    "$@" || true
  fi
}

# ---------------------------------------------------------------------------
# Locate the source script for a given python filename.
# Search order:
#   1. Explicit --src-dir (if provided)
#   2. scripts/ directory of the repo  (most exporters live here)
#   3. Repo root                        (dgx_ping_exporter.py lives here)
#   4. Already-installed /opt/nvis/     (upgrade in-place from live copy)
# Sets global FOUND_SRC; returns 0 if found, 1 if not.
# ---------------------------------------------------------------------------
locate_src() {
  local script="$1"
  FOUND_SRC=""

  local candidates=()
  if [[ -n "${SRC_DIR}" ]]; then
    candidates+=("${SRC_DIR}/${script}")
  fi
  candidates+=(
    "${SCRIPT_DIR}/${script}"
    "${REPO_ROOT}/${script}"
    "${INSTALL_DIR}/${script}"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -f "${candidate}" ]]; then
      FOUND_SRC="${candidate}"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Locate the systemd unit file for a given service name.
# Search order:
#   1. Exact service file  <service>.service  in scripts/
#   2. Fuzzy match: any *.service in scripts/ whose Description mentions the script
#   3. Already-installed /etc/systemd/system/<service>.service
# Sets global FOUND_UNIT; returns 0 if found, 1 if not.
# ---------------------------------------------------------------------------
locate_unit() {
  local service="$1"
  FOUND_UNIT=""

  local candidates=(
    "${SCRIPT_DIR}/${service}.service"
    "${REPO_ROOT}/${service}.service"
    "${SYSTEMD_DIR}/${service}.service"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -f "${candidate}" ]]; then
      FOUND_UNIT="${candidate}"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Summary table accumulator
# Written to a temp file so subshell calls (error isolation) can append to it.
# Each line: "name|status|note"
# ---------------------------------------------------------------------------
SUMMARY_FILE="$(mktemp /tmp/nvis-install-summary.XXXXXX)"
trap 'rm -f "${SUMMARY_FILE}"' EXIT

record() {
  printf "%s|%s|%s\n" "$1" "$2" "$3" >> "${SUMMARY_FILE}"
}

# ---------------------------------------------------------------------------
# Core: install or upgrade one exporter
# ---------------------------------------------------------------------------
install_exporter() {
  local name="$1"
  local script="$2"
  local port="$3"
  local envfile="$4"
  local service="$5"

  local dest="${INSTALL_DIR}/${script}"
  local action=""

  printf "\n${BOLD}--- %s (:%s / %s) ---${RESET}\n" "${name}" "${port}" "${service}"

  # -- 1. Locate source -------------------------------------------------
  if ! locate_src "${script}"; then
    warn "Source script '${script}' not found in repo or ${INSTALL_DIR}."
    printf "${YELLOW}[SKIP]${RESET}   %s — source not found\n" "${name}"
    record "${name}" "SKIP" "source not found"
    return 0
  fi
  info "Source: ${FOUND_SRC}"

  # -- 2. Install vs upgrade --------------------------------------------
  if [[ -f "${dest}" ]]; then
    action="UPGRADE"
    printf "${CYAN}[UPGRADE]${RESET} ${dest} already exists — upgrading.\n"
    # Stop service before replacing binary (ignore errors if not active)
    info "Stopping ${service} (if running)…"
    run_ignore_err $SUDO systemctl stop "${service}"
  else
    action="INSTALL"
    printf "${GREEN}[INSTALL]${RESET} Fresh install of ${dest}.\n"
  fi

  # -- 3. Copy script ---------------------------------------------------
  if [[ "${FOUND_SRC}" != "${dest}" ]]; then
    run $SUDO cp "${FOUND_SRC}" "${dest}"
  else
    info "Source is already the installed path — no copy needed."
  fi
  run $SUDO chmod 755 "${dest}"

  # -- 4. Install systemd unit file -------------------------------------
  local unit_dest="${SYSTEMD_DIR}/${service}.service"
  if locate_unit "${service}"; then
    info "Unit file: ${FOUND_UNIT} → ${unit_dest}"
    if [[ "${FOUND_UNIT}" != "${unit_dest}" ]]; then
      run $SUDO cp "${FOUND_UNIT}" "${unit_dest}"
      run $SUDO chmod 644 "${unit_dest}"
    else
      info "Unit file already in place."
    fi
  else
    warn "No unit file found for ${service} — skipping unit installation."
    warn "You may need to create ${unit_dest} manually."
    record "${name}" "${action}" "no unit file found"
    # We still copied the script; that part succeeded.
    return 0
  fi

  # -- 5. Env file check ------------------------------------------------
  if [[ ! -f "${envfile}" ]]; then
    warn "No env file — you must create ${envfile} before starting this service."
    printf "${YELLOW}[SKIP START]${RESET} ${service} — env file missing.\n"
    # Still daemon-reload so unit is registered even if we can't start it yet
    run $SUDO systemctl daemon-reload
    run $SUDO systemctl enable "${service}"
    record "${name}" "${action}" "env file missing — NOT started"
    return 0
  fi

  # -- 6. Enable and start ----------------------------------------------
  run $SUDO systemctl daemon-reload
  run $SUDO systemctl enable --now "${service}"

  # -- 7. Verify --------------------------------------------------------
  if $DRY_RUN; then
    dryrun "Would verify: systemctl is-active ${service}"
    record "${name}" "${action}" "dry-run — not verified"
  else
    local attempt
    for attempt in 1 2 3; do
      sleep 1
      if systemctl is-active --quiet "${service}"; then
        ok "${service} is active."
        record "${name}" "${action}" "running on :${port}"
        return 0
      fi
    done
    err "${service} did not become active after start."
    err "Check logs with: journalctl -u ${service} -n 50 --no-pager"
    record "${name}" "${action} (FAILED)" "not active after enable --now"
    # Per-exporter failure — do NOT propagate to abort the whole run
  fi
}

# ---------------------------------------------------------------------------
# Validate --exporter NAME
# ---------------------------------------------------------------------------
valid_names=()
for entry in "${EXPORTERS[@]}"; do
  valid_names+=("$(cut -d'|' -f1 <<< "${entry}")")
done

if [[ "${TARGET_EXPORTER}" != "all" ]]; then
  found=false
  for n in "${valid_names[@]}"; do
    [[ "${n}" == "${TARGET_EXPORTER}" ]] && found=true && break
  done
  if ! $found; then
    err "Unknown exporter name '${TARGET_EXPORTER}'."
    err "Valid names: ${valid_names[*]}"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
printf "\n${BOLD}NVIS Exporter Installer${RESET}\n"
printf "Repo root : %s\n" "${REPO_ROOT}"
printf "Install to: %s\n" "${INSTALL_DIR}"
printf "Target    : %s\n" "${TARGET_EXPORTER}"
$DRY_RUN && printf "Mode      : ${BOLD}DRY RUN${RESET}\n"

for entry in "${EXPORTERS[@]}"; do
  IFS='|' read -r name script port envfile service <<< "${entry}"

  if [[ "${TARGET_EXPORTER}" != "all" && "${TARGET_EXPORTER}" != "${name}" ]]; then
    continue
  fi

  # Wrap in a subshell so a hard error in install_exporter doesn't kill the
  # loop, but we can still capture exit status for the summary.
  if ! ( set -eo pipefail; install_exporter "${name}" "${script}" "${port}" "${envfile}" "${service}" ); then
    err "Unhandled error while processing ${name}."
    record "${name}" "ERROR" "unhandled error — check output above"
  fi
done

# ---------------------------------------------------------------------------
# Final summary table
# ---------------------------------------------------------------------------
printf "\n${BOLD}%-16s %-18s %s${RESET}\n" "EXPORTER" "STATUS" "NOTE"
printf "%s\n" "$(printf '%.0s-' {1..60})"
any_failure=false
while IFS='|' read -r r_name r_status r_note; do
  case "${r_status}" in
    INSTALL*)  colour="${GREEN}"  ;;
    UPGRADE*)  colour="${CYAN}"   ;;
    SKIP*)     colour="${YELLOW}" ;;
    ERROR*|*FAILED*)
               colour="${RED}"; any_failure=true ;;
    *)         colour="${RESET}"  ;;
  esac
  printf "${colour}%-16s %-18s${RESET} %s\n" "${r_name}" "${r_status}" "${r_note}"
done < "${SUMMARY_FILE}"
printf "\n"

$any_failure && exit 1
exit 0
