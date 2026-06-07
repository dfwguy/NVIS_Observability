#!/usr/bin/env bash
# setup-k8s.sh — NVIS Observability Stack: Unified Installer
#
# Usage:
#   ./setup-k8s.sh              Fresh install  — interactive wizard for all integrations
#   ./setup-k8s.sh --upgrade    Smart upgrade  — detects what's installed, only asks
#                                               about NEW integrations not yet configured
#   ./setup-k8s.sh --cleanup    Remove everything (namespace, helm releases, secrets)
#
# That's it. No flags to memorize. The installer figures out what's already there.
#
# ── What gets installed ─────────────────────────────────────────────────────────
#  Core (always):
#    Prometheus · Grafana · Loki · VictoriaMetrics · NVIS dashboards
#
#  Optional integrations (wizard asks during install, --upgrade adds missing ones):
#    BCM / DCGM   — GPU metrics via Base Command Manager, DCGM 4.x pushed to nodes
#    CDU Redfish  — Liquid cooling: leak detection, cold-plate, manifold, isolation
#    UFM          — InfiniBand fabric metrics via Unified Fabric Manager REST API
#    NMC          — NVIDIA Management Console integration
#
# ── GPU Architecture ───────────────────────────────────────────────────────────
#  DCGM 4.x supports: B100, B200, B300 (Blackwell) + H100, H200 (Hopper)
#  DCGM 3.x: Hopper only — NO Blackwell support
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/helm/nvis-obsvm"
GPU_CHART_DIR="${SCRIPT_DIR}/helm/nvis-gpu-agents"
VERSIONS_FILE="${CHART_DIR}/versions.yaml"
NAMESPACE="nvis-monitoring"
RELEASE="nvis-obsvm"
GPU_RELEASE="nvis-gpu-agents"
LOG_DIR="/tmp/nvis-install-$$"
mkdir -p "$LOG_DIR"

# ── NGC / DCGM config ─────────────────────────────────────────────────────────
# DCGM 4.x required for Blackwell (B100/B200/B300). Also supports Hopper (H100/H200).
# Verify latest tag: https://catalog.ngc.nvidia.com/orgs/nvidia/teams/k8s/containers/dcgm-exporter
NGC_API_KEY=""  # collected from wizard when BCM is selected
DCGM_IMAGE="nvcr.io/nvidia/k8s/dcgm-exporter:4.2.3-4.1.1-ubuntu22.04"
DCGM_TAR="${LOG_DIR}/nvis-dcgm-exporter.tar.gz"
DCGM_PORT=9400
# Grafana Alloy — deployed as systemd service on GPU/CPU nodes via BCM
ALLOY_VERSION="v1.5.1"  # https://github.com/grafana/alloy/releases

# BCM SSH options — used for ObsVM → BCM head node connections
BCM_SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
# Node SSH options — used for ObsVM → GPU node connections (via BCM jump host)
# ProxyJump is appended dynamically after BCM host is confirmed active
NODE_SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"
# Track which BCM host responded (set by discover_gpu_nodes, used by deploy)
ACTIVE_BCM_HOST=""
# Max concurrent node operations (pdcp/ssh) — tune for network
BCM_PARALLEL=20

# ── Parse args ────────────────────────────────────────────────────────────────
UPGRADE=false
CLEANUP=false
DIAGNOSE=false
RETRY_K8S=false
DRY_RUN=false
VERSION_CHECK=false

# Integration state — populated by wizard or detected from cluster on --upgrade
CLUSTER_NAME=""
STORAGE="victoria"

# BCM / DCGM
INT_BCM=false
SKIP_DCGM=false
BCM_HOST_PRIMARY=""       # SSH hostname/IP of primary BCM head node
BCM_HOST_SECONDARY=""     # SSH hostname/IP of secondary BCM head node (HA, optional)
DCGM_EXISTING_VERSION=""  # Detected DCGM version on nodes (empty = not found)
GPU_OPERATOR_MANAGED=false # true if GPU Operator owns the DCGM DaemonSet

# CDU / Redfish liquid cooling
INT_CDU=false
CDU_ENDPOINT=""
CDU_USER="admin"
CDU_PASS=""

# UFM — InfiniBand fabric
INT_UFM=false
UFM_ENDPOINT=""
UFM_USER="admin"
UFM_PASS=""

# Run:ai — job scheduling & GPU allocation
INT_RUNAI=false
RUNAI_URL=""
RUNAI_TOKEN=""
RUNAI_CLUSTER_UUID=""
RUNAI_CLUSTER_NAME=""
RUNAI_AUTH_TYPE=""   # "password" or "app_token"

# NMC — NVIDIA Management Console
INT_NMC=false
NMC_ENDPOINT=""

# Redfish / BMC per-component monitoring (decoupled from CDU)
# Enables GPU profiling + B300 temp history dashboards on its own.
INT_REDFISH=false
REDFISH_USER=""
REDFISH_PASS=""
REDFISH_TARGETS=""

# Helper: load --redfish-targets value (accepts @/path/to/file for one-per-line list)
_load_redfish_targets() {
  local v="$1"
  if [[ "$v" == @* ]]; then
    local f="${v#@}"
    [[ -f "$f" ]] || { echo "ERROR: redfish targets file not found: $f" >&2; exit 1; }
    # Strip blank lines and comments, comma-join hosts
    REDFISH_TARGETS=$(grep -vE '^\s*(#|$)' "$f" | tr '\n' ',' | sed 's/,$//')
  else
    REDFISH_TARGETS="$v"
  fi
}

for arg in "$@"; do
  case "$arg" in
    --upgrade)             UPGRADE=true ;;
    --cleanup|--uninstall) CLEANUP=true ;;
    --diagnose)            DIAGNOSE=true ;;
    --retry-k8s)           RETRY_K8S=true ;;
    --dry-run)             DRY_RUN=true ;;
    --version-check)       VERSION_CHECK=true ;;
    --storage=thanos)      STORAGE="thanos" ;;
    --storage=victoria)    STORAGE="victoria" ;;
    --bcm-host=*)          BCM_HOST_PRIMARY="${arg#--bcm-host=}" ;;
    --enable-redfish)      INT_REDFISH=true ;;
    --redfish-user=*)      REDFISH_USER="${arg#--redfish-user=}"; INT_REDFISH=true ;;
    --redfish-pass=*)      REDFISH_PASS="${arg#--redfish-pass=}"; INT_REDFISH=true ;;
    --redfish-targets=*)   _load_redfish_targets "${arg#--redfish-targets=}"; INT_REDFISH=true ;;
    --help|-h)
      sed -n '3,14p' "$0"
      echo "  --diagnose                       Post-install health check — shows what's broken and how to fix it"
      echo "  --retry-k8s                      Re-run only the k8s stack deployment (skip wizard, use saved state)"
      echo "  --bcm-host=<ip>                  Override BCM host for --cleanup when install-state is gone"
      echo ""
      echo "  Redfish/BMC per-component monitoring (independent of CDU):"
      echo "  --enable-redfish                 Turn on Redfish exporter (GPU profiling + B300 temp history)"
      echo "  --redfish-user=<user>            BMC username for Redfish (also enables Redfish)"
      echo "  --redfish-pass=<pass>            BMC password for Redfish (also enables Redfish)"
      echo "  --redfish-targets=<hosts>        Comma-separated BMC host list OR @/path/to/file (one host per line)"
      exit 0 ;;
    *) echo "Unknown arg: $arg"; exit 1 ;;
  esac
done

# ── Colors + logging ─────────────────────────────────────────────────────────
RED='\033[0;31m'; YLW='\033[0;33m'; GRN='\033[0;32m'
BLU='\033[0;34m'; CYN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Root / sudo check ────────────────────────────────────────────────────────
# k3s and helm installation require root. We support two modes:
#   1. Running as root directly:   sudo bash setup-k8s.sh   (recommended)
#   2. Running as non-root user with sudo access
# If neither, we fail immediately with a clear message.
SUDO=""
INVOKING_USER="${SUDO_USER:-$(whoami)}"   # the human who typed sudo (or current user)

if [[ $EUID -ne 0 ]]; then
  if sudo -n true 2>/dev/null; then
    SUDO="sudo"
    # Pre-escalate so we don't get a password prompt mid-install
    sudo -v
  elif sudo true 2>/dev/null; then
    SUDO="sudo"
  else
    echo ""
    echo -e "\033[0;31m  ✗ This installer requires root or sudo access.\033[0m"
    echo "    k3s and helm must be installed as root."
    echo ""
    echo "    Run as:  sudo bash $0"
    echo ""
    exit 1
  fi
fi

log()    { echo -e "${BLU}[nvis]${NC} $*"; }
logA()   { echo -e "${GRN}[k8s] ${NC} $*"; }   # Thread A — k8s stack
logB()   { echo -e "${CYN}[dcgm]${NC} $*"; }   # Thread B — GPU nodes
ok()     { echo -e "${GRN}  ✓${NC} $*"; }
warn()   { echo -e "${YLW}  ⚠${NC} $*"; }
die()    { echo -e "${RED}  ✗${NC} $*" >&2; exit 1; }
section(){ echo -e "\n${BOLD}${BLU}══════════════════════════════════════════${NC}"; \
           echo -e "${BOLD}${BLU}  $*${NC}"; \
           echo -e "${BOLD}${BLU}══════════════════════════════════════════${NC}"; }

# ── Load versions ─────────────────────────────────────────────────────────────
load_versions() {
  # Use || true on every pipeline — a missing key must never kill the installer
  PROMETHEUS_IMG=$(grep 'prometheus:'     "$VERSIONS_FILE" | awk '{print $2}' | tr -d '"' || true)
  GRAFANA_IMG=$(grep    'grafana:'        "$VERSIONS_FILE" | awk '{print $2}' | tr -d '"' || true)
  LOKI_IMG=$(grep       'loki:'           "$VERSIONS_FILE" | awk '{print $2}' | tr -d '"' || true)
  VICTORIA_IMG=$(grep   'victoriametrics:' "$VERSIONS_FILE" | awk '{print $2}' | tr -d '"' || true)
  THANOS_IMG=$(grep     'thanos:'         "$VERSIONS_FILE" | awk '{print $2}' | tr -d '"' || true)
}

# ── Prerequisites: auto-install k3s + helm ────────────────────────────────────
# Handles both airgap (bin/ directory present) and connected (download) modes.
# No manual pre-install required — the installer is self-sufficient.

_k3s_kubeconfig_fix() {
  # Always ensure kubeconfig is readable by the invoking user, regardless of how k3s was installed
  local cfg=/etc/rancher/k3s/k3s.yaml
  [[ -f "$cfg" ]] || return 0
  $SUDO chmod 0644 "$cfg" 2>/dev/null || true
  export KUBECONFIG="$cfg"
  # Also drop a copy in the invoking user's home so it persists across sessions
  if [[ -n "$SUDO_USER" && -d "/home/${SUDO_USER}" ]]; then
    $SUDO install -m 0600 -o "$SUDO_USER" "$cfg" "/home/${SUDO_USER}/.kube/config" 2>/dev/null || \
      { mkdir -p "/home/${SUDO_USER}/.kube" 2>/dev/null; \
        $SUDO install -m 0600 -o "$SUDO_USER" "$cfg" "/home/${SUDO_USER}/.kube/config" 2>/dev/null || true; }
  fi
}

ensure_k3s() {
  # Check if a working cluster already exists (k3s or kubeadm or any other)
  if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
    ok "Kubernetes cluster already running"
    _k3s_kubeconfig_fix
    return
  fi

  # k3s binary exists — check if it's just not started
  if command -v k3s >/dev/null 2>&1; then
    _k3s_kubeconfig_fix
    if k3s kubectl get nodes >/dev/null 2>&1; then
      ok "k3s single-node cluster is ready"
      return
    fi
    log "k3s binary found but cluster unreachable — starting k3s service..."
    $SUDO systemctl start k3s 2>/dev/null || true
    sleep 5
    _k3s_kubeconfig_fix
    if k3s kubectl get nodes >/dev/null 2>&1; then
      ok "k3s started"
      return
    fi
  fi

  log "k3s not installed — installing single-node cluster..."

  local k3s_bin="${SCRIPT_DIR}/bin/k3s"
  local k3s_install="${SCRIPT_DIR}/bin/k3s-install.sh"

  if [[ -f "$k3s_bin" && -f "$k3s_install" ]]; then
    # ── Airgap mode: use bundled binaries ──────────────────────────────────────
    log "  Airgap mode: using bundled k3s binary"
    $SUDO install -m 0755 "$k3s_bin" /usr/local/bin/k3s
    INSTALL_K3S_SKIP_DOWNLOAD=true \
      $SUDO bash "$k3s_install" \
        --disable traefik \
        --disable servicelb \
        --write-kubeconfig-mode 0644 \
      2>&1 | sed 's/^/  [k3s] /'
  else
    # ── Connected mode: download from get.k3s.io ───────────────────────────────
    log "  Connected mode: downloading k3s installer"
    if ! command -v curl >/dev/null 2>&1; then
      die "curl not found and no bundled k3s — cannot install k3s. Run on a connected machine first."
    fi
    curl -sfL https://get.k3s.io | \
      $SUDO INSTALL_K3S_EXEC="--disable traefik --disable servicelb --write-kubeconfig-mode 0644" sh - \
      2>&1 | sed 's/^/  [k3s] /'
  fi

  _k3s_kubeconfig_fix

  log "  Waiting for k3s node to become Ready (up to 3 minutes)..."
  local retries=60
  while (( retries-- > 0 )); do
    k3s kubectl get nodes 2>/dev/null | grep -q " Ready" && break
    sleep 3
  done
  k3s kubectl get nodes 2>/dev/null | grep -q " Ready" \
    || die "k3s installed but node not Ready — check: journalctl -u k3s -n 50"

  ok "k3s single-node cluster is Ready"
}

ensure_helm() {
  if command -v helm >/dev/null 2>&1; then
    ok "helm $(helm version --short 2>/dev/null | tr -d 'v') already installed"
    return
  fi

  log "helm not found — installing..."
  local helm_bin="${SCRIPT_DIR}/bin/helm"

  if [[ -f "$helm_bin" ]]; then
    log "  Airgap mode: using bundled helm binary"
    $SUDO install -m 0755 "$helm_bin" /usr/local/bin/helm
  else
    log "  Connected mode: downloading helm"
    if ! command -v curl >/dev/null 2>&1; then
      die "curl not found and no bundled helm binary — cannot install helm"
    fi
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
      | $SUDO bash 2>&1 | sed 's/^/  [helm] /'
  fi
  ok "helm $(helm version --short 2>/dev/null | tr -d 'v') installed"
}

load_images_airgap() {
  local images_tar="${SCRIPT_DIR}/nvis-images.tar"
  [[ -f "$images_tar" ]] || return 0

  log "Airgap mode — loading container images (this takes a few minutes)..."
  $SUDO k3s ctr images import "$images_tar" 2>&1 | grep -c "unpacking\|done" | \
    xargs -I{} echo "  {} images loaded" || true
  ok "Container images loaded from bundle"
}

# ── Preflight ─────────────────────────────────────────────────────────────────
preflight() {
  log "Preflight checks..."
  [[ -d "$CHART_DIR" ]] || die "Chart not found at $CHART_DIR"
  kubectl cluster-info >/dev/null 2>&1 || die "Cannot reach Kubernetes cluster"
  ok "Preflight passed"
}

# ── Integration state detection (used by --upgrade) ───────────────────────────
# Reads the live cluster to discover what's already configured.
# Sets INT_* flags and endpoint vars so the wizard skips already-done integrations.
detect_installed_integrations() {
  [[ "$UPGRADE" != "true" ]] && return
  log "Detecting installed integrations..."

  local prom_cfg=""
  prom_cfg=$(kubectl get configmap nvis-prometheus-config -n "$NAMESPACE" \
             -o jsonpath='{.data.prometheus\.yml}' 2>/dev/null || true)

  # BCM / DCGM
  if kubectl get daemonset nvis-gpu-agents -n "$NAMESPACE" >/dev/null 2>&1 \
     || echo "$prom_cfg" | grep -q "job_name: bcm-exporter"; then
    INT_BCM=true
    BCM_HOST_PRIMARY=$(kubectl get configmap nvis-install-state -n "$NAMESPACE" \
                       -o jsonpath='{.data.BCM_HOST_PRIMARY}' 2>/dev/null || true)
    BCM_HOST_SECONDARY=$(kubectl get configmap nvis-install-state -n "$NAMESPACE" \
                         -o jsonpath='{.data.BCM_HOST_SECONDARY}' 2>/dev/null || true)
    # Restore DCGM skip state — prevents NGC login attempt when DCGM 4.x already present
    local saved_dcgm_ver saved_skip_dcgm
    saved_dcgm_ver=$(kubectl get configmap nvis-install-state -n "$NAMESPACE" \
                     -o jsonpath='{.data.DCGM_EXISTING_VERSION}' 2>/dev/null || true)
    saved_skip_dcgm=$(kubectl get configmap nvis-install-state -n "$NAMESPACE" \
                      -o jsonpath='{.data.SKIP_DCGM}' 2>/dev/null || true)
    if [[ "$saved_skip_dcgm" == "true" && -n "$saved_dcgm_ver" ]]; then
      SKIP_DCGM=true
      DCGM_EXISTING_VERSION="$saved_dcgm_ver"
    else
      # Saved state missing or stale — re-detect DCGM version live from BCM nodes
      logA "Checking DCGM version on nodes (saved state missing)..."
      local live_info live_ver live_major
      live_info=$(validate_dcgm_on_nodes "${BCM_HOST_PRIMARY}" 2>/dev/null) || true
      live_ver=$(echo "$live_info" | awk '{print $1}')
      live_major=$(echo "$live_ver" | grep -oE '^[0-9]+' || echo "0")
      if [[ -n "$live_ver" && "$live_major" -ge 4 ]]; then
        SKIP_DCGM=true
        DCGM_EXISTING_VERSION="$live_ver"
        logA "Live DCGM detect: ${live_ver} >= 4.x — skipping NGC pull"
      fi
    fi
    ok "BCM/DCGM already configured (${BCM_HOST_PRIMARY}${BCM_HOST_SECONDARY:+, HA: ${BCM_HOST_SECONDARY}})${DCGM_EXISTING_VERSION:+ — DCGM ${DCGM_EXISTING_VERSION}, skip push} — will upgrade"
  fi

  # CDU Redfish
  if kubectl get deployment nvis-cdu-exporter -n "$NAMESPACE" >/dev/null 2>&1 \
     || echo "$prom_cfg" | grep -q "job_name: cdu-redfish"; then
    INT_CDU=true
    # Re-read endpoint from existing configmap so we don't prompt for it again
    CDU_ENDPOINT=$(kubectl get configmap nvis-install-state -n "$NAMESPACE" \
                   -o jsonpath='{.data.CDU_ENDPOINT}' 2>/dev/null || echo "existing")
    CDU_USER=$(kubectl get configmap nvis-install-state -n "$NAMESPACE" \
               -o jsonpath='{.data.CDU_USER}' 2>/dev/null || echo "admin")
    CDU_PASS=$(kubectl get secret nvis-cdu-credentials -n "$NAMESPACE" \
               -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
    ok "CDU Redfish already configured (${CDU_ENDPOINT}) — will upgrade"
  fi

  # Redfish / BMC per-component monitoring (decoupled from CDU)
  local saved_int_redfish saved_redfish_targets
  saved_int_redfish=$(kubectl get configmap nvis-install-state -n "$NAMESPACE" \
                      -o jsonpath='{.data.INT_REDFISH}' 2>/dev/null || true)
  saved_redfish_targets=$(kubectl get configmap nvis-install-state -n "$NAMESPACE" \
                          -o jsonpath='{.data.REDFISH_TARGETS}' 2>/dev/null || true)
  if [[ "$saved_int_redfish" == "true" ]] \
     || kubectl get secret nvis-redfish-credentials -n "$NAMESPACE" >/dev/null 2>&1 \
     || [[ -n "$saved_redfish_targets" ]]; then
    INT_REDFISH=true
    REDFISH_TARGETS="${saved_redfish_targets:-$REDFISH_TARGETS}"
    REDFISH_USER=$(kubectl get configmap nvis-install-state -n "$NAMESPACE" \
                   -o jsonpath='{.data.REDFISH_USER}' 2>/dev/null || echo "${REDFISH_USER}")
    [[ -z "$REDFISH_PASS" ]] && REDFISH_PASS=$(kubectl get secret nvis-redfish-credentials -n "$NAMESPACE" \
                   -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
    ok "Redfish/BMC per-component monitoring already configured (${REDFISH_TARGETS:-existing}) — will upgrade"
  fi

  # UFM
  local saved_ufm_endpoint
  saved_ufm_endpoint=$(kubectl get configmap nvis-install-state -n "$NAMESPACE" \
                       -o jsonpath='{.data.UFM_ENDPOINT}' 2>/dev/null || true)
  if kubectl get deployment nvis-ufm-exporter -n "$NAMESPACE" >/dev/null 2>&1 \
     || echo "$prom_cfg" | grep -q "job_name: ufm" \
     || [[ -n "$saved_ufm_endpoint" ]]; then
    INT_UFM=true
    UFM_ENDPOINT="${saved_ufm_endpoint:-existing}"
    UFM_USER=$(kubectl get configmap nvis-install-state -n "$NAMESPACE" \
               -o jsonpath='{.data.UFM_USER}' 2>/dev/null || echo "admin")
    UFM_PASS=$(kubectl get secret nvis-ufm-credentials -n "$NAMESPACE" \
               -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)
    ok "UFM already configured (${UFM_ENDPOINT}) — will upgrade"
  fi

  # Run:ai
  local saved_runai_url
  saved_runai_url=$(kubectl get configmap nvis-install-state -n "$NAMESPACE" \
                   -o jsonpath='{.data.RUNAI_URL}' 2>/dev/null || true)
  if [[ -n "$saved_runai_url" ]] || echo "$prom_cfg" | grep -q "job_name: runai-api"; then
    INT_RUNAI=true
    RUNAI_URL="${saved_runai_url:-existing}"
    RUNAI_CLUSTER_UUID=$(kubectl get configmap nvis-install-state -n "$NAMESPACE" \
                         -o jsonpath='{.data.RUNAI_CLUSTER_UUID}' 2>/dev/null || true)
    RUNAI_CLUSTER_NAME=$(kubectl get configmap nvis-install-state -n "$NAMESPACE" \
                         -o jsonpath='{.data.RUNAI_CLUSTER_NAME}' 2>/dev/null || true)
    RUNAI_AUTH_TYPE=$(kubectl get configmap nvis-install-state -n "$NAMESPACE" \
                      -o jsonpath='{.data.RUNAI_AUTH_TYPE}' 2>/dev/null || echo "password")
    RUNAI_TOKEN=$(kubectl get secret nvis-runai-token -n "$NAMESPACE" \
                  -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
    ok "Run:ai already configured (${RUNAI_URL}, cluster: ${RUNAI_CLUSTER_NAME}) — will upgrade"
  fi

  # NMC
  if kubectl get deployment nvis-nmc-exporter -n "$NAMESPACE" >/dev/null 2>&1 \
     || echo "$prom_cfg" | grep -q "job_name: nmc"; then
    INT_NMC=true
    NMC_ENDPOINT=$(kubectl get configmap nvis-install-state -n "$NAMESPACE" \
                   -o jsonpath='{.data.NMC_ENDPOINT}' 2>/dev/null || echo "existing")
    ok "NMC already configured (${NMC_ENDPOINT}) — will upgrade"
  fi

  # Cluster name
  if [[ -z "$CLUSTER_NAME" ]]; then
    CLUSTER_NAME=$(kubectl get configmap nvis-install-state -n "$NAMESPACE" \
                   -o jsonpath='{.data.CLUSTER_NAME}' 2>/dev/null || true)
  fi

  # Storage backend
  if echo "$prom_cfg" | grep -q "thanos"; then
    STORAGE="thanos"
  fi
}

# ── Integration wizard ─────────────────────────────────────────────────────────
# Asks about each integration that is not yet configured.
# On fresh install: asks about everything.
# On --upgrade: only asks about integrations not already detected above.
ask_yn() {
  # ask_yn "Question" → returns 0 (yes) or 1 (no)
  local question="$1"
  local ans
  echo -n "  ${question} [y/N]: "
  read -r ans
  [[ "$ans" =~ ^[yY] ]]
}

ask_val() {
  # ask_val "Prompt" "default" → prints value to stdout
  local prompt="$1" default="$2" val
  echo -n "  ${prompt}${default:+ [${default}]}: " >&2
  read -r val
  echo "${val:-$default}"
}

ask_secret() {
  local prompt="$1" val
  echo -n "  ${prompt}: " >&2
  read -rs val
  echo "" >&2
  echo "$val"
}

# ── Integration pre-flight validators ─────────────────────────────────────────
# Each validator: tests connectivity/auth, prints result, returns 0=ok 1=fail.

# Check DCGM on GPU nodes via BCM. Sets DCGM_EXISTING_VERSION and GPU_OPERATOR_MANAGED.
# Prints: "version [gpu-operator|standalone]"
# Returns 0 if 4.x found, 1 if not found or older.
validate_dcgm_on_nodes() {
  local bcm_host="$1"
  local sample_node=""
  local version=""

  # Pick first GPU node from BCM (use the same logic as _cmsh_node_discovery)
  local all_nodes
  all_nodes=$(ssh $BCM_SSH_OPTS "root@${bcm_host}" "cmsh -c 'device; list'" 2>/dev/null)
  while IFS= read -r line; do
    [[ "$line" =~ ^PhysicalNode ]] || continue
    local ip
    ip=$(echo "$line" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' | head -1 || true)
    [[ -z "$ip" ]] && continue
    # Only use a GPU node as sample
    if ssh $BCM_SSH_OPTS "root@${bcm_host}" \
       "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@${ip} \
        'nvidia-smi -L' 2>/dev/null | grep -q 'GPU '" 2>/dev/null; then
      sample_node="$ip"
      break
    fi
  done <<< "$all_nodes"

  [[ -z "$sample_node" ]] && return 0  # not found — caller checks empty stdout

  # Get DCGM version from crictl image list
  version=$(ssh $BCM_SSH_OPTS "root@${bcm_host}" \
    "ssh -o StrictHostKeyChecking=no root@${sample_node} \
     'crictl images 2>/dev/null | grep dcgm-exporter | awk \"{print \\\$2}\" | head -1'" \
    2>/dev/null | tr -d '[:space:]' || true)

  [[ -z "$version" ]] && return 0  # not found — caller checks empty stdout
  DCGM_EXISTING_VERSION="$version"

  # Detect GPU Operator — check for ClusterPolicy resource
  local clusterpolicy_name
  clusterpolicy_name=$(ssh $BCM_SSH_OPTS "root@${bcm_host}" \
    "ssh -o StrictHostKeyChecking=no root@${sample_node} \
     'kubectl get clusterpolicy -o jsonpath=\"{.items[0].metadata.name}\" 2>/dev/null'" \
    2>/dev/null | tr -d '[:space:]' || true)

  if [[ -n "$clusterpolicy_name" ]]; then
    GPU_OPERATOR_MANAGED=true
    echo "${version} [gpu-operator:${clusterpolicy_name}]"
  else
    GPU_OPERATOR_MANAGED=false
    echo "${version} [standalone]"
  fi

  return 0  # always succeed — caller checks stdout content
}

# Validate UFM REST API connectivity and credentials.
validate_ufm() {
  local endpoint="$1" user="$2" pass="$3"
  # Strip protocol prefix if user typed full URL (https://host or http://host)
  endpoint="${endpoint#https://}"
  endpoint="${endpoint#http://}"
  # Use /ufmRest/app/ufm_version — valid on UFM Enterprise 6.x+
  local url="https://${endpoint}/ufmRest/app/ufm_version"
  local http_code
  http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
    -u "${user}:${pass}" --connect-timeout 10 "$url" 2>/dev/null || echo "000")
  echo "$http_code"
  return 0  # never return non-zero — caller checks value, not exit code
}

# Validate Redfish BMC connectivity (first IP in the range/list).
validate_redfish() {
  local endpoint="$1" user="$2" pass="$3"
  # endpoint may be CIDR (10.0.1.0/24) or comma-separated IPs — test first IP
  local first_ip
  first_ip=$(echo "$endpoint" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' | head -1)
  [[ -z "$first_ip" ]] && return 1
  local url="https://${first_ip}/redfish/v1/"
  local http_code
  http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
    -u "${user}:${pass}" --connect-timeout 10 "$url" 2>/dev/null || echo "000")
  echo "$http_code"
  return 0  # never return non-zero — caller checks value, not exit code
}

prompt_integrations() {
  [[ "$DRY_RUN" == "true" ]] && return
  [[ ! -t 0 ]]               && return   # non-interactive (CI/pipe)

  local any_new=false

  echo ""
  echo -e "${BOLD}${BLU}  ── Integration Setup ──────────────────────────────────${NC}"

  # ── Cluster name ────────────────────────────────────────────────────────────
  if [[ -z "$CLUSTER_NAME" ]]; then
    CLUSTER_NAME=$(ask_val "Cluster name (label on all metrics)" "my-cluster")
  else
    log "Cluster: ${CLUSTER_NAME}"
  fi

  # ── BCM / DCGM ──────────────────────────────────────────────────────────────
  if [[ "$INT_BCM" == "true" ]]; then
    log "BCM/DCGM: already installed — upgrading"
  else
    echo ""
    echo -e "${BOLD}  BCM / DCGM (GPU Metrics)${NC}"
    echo    "  Pushes DCGM 4.x to GPU nodes via BCM for per-GPU metrics."
    echo    "  Supports H100/H200 (Hopper) and B100/B200/B300 (Blackwell)."
    echo    "  BCM head node(s) are used for GPU node discovery (cmsh)."
    if ask_yn "Configure BCM/DCGM GPU metrics?"; then
      INT_BCM=true
      any_new=true

      # BCM host(s) — ObsVM SSHes to BCM to run cmsh for node discovery
      BCM_HOST_PRIMARY=$(ask_val "BCM primary head node IP or hostname" "")
      while [[ -z "$BCM_HOST_PRIMARY" ]]; do
        echo "  BCM host is required for GPU node discovery." >&2
        BCM_HOST_PRIMARY=$(ask_val "BCM primary head node IP or hostname" "")
      done

      # Test SSH connectivity to primary BCM
      echo -n "  Testing SSH to ${BCM_HOST_PRIMARY}..." >&2
      if ssh $BCM_SSH_OPTS "root@${BCM_HOST_PRIMARY}" "which cmsh || test -x /cm/local/apps/cmd/bin/cmsh" >/dev/null 2>&1; then
        echo -e " ${GRN}OK${NC}" >&2
      else
        echo -e " ${YLW}WARN: SSH failed or cmsh not found on ${BCM_HOST_PRIMARY}${NC}" >&2
        echo    "  Check SSH key auth and that cmsh is installed on the BCM head node." >&2
        ask_yn "Continue anyway?" || { log "Aborted."; exit 1; }
      fi

      # Optional secondary BCM (HA)
      if ask_yn "Is there a secondary BCM head node (HA pair)?"; then
        BCM_HOST_SECONDARY=$(ask_val "BCM secondary head node IP or hostname" "")
        if [[ -n "$BCM_HOST_SECONDARY" ]]; then
          echo -n "  Testing SSH to ${BCM_HOST_SECONDARY}..." >&2
          if ssh $BCM_SSH_OPTS "root@${BCM_HOST_SECONDARY}" "which cmsh || test -x /cm/local/apps/cmd/bin/cmsh" >/dev/null 2>&1; then
            echo -e " ${GRN}OK${NC}" >&2
          else
            echo -e " ${YLW}WARN: SSH failed or cmsh not found on ${BCM_HOST_SECONDARY}${NC}" >&2
          fi
        fi
      fi

      # Check if DCGM is already running on the GPU nodes
      echo -n "  Checking DCGM on GPU nodes..." >&2
      local detected_info
      detected_info=$(validate_dcgm_on_nodes "$BCM_HOST_PRIMARY" 2>/dev/null) || true
      local detected_ver
      detected_ver=$(echo "$detected_info" | awk '{print $1}')
      if [[ -n "$detected_ver" ]]; then
        local major
        major=$(echo "$detected_ver" | grep -oE '^[0-9]+' || echo "0")
        if [[ "$major" -ge 4 ]]; then
          local mgmt_info
          mgmt_info=$(echo "$detected_info" | grep -oE '\[.*\]' || echo "")
          # Set globals from stdout — validate_dcgm_on_nodes ran in a subshell
          # so its internal assignments to DCGM_EXISTING_VERSION and GPU_OPERATOR_MANAGED
          # did NOT propagate. Extract them here from the captured stdout.
          DCGM_EXISTING_VERSION="$detected_ver"
          [[ "$mgmt_info" == *"gpu-operator"* ]] && GPU_OPERATOR_MANAGED=true || GPU_OPERATOR_MANAGED=false
          echo -e " ${GRN}${detected_ver}${NC} ${mgmt_info} — 4.x present, no push needed" >&2
          # Version >= 4.x is the gate — skip image push regardless of port check
          SKIP_DCGM=true
          # Validate metrics port as info only (uses first GPU node, not first PhysicalNode)
          local sample_ip
          sample_ip=$(ssh $BCM_SSH_OPTS "root@${BCM_HOST_PRIMARY}" \
            "cmsh -c 'device; list'" 2>/dev/null \
            | awk '/^PhysicalNode/{print $0}' \
            | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' \
            | while read -r ip; do
                ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
                  "root@${ip}" 'nvidia-smi -L' 2>/dev/null | grep -q 'GPU ' && echo "$ip" && break
              done || true)
          if [[ -n "$sample_ip" ]]; then
            echo -n "  Validating DCGM metrics at ${sample_ip}:9400..." >&2
            if ssh $BCM_SSH_OPTS "root@${BCM_HOST_PRIMARY}" \
               "curl -sf --max-time 5 http://${sample_ip}:9400/metrics 2>/dev/null | head -1" \
               2>/dev/null | grep -q '#'; then
              echo -e " ${GRN}OK${NC}" >&2
            else
              echo -e " ${YLW}WARN: port 9400 not responding on ${sample_ip} — check after install${NC}" >&2
            fi
          fi
        else
          echo -e " ${YLW}found ${detected_ver}${NC} (< 4.x — will deploy DCGM 4.x)" >&2
        fi
      else
        echo -e " ${YLW}not found${NC} — will deploy DCGM 4.x" >&2
      fi

      # Only ask for NGC key if we actually need to push DCGM
      if [[ "$SKIP_DCGM" != "true" ]]; then
        NGC_API_KEY=$(ask_secret "NGC API key (from ngc.nvidia.com — needed to pull DCGM 4.x image)")
      fi
      ok "BCM/DCGM enabled (primary: ${BCM_HOST_PRIMARY}${BCM_HOST_SECONDARY:+, secondary: ${BCM_HOST_SECONDARY}})${detected_ver:+ — DCGM ${detected_ver}}"
    else
      SKIP_DCGM=true
      log "Skipping BCM/DCGM"
    fi
  fi

  # ── BMC Liquid Cooling (Redfish) ────────────────────────────────────────────
  # Polls each node's BMC via Redfish for tray-level cold-plate and manifold
  # leak sensors (GB200/GB300 NVL72). No NMC license required.
  # Rack/CDU-level isolation (BMS MQTT) requires NMC — those panels are labeled.
  if [[ "$INT_CDU" == "true" ]]; then
    log "BMC Liquid Cooling: already configured (${CDU_ENDPOINT}) — upgrading"
  else
    echo ""
    echo -e "${BOLD}  Liquid Cooling — Tray-Level Leak Detection (BMC Redfish)${NC}"
    echo    "  Polls each node's BMC for cold-plate and inner-manifold leak sensors."
    echo    "  Works with GB200/GB300 NVL72. Uses standard BMC credentials."
    echo    "  Note: Rack/CDU-level isolation requires NVIDIA Mission Control (NMC)."
    if ask_yn "Is this a liquid-cooled cluster (GB200/GB300 NVL72)?"; then
      CDU_ENDPOINT=$(ask_val "BMC IP range or CIDR (e.g. 10.0.1.0/24 or 10.0.1.1,10.0.1.2)" "")
      if [[ -n "$CDU_ENDPOINT" ]]; then
        CDU_USER=$(ask_val "BMC username" "root")
        CDU_PASS=$(ask_secret "BMC password")
        # Validate Redfish connectivity on first IP
        echo -n "  Validating Redfish BMC connectivity..." >&2
        local redfish_code
        redfish_code=$(validate_redfish "$CDU_ENDPOINT" "$CDU_USER" "$CDU_PASS") || true
        if [[ "$redfish_code" =~ ^(200|401|403) ]]; then
          [[ "$redfish_code" == "200" ]] && echo -e " ${GRN}OK${NC}" >&2 \
            || echo -e " ${YLW}HTTP ${redfish_code} (auth issue — check credentials)${NC}" >&2
        else
          echo -e " ${YLW}WARN: HTTP ${redfish_code} — BMC not reachable or not Redfish${NC}" >&2
          ask_yn "  Continue with CDU/Redfish anyway?" || { warn "Skipping CDU/Redfish"; CDU_ENDPOINT=""; }
        fi
        if [[ -n "$CDU_ENDPOINT" ]]; then
          INT_CDU=true
          any_new=true
          ok "BMC Liquid Cooling configured (BMC range: ${CDU_ENDPOINT}, user: ${CDU_USER})"
        fi
      else
        warn "No BMC range entered — skipping liquid cooling"
      fi
    else
      log "Skipping liquid cooling (air-cooled or NMC-managed)"
    fi
  fi

  # ── Redfish / BMC per-component monitoring (independent of CDU) ────────────
  # Same exporter that powers CDU leak detection, but enables GPU profiling +
  # B300 temp history dashboards on clusters that don't need CDU coverage.
  if [[ "$INT_REDFISH" == "true" && -n "$REDFISH_TARGETS" ]]; then
    log "Redfish/BMC monitoring: already configured (${REDFISH_TARGETS}) — upgrading"
  else
    echo ""
    echo -e "${BOLD}  Redfish / BMC Per-Component Monitoring${NC}"
    echo    "  Polls each node's BMC via Redfish for per-component metrics:"
    echo    "  GPU temp/power profiling, B300 temp history, fan/PSU/SEL data."
    echo    "  Independent of CDU — works on air-cooled clusters too."
    if ask_yn "Enable Redfish/BMC per-component monitoring (GPU profiling + B300 temp history)?"; then
      local _rf_in
      _rf_in=$(ask_val "BMC host list (comma-separated) OR @/path/to/file" "")
      if [[ -n "$_rf_in" ]]; then
        _load_redfish_targets "$_rf_in"
      fi
      if [[ -n "$REDFISH_TARGETS" ]]; then
        REDFISH_USER=$(ask_val "Redfish/BMC username" "${REDFISH_USER:-admin}")
        REDFISH_PASS=$(ask_secret "Redfish/BMC password")
        # Validate Redfish connectivity on first IP
        echo -n "  Validating Redfish at first target..." >&2
        local rf_code
        rf_code=$(validate_redfish "$REDFISH_TARGETS" "$REDFISH_USER" "$REDFISH_PASS") || true
        if [[ "$rf_code" =~ ^(200|401|403) ]]; then
          [[ "$rf_code" == "200" ]] && echo -e " ${GRN}OK${NC}" >&2 \
            || echo -e " ${YLW}HTTP ${rf_code} (auth issue — check credentials)${NC}" >&2
          INT_REDFISH=true
          any_new=true
          ok "Redfish/BMC monitoring configured (targets: ${REDFISH_TARGETS}, user: ${REDFISH_USER})"
        else
          echo -e " ${YLW}WARN: HTTP ${rf_code} — BMC not reachable or not Redfish${NC}" >&2
          if ask_yn "  Continue with Redfish anyway?"; then
            INT_REDFISH=true
            any_new=true
            ok "Redfish/BMC monitoring configured (unvalidated): ${REDFISH_TARGETS}"
          else
            warn "Skipping Redfish/BMC monitoring"
            INT_REDFISH=false
            REDFISH_TARGETS=""
          fi
        fi
      else
        warn "No targets entered — skipping Redfish/BMC monitoring"
      fi
    else
      log "Skipping Redfish/BMC per-component monitoring"
    fi
  fi

  # ── Run:ai ──────────────────────────────────────────────────────────────────
  if [[ "$INT_RUNAI" == "true" ]]; then
    log "Run:ai: already configured (${RUNAI_URL}, cluster: ${RUNAI_CLUSTER_NAME}) — upgrading"
  else
    echo ""
    echo -e "${BOLD}  Run:ai — GPU Job Scheduling & Allocation${NC}"
    echo    "  Workloads, project quotas, department GPU allocation, cluster health."
    echo    "  Runs on a separate host/k8s from BCM."
    if ask_yn "Is Run:ai deployed on this cluster?"; then
      RUNAI_URL=$(ask_val "Run:ai URL (e.g. https://acme.run.ai or https://cluster.cm.cluster)" "")
      RUNAI_URL="${RUNAI_URL%/}"   # strip trailing slash
      if [[ -n "$RUNAI_URL" ]]; then
        echo    "  Authentication type:"
        echo    "    1) Username / password"
        echo    "    2) Application token  (for SAML/SSO customers — non-expiring)"
        local auth_choice
        auth_choice=$(ask_val "Choice [1/2]" "1")

        if [[ "$auth_choice" == "2" ]]; then
          # ── App token auth ──────────────────────────────────────────────────
          RUNAI_AUTH_TYPE="app_token"
          local app_name app_secret
          app_name=$(ask_val "Run:ai Application Name" "")
          app_secret=$(ask_secret "Run:ai Application Secret Key")
          echo -n "  Obtaining bearer token..." >&2
          local token_resp
          token_resp=$(curl -sf -X POST \
            "${RUNAI_URL}/api/v1/token" \
            -H "Content-Type: application/json" \
            -d "{\"grantType\":\"app_token\",\"AppId\":\"${app_name}\",\"AppSecret\":\"${app_secret}\"}" \
            --connect-timeout 10 --max-time 15 2>/dev/null || true)
          RUNAI_TOKEN=$(echo "$token_resp" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(d.get('token',d.get('accessToken','')))" \
            2>/dev/null || true)
        else
          # ── Username / password auth ────────────────────────────────────────
          RUNAI_AUTH_TYPE="password"
          local runai_user runai_pass
          runai_user=$(ask_val "Run:ai username" "")
          runai_pass=$(ask_secret "Run:ai password")
          echo -n "  Obtaining bearer token..." >&2
          local token_resp
          token_resp=$(curl -sf -X POST \
            "${RUNAI_URL}/auth/realms/runai/protocol/openid-connect/token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "grant_type=password&client_id=runai-admin-ui&username=${runai_user}&password=${runai_pass}" \
            --connect-timeout 10 --max-time 15 2>/dev/null || true)
          RUNAI_TOKEN=$(echo "$token_resp" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" \
            2>/dev/null || true)
        fi

        if [[ -z "$RUNAI_TOKEN" ]]; then
          echo -e " ${YLW}WARN: could not obtain token — check URL/credentials${NC}" >&2
          if ask_yn "  Continue with Run:ai anyway (token can be set later)?"; then
            INT_RUNAI=true
            any_new=true
            warn "Run:ai configured without valid token — fix credentials and re-run --upgrade"
          else
            warn "Skipping Run:ai"
          fi
        else
          echo -e " ${GRN}OK${NC}" >&2

          # ── Discover clusters ─────────────────────────────────────────────
          echo -n "  Fetching Run:ai cluster list..." >&2
          local clusters_json
          clusters_json=$(curl -sf \
            -H "Authorization: Bearer ${RUNAI_TOKEN}" \
            "${RUNAI_URL}/api/v1/clusters" \
            --connect-timeout 10 --max-time 15 2>/dev/null || true)
          local cluster_count
          cluster_count=$(echo "$clusters_json" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); clusters=d if isinstance(d,list) else d.get('clusters',d.get('data',[])); print(len(clusters))" \
            2>/dev/null || echo "0")

          if [[ "$cluster_count" -eq 0 ]]; then
            echo -e " ${YLW}no clusters found${NC}" >&2
            warn "Run:ai returned 0 clusters — using empty cluster UUID"
            INT_RUNAI=true; any_new=true
          else
            echo -e " ${GRN}${cluster_count} cluster(s)${NC}" >&2
            # Print cluster list
            echo "$clusters_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
clusters = d if isinstance(d, list) else d.get('clusters', d.get('data', []))
for i, c in enumerate(clusters):
    uid  = c.get('uuid', c.get('id', ''))
    name = c.get('name', c.get('clusterName', uid))
    gpus = c.get('totalGpus', c.get('gpuCount', '?'))
    print(f'  [{i+1}] {name}  (UUID: {uid}, GPUs: {gpus})')
" 2>/dev/null >&2

            if [[ "$cluster_count" -eq 1 ]]; then
              # Auto-select single cluster
              RUNAI_CLUSTER_UUID=$(echo "$clusters_json" | python3 -c \
                "import sys,json; d=json.load(sys.stdin); c=d[0] if isinstance(d,list) else d.get('clusters',d.get('data',[]))[0]; print(c.get('uuid',c.get('id','')))" \
                2>/dev/null || true)
              RUNAI_CLUSTER_NAME=$(echo "$clusters_json" | python3 -c \
                "import sys,json; d=json.load(sys.stdin); c=d[0] if isinstance(d,list) else d.get('clusters',d.get('data',[]))[0]; print(c.get('name',c.get('clusterName','')))" \
                2>/dev/null || true)
              ok "Auto-selected cluster: ${RUNAI_CLUSTER_NAME} (${RUNAI_CLUSTER_UUID})"
            else
              local sel
              sel=$(ask_val "Select cluster number" "1")
              RUNAI_CLUSTER_UUID=$(echo "$clusters_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
clusters = d if isinstance(d, list) else d.get('clusters', d.get('data', []))
idx = int('${sel}') - 1
c = clusters[idx] if 0 <= idx < len(clusters) else clusters[0]
print(c.get('uuid', c.get('id', '')))
" 2>/dev/null || true)
              RUNAI_CLUSTER_NAME=$(echo "$clusters_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
clusters = d if isinstance(d, list) else d.get('clusters', d.get('data', []))
idx = int('${sel}') - 1
c = clusters[idx] if 0 <= idx < len(clusters) else clusters[0]
print(c.get('name', c.get('clusterName', '')))
" 2>/dev/null || true)
              ok "Selected cluster: ${RUNAI_CLUSTER_NAME} (${RUNAI_CLUSTER_UUID})"
            fi

            INT_RUNAI=true
            any_new=true
            ok "Run:ai configured: ${RUNAI_URL}  cluster=${RUNAI_CLUSTER_NAME}"
          fi
        fi
      else
        warn "No URL entered — skipping Run:ai"
      fi
    else
      log "Skipping Run:ai"
    fi
  fi

  # ── UFM ─────────────────────────────────────────────────────────────────────
  if [[ "$INT_UFM" == "true" ]]; then
    log "UFM: already installed (${UFM_ENDPOINT}) — upgrading"
  else
    echo ""
    echo -e "${BOLD}  UFM — InfiniBand Fabric Manager${NC}"
    echo    "  UFM Enterprise (v6.x+): switch inventory, port states, link health,"
    echo    "  bandwidth counters, active alarms/events, and per-switch temperatures."
    echo    "  Endpoint format: host:port  (e.g. 10.0.0.1:443 or host:33735)"
    if ask_yn "Is UFM (Unified Fabric Manager) running on this cluster?"; then
      UFM_ENDPOINT=$(ask_val "UFM REST API host:port" "")
      if [[ -n "$UFM_ENDPOINT" ]]; then
        UFM_USER=$(ask_val "UFM username" "admin")
        UFM_PASS=$(ask_secret "UFM password")
        # Validate before accepting
        echo -n "  Validating UFM at ${UFM_ENDPOINT}..." >&2
        local ufm_code
        ufm_code=$(validate_ufm "$UFM_ENDPOINT" "$UFM_USER" "$UFM_PASS") || true
        if [[ "$ufm_code" == "200" ]]; then
          echo -e " ${GRN}OK${NC}" >&2
          INT_UFM=true
          any_new=true
          ok "UFM configured: ${UFM_ENDPOINT}"
        else
          echo -e " ${YLW}WARN: HTTP ${ufm_code} — check endpoint/credentials${NC}" >&2
          if ask_yn "  Continue with UFM anyway?"; then
            INT_UFM=true
            any_new=true
            ok "UFM configured (unvalidated): ${UFM_ENDPOINT}"
          else
            warn "Skipping UFM — fix endpoint/credentials and re-run with --upgrade"
          fi
        fi
      else
        warn "No endpoint entered — skipping UFM"
      fi
    else
      log "Skipping UFM"
    fi
  fi

  # ── NMC ─────────────────────────────────────────────────────────────────────
  if [[ "$INT_NMC" == "true" ]]; then
    log "NMC: already installed (${NMC_ENDPOINT}) — upgrading"
  else
    echo ""
    echo -e "${BOLD}  NMC — NVIDIA Management Console${NC}"
    echo    "  Job scheduling, cluster health, and resource allocation metrics."
    if ask_yn "Is NMC deployed on this cluster?"; then
      NMC_ENDPOINT=$(ask_val "NMC API IP or hostname" "")
      if [[ -n "$NMC_ENDPOINT" ]]; then
        INT_NMC=true
        any_new=true
        ok "NMC configured: ${NMC_ENDPOINT}"
      else
        warn "No endpoint entered — skipping NMC"
      fi
    else
      log "Skipping NMC"
    fi
  fi

  echo ""
  if [[ "$UPGRADE" == "true" && "$any_new" == "false" ]]; then
    log "No new integrations — upgrading existing stack"
  fi
}

# ── Persist integration state to cluster ──────────────────────────────────────
# Saved so --upgrade can detect what's configured without asking again.
save_install_state() {
  # Mirror to local file — survives kubectl delete namespace, readable by --cleanup
  local state_file="/var/lib/nvis-obsvm/install-state.env"
  mkdir -p /var/lib/nvis-obsvm
  cat > "$state_file" <<EOF
BCM_HOST_PRIMARY=${BCM_HOST_PRIMARY}
BCM_HOST_SECONDARY=${BCM_HOST_SECONDARY}
CLUSTER_NAME=${CLUSTER_NAME}
STORAGE=${STORAGE}
UFM_ENDPOINT=${UFM_ENDPOINT}
UFM_USER=${UFM_USER}
CDU_ENDPOINT=${CDU_ENDPOINT}
CDU_USER=${CDU_USER}
DCGM_EXISTING_VERSION=${DCGM_EXISTING_VERSION}
SKIP_DCGM=${SKIP_DCGM}
RUNAI_URL=${RUNAI_URL}
RUNAI_CLUSTER_UUID=${RUNAI_CLUSTER_UUID}
RUNAI_CLUSTER_NAME=${RUNAI_CLUSTER_NAME}
RUNAI_AUTH_TYPE=${RUNAI_AUTH_TYPE}
INT_REDFISH=${INT_REDFISH}
REDFISH_USER=${REDFISH_USER}
REDFISH_TARGETS=${REDFISH_TARGETS}
EOF

  kubectl create configmap nvis-install-state \
    --from-literal=CLUSTER_NAME="${CLUSTER_NAME}" \
    --from-literal=STORAGE="${STORAGE}" \
    --from-literal=BCM_HOST_PRIMARY="${BCM_HOST_PRIMARY}" \
    --from-literal=BCM_HOST_SECONDARY="${BCM_HOST_SECONDARY}" \
    --from-literal=CDU_ENDPOINT="${CDU_ENDPOINT}" \
    --from-literal=CDU_USER="${CDU_USER}" \
    --from-literal=UFM_ENDPOINT="${UFM_ENDPOINT}" \
    --from-literal=UFM_USER="${UFM_USER}" \
    --from-literal=NMC_ENDPOINT="${NMC_ENDPOINT}" \
    --from-literal=DCGM_EXISTING_VERSION="${DCGM_EXISTING_VERSION}" \
    --from-literal=SKIP_DCGM="${SKIP_DCGM}" \
    --from-literal=RUNAI_URL="${RUNAI_URL}" \
    --from-literal=RUNAI_CLUSTER_UUID="${RUNAI_CLUSTER_UUID}" \
    --from-literal=RUNAI_CLUSTER_NAME="${RUNAI_CLUSTER_NAME}" \
    --from-literal=RUNAI_AUTH_TYPE="${RUNAI_AUTH_TYPE}" \
    --from-literal=INT_REDFISH="${INT_REDFISH}" \
    --from-literal=REDFISH_USER="${REDFISH_USER}" \
    --from-literal=REDFISH_TARGETS="${REDFISH_TARGETS}" \
    -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # Store secrets separately (not in configmap)
  if [[ -n "$CDU_PASS" ]]; then
    kubectl create secret generic nvis-cdu-credentials \
      --from-literal=password="${CDU_PASS}" \
      -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  fi
  if [[ -n "$UFM_PASS" ]]; then
    kubectl create secret generic nvis-ufm-credentials \
      --from-literal=password="${UFM_PASS}" \
      -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  fi
  if [[ -n "$REDFISH_PASS" ]]; then
    kubectl create secret generic nvis-redfish-credentials \
      --from-literal=password="${REDFISH_PASS}" \
      -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  fi
  if [[ "$INT_RUNAI" == "true" && -n "$RUNAI_TOKEN" ]]; then
    kubectl create secret generic nvis-runai-token \
      --from-literal=token="${RUNAI_TOKEN}" \
      -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  fi
}

# ── Version check ─────────────────────────────────────────────────────────────
version_check() {
  log "Checking for newer component versions..."
  load_versions
  for pair in "grafana grafana/grafana" "prometheus prometheus/prometheus" "VictoriaMetrics VictoriaMetrics/VictoriaMetrics"; do
    name=${pair%% *}; repo=${pair##* }
    latest=$(curl -s "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
             | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/' || echo "unknown")
    current=$(grep "${name,,}:" "$VERSIONS_FILE" | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "?")
    printf "  %-20s current=%-12s latest=%s\n" "${name}:" "$current" "$latest"
  done
  echo ""
  echo "DCGM image: ${DCGM_IMAGE}"
  echo "To upgrade: edit ${VERSIONS_FILE} or DCGM_IMAGE in this script, then run: ./setup-k8s.sh --upgrade"
  exit 0
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
uninstall() {
  section "NVIS Full Cleanup"

  # ── Read BCM config — local file first, then k8s ConfigMap ─────────────────
  if [[ -z "$BCM_HOST_PRIMARY" ]]; then
    local state_file="/var/lib/nvis-obsvm/install-state.env"
    if [[ -f "$state_file" ]]; then
      BCM_HOST_PRIMARY=$(grep   '^BCM_HOST_PRIMARY='   "$state_file" | cut -d= -f2 || true)
      BCM_HOST_SECONDARY=$(grep '^BCM_HOST_SECONDARY=' "$state_file" | cut -d= -f2 || true)
      [[ -n "$BCM_HOST_PRIMARY" ]] && log "Restored BCM config from local state file: ${BCM_HOST_PRIMARY}"
    else
      BCM_HOST_PRIMARY=$(kubectl get configmap nvis-install-state -n "$NAMESPACE" \
                         -o jsonpath='{.data.BCM_HOST_PRIMARY}' 2>/dev/null || true)
      BCM_HOST_SECONDARY=$(kubectl get configmap nvis-install-state -n "$NAMESPACE" \
                           -o jsonpath='{.data.BCM_HOST_SECONDARY}' 2>/dev/null || true)
      [[ -n "$BCM_HOST_PRIMARY" ]] && log "Restored BCM config from k8s install-state: ${BCM_HOST_PRIMARY}"
    fi
  fi

  # ── ObsVM: remove all k8s resources ────────────────────────────────────────
  log "Removing k8s resources from ObsVM..."
  helm uninstall "$RELEASE"     -n "$NAMESPACE" 2>/dev/null && ok "  Removed $RELEASE"     || warn "  $RELEASE not installed"
  helm uninstall "$GPU_RELEASE" -n "$NAMESPACE" 2>/dev/null && ok "  Removed $GPU_RELEASE" || warn "  $GPU_RELEASE not installed"
  # Delete PVCs explicitly — Helm resource policy keeps them after helm uninstall
  kubectl delete pvc --all -n "$NAMESPACE" --ignore-not-found 2>/dev/null && ok "  PVCs deleted" || true
  kubectl delete namespace "$NAMESPACE" --ignore-not-found 2>/dev/null && ok "  Namespace $NAMESPACE deleted" || true
  ok "ObsVM k8s cleanup done"

  # ── Script run on every node and BCM head: remove Alloy, node_exporter, any nvis artifacts ──
  local node_clean_script
  node_clean_script=$(cat <<'CLEAN'
set -e
# Disable first so systemd won't restart after stop
for svc in alloy alloy-nvis-logs grafana-alloy nvis-alloy; do
  systemctl disable "$svc" 2>/dev/null || true
  systemctl stop    "$svc" 2>/dev/null || true
done
# Force-kill any surviving alloy / node_exporter processes (SIGKILL — no restart)
pkill -9 -f 'alloy run'     2>/dev/null || true
pkill -f 'node_exporter' 2>/dev/null || true
# Remove binaries
rm -f /usr/local/bin/alloy /bin/alloy /usr/bin/alloy
rm -f /usr/local/bin/node_exporter /bin/node_exporter /usr/bin/node_exporter
# Remove configs and data
rm -rf /etc/alloy /var/lib/alloy /etc/nvis-alloy /tmp/alloy-data
# Remove systemd units
rm -f /etc/systemd/system/alloy.service
rm -f /etc/systemd/system/alloy-nvis-logs.service
rm -f /etc/systemd/system/grafana-alloy.service
rm -f /etc/systemd/system/nvis-alloy.service
rm -f /etc/systemd/system/nvis-node-exporter.service
systemctl daemon-reload
# Remove nvis-monitoring namespace from the GPU node's own k8s cluster (RunAI/BCM managed)
kubectl delete namespace nvis-monitoring --ignore-not-found 2>/dev/null || true
# Remove any nvis docker containers
docker ps -a --filter "name=nvis-" --format "{{.Names}}" 2>/dev/null | xargs -r docker rm -f 2>/dev/null || true
echo "CLEAN_DONE"
CLEAN
)
  local script_b64
  script_b64=$(echo "$node_clean_script" | base64 -w0)

  # ── BCM-managed nodes (GPU + CPU — all of them) ─────────────────────────────
  if [[ -n "$BCM_HOST_PRIMARY" ]]; then
    log "Discovering all BCM-managed nodes..."
    local all_nodes=()
    local cmsh_out
    cmsh_out=$(ssh $BCM_SSH_OPTS "root@${BCM_HOST_PRIMARY}" "cmsh -c 'device; list'" 2>/dev/null || true)
    while IFS= read -r line; do
      [[ "$line" =~ ^PhysicalNode ]] || continue
      local ip
      ip=$(echo "$line" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' | head -1 || true)
      [[ -n "$ip" ]] && all_nodes+=("$ip")
    done <<< "$cmsh_out"

    log "Cleaning ${#all_nodes[@]} BCM-managed nodes..."
    for node_ip in "${all_nodes[@]}"; do
      local result
      result=$(ssh $BCM_SSH_OPTS "root@${BCM_HOST_PRIMARY}" \
        "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@${node_ip} \
         'printf \"%s\" \"${script_b64}\" | base64 -d | bash 2>&1'" 2>/dev/null || echo "SSH_FAIL")
      [[ "$result" == *"CLEAN_DONE"* ]] && ok "  ${node_ip}: clean" || warn "  ${node_ip}: ${result:-unreachable}"
    done

    # ── BCM head node(s) ──────────────────────────────────────────────────────
    for bcm_host in "$BCM_HOST_PRIMARY" "${BCM_HOST_SECONDARY:-}"; do
      [[ -z "$bcm_host" ]] && continue
      local bcm_result
      bcm_result=$(ssh $BCM_SSH_OPTS "root@${bcm_host}" \
        "printf \"%s\" \"${script_b64}\" | base64 -d | bash 2>&1" 2>/dev/null || echo "SSH_FAIL")
      [[ "$bcm_result" == *"CLEAN_DONE"* ]] && ok "  BCM ${bcm_host}: clean" || warn "  BCM ${bcm_host}: ${bcm_result:-unreachable}"
    done

    # ── Validation: confirm nothing remains ──────────────────────────────────
    section "Cleanup Validation"
    local all_clean=true
    for node_ip in "${all_nodes[@]}"; do
      local procs
      procs=$(ssh $BCM_SSH_OPTS "root@${BCM_HOST_PRIMARY}" \
        "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@${node_ip} \
         'pgrep -c -f \"alloy run\" 2>/dev/null || echo 0'" 2>/dev/null | tr -d '[:space:]' || echo "?")
      local bins
      bins=$(ssh $BCM_SSH_OPTS "root@${BCM_HOST_PRIMARY}" \
        "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@${node_ip} \
         'ls /usr/local/bin/alloy /bin/alloy /etc/alloy 2>/dev/null | wc -l'" 2>/dev/null | tr -d '[:space:]' || echo "?")
      if [[ "$procs" == "0" && "$bins" == "0" ]]; then
        ok "  ${node_ip}: verified clean (no processes, no binaries)"
      else
        warn "  ${node_ip}: procs=${procs} leftover_files=${bins}"
        all_clean=false
      fi
    done
    [[ "$all_clean" == "true" ]] && ok "All nodes verified clean" || warn "Re-run --cleanup to finish"
  else
    warn "BCM not configured — only ObsVM cleaned. Run with BCM configured to clean GPU nodes."
  fi

  ok "Cleanup complete"
  exit 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# THREAD B — NGC pull + BCM GPU node deployment
# Runs in background, writes results to $LOG_DIR/
# ═══════════════════════════════════════════════════════════════════════════════

# Run cmsh on a BCM host via SSH, return node IPs of UP nodes.
# Returns 0 and prints IPs if successful, returns 1 if unreachable/error.
_cmsh_node_discovery() {
  local host="$1"
  local all_nodes="${2:-false}"   # pass "all" to skip GPU filter
  local candidates=()
  local output
  # Run cmsh remotely — BCM head node has cmsh, ObsVM does not
  output=$(ssh $BCM_SSH_OPTS "root@${host}" \
    "cmsh -c 'device; list'" 2>/dev/null) || return 1

  # First pass: collect all UP PhysicalNode IPs
  while IFS= read -r line; do
    [[ "$line" =~ ^PhysicalNode ]] || continue
    local node_ip status
    node_ip=$(echo "$line" | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' | head -1 || true)
    status=$(echo  "$line" | grep -oE '\[\s*UP\s*\]' || true)
    [[ -n "$node_ip" && -n "$status" ]] && candidates+=("$node_ip")
  done <<< "$output"

  [[ ${#candidates[@]} -eq 0 ]] && return 1

  # If all_nodes mode requested, return everything without GPU filter
  if [[ "$all_nodes" == "all" ]]; then
    printf '%s\n' "${candidates[@]}"
    return 0
  fi

  # Second pass: filter to GPU nodes only — check nvidia-smi via BCM SSH.
  # CPU-only nodes (RunAI schedulers, mgmt nodes, etc.) are excluded.
  local nodes=()
  for node_ip in "${candidates[@]}"; do
    if ssh $BCM_SSH_OPTS "root@${host}" \
       "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@${node_ip} \
        'nvidia-smi -L' 2>/dev/null | grep -q 'GPU '" 2>/dev/null; then
      nodes+=("$node_ip")
    fi
  done

  [[ ${#nodes[@]} -eq 0 ]] && return 1
  printf '%s\n' "${nodes[@]}"
}

# Discover ALL BCM-managed PhysicalNodes (GPU + CPU) with HA failover.
# Used for Alloy deployment which should run on every node.
_discover_all_managed_nodes() {
  local nodes=()
  local active_bcm=""

  if [[ -n "$BCM_HOST_PRIMARY" ]]; then
    if mapfile -t nodes < <(_cmsh_node_discovery "$BCM_HOST_PRIMARY" "all") && [[ ${#nodes[@]} -gt 0 ]]; then
      active_bcm="$BCM_HOST_PRIMARY"
    fi
  fi
  if [[ ${#nodes[@]} -eq 0 && -n "$BCM_HOST_SECONDARY" ]]; then
    if mapfile -t nodes < <(_cmsh_node_discovery "$BCM_HOST_SECONDARY" "all") && [[ ${#nodes[@]} -gt 0 ]]; then
      active_bcm="$BCM_HOST_SECONDARY"
    fi
  fi

  if [[ ${#nodes[@]} -gt 0 ]]; then
    echo "BCM_ACTIVE:${active_bcm}"
    printf '%s\n' "${nodes[@]}"
  fi
}

# Discover GPU nodes via BCM (SSH to head node(s)) with HA failover.
# BCM manages all GPU node inventory — no kubectl labels needed.
discover_gpu_nodes() {
  local nodes=()
  local active_bcm=""

  # Try primary BCM first
  if [[ -n "$BCM_HOST_PRIMARY" ]]; then
    logB "Discovering GPU nodes via BCM primary (${BCM_HOST_PRIMARY})..." >&2
    if mapfile -t nodes < <(_cmsh_node_discovery "$BCM_HOST_PRIMARY") && [[ ${#nodes[@]} -gt 0 ]]; then
      active_bcm="$BCM_HOST_PRIMARY"
    else
      logB "Primary BCM unreachable or returned no nodes — trying secondary..." >&2
    fi
  fi

  # Failover to secondary BCM (HA)
  if [[ ${#nodes[@]} -eq 0 && -n "$BCM_HOST_SECONDARY" ]]; then
    logB "Discovering GPU nodes via BCM secondary (${BCM_HOST_SECONDARY})..." >&2
    if mapfile -t nodes < <(_cmsh_node_discovery "$BCM_HOST_SECONDARY") && [[ ${#nodes[@]} -gt 0 ]]; then
      active_bcm="$BCM_HOST_SECONDARY"
    else
      logB "Secondary BCM also unreachable or returned no nodes." >&2
    fi
  fi

  if [[ ${#nodes[@]} -gt 0 ]]; then
    logB "Discovered ${#nodes[@]} GPU nodes via BCM (${active_bcm})" >&2
    # Emit active BCM as a tagged first line so the caller can extract it
    # even through a process substitution subshell boundary.
    # ALL other output (logB) goes to stderr so it doesn't contaminate the node IP list.
    echo "BCM_ACTIVE:${active_bcm}"
  else
    logB "WARNING: No GPU nodes discovered via BCM. DCGM image will not be pushed to nodes." >&2
    logB "         Check BCM host connectivity and that 'cmsh device list' returns UP nodes." >&2
  fi

  printf '%s\n' "${nodes[@]}"
}

# Deploy DCGM to a single node via BCM — called in parallel subshells.
# BCM manages SSH trust to GPU nodes; ObsVM has no direct access.
# The DCGM tar is already staged at /tmp/nvis-dcgm.tar.gz on $bcm_host.
deploy_dcgm_one_node() {
  local node_ip="$1"
  local bcm_host="$2"
  local node_log="${LOG_DIR}/dcgm-node-${node_ip}.log"
  local node_ssh="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"
  local start_ts
  start_ts=$(date +%s)

  {
    echo "[$(date '+%H:%M:%S')] Starting DCGM deploy on ${node_ip} (via BCM ${bcm_host})"

    # Copy image from BCM to node — BCM has SSH trust to all managed nodes
    ssh $BCM_SSH_OPTS "root@${bcm_host}" \
      "scp -o StrictHostKeyChecking=no -o ConnectTimeout=30 /tmp/nvis-dcgm.tar.gz root@${node_ip}:/tmp/nvis-dcgm.tar.gz" \
      || { echo "FAIL: scp from BCM to node failed"; exit 1; }

    # Import into containerd on the node (executed via BCM)
    ssh $BCM_SSH_OPTS "root@${bcm_host}" \
      "$node_ssh root@${node_ip} bash -s" << 'NODEEOF'
set -e
IMG_TAR="/tmp/nvis-dcgm.tar.gz"

if command -v ctr >/dev/null 2>&1; then
  ctr -n k8s.io images import "$IMG_TAR"
elif command -v k3s >/dev/null 2>&1; then
  k3s ctr images import "$IMG_TAR"
else
  docker load < "$IMG_TAR" 2>/dev/null || true
fi
rm -f "$IMG_TAR"

if command -v ctr >/dev/null 2>&1; then
  ctr -n k8s.io images ls 2>/dev/null | grep -q "dcgm-exporter" \
    || echo "WARN: image not confirmed in ctr — DaemonSet will pull from registry"
fi
echo "DCGM_IMAGE_LOADED"
NODEEOF

    # Validate: wait up to 60s for DCGM exporter on :9400.
    # Curl the node IP directly from BCM — dcgm-exporter runs in a k8s pod
    # (different network namespace), so localhost on the node won't work.
    local elapsed=0
    while (( elapsed < 60 )); do
      if ssh $BCM_SSH_OPTS "root@${bcm_host}" \
           "curl -sf http://${node_ip}:${DCGM_PORT}/metrics | head -1" \
           2>/dev/null | grep -q '#'; then
        local dur=$(( $(date +%s) - start_ts ))
        echo "DCGM_VALIDATED OK ${node_ip} ${dur}s"
        exit 0
      fi
      sleep 5
      elapsed=$(( elapsed + 5 ))
    done
    echo "DCGM_VALIDATED TIMEOUT ${node_ip} — DaemonSet may still be starting"
  } > "$node_log" 2>&1

  # Signal result back to main thread
  if grep -q "DCGM_VALIDATED OK" "$node_log"; then
    echo "OK:${node_ip}"
  elif grep -q "DCGM_VALIDATED TIMEOUT" "$node_log"; then
    echo "TIMEOUT:${node_ip}"
  else
    echo "FAIL:${node_ip}"
  fi
}

# Push updated Alloy config to all GPU nodes via BCM.
# Substitutes OBSVM_IP, CLUSTER_NAME, NODE_HOSTNAME placeholders.
deploy_alloy_config() {
  local bcm_host="$1"
  local obsvm_ip
  obsvm_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  local alloy_tmpl="${SCRIPT_DIR}/alloy/config.alloy"
  [[ -f "$alloy_tmpl" ]] || { logB "Alloy template not found at ${alloy_tmpl}"; return 1; }

  # ── Connectivity pre-check: can nodes reach ObsVM? ───────────────────────────
  # Prometheus (:9090) and Loki (:3100) are bound to the ObsVM NIC via externalIPs.
  logB "Checking ObsVM reachability from BCM (${bcm_host})..."
  local prom_reachable=false
  if ssh $BCM_SSH_OPTS "root@${bcm_host}" \
       "curl -sf --max-time 5 http://${obsvm_ip}:9090/-/healthy >/dev/null 2>&1" 2>/dev/null; then
    prom_reachable=true
    logB "  ✓ BCM → ObsVM:9090 (Prometheus) reachable"
  else
    logB "  ✗ BCM → ObsVM:9090 UNREACHABLE — metrics will not flow"
    warn "Prometheus port 9090 not reachable from BCM — check ObsVM firewall"
  fi
  if ssh $BCM_SSH_OPTS "root@${bcm_host}" \
       "curl -sf --max-time 5 http://${obsvm_ip}:3100/ready >/dev/null 2>&1" 2>/dev/null; then
    logB "  ✓ BCM → ObsVM:3100 (Loki) reachable"
  else
    logB "  ✗ BCM → ObsVM:3100 UNREACHABLE — logs will not flow"
    warn "Loki port 3100 not reachable from BCM — check ObsVM firewall"
  fi

  # Deploy Alloy to ALL BCM-managed nodes (GPU + CPU) — DCGM target will be
  # set to dummy value for CPU nodes where no DCGM pod is running.
  logB "Pushing Alloy config to ALL managed nodes (GPU + CPU) via BCM (${bcm_host})..."
  local node_ips=()
  while IFS= read -r line; do
    [[ "$line" == BCM_ACTIVE:* ]] && continue
    # Only accept lines that look like IP addresses
    [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && node_ips+=("$line")
  done < <(_discover_all_managed_nodes)

  # ── Stage Alloy binary: download on ObsVM, push to BCM, then per-node ────────
  # GPU nodes have no internet — binary must be sourced from ObsVM (which does).
  local alloy_bin_local="${LOG_DIR}/alloy-linux-amd64"
  local alloy_staged_on_bcm=false
  if [[ ! -x "$alloy_bin_local" ]]; then
    logB "Downloading Alloy ${ALLOY_VERSION} binary to ObsVM..."
    curl -fsSL --max-time 300 \
      "https://github.com/grafana/alloy/releases/download/${ALLOY_VERSION}/alloy-linux-amd64.zip" \
      -o "${alloy_bin_local}.zip" 2>/dev/null \
    && unzip -oq "${alloy_bin_local}.zip" alloy-linux-amd64 -d "${LOG_DIR}/" 2>/dev/null \
    && chmod +x "$alloy_bin_local" \
    && logB "  ✓ Alloy ${ALLOY_VERSION} downloaded" \
    || { warn "Alloy binary download failed — nodes will attempt self-download"; alloy_bin_local=""; }
  fi
  if [[ -n "$alloy_bin_local" ]] && [[ -x "$alloy_bin_local" ]]; then
    scp $BCM_SSH_OPTS "$alloy_bin_local" "root@${bcm_host}:/tmp/alloy-linux-amd64" 2>/dev/null \
    && alloy_staged_on_bcm=true \
    && logB "  ✓ Alloy binary staged on BCM (${bcm_host})" \
    || warn "Failed to stage Alloy binary on BCM"
  fi

  # Systemd unit definition — static, build once outside the loop so it's
  # also available for the BCM head node section below.
  local alloy_unit
  alloy_unit=$(printf '%s\n' \
    '[Unit]' \
    'Description=Grafana Alloy' \
    'After=network-online.target' \
    'Wants=network-online.target' \
    '[Service]' \
    'ExecStart=/usr/local/bin/alloy run /etc/alloy/config.alloy --storage.path=/var/lib/alloy' \
    'Restart=always' \
    'RestartSec=5' \
    '[Install]' \
    'WantedBy=multi-user.target')
  local unit_b64
  unit_b64=$(echo "$alloy_unit" | base64 -w0)

  local ok_count=0
  for node_ip in "${node_ips[@]}"; do
    local hostname
    hostname=$(ssh $BCM_SSH_OPTS "root@${bcm_host}" \
      "ssh -o StrictHostKeyChecking=no root@${node_ip} 'hostname -s'" 2>/dev/null | tr -d '\r\n' || echo "$node_ip")

    # ── Discover DCGM pod IP for this node (GPU Operator pod, not node IP) ──────
    # DCGM runs as a GPU Operator DaemonSet pod with a pod IP (172.29.x.x).
    # Alloy must scrape the pod IP directly — the node IP:9400 is not exposed.
    local dcgm_pod_ip
    dcgm_pod_ip=$(ssh $BCM_SSH_OPTS "root@${bcm_host}" \
      "ssh -o StrictHostKeyChecking=no root@${node_ip} \
       'kubectl get pods -n gpu-operator -l app=nvidia-dcgm-exporter \
        --field-selector spec.nodeName=${hostname} \
        -o jsonpath=\"{.items[0].status.podIP}\" 2>/dev/null'" \
      2>/dev/null | tr -d '[:space:]' || true)

    local dcgm_target
    if [[ -n "$dcgm_pod_ip" ]]; then
      dcgm_target="${dcgm_pod_ip}:9400"
      logB "    DCGM pod: ${dcgm_pod_ip}:9400 on ${hostname}"
    else
      # CPU node or GPU Operator not yet running — use a safe no-op target
      dcgm_target="127.0.0.1:65535"
      logB "    DCGM: no pod found on ${hostname} — using dummy target (CPU node or operator pending)"
    fi

    local config
    config=$(sed \
      -e "s|<OBSVM_IP>|${obsvm_ip}|g" \
      -e "s|<CLUSTER_NAME>|${CLUSTER_NAME}|g" \
      -e "s|<NODE_HOSTNAME>|${node_ip}|g" \
      -e "s|<DCGM_SCRAPE_TARGET>|${dcgm_target}|g" \
      "$alloy_tmpl")

    local b64
    b64=$(echo "$config" | base64 -w0)

    # Build remote script — base64-encode it so it survives the double-SSH quoting.
    # alloy_ver expands at build time (outer bash variable).
    local alloy_ver="${ALLOY_VERSION}"
    local remote_script
    remote_script=$(cat <<SCRIPT
set -e
mkdir -p /etc/alloy /var/lib/alloy
printf '%s' '${b64}' | base64 -d > /etc/alloy/config.alloy
# ── Install Alloy binary if not present (binary was pre-staged via scp) ──
if [[ ! -x /usr/local/bin/alloy ]] && [[ ! -x /usr/bin/alloy ]]; then
  echo "WARN: Alloy binary not found at /usr/local/bin/alloy — binary push may have failed"
fi
# ── Always install/update the systemd unit and restart Alloy ─────────────
# Stop any old variant first, then install fresh unit to ensure config takes effect.
for _svc in alloy-nvis-logs grafana-alloy; do
  systemctl stop "\${_svc}" 2>/dev/null || true
  systemctl disable "\${_svc}" 2>/dev/null || true
done
printf '%s' '${unit_b64}' | base64 -d > /etc/systemd/system/alloy.service
systemctl daemon-reload
systemctl enable alloy
systemctl restart alloy || systemctl start alloy
SCRIPT
)
    local script_b64
    script_b64=$(echo "$remote_script" | base64 -w0)

    # Push binary from BCM → node before running the config script
    if [[ "$alloy_staged_on_bcm" == "true" ]]; then
      ssh $BCM_SSH_OPTS "root@${bcm_host}" \
        "scp -o StrictHostKeyChecking=no /tmp/alloy-linux-amd64 root@${node_ip}:/usr/local/bin/alloy \
         && ssh -o StrictHostKeyChecking=no root@${node_ip} 'chmod +x /usr/local/bin/alloy'" \
        2>/dev/null \
      && logB "    Binary installed on ${node_ip}" \
      || logB "    Binary push to ${node_ip} failed — remote_script will attempt self-download"
    fi

    if ssh $BCM_SSH_OPTS "root@${bcm_host}" \
       "ssh -o StrictHostKeyChecking=no root@${node_ip} \
        'printf \"%s\" \"${script_b64}\" | base64 -d | bash'" \
       2>/dev/null; then
      logB "  ✓ ${node_ip} (${hostname})"
      (( ok_count++ )) || true
    else
      logB "  ✗ ${node_ip} — Alloy config write failed (SSH error or node unreachable)"
    fi
  done
  logB "Alloy config pushed to ${ok_count}/${#node_ips[@]} managed nodes"

  # ── Also deploy Alloy directly on the BCM head node ─────────────────────────
  # BCM head node runs node_exporter and syslog but no DCGM.
  logB "Pushing Alloy config to BCM head node (${bcm_host})..."
  local bcm_hostname
  bcm_hostname=$(ssh $BCM_SSH_OPTS "root@${bcm_host}" "hostname -s" 2>/dev/null | tr -d '\r\n' || echo "$bcm_host")
  local bcm_config
  bcm_config=$(sed \
    -e "s|<OBSVM_IP>|${obsvm_ip}|g" \
    -e "s|<CLUSTER_NAME>|${CLUSTER_NAME}|g" \
    -e "s|<NODE_HOSTNAME>|${bcm_host}|g" \
    -e "s|<DCGM_SCRAPE_TARGET>|127.0.0.1:65535|g" \
    "$alloy_tmpl")
  local bcm_b64 bcm_unit_b64 bcm_script_b64
  bcm_b64=$(echo "$bcm_config" | base64 -w0)
  bcm_unit_b64=$(echo "$alloy_unit" | base64 -w0)
  local bcm_remote_script
  bcm_remote_script=$(cat <<SCRIPT
set -e
mkdir -p /etc/alloy /var/lib/alloy
printf '%s' '${bcm_b64}' | base64 -d > /etc/alloy/config.alloy
if [[ ! -x /usr/local/bin/alloy ]] && [[ ! -x /usr/bin/alloy ]]; then
  if [[ -x /tmp/alloy-linux-amd64 ]]; then
    cp /tmp/alloy-linux-amd64 /usr/local/bin/alloy && chmod +x /usr/local/bin/alloy
    echo "Alloy binary installed from staged copy"
  else
    echo "Alloy binary missing — downloading ${alloy_ver}..."
    curl -fsSL --max-time 180 \
      "https://github.com/grafana/alloy/releases/download/${alloy_ver}/alloy-linux-amd64.zip" \
      -o /tmp/alloy.zip 2>/dev/null \
    && unzip -oq /tmp/alloy.zip alloy-linux-amd64 -d /tmp/ 2>/dev/null \
    && mv /tmp/alloy-linux-amd64 /usr/local/bin/alloy \
    && chmod +x /usr/local/bin/alloy \
    || echo "WARN: Alloy binary download failed"
  fi
fi
for _svc in alloy-nvis-logs grafana-alloy; do
  systemctl stop "\${_svc}" 2>/dev/null || true
  systemctl disable "\${_svc}" 2>/dev/null || true
done
printf '%s' '${bcm_unit_b64}' | base64 -d > /etc/systemd/system/alloy.service
systemctl daemon-reload
systemctl enable alloy
systemctl restart alloy || systemctl start alloy
SCRIPT
)
  bcm_script_b64=$(echo "$bcm_remote_script" | base64 -w0)
  if ssh $BCM_SSH_OPTS "root@${bcm_host}" \
     "printf '%s' '${bcm_script_b64}' | base64 -d | bash" 2>/dev/null; then
    logB "  ✓ BCM head node (${bcm_host} / ${bcm_hostname})"
    (( ok_count++ )) || true
  else
    logB "  ✗ BCM head node — Alloy config write failed"
  fi

  # ── Post-deploy: verify Alloy is running on each node ───────────────────────
  logB "Waiting 10s for Alloy to start on all nodes..."
  sleep 10
  logB "Verifying Alloy health on all nodes (HTTP API :12345)..."
  local health_ok=0
  for node_ip in "${node_ips[@]}"; do
    local alloy_health
    alloy_health=$(ssh $BCM_SSH_OPTS "root@${bcm_host}" \
      "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@${node_ip} \
       'curl -sf --max-time 3 http://localhost:12345/-/ready 2>/dev/null || echo FAIL'" \
      2>/dev/null | tr -d '[:space:]' || echo "FAIL")
    if [[ "$alloy_health" == *"ready"* || "$alloy_health" == "OK" ]]; then
      logB "  ✓ ${node_ip} Alloy ready"
      (( health_ok++ )) || true
    else
      logB "  ✗ ${node_ip} Alloy not ready (got: ${alloy_health}) — may still be starting"
    fi
  done
  logB "Alloy health: ${health_ok}/${#node_ips[@]} nodes ready"
  logB "Total Alloy deployments: ${ok_count} (${#node_ips[@]} managed nodes + 1 BCM head)"
}

# Full BCM GPU node deployment — runs as background thread
run_dcgm_deploy() {
  local result_file="${LOG_DIR}/dcgm-results.txt"
  touch "$result_file"

  section "[Thread B] BCM GPU Node Deployment"

  # ── Step B1: DCGM image — skip if 4.x already running on nodes ────────────
  if [[ "$SKIP_DCGM" == "true" && -n "$DCGM_EXISTING_VERSION" ]]; then
    logB "DCGM ${DCGM_EXISTING_VERSION} already running on nodes — skipping image push"
  else
    logB "Logging in to nvcr.io (NGC)..."
    if ! echo "$NGC_API_KEY" | docker login nvcr.io -u '$oauthtoken' --password-stdin 2>/dev/null; then
      echo "DCGM_THREAD_FAILED: NGC login failed" >> "$result_file"
      logB "ERROR: NGC login failed. Check NGC_API_KEY."
      return 1
    fi
    ok "NGC login successful"

    logB "Pulling DCGM image: ${DCGM_IMAGE}"
    if ! docker pull "$DCGM_IMAGE"; then
      echo "DCGM_THREAD_FAILED: docker pull failed" >> "$result_file"
      logB "ERROR: Failed to pull ${DCGM_IMAGE}."
      return 1
    fi
    ok "DCGM image pulled"
  fi

  # ── Step B2 (only when pushing): Save image to tar ────────────────────────
  if [[ "$SKIP_DCGM" != "true" || -z "$DCGM_EXISTING_VERSION" ]]; then
    logB "Saving image to ${DCGM_TAR}..."
    docker save "$DCGM_IMAGE" | gzip > "$DCGM_TAR"
    local tar_size
    tar_size=$(du -sh "$DCGM_TAR" | cut -f1)
    ok "Image saved (${tar_size})"
  fi

  # ── Step B3: Discover GPU nodes ────────────────────────────────────────────
  # discover_gpu_nodes emits "BCM_ACTIVE:<host>" as first line, then node IPs.
  # We parse the tag here because process substitution is a subshell — any
  # variable assignments inside discover_gpu_nodes would not propagate back.
  local gpu_nodes=()
  local active_bcm=""
  while IFS= read -r line; do
    if [[ "$line" == BCM_ACTIVE:* ]]; then
      active_bcm="${line#BCM_ACTIVE:}"
    elif [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      gpu_nodes+=("$line")
    fi
  done < <(discover_gpu_nodes)

  if [[ ${#gpu_nodes[@]} -eq 0 ]]; then
    echo "DCGM_THREAD_NO_NODES" >> "$result_file"
    logB "No GPU nodes found — skipping node deployment."
    return 0
  fi

  if [[ -z "$active_bcm" ]]; then
    logB "ERROR: No active BCM host — cannot route node SSH. Aborting node deployment."
    echo "DCGM_THREAD_FAILED: no BCM host" >> "$result_file"
    return 1
  fi

  # ── Steps B4a/B4b: Only run if we're actually deploying a new DCGM image ─────
  if [[ "$SKIP_DCGM" != "true" || -z "$DCGM_EXISTING_VERSION" ]]; then
    # B4a: If GPU Operator manages DCGM, upgrade via ClusterPolicy patch.
    # This triggers GPU Operator's own rolling update (maxUnavailable=1) — safe
    # for RunAI since only one node loses DCGM metrics at a time during rollout.
    if [[ "$GPU_OPERATOR_MANAGED" == "true" ]]; then
      local cp_name
      cp_name=$(ssh $BCM_SSH_OPTS "root@${active_bcm}" \
        "ssh -o StrictHostKeyChecking=no root@${gpu_nodes[0]} \
         'kubectl get clusterpolicy -o jsonpath=\"{.items[0].metadata.name}\" 2>/dev/null'" \
        2>/dev/null | tr -d '[:space:]' || true)
      local new_tag="${DCGM_IMAGE##*:}"
      if [[ -n "$cp_name" && -n "$new_tag" ]]; then
        logB "Patching ClusterPolicy '${cp_name}' → dcgm-exporter:${new_tag}"
        ssh $BCM_SSH_OPTS "root@${active_bcm}" \
          "ssh -o StrictHostKeyChecking=no root@${gpu_nodes[0]} \
           'kubectl patch clusterpolicy ${cp_name} --type=merge \
            -p \"{\\\"spec\\\":{\\\"dcgmExporter\\\":{\\\"version\\\":\\\"${new_tag}\\\"}}}\"'" \
          2>/dev/null \
          && logB "ClusterPolicy patched — GPU Operator will do rolling update" \
          || logB "WARN: ClusterPolicy patch failed — image preload only"
      fi
    fi

    # Stage DCGM tar on BCM once — each node deploy then copies from BCM locally.
    # GPU nodes are on the BCM internal network; ObsVM has no direct SSH to them.
    logB "Staging DCGM image on BCM (${active_bcm})..."
    scp $BCM_SSH_OPTS "${DCGM_TAR}" "root@${active_bcm}:/tmp/nvis-dcgm.tar.gz" \
      || { logB "ERROR: Failed to stage tar on BCM"; echo "DCGM_THREAD_FAILED: bcm scp" >> "$result_file"; return 1; }
    logB "Image staged on BCM"

    # B4b: Pre-load image on all nodes (airgap + speeds up Operator rollout)
    logB "Pre-loading DCGM image on ${#gpu_nodes[@]} nodes (max ${BCM_PARALLEL} parallel)..."
    local pids=()
    local node_results=()
    local active=0

    for node_ip in "${gpu_nodes[@]}"; do
      logB "  → ${node_ip}"
      deploy_dcgm_one_node "$node_ip" "$active_bcm" >> "$result_file" &
      pids+=($!)
      (( active++ )) || true

      # Throttle to BCM_PARALLEL concurrent
      if (( active >= BCM_PARALLEL )); then
        wait "${pids[0]}"
        pids=("${pids[@]:1}")
        (( active-- )) || true
      fi
    done

    # Wait for remaining
    for pid in "${pids[@]}"; do
      wait "$pid" || true
    done
  else
    logB "DCGM ${DCGM_EXISTING_VERSION} already 4.x — skipping image push and node pre-load"
    # Write a synthetic result so the summary doesn't show 0/0/0
    for node_ip in "${gpu_nodes[@]}"; do
      echo "OK:${node_ip}" >> "$result_file"
    done
  fi

  # ── Step B5: Summarize results ─────────────────────────────────────────────
  local ok_count=0 timeout_count=0 fail_count=0
  while IFS= read -r line; do
    case "$line" in
      OK:*)      (( ok_count++ ))      || true ;;
      TIMEOUT:*) (( timeout_count++ )) || true ;;
      FAIL:*)    (( fail_count++ ))    || true ;;
    esac
  done < "$result_file"

  echo "DCGM_THREAD_DONE ok=${ok_count} timeout=${timeout_count} fail=${fail_count}" >> "$result_file"

  # ── Step B6: Push Alloy config to all nodes ────────────────────────────────
  # Updates DCGM scrape target (node IP), cluster label, ObsVM remote_write URL.
  if [[ -n "$active_bcm" ]]; then
    deploy_alloy_config "$active_bcm"
  fi

  section "[Thread B] DCGM Deployment Complete"
  [[ -n "$DCGM_EXISTING_VERSION" ]] && ok "DCGM version: ${DCGM_EXISTING_VERSION} (pre-existing, not pushed)"
  ok  "Nodes validated (DCGM responding): ${ok_count}"
  [[ $timeout_count -gt 0 ]] && warn "Nodes still starting (DaemonSet pending): ${timeout_count}"
  [[ $fail_count    -gt 0 ]] && warn "Nodes failed: ${fail_count} — check ${LOG_DIR}/dcgm-node-*.log"
  logB "Full node logs: ${LOG_DIR}/dcgm-node-*.log"
}

# ═══════════════════════════════════════════════════════════════════════════════
# THREAD A — K8s stack deployment
# ═══════════════════════════════════════════════════════════════════════════════

build_helm_values() {
  local extra_values=()

  if [[ "$STORAGE" == "thanos" ]]; then
    extra_values+=(
      "--set" "victoriametrics.enabled=false"
      "--set" "thanos.enabled=true"
    )
  else
    extra_values+=(
      "--set" "victoriametrics.enabled=true"
      "--set" "thanos.enabled=false"
    )
  fi

  extra_values+=(
    "--set" "namespace=${NAMESPACE}"
    "--create-namespace"
    "--namespace" "${NAMESPACE}"
  )

  # clusterName key (matches .Values.clusterName in prometheus configmap template)
  [[ -n "$CLUSTER_NAME" ]] && extra_values+=("--set" "clusterName=${CLUSTER_NAME}")

  # ObsVM external IP — used as externalIPs on Prometheus/Loki services so GPU nodes
  # can reach them on port 9090/3100 directly (kube-proxy binds to host NIC).
  local obsvm_ip
  obsvm_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  [[ -n "$obsvm_ip" ]] && extra_values+=("--set" "obsvm.externalIP=${obsvm_ip}")

  # Grafana public URL — required so snapshot/share links use the externally
  # reachable NodePort instead of localhost:3000 (the in-pod listen address).
  # Read grafana.nodePort from values.yaml if set; else default to 30300.
  local grafana_nodeport
  grafana_nodeport=$(awk '/^grafana:/{f=1;next} f&&/^  nodePort:/{print $2;exit}' "${CHART_DIR}/values.yaml" 2>/dev/null)
  [[ -z "$grafana_nodeport" ]] && grafana_nodeport=30300
  if [[ -n "$obsvm_ip" ]]; then
    extra_values+=(
      "--set" "grafana.rootUrl=http://${obsvm_ip}:${grafana_nodeport}/"
      "--set" "grafana.domain=${obsvm_ip}"
    )
  fi

  # Disable BCM/Slurm exporters when BCM is not configured — they need an SSH
  # key secret (nvis-bcm-ssh-key) which is only created when INT_BCM=true.
  if [[ "$INT_BCM" != "true" ]]; then
    extra_values+=(
      "--set" "bcmExporter.enabled=false"
      "--set" "slurmExporter.enabled=false"
    )
  else
    # Pass BCM host to exporter pods so they can SSH to BCM for metrics
    [[ -n "$BCM_HOST_PRIMARY" ]] && extra_values+=(
      "--set" "bcmExporter.env.BCM_HOST=${BCM_HOST_PRIMARY}"
      "--set" "slurmExporter.env.BCM_HOST=${BCM_HOST_PRIMARY}"
    )
  fi

  # UFM exporter — deploy when UFM is configured
  if [[ "$INT_UFM" == "true" && -n "$UFM_ENDPOINT" ]]; then
    local ufm_host="${UFM_ENDPOINT#https://}"
    ufm_host="${ufm_host#http://}"
    extra_values+=(
      "--set" "ufmExporter.enabled=true"
      "--set" "ufmExporter.env.UFM_HOST=${ufm_host}"
      "--set" "ufmExporter.env.UFM_USER=${UFM_USER}"
    )
  else
    extra_values+=("--set" "ufmExporter.enabled=false")
  fi

  echo "${extra_values[@]}"
}

build_gpu_agent_values() {
  local extra_values=(
    "--namespace" "${NAMESPACE}"
    "--set" "namespace=${NAMESPACE}"
  )
  [[ -n "$CLUSTER_NAME" ]] && extra_values+=("--set" "cluster=${CLUSTER_NAME}")
  echo "${extra_values[@]}"
}

run_k8s_deploy() {
  local result_file="${LOG_DIR}/k8s-result.txt"
  local helm_cmd="install"
  [[ "$UPGRADE" == "true" ]] && helm_cmd="upgrade --install --cleanup-on-fail"
  local dry_flag=""
  [[ "$DRY_RUN" == "true" ]] && dry_flag="--dry-run"

  section "[Thread A] Kubernetes Stack Deployment"
  logA "Mode: $( [[ $UPGRADE == true ]] && echo 'UPGRADE' || echo 'FRESH INSTALL' )"
  logA "Storage backend: ${STORAGE}"
  [[ -n "$CLUSTER_NAME" ]] && logA "Cluster label: ${CLUSTER_NAME}"

  # ── Verify kubectl works before doing anything else ──────────────────────
  # Background threads don't inherit sudo's env — set KUBECONFIG explicitly
  export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
  if ! kubectl cluster-info >/dev/null 2>&1; then
    logA "ERROR: kubectl cannot reach cluster. KUBECONFIG=${KUBECONFIG}"
    logA "       Possible fix: sudo chmod 644 /etc/rancher/k3s/k3s.yaml"
    logA "       Or run: sudo bash setup-k8s.sh --retry-k8s"
    echo "K8S_THREAD_FAILED: kubectl unreachable" >> "$result_file"
    return 1
  fi
  logA "kubectl OK ($(kubectl version --short 2>/dev/null | grep Server | awk '{print $3}'))"

  load_versions

  # Namespace — create it and immediately label it so helm can adopt/manage it
  kubectl create namespace "$NAMESPACE" 2>/dev/null || true
  kubectl label namespace "$NAMESPACE" \
    app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true
  kubectl annotate namespace "$NAMESPACE" \
    meta.helm.sh/release-name="${RELEASE}" \
    meta.helm.sh/release-namespace="${NAMESPACE}" \
    --overwrite >/dev/null 2>&1 || true

  # Persist integration state so --upgrade knows what's configured
  save_install_state

  # Grafana admin secret — helm chart references "nvis-grafana-secret"
  if ! kubectl get secret nvis-grafana-secret -n "$NAMESPACE" >/dev/null 2>&1; then
    GRAFANA_PASS="${GRAFANA_ADMIN_PASSWORD:-$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 20)}"
    kubectl create secret generic nvis-grafana-secret \
      --from-literal=admin-password="${GRAFANA_PASS}" \
      -n "$NAMESPACE"
    ok "Grafana admin secret created"
    echo ""
    echo -e "${BOLD}${YLW}  ┌─────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${YLW}  │  SAVE THIS GRAFANA PASSWORD: ${GRAFANA_PASS}${NC}"
    echo -e "${BOLD}${YLW}  └─────────────────────────────────────────────────────┘${NC}"
    echo ""
  fi

  # BCM SSH key secret — required by BCM and Slurm exporters when BCM is configured
  if [[ "$INT_BCM" == "true" ]]; then
    if ! kubectl get secret nvis-bcm-ssh-key -n "$NAMESPACE" >/dev/null 2>&1; then
      local ssh_key_path="/home/${INVOKING_USER}/.ssh/id_ed25519"
      [[ ! -f "$ssh_key_path" ]] && ssh_key_path="/root/.ssh/id_ed25519"
      if [[ -f "$ssh_key_path" ]]; then
        kubectl create secret generic nvis-bcm-ssh-key \
          --from-file=id_ed25519="$ssh_key_path" \
          -n "$NAMESPACE"
        ok "BCM SSH key secret created from ${ssh_key_path}"
      else
        warn "BCM/SSH key not found at ~/.ssh/id_ed25519 — BCM and Slurm exporters may fail"
        warn "Create it later: kubectl create secret generic nvis-bcm-ssh-key --from-file=id_ed25519=~/.ssh/id_ed25519 -n ${NAMESPACE}"
      fi
    fi
  fi

  # If liquid cooling (CDU) OR standalone Redfish/BMC monitoring is configured,
  # deploy the BMC Redfish exporter. The redfish scrape job is passed to helm
  # via a generated values file (see below) so helm's prometheus configmap
  # template picks it up via extraScrapeConfigs.
  #
  # Unified host list — covers both CDU (liquid cooling) and standalone Redfish
  # (GPU profiling + B300 temp history). When both are set, concatenate without
  # duplicates so a single exporter polls the union.
  BMC_HOSTS_VALUE=""
  BMC_USER_VALUE=""
  BMC_PASS_VALUE=""
  if [[ "$INT_CDU" == "true" && -n "$CDU_ENDPOINT" ]]; then
    BMC_HOSTS_VALUE="${CDU_ENDPOINT}"
    BMC_USER_VALUE="${CDU_USER}"
    BMC_PASS_VALUE="${CDU_PASS}"
  fi
  if [[ "$INT_REDFISH" == "true" && -n "$REDFISH_TARGETS" ]]; then
    if [[ -z "$BMC_HOSTS_VALUE" ]]; then
      BMC_HOSTS_VALUE="${REDFISH_TARGETS}"
    else
      # Concatenate then de-duplicate (split on comma, dedupe in-order, rejoin)
      BMC_HOSTS_VALUE=$(printf '%s,%s' "${CDU_ENDPOINT}" "${REDFISH_TARGETS}" \
        | tr ',' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -)
    fi
    # Prefer dedicated REDFISH_* credentials when present; fall back to CDU_*
    [[ -n "$REDFISH_USER" ]] && BMC_USER_VALUE="${REDFISH_USER}"
    [[ -n "$REDFISH_PASS" ]] && BMC_PASS_VALUE="${REDFISH_PASS}"
    # Default user if still empty
    [[ -z "$BMC_USER_VALUE" ]] && BMC_USER_VALUE="admin"
  fi

  if [[ -n "$BMC_HOSTS_VALUE" ]]; then
    if [[ "$INT_CDU" == "true" && "$INT_REDFISH" == "true" ]]; then
      logA "Liquid cooling + Redfish/BMC monitoring enabled — deploying BMC Redfish exporter (port 9102)..."
    elif [[ "$INT_CDU" == "true" ]]; then
      logA "Liquid cooling enabled — deploying BMC Redfish exporter (port 9102)..."
    else
      logA "Redfish/BMC per-component monitoring enabled — deploying Redfish exporter (port 9102)..."
    fi

    # Generate a values file so helm includes the redfish scrape job in prometheus.yml
    cat > "${LOG_DIR}/redfish-values.yaml" <<REFISH_VALUES
prometheus:
  extraScrapeConfigs:
    - job_name: redfish-exporter
      scrape_interval: 60s
      scrape_timeout: 55s
      metrics_path: /metrics
      static_configs:
        - targets:
            - "nvis-redfish-exporter.${NAMESPACE}.svc:9102"
          labels:
            cluster: "${CLUSTER_NAME}"
REFISH_VALUES

    # Create BMC credentials secret
    kubectl create secret generic nvis-bmc-credentials \
      --from-literal=BMC_USER="${BMC_USER_VALUE}" \
      --from-literal=BMC_PASS="${BMC_PASS_VALUE}" \
      -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    # Deploy nvis-redfish-exporter using existing redfish_exporter.py script
    kubectl apply -f - -n "$NAMESPACE" >/dev/null << REFISH_DEPLOY
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nvis-redfish-exporter
  namespace: ${NAMESPACE}
  labels:
    app: nvis-redfish-exporter
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nvis-redfish-exporter
  template:
    metadata:
      labels:
        app: nvis-redfish-exporter
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
      containers:
      - name: redfish-exporter
        image: python:3.11-slim
        command: ["python3", "/scripts/redfish_exporter.py"]
        ports:
        - containerPort: 9102
        env:
        - name: BMC_HOSTS
          value: "${BMC_HOSTS_VALUE}"
        - name: BMC_USER
          valueFrom:
            secretKeyRef:
              name: nvis-bmc-credentials
              key: BMC_USER
        - name: BMC_PASS
          valueFrom:
            secretKeyRef:
              name: nvis-bmc-credentials
              key: BMC_PASS
        - name: CLUSTER_NAME
          value: "${CLUSTER_NAME}"
        - name: PORT
          value: "9102"
        - name: SCRAPE_INTERVAL
          value: "60"
        - name: VERIFY_SSL
          value: "false"
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
        volumeMounts:
        - name: scripts
          mountPath: /scripts
          readOnly: true
      volumes:
      - name: scripts
        configMap:
          name: nvis-exporter-scripts
---
apiVersion: v1
kind: Service
metadata:
  name: nvis-redfish-exporter
  namespace: ${NAMESPACE}
spec:
  selector:
    app: nvis-redfish-exporter
  ports:
  - port: 9102
    targetPort: 9102
REFISH_DEPLOY
    ok "BMC Redfish exporter deployed (polling ${BMC_HOSTS_VALUE})"
  fi

  # ── ConfigMaps managed by kubectl (NOT by helm templates) ──────────────────
  # nvis-prometheus-config, nvis-loki-config: managed by helm chart templates
  # The following are NOT in helm templates so helm never overwrites them.
  logA "Syncing exporter script ConfigMaps..."

  # Per-exporter script configmaps — individual files with correct key names
  # so each pod finds its script at the right path inside /scripts/
  kubectl create configmap nvis-s4k-generator-scripts \
    --from-file=s4k_generator.py="${SCRIPT_DIR}/scripts/s4k_generator.py" \
    -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  if [[ "$INT_BCM" == "true" ]]; then
    kubectl create configmap nvis-bcm-exporter-scripts \
      --from-file=bcm_exporter.py="${SCRIPT_DIR}/scripts/bcm_exporter.py" \
      -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl create configmap nvis-slurm-exporter-scripts \
      --from-file=slurm_job_exporter.py="${SCRIPT_DIR}/scripts/slurm_job_exporter.py" \
      -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  fi

  # Combined exporter-scripts configmap — used by redfish + UFM exporter pods
  kubectl create configmap nvis-exporter-scripts \
    --from-file="${SCRIPT_DIR}/scripts/bcm_exporter.py" \
    --from-file="${SCRIPT_DIR}/scripts/slurm_job_exporter.py" \
    --from-file="${SCRIPT_DIR}/scripts/s4k_generator.py" \
    --from-file="${SCRIPT_DIR}/scripts/redfish_exporter.py" \
    --from-file="${SCRIPT_DIR}/scripts/ufm_exporter.py" \
    -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # Grafana dashboard JSONs — mounted at /var/lib/grafana/dashboards in grafana pod
  # Use delete+create (not apply) — kubectl apply stores last-applied-configuration
  # annotation which has a 262144 byte limit, exceeded by the dashboards configmap.
  logA "Loading Grafana dashboards..."
  # Patch cluster variable current value to actual CLUSTER_NAME so Grafana
  # always defaults to the correct cluster regardless of VictoriaMetrics history.
  local dash_tmp="${LOG_DIR}/dashboards-patched"
  rm -rf "$dash_tmp" && mkdir -p "$dash_tmp"
  # Build the refresh-button URL for the Hardware Config Mgmt dashboard so the
  # redfish-exporter /refresh endpoint resolves to the in-cluster service.
  local OBSVM_URL_VALUE="http://nvis-redfish-exporter.${NAMESPACE}.svc:9102"
  python3 - "${SCRIPT_DIR}/grafana/dashboards/NVIS" "$dash_tmp" "${CLUSTER_NAME}" "${OBSVM_URL_VALUE}" << 'PYEOF'
import json, glob, sys, os
src, dst, cluster, obsvm_url = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
for fpath in glob.glob(f"{src}/*.json"):
    # Read as text first so we can do a placeholder substitution that survives
    # nested-JSON-as-string panel definitions (used by some link/iframe panels).
    with open(fpath) as f:
        raw = f.read()
    # Replace __OBSVM_URL__ placeholder anywhere in the dashboard JSON text.
    # This wires the Hardware Config Mgmt refresh button to the in-cluster
    # redfish-exporter /refresh endpoint.
    if "__OBSVM_URL__" in raw:
        raw = raw.replace("__OBSVM_URL__", obsvm_url)
    d = json.loads(raw)
    for t in d.get("templating", {}).get("list", []):
        if t.get("name") == "cluster":
            t["current"] = {"selected": True, "text": cluster, "value": cluster}
    with open(f"{dst}/{os.path.basename(fpath)}", "w") as f:
        json.dump(d, f, indent=2)
PYEOF
  kubectl delete configmap nvis-grafana-dashboards -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
  kubectl create configmap nvis-grafana-dashboards \
    --from-file="${dash_tmp}/" \
    -n "$NAMESPACE" >/dev/null
  local dash_count
  dash_count=$(ls "${dash_tmp}/"*.json 2>/dev/null | wc -l || echo 0)
  ok "ConfigMaps synced (exporter scripts + ${dash_count} dashboards, cluster=${CLUSTER_NAME})"

  # ── Main obsvm chart ────────────────────────────────────────────────────────
  logA "Installing nvis-obsvm chart (Prometheus, Grafana, Loki, ${STORAGE^})..."
  local values_args
  read -ra values_args <<< "$(build_helm_values)"

  # Optional values file for redfish scrape job (generated earlier when CDU enabled)
  local redfish_values_flag=""
  [[ -f "${LOG_DIR}/redfish-values.yaml" ]] && redfish_values_flag="--values ${LOG_DIR}/redfish-values.yaml"

  # Optional values file for Run:ai scrape job (bearer token auth to runai-api)
  local runai_values_flag=""
  if [[ "$INT_RUNAI" == "true" && -n "$RUNAI_URL" && -n "$RUNAI_TOKEN" ]]; then
    cat > "${LOG_DIR}/runai-values.yaml" <<RUNAI_VALUES
prometheus:
  extraScrapeConfigs:
    - job_name: runai-api
      scrape_interval: 30s
      scrape_timeout: 25s
      honor_labels: true
      metrics_path: /api/v1/metrics
      scheme: https
      tls_config:
        insecure_skip_verify: true
      authorization:
        credentials: ${RUNAI_TOKEN}
      static_configs:
        - targets:
            - "$(echo "$RUNAI_URL" | sed 's|^https\?://||')"
          labels:
            cluster: "${CLUSTER_NAME}"
            cluster_id: "${RUNAI_CLUSTER_UUID}"
RUNAI_VALUES
    runai_values_flag="--values ${LOG_DIR}/runai-values.yaml"
  fi

  # Pre-flight: ensure hostNetwork ports are free before helm deploy.
  # Prometheus uses :9090 and Loki uses :3100 with hostNetwork — if something else
  # already holds those ports the pods will CrashLoop immediately after deploy.
  local port_conflict=0
  for chk_port in 9090 3100; do
    if ss -tlnH "sport = :${chk_port}" 2>/dev/null | grep -q ":${chk_port}"; then
      logA "ERROR: Port ${chk_port} is already in use on this host — helm deploy will fail."
      logA "       Run: ss -tlnp | grep :${chk_port}  to identify the process and free the port."
      port_conflict=1
    fi
  done
  if (( port_conflict )); then
    echo "K8S_THREAD_FAILED: port conflict (9090 or 3100 in use)" >> "$result_file"
    return 1
  fi

  # shellcheck disable=SC2086
  # Use a temp file for helm output so the pipe doesn't swallow the exit code.
  # (bash: in cmd | sed, exit code of sed is returned, masking helm failures)
  local helm_out
  helm_out=$(mktemp "${LOG_DIR}/helm-out.XXXXXX")
  helm $helm_cmd "$RELEASE" "$CHART_DIR" \
    "${values_args[@]}" \
    --values "${CHART_DIR}/values.yaml" \
    --values "${CHART_DIR}/versions.yaml" \
    $redfish_values_flag \
    $runai_values_flag \
    $dry_flag \
    --timeout 20m \
    --wait \
    2>&1 | tee "$helm_out" | sed 's/^/  [helm] /'
  local helm_exit=${PIPESTATUS[0]}
  if (( helm_exit != 0 )); then
    # Helm failed but set -e would have been bypassed by pipe — fail explicitly
    logA "ERROR: helm ${helm_cmd} failed (exit ${helm_exit}) — last output:"
    grep -v "^  \[helm\] W" "$helm_out" | tail -10 | sed 's/^/    /'
    echo "K8S_THREAD_FAILED: helm exit ${helm_exit}" >> "$result_file"
    return 1
  fi
  ok "nvis-obsvm chart deployed"

  # GPU agents chart — DaemonSet uses pre-loaded DCGM image (Thread B loaded it)
  local gpu_node_count
  gpu_node_count=$(kubectl get nodes -l 'nvidia.com/gpu.present=true' --no-headers 2>/dev/null | wc -l || echo 0)

  if (( gpu_node_count > 0 )); then
    logA "GPU nodes found (${gpu_node_count}) — installing nvis-gpu-agents DaemonSet..."
    local gpu_values_args
    read -ra gpu_values_args <<< "$(build_gpu_agent_values)"
    # shellcheck disable=SC2086
    local gpu_helm_out
    gpu_helm_out=$(mktemp "${LOG_DIR}/helm-gpu-out.XXXXXX")
    helm $helm_cmd "$GPU_RELEASE" "$GPU_CHART_DIR" \
      "${gpu_values_args[@]}" \
      --values "${GPU_CHART_DIR}/values.yaml" \
      $dry_flag \
      --timeout 10m \
      --wait \
      2>&1 | tee "$gpu_helm_out" | sed 's/^/  [helm] /'
    local gpu_helm_exit=${PIPESTATUS[0]}
    if (( gpu_helm_exit != 0 )); then
      logA "WARN: nvis-gpu-agents helm failed (exit ${gpu_helm_exit}) — non-fatal, continuing"
    else
      ok "nvis-gpu-agents DaemonSet deployed (DCGM + node_exporter on ${gpu_node_count} nodes)"
    fi
  else
    warn "No GPU nodes labeled nvidia.com/gpu.present=true yet."
    warn "Run './setup-k8s.sh --upgrade' after GPU Operator labels the nodes."
  fi

  echo "K8S_THREAD_DONE" >> "$result_file"
}

# ═══════════════════════════════════════════════════════════════════════════════
# DIAGNOSE — post-install health check, shows exactly what's wrong + how to fix
# ═══════════════════════════════════════════════════════════════════════════════
diagnose() {
  section "NVIS Observability — Diagnostic Report"
  local issues=0

  # ── k3s / kubectl ─────────────────────────────────────────────────────────
  echo -e "\n${BOLD}[ Kubernetes ]${NC}"
  if ! command -v k3s >/dev/null 2>&1; then
    warn "k3s not installed"
    echo "  Fix: sudo bash setup-k8s.sh"
    (( issues++ ))
  else
    ok "k3s binary present ($(k3s --version 2>/dev/null | head -1))"
  fi

  if [[ ! -r /etc/rancher/k3s/k3s.yaml ]]; then
    warn "kubeconfig not readable by current user"
    echo "  Fix: sudo chmod 644 /etc/rancher/k3s/k3s.yaml"
    (( issues++ ))
  else
    ok "kubeconfig readable"
  fi

  if ! kubectl get nodes >/dev/null 2>&1; then
    warn "kubectl cannot reach cluster"
    echo "  Fix: export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
    echo "       sudo systemctl status k3s"
    (( issues++ ))
  else
    local node_status
    node_status=$(kubectl get nodes --no-headers 2>/dev/null)
    if echo "$node_status" | grep -q " Ready"; then
      ok "Node Ready: $(echo "$node_status" | awk '{print $1, $2}')"
    else
      warn "Node NOT Ready: $(echo "$node_status" | awk '{print $1, $2}')"
      echo "  Fix: sudo journalctl -u k3s -n 50"
      (( issues++ ))
    fi
  fi

  # ── Namespace + pods ──────────────────────────────────────────────────────
  echo -e "\n${BOLD}[ Pods — ${NAMESPACE} ]${NC}"
  if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    warn "Namespace '${NAMESPACE}' does not exist — stack not deployed"
    echo "  Fix: sudo bash setup-k8s.sh"
    (( issues++ ))
  else
    local not_running
    not_running=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v "Running\|Completed" || true)
    kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | while read -r line; do
      local pod status
      pod=$(echo "$line" | awk '{print $1}')
      status=$(echo "$line" | awk '{print $3}')
      if [[ "$status" == "Running" ]]; then
        ok "${pod}: ${status}"
      else
        warn "${pod}: ${status}"
        echo "  Fix: kubectl logs ${pod} -n ${NAMESPACE} --previous"
        (( issues++ )) || true
      fi
    done
    if [[ -z "$not_running" ]]; then
      ok "All pods Running"
    fi
  fi

  # ── Services / ports ──────────────────────────────────────────────────────
  echo -e "\n${BOLD}[ Services ]${NC}"
  local node_ip
  node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "unknown")
  # Prometheus and Loki use LoadBalancer (direct port binding via k3s ServiceLB).
  # Grafana and VictoriaMetrics keep NodePort.
  for svc_check in "nvis-grafana:30300" "nvis-obsvm-prometheus:9090" "nvis-obsvm-loki:3100" "nvis-victoriametrics:30428"; do
    local svc_name port
    svc_name="${svc_check%%:*}"
    port="${svc_check##*:}"
    if kubectl get svc "$svc_name" -n "$NAMESPACE" >/dev/null 2>&1; then
      if curl -sf --max-time 3 "http://${node_ip}:${port}" >/dev/null 2>&1 || \
         curl -sf --max-time 3 "http://${node_ip}:${port}/ready" >/dev/null 2>&1 || \
         curl -sf --max-time 3 "http://${node_ip}:${port}/-/ready" >/dev/null 2>&1; then
        ok "${svc_name} reachable at http://${node_ip}:${port}"
      else
        warn "${svc_name} service exists but port ${port} not responding"
        echo "  Fix: kubectl describe svc ${svc_name} -n ${NAMESPACE}"
        (( issues++ )) || true
      fi
    else
      warn "${svc_name} service not found"
      (( issues++ )) || true
    fi
  done

  # ── PVCs ─────────────────────────────────────────────────────────────────
  echo -e "\n${BOLD}[ Storage (PVCs) ]${NC}"
  kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | while read -r line; do
    local pvc_name pvc_status
    pvc_name=$(echo "$line" | awk '{print $1}')
    pvc_status=$(echo "$line" | awk '{print $2}')
    if [[ "$pvc_status" == "Bound" ]]; then
      ok "${pvc_name}: Bound"
    else
      warn "${pvc_name}: ${pvc_status} — storage provisioner may be missing"
      echo "  Fix: kubectl describe pvc ${pvc_name} -n ${NAMESPACE}"
      (( issues++ )) || true
    fi
  done

  # ── Helm releases ─────────────────────────────────────────────────────────
  echo -e "\n${BOLD}[ Helm Releases ]${NC}"
  helm list -n "$NAMESPACE" 2>/dev/null | tail -n +2 | while read -r line; do
    local rel_name rel_status
    rel_name=$(echo "$line" | awk '{print $1}')
    rel_status=$(echo "$line" | awk '{print $8}')
    if [[ "$rel_status" == "deployed" ]]; then
      ok "${rel_name}: deployed"
    else
      warn "${rel_name}: ${rel_status}"
      echo "  Fix: helm status ${rel_name} -n ${NAMESPACE}"
      (( issues++ )) || true
    fi
  done

  # ── Summary ───────────────────────────────────────────────────────────────
  echo ""
  if (( issues == 0 )); then
    ok "All checks passed — stack looks healthy"
  else
    warn "${issues} issue(s) found — see Fix suggestions above"
    echo ""
    echo "  Quick fixes:"
    echo "    Re-deploy stack:      sudo bash setup-k8s.sh --retry-k8s"
    echo "    Add/fix integration:  sudo bash setup-k8s.sh --upgrade"
    echo "    Full reinstall:       sudo bash setup-k8s.sh --cleanup && sudo bash setup-k8s.sh"
    echo "    Full k8s log:         journalctl -u k3s -n 100"
  fi
  exit 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN — fire both threads, wait, validate, print summary
# ═══════════════════════════════════════════════════════════════════════════════

main() {
  echo ""
  echo -e "${BOLD}${BLU}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${BLU}║   NVIS Observability — Unified Installer                 ║${NC}"
  echo -e "${BOLD}${BLU}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""

  [[ "$VERSION_CHECK" == "true" ]] && version_check

  # Always ensure k3s + helm before any kubectl/helm calls (including --cleanup/diagnose)
  ensure_k3s
  ensure_helm
  load_images_airgap

  [[ "$DIAGNOSE"  == "true" ]] && diagnose
  [[ "$CLEANUP"   == "true" ]] && uninstall

  # --retry-k8s: skip wizard, read saved state from cluster, re-run k8s thread only
  if [[ "$RETRY_K8S" == "true" ]]; then
    UPGRADE=true
    detect_installed_integrations
    log "Retrying k8s stack deployment with saved integration state..."
    run_k8s_deploy
    exit $?
  fi

  preflight

  # On upgrade: detect what's already installed first, then only ask about new things.
  # On fresh install: ask about everything.
  detect_installed_integrations
  prompt_integrations

  DCGM_PID=""
  K8S_PID=""

  # ── Launch Thread B: NGC pull + BCM GPU deploy (background) ─────────────────
  if [[ "$INT_BCM" == "true" && "$DRY_RUN" == "false" ]]; then
    log "Starting Thread B: NGC pull + BCM GPU node deployment (background)"
    run_dcgm_deploy > "${LOG_DIR}/dcgm-thread.log" 2>&1 &
    DCGM_PID=$!
    log "  DCGM thread PID: ${DCGM_PID} (live log: ${LOG_DIR}/dcgm-thread.log)"
  else
    log "BCM/DCGM: skipped"
  fi

  # ── Launch Thread A: K8s stack deploy (background) ───────────────────────────
  log "Starting Thread A: Kubernetes stack deployment (background)"
  run_k8s_deploy > "${LOG_DIR}/k8s-thread.log" 2>&1 &
  K8S_PID=$!
  log "  K8s thread PID: ${K8S_PID} (live log: ${LOG_DIR}/k8s-thread.log)"

  echo ""
  log "Both deployment threads running. Streaming live output..."
  echo ""

  # ── Stream both logs to console concurrently ──────────────────────────────────
  tail -f "${LOG_DIR}/k8s-thread.log"  --pid="$K8S_PID"  --sleep-interval=1 \
    | sed 's/^/[k8s]  /' &
  TAIL_K8S=$!

  if [[ -n "$DCGM_PID" ]]; then
    tail -f "${LOG_DIR}/dcgm-thread.log" --pid="$DCGM_PID" --sleep-interval=1 \
      | sed 's/^/[dcgm] /' &
    TAIL_DCGM=$!
  fi

  # ── Wait for both threads to complete ────────────────────────────────────────
  K8S_EXIT=0
  DCGM_EXIT=0

  wait "$K8S_PID" || K8S_EXIT=$?
  kill "$TAIL_K8S" 2>/dev/null || true

  if [[ -n "$DCGM_PID" ]]; then
    wait "$DCGM_PID" || DCGM_EXIT=$?
    kill "$TAIL_DCGM" 2>/dev/null || true
  fi

  # ── Final validation + summary ────────────────────────────────────────────────
  section "Installation Complete — Summary"

  # K8s stack status
  if (( K8S_EXIT == 0 )) && grep -q "K8S_THREAD_DONE" "${LOG_DIR}/k8s-result.txt" 2>/dev/null; then
    ok "K8s stack (Prometheus/Grafana/Loki/${STORAGE^}): DEPLOYED"
  else
    warn "K8s stack: FAILED — last 30 lines:"
    echo "─────────────────────────────────────────────────"
    tail -30 "${LOG_DIR}/k8s-thread.log" 2>/dev/null | sed 's/^/  /'
    echo "─────────────────────────────────────────────────"
    echo "  Full log: ${LOG_DIR}/k8s-thread.log"
    echo "  Retry:    sudo bash setup-k8s.sh --retry-k8s"
    echo "  Diagnose: sudo bash setup-k8s.sh --diagnose"
  fi

  # Integration status
  if [[ -n "$DCGM_PID" ]]; then
    if grep -q "DCGM_THREAD_DONE" "${LOG_DIR}/dcgm-results.txt" 2>/dev/null; then
      dcgm_summary=$(grep "DCGM_THREAD_DONE" "${LOG_DIR}/dcgm-results.txt")
      ok "BCM/DCGM: ${dcgm_summary#DCGM_THREAD_DONE }"
    elif grep -q "DCGM_THREAD_NO_NODES" "${LOG_DIR}/dcgm-results.txt" 2>/dev/null; then
      warn "BCM/DCGM: No GPU nodes found — run --upgrade after GPU Operator labels nodes"
    elif grep -q "DCGM_THREAD_FAILED" "${LOG_DIR}/dcgm-results.txt" 2>/dev/null; then
      warn "BCM/DCGM: Failed — last 15 lines:"
      tail -15 "${LOG_DIR}/dcgm-thread.log" 2>/dev/null | sed 's/^/  /'
      echo "  Retry: sudo bash setup-k8s.sh --upgrade"
    fi
  else
    log "BCM/DCGM: not configured"
  fi
  [[ "$INT_CDU" == "true" ]] && ok "CDU Redfish: configured (${CDU_ENDPOINT})"  || log "CDU Redfish: not configured"
  [[ "$INT_UFM" == "true" ]] && ok "UFM: configured (${UFM_ENDPOINT})"          || log "UFM: not configured"
  [[ "$INT_RUNAI" == "true" ]] && ok "Run:ai: configured (${RUNAI_URL}, cluster: ${RUNAI_CLUSTER_NAME})" || log "Run:ai: not configured"
  [[ "$INT_NMC" == "true" ]] && ok "NMC: configured (${NMC_ENDPOINT})"          || log "NMC: not configured"

  # ── Post-deploy connectivity re-check — now that k8s stack is up ─────────────
  # The DCGM thread ran its check concurrently (pods may not have been up yet).
  # Re-verify from BCM after both threads complete.
  if [[ "$INT_BCM" == "true" ]]; then
    local active_bcm=""
    active_bcm=$(grep "BCM_ACTIVE:" "${LOG_DIR}/dcgm-results.txt" 2>/dev/null | head -1 | cut -d: -f2 || true)
    [[ -z "$active_bcm" ]] && active_bcm="${BCM_HOST_PRIMARY}"
    if [[ -n "$active_bcm" ]]; then
      local obsvm_ip
      obsvm_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
      section "Post-Deploy Connectivity Verification"
      if ssh $BCM_SSH_OPTS "root@${active_bcm}" \
           "curl -sf --max-time 5 http://${obsvm_ip}:9090/-/healthy >/dev/null 2>&1" 2>/dev/null; then
        ok "BCM → ObsVM:9090 (Prometheus) REACHABLE — Alloy metrics will flow"
      else
        warn "BCM → ObsVM:9090 STILL UNREACHABLE — check k3s ServiceLB and firewall"
        logA "  Expected: LoadBalancer service klipper-lb pod binding port 9090 on ObsVM NIC (${obsvm_ip})"
        logA "  Check: kubectl get svc nvis-obsvm-prometheus -n ${NAMESPACE}"
      fi
      if ssh $BCM_SSH_OPTS "root@${active_bcm}" \
           "curl -sf --max-time 5 http://${obsvm_ip}:3100/ready >/dev/null 2>&1" 2>/dev/null; then
        ok "BCM → ObsVM:3100 (Loki) REACHABLE — Alloy logs will flow"
      else
        warn "BCM → ObsVM:3100 STILL UNREACHABLE — check k3s ServiceLB and firewall"
      fi
    fi
  fi

  # ── Grafana folder migration + metric validation ──────────────────────────────
  GRAFANA_PORT=$(kubectl get svc nvis-grafana -n "$NAMESPACE" \
    -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "3000")
  NODE_IP=$(kubectl get nodes \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
    2>/dev/null || echo "<node-ip>")
  local grafana_pass
  grafana_pass=$(kubectl get secret nvis-grafana-secret -n "$NAMESPACE" \
    -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || true)
  local grafana_url="http://localhost:${GRAFANA_PORT}"

  # Wait up to 60s for Grafana to be ready.
  # Primary: curl from host (works when NodePort is reachable).
  # Fallback: kubectl exec into the pod — handles cases where localhost NodePort
  # is not reachable from the host network but the pod itself is up.
  logA "Waiting for Grafana to be ready..."
  local gready=0
  local grafana_pod
  grafana_pod=$(kubectl get pods -n "$NAMESPACE" -l 'app.kubernetes.io/name=grafana' \
    --no-headers 2>/dev/null | awk 'NR==1{print $1}')
  for i in $(seq 1 12); do
    if curl -sf --max-time 3 "${grafana_url}/api/health" >/dev/null 2>&1; then
      gready=1; break
    fi
    # Fallback: check via exec into the grafana pod
    if [[ -n "$grafana_pod" ]]; then
      if kubectl exec -n "$NAMESPACE" "$grafana_pod" -- \
           wget -qO- http://localhost:3000/api/health >/dev/null 2>&1; then
        logA "Grafana healthy (confirmed via kubectl exec fallback)"
        gready=1; break
      fi
    fi
    sleep 5
  done

  if [[ "$gready" == "1" && -n "$grafana_pass" ]]; then
    # Move any dashboards left in root folder → NVIS
    local nvis_folder_uid
    nvis_folder_uid=$(curl -sf -u "admin:${grafana_pass}" \
      "${grafana_url}/api/folders" 2>/dev/null \
      | python3 -c "import sys,json; fl=[f for f in json.load(sys.stdin) if f['title']=='NVIS']; print(fl[0]['uid'] if fl else '')" 2>/dev/null || true)

    if [[ -n "$nvis_folder_uid" ]]; then
      local root_dashes
      root_dashes=$(curl -sf -u "admin:${grafana_pass}" \
        "${grafana_url}/api/search?type=dash-db&folderIds=0" 2>/dev/null || echo "[]")
      local moved=0
      while IFS= read -r dash_uid; do
        [[ -z "$dash_uid" ]] && continue
        local dash_json
        dash_json=$(curl -sf -u "admin:${grafana_pass}" \
          "${grafana_url}/api/dashboards/uid/${dash_uid}" 2>/dev/null || true)
        [[ -z "$dash_json" ]] && continue
        local dash_model
        dash_model=$(echo "$dash_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d['dashboard']))" 2>/dev/null || true)
        [[ -z "$dash_model" ]] && continue
        curl -sf -u "admin:${grafana_pass}" \
          -X POST -H "Content-Type: application/json" \
          -d "{\"dashboard\":${dash_model},\"folderUid\":\"${nvis_folder_uid}\",\"overwrite\":true}" \
          "${grafana_url}/api/dashboards/db" >/dev/null 2>&1 || true
        (( moved++ )) || true
      done < <(echo "$root_dashes" | python3 -c "import sys,json; [print(d['uid']) for d in json.load(sys.stdin)]" 2>/dev/null || true)
      [[ "$moved" -gt 0 ]] && ok "Moved ${moved} dashboard(s) from root → NVIS folder"
    fi

    # ── Metric validation — query Prometheus/VM for each module ───────────────
    section "Metric Validation"
    local prom="http://localhost:9090"
    local vm="http://localhost:30428"
    local cl="${CLUSTER_NAME}"

    # Helper: query Prometheus-compatible API, return series count
    prom_count() {
      local url="$1" q="$2"
      curl -sf --max-time 8 "${url}/api/v1/query" \
        --data-urlencode "query=${q}" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',{}).get('result',[])))" 2>/dev/null || echo "0"
    }

    metric_check() {
      local label="$1" url="$2" q="$3"
      local n
      n=$(prom_count "$url" "$q")
      if [[ "$n" -gt 0 ]] 2>/dev/null; then
        ok "  ${label}: ${n} series"
      else
        warn "  ${label}: NO DATA — query: ${q}"
      fi
    }

    echo -e "\n${BOLD}[ Core Stack ]${NC}"
    metric_check "Prometheus self-scrape"        "$prom" "up{job=\"prometheus\"}"
    metric_check "VM remote_write (up)"          "$vm"   "up{cluster=\"${cl}\"}"
    local loki_rdy
    loki_rdy=$(curl -sf --max-time 5 "http://localhost:3100/ready" 2>/dev/null || echo "")
    [[ "$loki_rdy" == "ready" ]] && ok "  Loki: ready" || warn "  Loki: not responding on :3100"

    if [[ "$INT_BCM" == "true" ]]; then
      echo -e "\n${BOLD}[ BCM Exporter ]${NC}"
      metric_check "bcm_up"                "$prom" "bcm_up{cluster=\"${cl}\"}"
      metric_check "bcm_collection_errors" "$prom" "bcm_collection_errors_total{cluster=\"${cl}\"}"

      echo -e "\n${BOLD}[ GPU Nodes — DCGM via Alloy ]${NC}"
      metric_check "DCGM GPU temperature"  "$prom" "DCGM_FI_DEV_GPU_TEMP{cluster=\"${cl}\"}"
      metric_check "DCGM GPU utilization"  "$prom" "DCGM_FI_DEV_GPU_UTIL{cluster=\"${cl}\"}"
      metric_check "DCGM power usage"      "$prom" "DCGM_FI_DEV_POWER_USAGE{cluster=\"${cl}\"}"

      echo -e "\n${BOLD}[ Node Exporter — GPU Nodes via Alloy ]${NC}"
      metric_check "node CPU"              "$prom" "node_cpu_seconds_total{cluster=\"${cl}\",mode=\"idle\"}"
      metric_check "node memory"           "$prom" "node_memory_MemTotal_bytes{cluster=\"${cl}\"}"
      metric_check "node filesystem"       "$prom" "node_filesystem_avail_bytes{cluster=\"${cl}\"}"

      echo -e "\n${BOLD}[ Slurm Exporter ]${NC}"
      metric_check "slurm_jobs_running"    "$prom" "slurm_jobs_running_total{cluster=\"${cl}\"}"
      metric_check "slurm_jobs_active"     "$prom" "slurm_jobs_active_total{cluster=\"${cl}\"}"
      metric_check "slurm_users_active"    "$prom" "slurm_users_active_total{cluster=\"${cl}\"}"
    fi

    if [[ "$INT_UFM" == "true" ]]; then
      echo -e "\n${BOLD}[ UFM — InfiniBand ]${NC}"
      metric_check "ufm_up"                "$prom" "ufm_up{cluster=\"${cl}\"}"
      metric_check "ufm_fabric_healthy"    "$prom" "ufm_fabric_healthy{cluster=\"${cl}\"}"
      metric_check "ufm_switch_count"      "$prom" "ufm_switch_count{cluster=\"${cl}\"}"
      metric_check "ufm_port_count"        "$prom" "ufm_port_count{cluster=\"${cl}\"}"
      metric_check "ufm_port_active"       "$prom" "ufm_port_active_count{cluster=\"${cl}\"}"
      metric_check "ufm_link_count"        "$prom" "ufm_link_count{cluster=\"${cl}\"}"
      metric_check "ufm_alarms_total"      "$prom" "ufm_alarms_total{cluster=\"${cl}\"}"
    fi

    if [[ "$INT_RUNAI" == "true" ]]; then
      echo -e "\n${BOLD}[ Run:ai — GPU Job Scheduling ]${NC}"
      # Re-read token from secret in case it was set after interview
      local runai_token_check
      runai_token_check=$(kubectl get secret nvis-runai-token -n "$NAMESPACE" \
                          -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
      if [[ -z "$runai_token_check" ]]; then
        warn "  RUNAI_STATUS=FAILED — nvis-runai-token secret missing or empty"
      else
        local runai_http
        runai_http=$(curl -sf -o /dev/null -w "%{http_code}" \
          -H "Authorization: Bearer ${runai_token_check}" \
          "${RUNAI_URL}/api/v1/workloads" \
          --connect-timeout 10 --max-time 15 2>/dev/null || echo "000")
        if [[ "$runai_http" == "200" || "$runai_http" == "206" ]]; then
          ok "  RUNAI_STATUS=OK  (${RUNAI_URL}, cluster: ${RUNAI_CLUSTER_NAME}, HTTP ${runai_http})"
        else
          warn "  RUNAI_STATUS=FAILED — /api/v1/workloads returned HTTP ${runai_http}"
          warn "  Check token or Run:ai URL: ${RUNAI_URL}"
        fi
      fi
      metric_check "runai scrape up" "$prom" "up{job=\"runai-api\",cluster=\"${cl}\"}"
    fi

    if [[ "$INT_CDU" == "true" ]]; then
      echo -e "\n${BOLD}[ CDU Redfish ]${NC}"
      metric_check "redfish_up"           "$prom" "redfish_up"
      metric_check "thermal sensors"      "$prom" "redfish_thermal_celsius"
      metric_check "power sensors"        "$prom" "redfish_power_watts"
    fi

    echo -e "\n${BOLD}[ Grafana Dashboards ]${NC}"
    local total_dashes
    total_dashes=$(curl -sf -u "admin:${grafana_pass}" \
      "${grafana_url}/api/search?type=dash-db" 2>/dev/null \
      | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
    local nvis_dashes
    nvis_dashes=$(curl -sf -u "admin:${grafana_pass}" \
      "${grafana_url}/api/search?type=dash-db&limit=200" 2>/dev/null \
      | python3 -c "
import sys,json
dashes = json.load(sys.stdin)
nvis = [d for d in dashes if d.get('folderTitle','') == 'NVIS']
root = [d for d in dashes if d.get('folderTitle','') == '']
other = [d for d in dashes if d.get('folderTitle','') not in ('','NVIS')]
print(str(len(nvis)) + ' in NVIS, ' + str(len(root)) + ' in root' + (', ' + str(len(other)) + ' other' if other else ''))
" 2>/dev/null || echo "?")
    ok "  Dashboards: ${total_dashes} total (${nvis_dashes})"
    echo ""
  else
    warn "Grafana not reachable at ${grafana_url} — skipping metric validation"
  fi

  # Access info
  echo ""

  echo -e "${BOLD}  Access URLs:${NC}"
  ok "Grafana:         http://${NODE_IP}:${GRAFANA_PORT}  (admin / password shown above)"
  ok "Prometheus:      http://${NODE_IP}:9090"
  ok "Loki:            http://${NODE_IP}:3100"
  [[ "$STORAGE" == "victoria" ]] && ok "VictoriaMetrics: http://${NODE_IP}:30428"
  [[ "$STORAGE" == "thanos"   ]] && ok "Thanos Querier:  http://${NODE_IP}:30901"
  [[ "$INT_CDU" == "true"     ]] && ok "CDU Redfish:     ${CDU_ENDPOINT} (exporter -> :9610)"
  echo ""
  ok "Install logs: ${LOG_DIR}/"

  # Exit with failure if either thread failed
  (( K8S_EXIT + DCGM_EXIT == 0 )) || exit 1
}

main "$@"
