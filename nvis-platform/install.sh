#!/usr/bin/env bash
# install.sh — nvis-platform unified installer.
#
# Usage:
#   sudo bash install.sh                          fresh interactive install
#   sudo bash install.sh --upgrade                only ask about NEW integrations
#   sudo bash install.sh --cleanup                tear everything down
#   sudo bash install.sh --dry-run                wizard runs; no kubectl/helm
#   sudo bash install.sh --detect-only            run detect + prereqs check, exit
#   sudo bash install.sh --non-interactive        fail-fast if a required value
#                                                 is missing (CI mode)
#   sudo bash install.sh --values-file PATH       preload answers (skip wizard)
#   sudo bash install.sh --help
#
# This installer is deliberately stateless about the customer's environment:
# every endpoint / credential / contact list is collected at install time and
# stored in a k8s Secret (or, for non-secret values, an install-state ConfigMap).
#
# All output goes to stderr; the log file at /tmp/nvis-install-$$.log captures
# every state-mutating action.
#
# ---------------------------------------------------------------------------

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths + constants
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
CHART_DIR="${SCRIPT_DIR}/helm/nvis-platform"
NAMESPACE="${NAMESPACE:-nvis-monitoring}"
RELEASE="${RELEASE:-nvis-platform}"
INSTALL_LOG="/tmp/nvis-install-$$.log"
INSTALL_VERSION="$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo unknown)"
TOTAL_PHASES=11

# ---------------------------------------------------------------------------
# CLI flags
# ---------------------------------------------------------------------------
MODE_UPGRADE=false
MODE_CLEANUP=false
MODE_DRY_RUN=false
MODE_DETECT_ONLY=false
MODE_NON_INTERACTIVE=false
VALUES_FILE=""

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------
log()      { printf '[install] %s\n' "$*" | tee -a "$INSTALL_LOG" >&2; }
log_warn() { printf '[install][WARN] %s\n' "$*" | tee -a "$INSTALL_LOG" >&2; }
log_err()  { printf '[install][ERROR] %s\n' "$*" | tee -a "$INSTALL_LOG" >&2; }
log_phase() {
    local n="$1"; shift
    local msg="$*"
    printf '\n=================================================================\n' \
        | tee -a "$INSTALL_LOG" >&2
    printf '[%d/%d] %s\n' "$n" "$TOTAL_PHASES" "$msg" \
        | tee -a "$INSTALL_LOG" >&2
    printf '=================================================================\n' \
        | tee -a "$INSTALL_LOG" >&2
}

# ---------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------
usage() {
    cat <<'USAGE'
nvis-platform installer

Usage:
  install.sh                Fresh interactive install.
  install.sh --upgrade      Re-run; only asks about NEW integrations.
  install.sh --cleanup      Remove the platform from this host.
  install.sh --dry-run      Wizard runs; no kubectl/helm calls are made.
  install.sh --detect-only  Run prereqs + DGX detection, then exit.
  install.sh --non-interactive
                            CI mode. Required values must be supplied via env
                            or --values-file; missing values are a hard error.
  install.sh --values-file PATH
                            Preload answers (shell-syntax KEY=VALUE) and skip
                            the wizard for any preloaded key.
  install.sh --help         This text.

Environment:
  NAMESPACE      k8s namespace (default: nvis-monitoring)
  RELEASE        helm release name (default: nvis-platform)
  STATE_DIR      install state directory (default: /var/lib/nvis-platform)

Logs:
  Each run writes to /tmp/nvis-install-<PID>.log

What it does:
  1.  Prereqs check (OS, disk, RAM, curl/jq, k3s, helm).
  2.  Cluster name + ObsVM host prompt.
  3.  DGX flavor auto-detect (BCM cmsh -> Redfish -> prompt).
  4.  Wizard: per-integration Y/N + per-YES credentials.
  5.  Grafana admin password (or auto-generate).
  6.  Persist state (file + ConfigMap once cluster is up).
  7.  Install k3s if missing.
  8.  Render helm values.yaml from collected answers.
  9.  Create k8s Secrets for every enabled integration.
  10. helm install / upgrade the chart.
  11. Validate + print access info.
USAGE
}

# ---------------------------------------------------------------------------
# parse args
# ---------------------------------------------------------------------------
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --upgrade)         MODE_UPGRADE=true ;;
            --cleanup)         MODE_CLEANUP=true ;;
            --dry-run)         MODE_DRY_RUN=true ;;
            --detect-only)     MODE_DETECT_ONLY=true ;;
            --non-interactive) MODE_NON_INTERACTIVE=true ;;
            --values-file)     shift; VALUES_FILE="${1:-}" ;;
            --values-file=*)   VALUES_FILE="${1#*=}" ;;
            -h|--help)         usage; exit 0 ;;
            *)
                log_err "Unknown flag: $1"
                usage
                exit 2
                ;;
        esac
        shift
    done

    if "$MODE_NON_INTERACTIVE"; then
        export NVIS_NON_INTERACTIVE=1
    fi
    if "$MODE_DRY_RUN"; then
        export DRY_RUN=true
    fi
}

# ---------------------------------------------------------------------------
# load libs
# ---------------------------------------------------------------------------
source_libs() {
    local missing=0
    local f
    for f in detect.sh wizard.sh state.sh secrets.sh prereqs.sh; do
        if [[ ! -r "${LIB_DIR}/${f}" ]]; then
            log_err "Missing required lib: ${LIB_DIR}/${f}"
            missing=1
        fi
    done
    (( missing == 0 )) || exit 1

    # detect.sh sets `set -euo pipefail` of its own; that's fine because we did too.
    # shellcheck disable=SC1091
    . "${LIB_DIR}/wizard.sh"
    # shellcheck disable=SC1091
    . "${LIB_DIR}/state.sh"
    # shellcheck disable=SC1091
    . "${LIB_DIR}/secrets.sh"
    # shellcheck disable=SC1091
    . "${LIB_DIR}/prereqs.sh"
    # shellcheck disable=SC1091
    . "${LIB_DIR}/detect.sh"
}

# ---------------------------------------------------------------------------
# load values file (preload var=value entries)
# ---------------------------------------------------------------------------
load_values_file() {
    [[ -z "$VALUES_FILE" ]] && return 0
    if [[ ! -r "$VALUES_FILE" ]]; then
        log_err "--values-file not readable: $VALUES_FILE"
        exit 1
    fi
    log "Loading preloaded answers from $VALUES_FILE"
    # shellcheck disable=SC1090
    set -a; . "$VALUES_FILE"; set +a
}

# ---------------------------------------------------------------------------
# Default integration toggles
# ---------------------------------------------------------------------------
init_int_defaults() {
    : "${INT_DCGM:=}"
    : "${INT_NODE_EXPORTER:=}"
    : "${INT_ALLOY:=}"
    : "${INT_BCM:=}"
    : "${INT_SLURM:=}"
    : "${INT_CGROUP:=}"
    : "${INT_REDFISH_MAIN:=}"
    : "${INT_REDFISH_NM:=}"
    : "${INT_REDFISH_FAST:=}"
    : "${INT_REDFISH_SENSORS:=}"
    : "${INT_IPMI_SEL:=}"
    : "${INT_IPMI_SOL:=}"
    : "${INT_POWERSHELF:=}"
    : "${INT_UFM:=}"
    : "${INT_NETQ:=}"
    : "${INT_RUNAI:=}"
    : "${INT_NMC:=}"
    : "${INT_ALERT_EMAIL:=}"
    : "${INT_ALERT_TEAMS:=}"
    : "${INT_ALERT_SLACK:=}"

    : "${CLUSTER_NAME:=}"
    : "${OBSVM_HOST:=}"
    : "${DGX_FLAVOR:=}"
    : "${GRAFANA_ADMIN_PASSWORD:=}"
}

# ---------------------------------------------------------------------------
# Phase 1 — prereqs
# ---------------------------------------------------------------------------
phase_prereqs() {
    log_phase 1 "Prereqs check"
    if "$MODE_DRY_RUN"; then
        log "DRY-RUN: prereqs check only reports state, never installs."
    fi
    prereqs_detect_os    || { log_err "OS detection failed"; return 1; }
    prereqs_check_resources || log_warn "Resource check failed (continuing — not fatal in --dry-run/--detect-only)"
    prereqs_ensure_curl_jq  || log_warn "Could not install curl/jq (auto-install failed)"
    return 0
}

# ---------------------------------------------------------------------------
# Phase 2 — cluster name + ObsVM host
# ---------------------------------------------------------------------------
phase_cluster_basics() {
    log_phase 2 "Cluster identity"

    # CLUSTER_NAME
    if [[ -z "$CLUSTER_NAME" ]]; then
        local def=""
        if "$MODE_UPGRADE"; then
            def="$(state_get CLUSTER_NAME)"
        fi
        prompt_validated "Cluster name (lowercase alphanum + dash, no spaces)" \
            "$def" CLUSTER_NAME wiz_validate_cluster_name
    else
        wiz_validate_cluster_name "$CLUSTER_NAME" \
            || { log_err "CLUSTER_NAME='$CLUSTER_NAME' fails validation"; return 1; }
    fi
    log "CLUSTER_NAME=$CLUSTER_NAME"

    # OBSVM_HOST — default to this host's first IP.
    if [[ -z "$OBSVM_HOST" ]]; then
        local autodetect
        autodetect="$(hostname -I 2>/dev/null | awk '{print $1}')"
        [[ -z "$autodetect" ]] && autodetect="$(hostname 2>/dev/null || echo localhost)"
        local def="$autodetect"
        if "$MODE_UPGRADE"; then
            local saved
            saved="$(state_get OBSVM_HOST)"
            [[ -n "$saved" ]] && def="$saved"
        fi
        prompt_validated "ObsVM host (IP or hostname)" "$def" OBSVM_HOST wiz_validate_host
    fi
    log "OBSVM_HOST=$OBSVM_HOST"
}

# ---------------------------------------------------------------------------
# Phase 3 — DGX flavor detection
# ---------------------------------------------------------------------------
phase_dgx_detect() {
    log_phase 3 "DGX flavor detection"

    if [[ -n "$DGX_FLAVOR" ]]; then
        log "DGX_FLAVOR preloaded: $DGX_FLAVOR"
        return 0
    fi

    DGX_FLAVOR=$(detect_dgx_flavor || echo UNKNOWN)
    if ! validate_dgx_flavor "$DGX_FLAVOR"; then
        log_warn "Detected flavor '$DGX_FLAVOR' fails validation; coercing to UNKNOWN"
        DGX_FLAVOR=UNKNOWN
    fi
    log "DGX_FLAVOR=$DGX_FLAVOR"

    if [[ "${NVIS_NON_INTERACTIVE:-}" != "1" ]] && ! "$MODE_DETECT_ONLY"; then
        local confirm=""
        prompt "Confirm DGX flavor (Enter to accept, or type override)" \
            "$DGX_FLAVOR" confirm
        if [[ "$confirm" != "$DGX_FLAVOR" ]]; then
            if validate_dgx_flavor "$confirm"; then
                DGX_FLAVOR="$confirm"
                log "DGX_FLAVOR override accepted: $DGX_FLAVOR"
            else
                log_warn "Override '$confirm' fails validation; keeping $DGX_FLAVOR"
            fi
        fi
    fi
}

# ---------------------------------------------------------------------------
# Phase 4 — per-integration wizard
# ---------------------------------------------------------------------------

# _wizard_int VAR_NAME LABEL DEFAULT_Y_OR_N PROMPT_BLOCK_FN
#   * On --upgrade: if the integration was already enabled per the state file,
#     skip and re-use any preloaded creds (but DO ask about it if it was
#     previously OFF — i.e. it's a "new" integration).
_wizard_int() {
    local var="$1"
    local label="$2"
    local default="$3"
    local block_fn="${4:-}"

    if "$MODE_UPGRADE"; then
        local prev
        prev="$(state_get "$var")"
        if [[ "$prev" == "true" ]]; then
            log "$var was previously enabled; re-using prior config"
            printf -v "$var" '%s' 'true'
            return 0
        fi
        # Wasn't enabled before; ask now.
    fi

    prompt_bool "$label" "$default" "$var"
    if [[ "${!var}" == "true" && -n "$block_fn" ]]; then
        "$block_fn" || {
            log_warn "$block_fn failed; disabling $var"
            printf -v "$var" '%s' 'false'
        }
    fi
}

phase_wizard() {
    log_phase 4 "Per-integration wizard"

    if "$MODE_UPGRADE"; then
        log "Upgrade mode: only asking about integrations that were previously OFF."
    fi

    _wizard_int INT_DCGM           "Enable DCGM GPU exporter?"            Y ""
    _wizard_int INT_NODE_EXPORTER  "Enable node-exporter?"                 Y ""
    _wizard_int INT_ALLOY          "Enable Alloy logs collector?"          Y ""

    _wizard_int INT_BCM            "Enable BCM (Bright Cluster Manager) integration?" N prompt_bcm_block
    if [[ "${INT_BCM:-false}" == "true" ]]; then
        _wizard_int INT_SLURM      "Enable Slurm jobstats exporter (uses BCM SSH)?"   N ""
        _wizard_int INT_CGROUP     "Enable cgroup_exporter DaemonSet on compute nodes?" N ""
    else
        INT_SLURM=false
        INT_CGROUP=false
    fi

    _wizard_int INT_REDFISH_MAIN   "Enable Redfish-main exporter?"         N prompt_bmc_block
    _wizard_int INT_REDFISH_NM     "Enable Redfish-NM exporter?"           N prompt_bmc_block
    _wizard_int INT_REDFISH_FAST   "Enable Redfish-Fast exporter?"         N prompt_bmc_block
    _wizard_int INT_REDFISH_SENSORS "Enable Redfish-Sensors exporter?"     N prompt_bmc_block

    _wizard_int INT_IPMI_SEL       "Enable IPMI SEL collector?"            N prompt_bmc_block
    _wizard_int INT_IPMI_SOL       "Enable IPMI SOL capture?"              N prompt_bmc_block

    _wizard_int INT_POWERSHELF     "Enable PowerShelf exporter (LiteOn PF-1333-13RD)?" N prompt_powershelf_block

    _wizard_int INT_UFM            "Enable UFM (InfiniBand) integration?"  N prompt_ufm_block
    _wizard_int INT_NETQ           "Enable NetQ (Cumulus) integration?"    N prompt_netq_block
    _wizard_int INT_RUNAI          "Enable RunAI integration?"             N prompt_runai_block
    _wizard_int INT_NMC            "Enable NMC integration?"               N prompt_nmc_block

    # Alerts block — top-level Y/N then sub-questions.
    local _enable_alerts=""
    prompt_bool "Configure alert contact points (email/Teams/Slack)?" N _enable_alerts
    if [[ "$_enable_alerts" == "true" ]]; then
        _wizard_int INT_ALERT_EMAIL "Configure email alerts?" N prompt_smtp_block
        _wizard_int INT_ALERT_TEAMS "Configure Teams alerts?" N prompt_teams_block
        _wizard_int INT_ALERT_SLACK "Configure Slack alerts?" N prompt_slack_block
    else
        INT_ALERT_EMAIL=false
        INT_ALERT_TEAMS=false
        INT_ALERT_SLACK=false
    fi

    log "Wizard complete. Enabled integrations:"
    local k
    for k in INT_DCGM INT_NODE_EXPORTER INT_ALLOY INT_BCM INT_SLURM INT_CGROUP \
             INT_REDFISH_MAIN INT_REDFISH_NM INT_REDFISH_FAST INT_REDFISH_SENSORS \
             INT_IPMI_SEL INT_IPMI_SOL INT_POWERSHELF INT_UFM INT_NETQ INT_RUNAI INT_NMC \
             INT_ALERT_EMAIL INT_ALERT_TEAMS INT_ALERT_SLACK; do
        log "  $k=${!k:-false}"
    done
}

# ---------------------------------------------------------------------------
# Phase 5 — Grafana admin password
# ---------------------------------------------------------------------------
phase_grafana_password() {
    log_phase 5 "Grafana admin password"

    if [[ -n "$GRAFANA_ADMIN_PASSWORD" ]]; then
        log "GRAFANA_ADMIN_PASSWORD preloaded"
        return 0
    fi

    local typed=""
    if [[ "${NVIS_NON_INTERACTIVE:-}" != "1" ]]; then
        prompt_silent "Grafana admin password (leave blank to auto-generate)" typed
    fi
    if [[ -z "$typed" ]]; then
        GRAFANA_ADMIN_PASSWORD=$(generate_password 20)
        log "Auto-generated 20-char Grafana admin password"
    else
        GRAFANA_ADMIN_PASSWORD="$typed"
        log "Grafana admin password set by user"
    fi
}

# ---------------------------------------------------------------------------
# Phase 6 — persist state
# ---------------------------------------------------------------------------
phase_persist_state() {
    log_phase 6 "Persist install state"
    INSTALL_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    export INSTALL_VERSION INSTALL_TIMESTAMP
    save_state || log_warn "save_state failed"
    if "$MODE_DRY_RUN"; then
        log "DRY-RUN: skipping ConfigMap upload (no cluster contact)"
        return 0
    fi
    # ConfigMap upload happens after k3s is up (phase 10).
}

# ---------------------------------------------------------------------------
# Phase 7 — k3s
# ---------------------------------------------------------------------------
phase_k3s() {
    log_phase 7 "k3s install"
    if "$MODE_DRY_RUN"; then
        log "DRY-RUN: skipping k3s install"
        return 0
    fi
    prereqs_ensure_helm || log_warn "helm install failed"
    prereqs_ensure_k3s  || { log_err "k3s install failed"; return 1; }
    prereqs_wait_k8s_ready 180 || { log_err "k8s did not become Ready in time"; return 1; }
}

# ---------------------------------------------------------------------------
# Phase 8 — render helm values
# ---------------------------------------------------------------------------
render_values_file() {
    local out="$1"
    cat > "$out" <<EOF
# Generated by nvis-platform install.sh on ${INSTALL_TIMESTAMP:-unknown}
cluster:
  name: ${CLUSTER_NAME}
  dgxFlavor: ${DGX_FLAVOR}
  obsvmHost: ${OBSVM_HOST}

image:
  tag: "${INSTALL_VERSION}"

integrations:
  dcgm:           { enabled: ${INT_DCGM:-false} }
  nodeExporter:   { enabled: ${INT_NODE_EXPORTER:-false} }
  alloy:          { enabled: ${INT_ALLOY:-false} }
  bcm:            { enabled: ${INT_BCM:-false} }
  slurm:          { enabled: ${INT_SLURM:-false} }
  cgroupExporter: { enabled: ${INT_CGROUP:-false} }
  redfishMain:    { enabled: ${INT_REDFISH_MAIN:-false} }
  redfishNm:      { enabled: ${INT_REDFISH_NM:-false} }
  redfishFast:    { enabled: ${INT_REDFISH_FAST:-false} }
  redfishSensors: { enabled: ${INT_REDFISH_SENSORS:-false} }
  ipmiSel:        { enabled: ${INT_IPMI_SEL:-false} }
  ipmiSol:        { enabled: ${INT_IPMI_SOL:-false} }
  powershelf:     { enabled: ${INT_POWERSHELF:-false}, hosts: "${POWERSHELF_HOSTS:-}" }
  ufm:            { enabled: ${INT_UFM:-false} }
  netq:           { enabled: ${INT_NETQ:-false} }
  runai:          { enabled: ${INT_RUNAI:-false} }
  nmc:            { enabled: ${INT_NMC:-false} }

bcm:
  host: "${BCM_HOST:-}"
  user: "${BCM_USER:-root}"

bmc:
  hosts: "${BMC_HOSTS:-}"
  user:  "${BMC_USER:-admin}"

ufm:
  host: "${UFM_HOST:-}"
  user: "${UFM_USER:-admin}"

netq:
  url: "${NETQ_URL:-}"
  user: "${NETQ_USER:-}"

runai:
  url:         "${RUNAI_URL:-}"
  clusterUuid: "${RUNAI_CLUSTER_UUID:-}"
  promTarget:  "${RUNAI_PROM_TARGET:-}"

nmc:
  host: "${NMC_HOST:-}"
  port: ${NMC_PORT:-8081}
  user: "${NMC_USER:-apiuser}"

alerts:
  email:
    enabled:   ${INT_ALERT_EMAIL:-false}
    smtpHost:  "${SMTP_HOST:-}"
    smtpPort:  "${SMTP_PORT:-25}"
    from:      "${SMTP_FROM:-}"
    to:        "${SMTP_TO:-}"
    starttls:  ${SMTP_STARTTLS:-true}
    auth:      ${SMTP_AUTH:-false}
  teams:
    enabled: ${INT_ALERT_TEAMS:-false}
  slack:
    enabled: ${INT_ALERT_SLACK:-false}
EOF
}

phase_render_values() {
    log_phase 8 "Render helm values"
    VALUES_RENDERED="${STATE_DIR:-/var/lib/nvis-platform}/values.yaml"
    mkdir -p "$(dirname "$VALUES_RENDERED")" 2>/dev/null || true
    render_values_file "$VALUES_RENDERED" \
        || { log_err "Failed to render $VALUES_RENDERED"; return 1; }
    chmod 0600 "$VALUES_RENDERED" 2>/dev/null || true
    log "Rendered helm values: $VALUES_RENDERED"
}

# ---------------------------------------------------------------------------
# Phase 9 — k8s secrets
# ---------------------------------------------------------------------------
phase_secrets() {
    log_phase 9 "Create k8s Secrets for enabled integrations"
    if "$MODE_DRY_RUN"; then
        log "DRY-RUN: would create Secrets but skipping kubectl apply"
    fi
    if ! "$MODE_DRY_RUN"; then
        # Make sure namespace exists.
        if command -v kubectl >/dev/null 2>&1; then
            kubectl create namespace "$NAMESPACE" \
                --dry-run=client -o yaml 2>/dev/null \
                | kubectl apply -f - >&2 \
                || log_warn "Could not ensure namespace $NAMESPACE"
        fi
    fi
    SECRETS_NAMESPACE="$NAMESPACE" create_all_enabled_secrets \
        || log_warn "create_all_enabled_secrets returned non-zero"
}

# ---------------------------------------------------------------------------
# Phase 10 — helm install/upgrade
# ---------------------------------------------------------------------------
phase_helm() {
    log_phase 10 "helm install/upgrade nvis-platform"
    if "$MODE_DRY_RUN"; then
        log "DRY-RUN: would run: helm upgrade --install $RELEASE $CHART_DIR -n $NAMESPACE -f $VALUES_RENDERED"
        return 0
    fi
    if [[ ! -d "$CHART_DIR" ]]; then
        log_err "Helm chart dir not found: $CHART_DIR"
        return 1
    fi
    if ! command -v helm >/dev/null 2>&1; then
        log_err "helm CLI not found"
        return 1
    fi

    helm upgrade --install "$RELEASE" "$CHART_DIR" \
        --namespace "$NAMESPACE" \
        --create-namespace \
        --values "$VALUES_RENDERED" \
        --set "cluster.name=${CLUSTER_NAME}" \
        --set "cluster.dgxFlavor=${DGX_FLAVOR}" \
        --set "image.tag=${INSTALL_VERSION}" \
        --wait --timeout 10m >&2 \
        || { log_err "helm upgrade --install failed"; return 1; }

    # Now that the cluster has the namespace, push the install-state ConfigMap.
    save_state_configmap "$NAMESPACE" || log_warn "save_state_configmap failed"
}

# ---------------------------------------------------------------------------
# Phase 11 — validate + print access info
# ---------------------------------------------------------------------------
phase_validate() {
    log_phase 11 "Validation + access info"
    if "$MODE_DRY_RUN"; then
        log "DRY-RUN: skipping validation"
        _print_access_info "(dry-run; no live URL)"
        return 0
    fi
    if ! command -v kubectl >/dev/null 2>&1; then
        log_warn "kubectl missing; skipping pod-readiness check"
    else
        log "Waiting for pods in $NAMESPACE to be Ready (max 5m)..."
        local elapsed=0 timeout=300
        while (( elapsed < timeout )); do
            local not_ready
            not_ready=$(kubectl get pods -n "$NAMESPACE" \
                --field-selector=status.phase!=Running,status.phase!=Succeeded \
                --no-headers 2>/dev/null | wc -l | tr -d ' ')
            if [[ "$not_ready" == "0" ]]; then
                log "All pods in $NAMESPACE are Running"
                break
            fi
            sleep 5; elapsed=$((elapsed+5))
        done
    fi

    # Grafana health.
    local grafana_url
    grafana_url=$(_grafana_url)
    if [[ -n "$grafana_url" ]]; then
        if curl -fsS --max-time 10 "${grafana_url}/api/health" >/dev/null 2>&1; then
            log "Grafana health OK at $grafana_url"
        else
            log_warn "Grafana health probe failed at $grafana_url"
        fi
    fi

    _print_access_info "$grafana_url"
}

_grafana_url() {
    if ! command -v kubectl >/dev/null 2>&1; then
        printf 'http://%s:30300' "$OBSVM_HOST"
        return 0
    fi
    local port
    port=$(kubectl get svc -n "$NAMESPACE" \
        -l app.kubernetes.io/name=grafana \
        -o jsonpath='{.items[0].spec.ports[0].nodePort}' 2>/dev/null || true)
    [[ -z "$port" ]] && port="30300"
    printf 'http://%s:%s' "$OBSVM_HOST" "$port"
}

_print_access_info() {
    local url="$1"
    cat <<EOF | tee -a "$INSTALL_LOG" >&2

═══════════════════════════════════════════════════════════════════
  nvis-platform install complete
═══════════════════════════════════════════════════════════════════
  Cluster:          ${CLUSTER_NAME}
  DGX flavor:       ${DGX_FLAVOR}
  Grafana URL:      ${url}
  Grafana user:     admin
  Grafana password: (stored in k8s Secret ${NAMESPACE}/nvis-grafana-admin)

  Enabled integrations:
EOF
    local k
    for k in INT_DCGM INT_NODE_EXPORTER INT_ALLOY INT_BCM INT_SLURM INT_CGROUP \
             INT_REDFISH_MAIN INT_REDFISH_NM INT_REDFISH_FAST INT_REDFISH_SENSORS \
             INT_IPMI_SEL INT_IPMI_SOL INT_POWERSHELF INT_UFM INT_NETQ INT_RUNAI INT_NMC \
             INT_ALERT_EMAIL INT_ALERT_TEAMS INT_ALERT_SLACK; do
        local v="${!k:-false}"
        [[ "$v" == "true" ]] && printf '    - %s\n' "$k" | tee -a "$INSTALL_LOG" >&2
    done

    cat <<EOF | tee -a "$INSTALL_LOG" >&2

  State file:       ${STATE_FILE:-/var/lib/nvis-platform/install-state.env}
  Helm values:      ${VALUES_RENDERED:-(not rendered)}
  Logs:             ${INSTALL_LOG}
═══════════════════════════════════════════════════════════════════
EOF
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
phase_cleanup() {
    log_phase 1 "Cleanup (--cleanup)"
    if "$MODE_DRY_RUN"; then
        log "DRY-RUN: would helm uninstall $RELEASE and delete namespace $NAMESPACE"
        return 0
    fi
    if command -v helm >/dev/null 2>&1; then
        helm uninstall "$RELEASE" -n "$NAMESPACE" >&2 \
            || log_warn "helm uninstall returned non-zero"
    fi
    if command -v kubectl >/dev/null 2>&1; then
        kubectl delete namespace "$NAMESPACE" --ignore-not-found=true >&2 \
            || log_warn "namespace delete returned non-zero"
    fi
    if [[ -d "${STATE_DIR:-/var/lib/nvis-platform}" ]]; then
        rm -rf "${STATE_DIR:-/var/lib/nvis-platform}"
        log "Removed ${STATE_DIR:-/var/lib/nvis-platform}"
    fi
    log "Cleanup complete"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    # Handle --help / -h before touching the filesystem so users can read help
    # without root, without /tmp being writable, etc.
    local a
    for a in "$@"; do
        case "$a" in
            -h|--help) usage; exit 0 ;;
        esac
    done

    : > "$INSTALL_LOG"
    log "nvis-platform installer v${INSTALL_VERSION} starting (pid $$)"
    log "Log file: $INSTALL_LOG"

    parse_args "$@"
    source_libs
    load_values_file
    state_init
    init_int_defaults

    if "$MODE_UPGRADE"; then
        load_state || log_warn "No prior state; treating as fresh install"
    fi

    if "$MODE_CLEANUP"; then
        phase_cleanup
        exit 0
    fi

    if "$MODE_DETECT_ONLY"; then
        phase_prereqs
        # Cluster basics needed only for prompting; in detect-only just probe.
        DGX_FLAVOR=$(detect_dgx_flavor || echo UNKNOWN)
        validate_dgx_flavor "$DGX_FLAVOR" || DGX_FLAVOR=UNKNOWN
        log "DGX_FLAVOR=$DGX_FLAVOR"
        printf 'DGX_FLAVOR=%s\n' "$DGX_FLAVOR"
        exit 0
    fi

    phase_prereqs            || { log_err "Prereqs failed"; exit 1; }
    phase_cluster_basics     || { log_err "Cluster basics phase failed"; exit 1; }
    phase_dgx_detect
    phase_wizard
    phase_grafana_password
    phase_persist_state
    phase_k3s                || { log_err "k3s phase failed"; exit 1; }
    phase_render_values      || { log_err "Render values failed"; exit 1; }
    phase_secrets
    phase_helm               || { log_err "helm phase failed"; exit 1; }
    phase_validate

    log "All phases complete."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
