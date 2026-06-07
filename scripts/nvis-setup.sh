#!/bin/bash
# =============================================================================
# nvis-setup.sh — NVIS Observability Unified Installer
# =============================================================================
# Deploys the full NVIS observability stack:
#   ObsVM   : Docker Compose (Prometheus, Grafana, Loki, VictoriaMetrics,
#             bcm-exporter, slurm-job-exporter, local registry)
#   BCM     : Docker containers (cAdvisor, node-exporter, Grafana Alloy)
#   GPU nodes: Kubernetes DaemonSets via Helm (DCGM, node-exporter, Alloy)
#
# Usage:
#   sudo bash scripts/nvis-setup.sh
#   sudo bash scripts/nvis-setup.sh --reconfigure
#   sudo bash scripts/nvis-setup.sh --skip-phase 0,1
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NVIS_DIR="$(dirname "${SCRIPT_DIR}")"
CONF_FILE="${NVIS_DIR}/nvis-deploy.conf"
LOG_FILE="${NVIS_DIR}/nvis-setup-debug-$(date +%Y%m%d-%H%M%S).log"
REPORT_FILE="${NVIS_DIR}/nvis-setup-report-$(date +%Y%m%d-%H%M%S).txt"

# Keep only the 2 most recent logs — delete older ones immediately
find "${NVIS_DIR}" -maxdepth 1 -name "nvis-setup-debug-*.log" -o -name "nvis-setup-report-*.txt" 2>/dev/null \
  | sort -r | tail -n +3 | xargs -r rm -f
SKIP_PHASES="${SKIP_PHASES:-}"
RECONFIGURE=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
exec > >(tee -a "${LOG_FILE}") 2>&1

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR ]${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}"; }
banner()  {
  echo -e "\n${BOLD}${BLUE}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${BLUE}║${NC}  $* ${BOLD}${BLUE}║${NC}"
  echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════╝${NC}"
}

# ---------------------------------------------------------------------------
# CLI args
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reconfigure) RECONFIGURE=true; shift ;;
    --skip-phase)  SKIP_PHASES="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--reconfigure] [--skip-phase 0,1,2]"
      exit 0 ;;
    *) warn "Unknown arg: $1"; shift ;;
  esac
done

phase_enabled() {
  local p="$1"
  [[ -z "${SKIP_PHASES}" ]] && return 0
  IFS=',' read -ra skips <<< "${SKIP_PHASES}"
  for s in "${skips[@]}"; do
    [[ "${s// /}" == "${p}" ]] && return 1
  done
  return 0
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
ask_secret() {
  local prompt="$1" varname="$2"
  local val=""
  while [[ -z "${val}" ]]; do
    printf "%s: " "${prompt}"
    read -r -s val
    echo
    [[ -z "${val}" ]] && warn "Value cannot be empty, please try again."
  done
  printf -v "${varname}" '%s' "${val}"
}

ask() {
  local prompt="$1" default="$2" varname="$3"
  printf "%s [%s]: " "${prompt}" "${default}"
  read -r val
  printf -v "${varname}" '%s' "${val:-${default}}"
}

ask_nodefault() {
  local prompt="$1" varname="$2"
  local val=""
  while [[ -z "${val}" ]]; do
    printf "%s: " "${prompt}"
    read -r val
    [[ -z "${val}" ]] && warn "Value required."
  done
  printf -v "${varname}" '%s' "${val}"
}

wait_for_url() {
  local url="$1" timeout="${2:-30}" label="${3:-service}"
  local elapsed=0
  info "Waiting for ${label} at ${url} (up to ${timeout}s)..."
  while [[ ${elapsed} -lt ${timeout} ]]; do
    if curl -sf "${url}" &>/dev/null; then
      success "${label} is up"
      return 0
    fi
    sleep 2; elapsed=$((elapsed + 2))
  done
  warn "${label} did not respond within ${timeout}s (continuing anyway)"
  return 1
}

# ---------------------------------------------------------------------------
# SSH helpers — defined after config is loaded
# ---------------------------------------------------------------------------
bcm_ssh() {
  local jump_opt=()
  [[ -n "${BCM_JUMP:-}" ]] && jump_opt=(-J "${BCM_JUMP}")
  # Explicitly set PATH — BCM non-login SSH sessions often lack /usr/local/bin
  # which is where docker, helm, etc. are typically installed.
  ssh "${jump_opt[@]}" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -o BatchMode=yes \
    -i "${BCM_SSH_KEY:-/home/hlakshminara/.ssh/id_ed25519}" \
    "${BCM_USER}@${BCM_HOST}" \
    "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH; $*"
}

bcm_scp() {
  local jump_opt=()
  [[ -n "${BCM_JUMP:-}" ]] && jump_opt=(-J "${BCM_JUMP}")
  scp "${jump_opt[@]}" \
    -o StrictHostKeyChecking=no \
    -i "${BCM_SSH_KEY:-/home/hlakshminara/.ssh/id_ed25519}" \
    "$@"
}

# Run a command on a GPU node via BCM (BCM→node passwordless SSH)
gpu_run() {
  local node="$1"; shift
  local jump_opt=()
  [[ -n "${BCM_JUMP:-}" ]] && jump_opt=(-J "${BCM_JUMP}")
  ssh "${jump_opt[@]}" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -o BatchMode=yes \
    -i "${BCM_SSH_KEY:-/home/hlakshminara/.ssh/id_ed25519}" \
    "${BCM_USER}@${BCM_HOST}" \
    "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 ${GPU_SSH_USER}@${node} $*"
}

# K8s control plane runs on BCM — run kubectl/helm directly on BCM
k8s_cmd() { bcm_ssh "$@"; }

# Run kubectl on Run.ai K8s master (may be BCM or a separate cluster)
runai_ssh() {
  if [[ "${RUNAI_ON_BCM:-true}" == "true" ]]; then
    bcm_ssh "$@"
  else
    local jopt=()
    [[ -n "${RUNAI_K8S_JUMP:-}" ]] && jopt=(-J "${RUNAI_K8S_JUMP}")
    ssh "${jopt[@]}" \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=15 \
      -o BatchMode=yes \
      -i "${BCM_SSH_KEY:-/home/hlakshminara/.ssh/id_ed25519}" \
      "root@${RUNAI_K8S_HOST}" \
      "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH; $*"
  fi
}
runai_k8s_cmd() { runai_ssh "$@"; }

# ---------------------------------------------------------------------------
# Alloy binary staging helpers (extract from local Docker image — no internet)
# ---------------------------------------------------------------------------
_extract_alloy_bin() {
  # Extracts /usr/bin/alloy from grafana/alloy:${ALLOY_VERSION} into $1
  local dest="$1"
  local cid
  cid="$(docker create "grafana/alloy:${ALLOY_VERSION}" 2>/dev/null)" || return 1
  docker cp "${cid}:/usr/bin/alloy" "${dest}" 2>/dev/null
  docker rm "${cid}" 2>/dev/null || true
  [[ -s "${dest}" ]]
}

stage_alloy_binary_to_bcm() {
  local existing_ver
  existing_ver="$(bcm_ssh "alloy --version 2>/dev/null | head -1" 2>/dev/null || true)"
  echo "${existing_ver}" | grep -q "${ALLOY_VERSION}" \
    && { success "Alloy ${ALLOY_VERSION} already on BCM"; return 0; }
  info "Extracting Alloy ${ALLOY_VERSION} from local Docker image..."
  local tmp="/tmp/nvis-alloy-bin-$$"
  _extract_alloy_bin "${tmp}" || { warn "Could not extract alloy binary from Docker image"; rm -f "${tmp}"; return 1; }
  info "Copying Alloy binary to BCM ($(du -h "${tmp}" | cut -f1))..."
  if bcm_scp "${tmp}" "${BCM_USER}@${BCM_HOST}:/usr/local/bin/alloy" 2>/dev/null; then
    bcm_ssh "chmod 755 /usr/local/bin/alloy"
    rm -f "${tmp}"
    success "Alloy ${ALLOY_VERSION} installed on BCM"
  else
    rm -f "${tmp}"
    # scp may fail if alloy is already running and file is locked — verify version
    _bcm_ver="$(bcm_ssh "alloy --version 2>/dev/null | head -1" 2>/dev/null || true)"
    if echo "${_bcm_ver}" | grep -q "${ALLOY_VERSION}"; then
      success "Alloy ${ALLOY_VERSION} already present on BCM (scp skipped — binary locked)"
    else
      warn "Failed to copy Alloy binary to BCM — alloy may be running; stopping and retrying"
      bcm_ssh "systemctl stop alloy 2>/dev/null || true; sleep 1"
      local tmp2="/tmp/nvis-alloy-bin-$$-retry"
      _extract_alloy_bin "${tmp2}" && bcm_scp "${tmp2}" "${BCM_USER}@${BCM_HOST}:/usr/local/bin/alloy" \
        && bcm_ssh "chmod 755 /usr/local/bin/alloy" \
        && success "Alloy ${ALLOY_VERSION} installed on BCM (retry OK)" \
        || warn "Alloy binary install on BCM FAILED — Alloy log forwarding from BCM will not work"
      rm -f "${tmp2}"
    fi
  fi
}

stage_alloy_binary_to_node() {
  local node_ip="$1"
  local existing_ver
  existing_ver="$(bcm_ssh "ssh -o StrictHostKeyChecking=no root@${node_ip} 'alloy --version 2>/dev/null | head -1'" 2>/dev/null || true)"
  echo "${existing_ver}" | grep -q "${ALLOY_VERSION}" \
    && { success "Alloy ${ALLOY_VERSION} already on ${node_ip}"; return 0; }
  info "Staging Alloy ${ALLOY_VERSION} to ${node_ip}..."
  local tmp="/tmp/nvis-alloy-bin-$$"
  _extract_alloy_bin "${tmp}" || { warn "Could not extract alloy binary"; rm -f "${tmp}"; return 1; }
  local bcm_tmp="/tmp/nvis-alloy-bin-${node_ip//./-}"
  bcm_scp "${tmp}" "${BCM_USER}@${BCM_HOST}:${bcm_tmp}"
  bcm_ssh "scp -o StrictHostKeyChecking=no ${bcm_tmp} root@${node_ip}:/usr/local/bin/alloy && \
           ssh -o StrictHostKeyChecking=no root@${node_ip} 'chmod 755 /usr/local/bin/alloy' && \
           rm -f ${bcm_tmp}"
  rm -f "${tmp}"
  success "Alloy ${ALLOY_VERSION} installed on ${node_ip}"
}

# Copy a file: ObsVM → BCM → GPU node
# Usage: push_to_node LOCAL_FILE BCM_TMPPATH NODE NODE_PATH
push_to_node() {
  local local_file="$1" bcm_tmp="$2" node="$3" node_path="$4"
  bcm_scp "${local_file}" "${BCM_USER}@${BCM_HOST}:${bcm_tmp}"
  bcm_ssh "scp -o StrictHostKeyChecking=no ${bcm_tmp} ${GPU_SSH_USER}@${node}:${node_path}"
}

# ---------------------------------------------------------------------------
# Load existing config if present (and not --reconfigure)
# ---------------------------------------------------------------------------
if [[ -f "${CONF_FILE}" ]] && [[ "${RECONFIGURE}" == "false" ]]; then
  info "Loading existing config: ${CONF_FILE}"
  # shellcheck source=/dev/null
  source "${CONF_FILE}"
  info "Config loaded. Use --reconfigure to change settings."
fi

# ===========================================================================
# INTERVIEW
# ===========================================================================
run_interview() {
  banner "NVIS Observability Setup"

  # Hardcoded — always root, no reason to ask
  BCM_USER="root"
  GPU_SSH_USER="root"
  BCM_PASS=""
  NGC_API_KEY=""
  NAMESPACE="nvis-monitoring"

  # ---------------------------------------------------------------------------
  # STEP 1 — This host (ObsVM)
  # ---------------------------------------------------------------------------
  echo -e "\n${BOLD}${CYAN}── Step 1: This host (ObsVM) ───────────────────────────${NC}"

  # Detect SSH key (handle sudo: real user's key, not root's)
  REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
  REAL_HOME="$(getent passwd "${REAL_USER}" 2>/dev/null | cut -d: -f6 || echo "/home/${REAL_USER}")"
  BCM_SSH_KEY=""
  for _k in "${REAL_HOME}/.ssh/id_ed25519" "${REAL_HOME}/.ssh/id_rsa"; do
    [[ -f "${_k}" ]] && { BCM_SSH_KEY="${_k}"; break; }
  done
  [[ -z "${BCM_SSH_KEY}" ]] && error "No SSH private key found in ${REAL_HOME}/.ssh/ — generate one with: ssh-keygen -t ed25519"
  info "SSH key: ${BCM_SSH_KEY}"

  # Detect ObsVM IPs from network interfaces
  DETECTED_IPS=()
  while IFS= read -r ip; do
    [[ -n "${ip}" ]] && DETECTED_IPS+=("${ip}")
  done < <(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.')

  if [[ ${#DETECTED_IPS[@]} -eq 1 ]]; then
    DETECTED_IP="${DETECTED_IPS[0]}"
    printf "  ObsVM IP (cluster nodes will reach this host) [%s]: " "${DETECTED_IP}"
    read -r _ip_ans
    OBSVM_IP="${_ip_ans:-${DETECTED_IP}}"
  elif [[ ${#DETECTED_IPS[@]} -gt 1 ]]; then
    echo "  Detected IPs on this host:"
    for i in "${!DETECTED_IPS[@]}"; do
      echo "    [$((i+1))] ${DETECTED_IPS[$i]}"
    done
    printf "  Which IP should cluster nodes use to reach ObsVM? [1]: "
    read -r _choice
    _choice="${_choice:-1}"
    OBSVM_IP="${DETECTED_IPS[$((_choice-1))]:-${DETECTED_IPS[0]}}"
  else
    ask_nodefault "  ObsVM IP (cluster nodes will reach this host)" OBSVM_IP
  fi
  success "ObsVM IP: ${OBSVM_IP}"

  # Check Docker
  if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    DOCKER_VER="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'installed')"
    success "Docker ${DOCKER_VER} — will run Prometheus, Grafana, Loki, VictoriaMetrics"
    DOCKER_INSTALL_SOURCE="none"
  else
    echo ""
    warn "Docker not found — required for Prometheus, Grafana, Loki, VictoriaMetrics"
    echo "  [1] Install from internet (apt/yum)"
    echo "  [2] Specify internal mirror URL"
    echo "  [3] Abort — I will install Docker manually"
    printf "  Choice [1]: "
    read -r _docker_choice
    case "${_docker_choice:-1}" in
      2)
        ask_nodefault "  Internal Docker mirror URL (e.g. https://mirror.internal/docker)" DOCKER_MIRROR_URL
        DOCKER_INSTALL_SOURCE="mirror:${DOCKER_MIRROR_URL}"
        ;;
      3)
        error "Aborted — install Docker and re-run"
        ;;
      *)
        DOCKER_INSTALL_SOURCE="internet"
        ;;
    esac
  fi

  # ---------------------------------------------------------------------------
  # STEP 2 — BCM connection
  # ---------------------------------------------------------------------------
  echo -e "\n${BOLD}${CYAN}── Step 2: BCM head node ───────────────────────────────${NC}"

  ask_nodefault "  BCM head node IP or hostname" BCM_HOST

  # Auto-detect jump host: try direct first, then parse SSH config
  BCM_JUMP=""
  info "Testing direct SSH to ${BCM_HOST}..."
  if ssh -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=no \
       -i "${BCM_SSH_KEY}" "root@${BCM_HOST}" "echo ok" 2>/dev/null | grep -q "ok"; then
    success "Direct connection to BCM works — no jump host needed"
  else
    warn "Direct SSH failed — checking SSH config for jump host..."
    SSH_CFG="${REAL_HOME}/.ssh/config"
    DETECTED_JUMP=""
    if [[ -f "${SSH_CFG}" ]]; then
      DETECTED_JUMP="$(ssh -F "${SSH_CFG}" -G "root@${BCM_HOST}" 2>/dev/null \
        | grep -i '^proxyjump' | awk '{print $2}' | grep -v '^none$' | head -1 || true)"
    fi

    if [[ -n "${DETECTED_JUMP}" ]]; then
      info "Found jump host in SSH config: ${DETECTED_JUMP} — testing..."
      BCM_JUMP="${DETECTED_JUMP}"
      # Test with jump
      _jopt=(-J "${BCM_JUMP}")
      if ssh "${_jopt[@]}" -F /dev/null \
           -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no \
           -i "${BCM_SSH_KEY}" "root@${BCM_HOST}" "echo ok" 2>/dev/null | grep -q "ok"; then
        success "Connected via ${BCM_JUMP}"
      else
        warn "Jump ${DETECTED_JUMP} also failed"
        BCM_JUMP=""
      fi
    fi

    if [[ -z "${BCM_JUMP}" ]]; then
      printf "  Enter jump host (user@host) or press Enter to abort: "
      read -r BCM_JUMP
      [[ -z "${BCM_JUMP}" ]] && error "Cannot reach BCM — check connectivity and SSH keys"
    fi
  fi

  # Final connectivity test with the resolved settings
  if ! bcm_ssh "echo ok" 2>/dev/null | grep -q "ok"; then
    error "Cannot reach BCM at ${BCM_HOST} via ${BCM_JUMP:-direct} — check SSH key and network"
  fi
  success "BCM connected"

  # K8s master IS BCM
  K8S_MASTER="${BCM_HOST}"

  # Query BCM version
  info "Querying BCM version..."
  BCM_VERSION="$(bcm_ssh "
    if [ -f /etc/cm-release ]; then
      grep -oP 'v\K[\d.]+' /etc/cm-release | head -1
    elif [ -f /cm/local/apps/cm-server/etc/VERSION ]; then
      grep -oP '[\d.]+' /cm/local/apps/cm-server/etc/VERSION | head -1
    elif [ -f /etc/bright-release ]; then
      grep -oP '[\d.]+' /etc/bright-release | head -1
    else
      dpkg -l cm-server 2>/dev/null | grep cm-server | awk '{print \$3}' | grep -oP '[\d.]+' | head -1
    fi
  " 2>/dev/null | head -1 | tr -d '[:space:]' || true)"

  if [[ -n "${BCM_VERSION}" ]]; then
    success "BCM version: ${BCM_VERSION}"
  else
    warn "Could not detect BCM version — defaulting to 11"
    BCM_VERSION="11"
  fi

  # ---------------------------------------------------------------------------
  # STEP 3 — Cluster discovery (no user input needed)
  # ---------------------------------------------------------------------------
  echo -e "\n${BOLD}${CYAN}── Step 3: Cluster discovery ───────────────────────────${NC}"

  # Discover GPU worker nodes
  info "Scanning cluster..."
  _NODE_JSON="$(bcm_ssh "kubectl get nodes -o json 2>/dev/null" 2>/dev/null || echo '{}')"
  GPU_NODES=(); GPU_NODE_NAMES=()
  while IFS='|' read -r name ip; do
    [[ -z "${name}" ]] && continue
    GPU_NODES+=("${ip}"); GPU_NODE_NAMES+=("${name}")
  done < <(echo "${_NODE_JSON}" | python3 -c "
import json, sys
try: data = json.load(sys.stdin)
except: sys.exit(0)
for node in data.get('items', []):
    labels = node.get('metadata', {}).get('labels', {})
    if 'node-role.kubernetes.io/control-plane' in labels or \
       'node-role.kubernetes.io/master' in labels:
        continue
    name = node['metadata']['name']
    ip = next((a['address'] for a in node.get('status',{}).get('addresses',[])
               if a['type']=='InternalIP'), '')
    if ip: print(f'{name}|{ip}')
" 2>/dev/null)
  GPU_NODES_CSV="$(IFS=','; echo "${GPU_NODES[*]}")"

  # Discover services (DCGM + node-exporter)
  _SVC_JSON="$(bcm_ssh "kubectl get svc -A -o json 2>/dev/null" 2>/dev/null || echo '{}')"

  DCGM_SVC_INFO="$(echo "${_SVC_JSON}" | python3 -c "
import json, sys
try: data = json.load(sys.stdin)
except: sys.exit(0)
for item in data.get('items', []):
    if 'dcgm' in item['metadata']['name'].lower():
        ns=item['metadata']['namespace']; name=item['metadata']['name']
        port=item['spec']['ports'][0]['port']
        print(f'{ns}/{name}:{port}'); break
" 2>/dev/null || true)"

  NE_SVC_INFO="$(echo "${_SVC_JSON}" | python3 -c "
import json, sys
try: data = json.load(sys.stdin)
except: sys.exit(0)
for item in data.get('items', []):
    if 'node-exporter' in item['metadata']['name'].lower():
        ns=item['metadata']['namespace']; name=item['metadata']['name']
        port=item['spec']['ports'][0]['port']
        print(f'{ns}/{name}:{port}'); break
" 2>/dev/null || true)"

  [[ -n "${DCGM_SVC_INFO}" ]] && { DCGM_EXISTS=true;  DCGM_DEPLOY=false; DCGM_PORT="$(echo "${DCGM_SVC_INFO}"|cut -d: -f2)"; } \
                               || { DCGM_EXISTS=false; DCGM_DEPLOY=false; DCGM_PORT="9400"; }
  [[ -n "${NE_SVC_INFO}" ]]   && { NODE_EXPORTER_EXISTS=true;  NODE_EXPORTER_DEPLOY=false; NODE_EXPORTER_PORT="$(echo "${NE_SVC_INFO}"|cut -d: -f2)"; } \
                               || { NODE_EXPORTER_EXISTS=false; NODE_EXPORTER_DEPLOY=true;  NODE_EXPORTER_PORT="9100"; }

  # ---------------------------------------------------------------------------
  # Metric coverage validation against live exporters on first GPU node
  # Confirms that Run.ai's/pre-existing exporters cover all dashboard panels
  # ---------------------------------------------------------------------------
  DCGM_METRIC_REPORT=""; NE_METRIC_REPORT=""; DCGM_METRIC_OK=false; NE_METRIC_OK=false
  _CHECK_NODE="${GPU_NODES[0]:-}"
  _CHECK_NODE_NAME="${GPU_NODE_NAMES[0]:-${_CHECK_NODE}}"

  if [[ -n "${_CHECK_NODE}" ]]; then
    info "Validating metric coverage on ${_CHECK_NODE_NAME} (${_CHECK_NODE})..."

    # ---- DCGM metric check ----
    if [[ "${DCGM_EXISTS}" == "true" ]]; then
      # Try localhost first (hostNetwork pods), then fall back to pod IP via kubectl
      _DCGM_RAW="$(bcm_ssh "
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 root@${_CHECK_NODE} \
          'curl -sf --max-time 5 localhost:${DCGM_PORT}/metrics 2>/dev/null | grep -oE \"^DCGM_FI_[A-Z_0-9]+\" | sort -u'
      " 2>/dev/null | tr -d '\r' || true)"
      # If localhost returned nothing, DCGM pod may not use hostNetwork — try pod IP from kubectl
      if [[ -z "${_DCGM_RAW}" ]]; then
        _DCGM_POD_IP="$(bcm_ssh "kubectl get pods -A -l app=nvidia-dcgm-exporter -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || \
          kubectl get pods -A -l app.kubernetes.io/name=dcgm-exporter -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true" \
          2>/dev/null | tr -d "' \r\n" || true)"
        if [[ -n "${_DCGM_POD_IP}" ]]; then
          info "DCGM: localhost unreachable on node, trying pod IP ${_DCGM_POD_IP}..."
          _DCGM_RAW="$(bcm_ssh "curl -sf --max-time 5 http://${_DCGM_POD_IP}:${DCGM_PORT}/metrics 2>/dev/null | grep -oE '^DCGM_FI_[A-Z_0-9]+' | sort -u" \
            2>/dev/null | tr -d '\r' || true)"
        fi
      fi

      # Metrics required by our dashboards, grouped by criticality
      _DCGM_CRITICAL=("DCGM_FI_DEV_GPU_UTIL" "DCGM_FI_DEV_FB_USED" "DCGM_FI_DEV_FB_FREE"
                      "DCGM_FI_DEV_POWER_USAGE" "DCGM_FI_DEV_GPU_TEMP")
      _DCGM_IMPORTANT=("DCGM_FI_DEV_SM_CLOCK" "DCGM_FI_DEV_MEM_CLOCK" "DCGM_FI_DEV_XID_ERRORS"
                       "DCGM_FI_DEV_ECC_DBE_VOL_TOTAL" "DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL"
                       "DCGM_FI_DEV_PCIE_REPLAY_COUNTER" "DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION"
                       "DCGM_FI_DEV_MEMORY_TEMP" "DCGM_FI_DEV_MEM_COPY_UTIL"
                       "DCGM_FI_DEV_CLOCK_THROTTLE_REASONS")
      _DCGM_PROF=("DCGM_FI_PROF_GR_ENGINE_ACTIVE" "DCGM_FI_PROF_DRAM_ACTIVE"
                  "DCGM_FI_PROF_PIPE_TENSOR_ACTIVE")

      _dcgm_missing_critical=(); _dcgm_missing_important=(); _dcgm_missing_prof=()
      for m in "${_DCGM_CRITICAL[@]}";   do echo "${_DCGM_RAW}" | grep -qx "${m}" || _dcgm_missing_critical+=("${m}"); done
      for m in "${_DCGM_IMPORTANT[@]}";  do echo "${_DCGM_RAW}" | grep -qx "${m}" || _dcgm_missing_important+=("${m}"); done
      for m in "${_DCGM_PROF[@]}";       do echo "${_DCGM_RAW}" | grep -qx "${m}" || _dcgm_missing_prof+=("${m}"); done

      _dcgm_total_found="$(echo "${_DCGM_RAW}" | grep -c "^DCGM" 2>/dev/null || echo 0)"

      if [[ ${#_dcgm_missing_critical[@]} -eq 0 ]]; then
        DCGM_METRIC_OK=true
        if [[ ${#_dcgm_missing_important[@]} -eq 0 && ${#_dcgm_missing_prof[@]} -eq 0 ]]; then
          DCGM_METRIC_REPORT="${GREEN}✓ FULL COVERAGE${NC} — all ${_dcgm_total_found} DCGM metrics present"
        elif [[ ${#_dcgm_missing_prof[@]} -gt 0 && ${#_dcgm_missing_important[@]} -eq 0 ]]; then
          DCGM_METRIC_REPORT="${GREEN}✓ GOOD COVERAGE${NC} — ${_dcgm_total_found} metrics; profiling metrics not exposed: ${_dcgm_missing_prof[*]}"
          DCGM_METRIC_REPORT+=$'\n'"                     → Enable DCGM field IDs 1001/1002/1003 for tensor/DRAM profiling panels"
        else
          DCGM_METRIC_REPORT="${YELLOW}✓ PARTIAL COVERAGE${NC} — ${_dcgm_total_found} metrics; some dashboard panels may show 'No data'"
          [[ ${#_dcgm_missing_important[@]} -gt 0 ]] && DCGM_METRIC_REPORT+=$'\n'"                     Missing: ${_dcgm_missing_important[*]}"
          [[ ${#_dcgm_missing_prof[@]} -gt 0 ]]      && DCGM_METRIC_REPORT+=$'\n'"                     Missing prof: ${_dcgm_missing_prof[*]}"
        fi
      elif [[ -z "${_DCGM_RAW}" ]]; then
        DCGM_METRIC_REPORT="${RED}✗ UNREACHABLE${NC} — could not reach DCGM on ${_CHECK_NODE_NAME} (tried localhost:${DCGM_PORT} and pod IP)"
        DCGM_METRIC_REPORT+=$'\n'"                     Check: DCGM pod running? (kubectl get pods -A -l app=nvidia-dcgm-exporter)"
      else
        DCGM_METRIC_REPORT="${RED}✗ MISSING CRITICAL${NC} — ${_dcgm_total_found} metrics but missing: ${_dcgm_missing_critical[*]}"
        DCGM_METRIC_REPORT+=$'\n'"                     Check DCGM field ID configuration on Run.ai DCGM exporter"
      fi
    fi

    # ---- node-exporter metric check ----
    if [[ "${NODE_EXPORTER_EXISTS}" == "true" ]]; then
      _NE_RAW="$(bcm_ssh "
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 root@${_CHECK_NODE} \
          'curl -sf --max-time 5 localhost:${NODE_EXPORTER_PORT}/metrics 2>/dev/null | grep -oE \"^node_[A-Za-z0-9_]+\" | sort -u'
      " 2>/dev/null | tr -d '\r' || true)"

      _NE_CRITICAL=("node_cpu_seconds_total" "node_memory_MemTotal_bytes" "node_memory_MemAvailable_bytes"
                    "node_disk_read_bytes_total" "node_network_receive_bytes_total"
                    "node_network_transmit_bytes_total" "node_uname_info" "node_filesystem_size_bytes")
      _NE_IMPORTANT=("node_memory_Cached_bytes" "node_disk_writes_completed_total"
                     "node_disk_io_time_seconds_total" "node_network_receive_drop_total"
                     "node_netstat_Tcp_CurrEstab" "node_boot_time_seconds"
                     "node_softnet_dropped_total" "node_sockstat_TCP_inuse")

      _ne_missing_critical=(); _ne_missing_important=()
      for m in "${_NE_CRITICAL[@]}";   do echo "${_NE_RAW}" | grep -qx "${m}" || _ne_missing_critical+=("${m}"); done
      for m in "${_NE_IMPORTANT[@]}";  do echo "${_NE_RAW}" | grep -qx "${m}" || _ne_missing_important+=("${m}"); done

      _ne_total_found="$(echo "${_NE_RAW}" | grep -c "^node_" 2>/dev/null || echo 0)"

      if [[ -z "${_NE_RAW}" ]]; then
        NE_METRIC_REPORT="${RED}✗ UNREACHABLE${NC} — could not curl localhost:${NODE_EXPORTER_PORT} on ${_CHECK_NODE_NAME}"
      elif [[ ${#_ne_missing_critical[@]} -eq 0 ]]; then
        NE_METRIC_OK=true
        if [[ ${#_ne_missing_important[@]} -eq 0 ]]; then
          NE_METRIC_REPORT="${GREEN}✓ FULL COVERAGE${NC} — all ${_ne_total_found} node metrics present"
        else
          NE_METRIC_REPORT="${GREEN}✓ GOOD COVERAGE${NC} — ${_ne_total_found} metrics; minor gaps won't affect core panels"
          NE_METRIC_REPORT+=$'\n'"                     Missing (non-critical): ${_ne_missing_important[*]}"
        fi
      else
        NE_METRIC_REPORT="${RED}✗ MISSING CRITICAL${NC} — ${_ne_total_found} metrics but missing: ${_ne_missing_critical[*]}"
      fi
    fi
  else
    DCGM_METRIC_REPORT="${YELLOW}⚠ No GPU nodes discovered — cannot validate live metrics${NC}"
    NE_METRIC_REPORT="${YELLOW}⚠ No GPU nodes discovered${NC}"
  fi

  # Detect Run.ai on BCM K8s (present if Run.ai is co-located; absent for customers with separate cluster)
  _NS_LIST="$(bcm_ssh "kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null" 2>/dev/null | tr -d "'" || true)"
  RUNAI_DETECTED=false; RUNAI_VERSION=""; RUNAI_PROM_NS=""; RUNAI_PROM_SVC=""
  RUNAI_ON_BCM=true; RUNAI_K8S_HOST=""; RUNAI_K8S_JUMP=""
  if echo "${_NS_LIST}" | grep -qw "runai"; then
    RUNAI_DETECTED=true
    RUNAI_ON_BCM=true
    # Version from runai-backend deployment image
    RUNAI_VERSION="$(bcm_ssh "kubectl get deployment -n runai-backend runai-backend-backend \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null" 2>/dev/null \
      | grep -oP '(?<=:)\d+\.\d+\.\d+' | head -1 || true)"
    # Prometheus CR — separate targeted call, clean JSON
    _PROM_JSON="$(bcm_ssh "kubectl get prometheus -A -o json 2>/dev/null" 2>/dev/null || echo '{}')"
    RUNAI_PROM_NS="$(echo "${_PROM_JSON}" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except: sys.exit(0)
items=d.get('items',[])
if items: print(items[0]['metadata']['namespace'])
" 2>/dev/null | tr -d '[:space:]' || true)"
    RUNAI_PROM_SVC="$(echo "${_PROM_JSON}" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except: sys.exit(0)
items=d.get('items',[])
if items: print(items[0]['metadata']['name'])
" 2>/dev/null | tr -d '[:space:]' || true)"
  fi

  # Cluster name from BCM hostname
  BCM_HOSTNAME="$(bcm_ssh "hostname -s" 2>/dev/null | tr -d '[:space:]' || true)"
  SUGGESTED_CLUSTER="${BCM_HOSTNAME:-prod-cluster}"

  # ---------------------------------------------------------------------------
  # STEP 4 — Display findings, ask only what's left
  # ---------------------------------------------------------------------------
  echo ""
  echo -e "${BOLD}${CYAN}── Discovered ──────────────────────────────────────────${NC}"
  echo -e "  BCM            : ${BOLD}${BCM_HOST}${NC}  (v${BCM_VERSION}, jump: ${BCM_JUMP:-none})"
  echo -e "  GPU nodes      : ${BOLD}${#GPU_NODES[@]} found${NC}  ${YELLOW}[AIRGAPPED — all images staged from ${OBSVM_IP}:5000]${NC}"
  for i in "${!GPU_NODES[@]}"; do
    printf "    ${GREEN}✓${NC}  %-35s %s\n" "${GPU_NODE_NAMES[$i]}" "${GPU_NODES[$i]}"
  done
  echo ""

  if [[ "${DCGM_EXISTS}" == "true" ]]; then
    echo -e "  DCGM           : ${GREEN}✓ Found${NC}  ${DCGM_SVC_INFO}  (Run.ai/pre-existing — will NOT redeploy)"
    echo -e "  Metric check   : $(echo -e "${DCGM_METRIC_REPORT}")"
  else
    echo -e "  DCGM           : ${YELLOW}⚠ Not found${NC} — GPU metrics unavailable until deployed"
    echo -e "                   Needs NGC key + nvcr.io/nvidia/k8s/dcgm-exporter image"
  fi
  echo ""

  if [[ "${NODE_EXPORTER_EXISTS}" == "true" ]]; then
    echo -e "  node-exporter  : ${GREEN}✓ Found${NC}  ${NE_SVC_INFO}  (Run.ai/pre-existing — will NOT redeploy)"
    echo -e "  Metric check   : $(echo -e "${NE_METRIC_REPORT}")"
  else
    echo -e "  node-exporter  : ${YELLOW}⚠ Not found${NC} — will deploy via Helm from local registry"
  fi
  echo ""

  if [[ "${RUNAI_DETECTED}" == "true" ]]; then
    echo -e "  Run.ai         : ${GREEN}✓ Detected on BCM K8s${NC}  v${RUNAI_VERSION:-unknown}"
    if [[ -n "${RUNAI_PROM_NS}" ]]; then
      echo -e "                   Prometheus CR: ${BOLD}${RUNAI_PROM_NS}/${RUNAI_PROM_SVC}${NC}"
    else
      echo -e "                   Prometheus CR: not found (will ask below)"
    fi
  else
    echo -e "  Run.ai         : not detected on BCM K8s"
    echo -e "                   ${YELLOW}(customers with Run.ai on a separate cluster will be asked below)${NC}"
  fi
  echo ""

  # Cluster name — suggest from BCM hostname, confirm/override
  printf "  Cluster name [${SUGGESTED_CLUSTER}]: "
  read -r _cname
  CLUSTER_NAME="${_cname:-${SUGGESTED_CLUSTER}}"

  # Run.ai integration
  RUNAI_ENABLED=false

  if [[ "${RUNAI_DETECTED}" == "true" ]]; then
    # Found on BCM K8s — use existing detection
    if [[ -n "${RUNAI_PROM_NS}" && -n "${RUNAI_PROM_SVC}" ]]; then
      RUNAI_ENABLED=true
      success "Run.ai integration enabled  (${RUNAI_PROM_NS}/${RUNAI_PROM_SVC})"
    else
      warn "Run.ai detected on BCM but Prometheus CR not found"
      ask "  Prometheus namespace" "monitoring" RUNAI_PROM_NS
      ask "  Prometheus CR name" "kube-prometheus-stack-prometheus" RUNAI_PROM_SVC
      RUNAI_ENABLED=true
    fi
  else
    # Run.ai not on BCM — ask if customer has it on a separate K8s cluster
    printf "\n  Do you have Run.ai on a separate K8s cluster? [y/N]: "
    read -r _has_runai
    if [[ "${_has_runai,,}" == "y" ]]; then
      ask_nodefault "  Run.ai K8s master IP or hostname" RUNAI_K8S_HOST
      RUNAI_ON_BCM=false

      # Test connectivity — direct first, then via BCM as jump, then manual
      info "Testing SSH to Run.ai K8s master ${RUNAI_K8S_HOST}..."
      RUNAI_K8S_JUMP=""
      if ssh -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=no \
           -i "${BCM_SSH_KEY}" "root@${RUNAI_K8S_HOST}" "echo ok" 2>/dev/null | grep -q "ok"; then
        success "Direct SSH to Run.ai master works"
      else
        info "Direct SSH failed — trying via BCM as jump..."
        if ssh -J "${BCM_USER}@${BCM_HOST}" \
             -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -F /dev/null \
             -i "${BCM_SSH_KEY}" "root@${RUNAI_K8S_HOST}" "echo ok" 2>/dev/null | grep -q "ok"; then
          RUNAI_K8S_JUMP="${BCM_USER}@${BCM_HOST}"
          success "Connected to Run.ai master via BCM jump"
        else
          printf "  Enter jump host for Run.ai master (user@host) or Enter to skip Run.ai: "
          read -r RUNAI_K8S_JUMP
          if [[ -n "${RUNAI_K8S_JUMP}" ]]; then
            if ! ssh -J "${RUNAI_K8S_JUMP}" \
                 -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no \
                 -i "${BCM_SSH_KEY}" "root@${RUNAI_K8S_HOST}" "echo ok" 2>/dev/null | grep -q "ok"; then
              warn "Cannot reach Run.ai master — skipping Run.ai integration"
              RUNAI_K8S_HOST=""
            fi
          else
            warn "No connectivity to Run.ai master — skipping Run.ai integration"
            RUNAI_K8S_HOST=""
          fi
        fi
      fi

      if [[ -n "${RUNAI_K8S_HOST}" ]]; then
        # Auto-detect Prometheus CR on the separate Run.ai K8s master
        info "Detecting Run.ai Prometheus CR on ${RUNAI_K8S_HOST}..."
        _RUNAI_PROM_JSON="$(runai_ssh "kubectl get prometheus -A -o json 2>/dev/null" 2>/dev/null || echo '{}')"
        RUNAI_PROM_NS="$(echo "${_RUNAI_PROM_JSON}" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except: sys.exit(0)
items=d.get('items',[])
if items: print(items[0]['metadata']['namespace'])
" 2>/dev/null | tr -d '[:space:]' || true)"
        RUNAI_PROM_SVC="$(echo "${_RUNAI_PROM_JSON}" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except: sys.exit(0)
items=d.get('items',[])
if items: print(items[0]['metadata']['name'])
" 2>/dev/null | tr -d '[:space:]' || true)"
        RUNAI_VERSION="$(runai_ssh "kubectl get deployment -n runai-backend runai-backend-backend \
          -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null" 2>/dev/null \
          | grep -oP '(?<=:)\d+\.\d+\.\d+' | head -1 || true)"

        if [[ -n "${RUNAI_PROM_NS}" && -n "${RUNAI_PROM_SVC}" ]]; then
          success "Run.ai v${RUNAI_VERSION:-unknown} detected — Prometheus: ${RUNAI_PROM_NS}/${RUNAI_PROM_SVC}"
          RUNAI_ENABLED=true
        else
          warn "Run.ai K8s master reachable but Prometheus CR not auto-detected"
          ask "  Prometheus namespace" "monitoring" RUNAI_PROM_NS
          ask "  Prometheus CR name" "kube-prometheus-stack-prometheus" RUNAI_PROM_SVC
          RUNAI_ENABLED=true
        fi
      fi
    fi
  fi

  # ---------------------------------------------------------------------------
  # Optional integrations — CMDaemon, Redfish, UFM
  # ---------------------------------------------------------------------------
  echo -e "\n${BOLD}${CYAN}── Optional integrations ───────────────────────────────${NC}"

  # CMDaemon Exporter
  echo ""
  echo -e "  ${BOLD}CMDaemon Exporter${NC} (port 9101)"
  echo -e "  ${YELLOW}What it does:${NC} SSHes to the BCM head node every 30s and collects node"
  echo -e "  inventory via cmsh: per-node UP/DOWN status, kernel version, health check"
  echo -e "  results, node category, and scrape timing. Useful for BCM-managed clusters"
  echo -e "  where you want node provisioning state visible in Grafana alongside GPU metrics."
  echo -e "  ${YELLOW}Limitation:${NC} Only works with BrightCluster Manager (BCM/CMDaemon). Does NOT"
  echo -e "  provide BIOS, firmware, fan, or hardware-level data. If your cluster has UFM"
  echo -e "  or Redfish BMCs, those integrations give richer hardware visibility."
  printf "\n  Enable CMDaemon exporter? [y/N]: "
  read -r _has_cmdaemon
  CMDAEMON_ENABLED=false
  [[ "${_has_cmdaemon,,}" == "y" ]] && CMDAEMON_ENABLED=true
  [[ "${CMDAEMON_ENABLED}" == "true" ]] && success "CMDaemon exporter enabled" \
                                        || info "CMDaemon exporter skipped"

  # Redfish BMC Exporter
  echo ""
  echo -e "  ${BOLD}Redfish BMC Exporter${NC} (port 9102)"
  echo -e "  ${YELLOW}What it does:${NC} Queries the Redfish API on each node's BMC (iDRAC, iLO,"
  echo -e "  OpenBMC) to collect: BIOS version, boot order, NIC/GPU/drive firmware versions,"
  echo -e "  fan speeds, CPU/inlet temperatures, and power draw. Essential for the"
  echo -e "  'path-to-stability' workflow — detecting misconfigured boot sequences, wrong"
  echo -e "  firmware on NVLink or BlueField adapters, or nodes deviating from the gold"
  echo -e "  configuration standard."
  echo -e "  ${YELLOW}Requires:${NC} Physical nodes with BMC access (iDRAC/iLO/OpenBMC). Not available"
  echo -e "  for VM-based clusters."
  printf "\n  Do your nodes have Redfish-capable BMCs (iDRAC/iLO/OpenBMC)? [y/N]: "
  read -r _has_redfish
  REDFISH_ENABLED=false
  REDFISH_HOSTS=""
  REDFISH_USER="root"
  REDFISH_PASS=""
  if [[ "${_has_redfish,,}" == "y" ]]; then
    REDFISH_ENABLED=true
    echo -e "  Enter BMC IPs or CIDR (comma-separated, e.g. 10.0.1.1,10.0.1.2 or 10.0.1.0/24):"
    printf "  BMC hosts: "
    read -r REDFISH_HOSTS
    ask "  BMC username" "root" REDFISH_USER
    ask_secret "  BMC password" REDFISH_PASS
    success "Redfish BMC exporter enabled — ${REDFISH_HOSTS}"
  else
    info "Redfish BMC exporter skipped"
  fi

  # UFM + Cluster Minder
  echo ""
  echo -e "  ${BOLD}UFM (Unified Fabric Manager) Integration${NC}"
  echo -e "  ${YELLOW}What it does:${NC} Integrates with NVIDIA UFM Enterprise to expose InfiniBand"
  echo -e "  and Spectrum-X fabric metrics: port utilization, link health, switch temperatures,"
  echo -e "  cable inventory, and alarms. With the Cluster Minder plugin enabled, also provides"
  echo -e "  topology-aware health checks — fan speeds per switch, NVLink switch firmware,"
  echo -e "  and fabric-wide event streams for the UFM Events Grafana Dashboard plugin."
  echo -e "  ${YELLOW}Requires:${NC} UFM Enterprise installed and accessible from ObsVM."
  printf "\n  Do you have NVIDIA UFM Enterprise installed? [y/N]: "
  read -r _has_ufm
  UFM_ENABLED=false
  UFM_HOST=""
  UFM_USER="ufmsystem"
  UFM_PASS=""
  UFM_CLUSTER_MINDER=false
  if [[ "${_has_ufm,,}" == "y" ]]; then
    UFM_ENABLED=true
    ask_nodefault "  UFM host IP or hostname" UFM_HOST
    ask "  UFM username" "ufmsystem" UFM_USER
    ask_secret "  UFM password" UFM_PASS

    # Test UFM connectivity
    info "Testing UFM API at ${UFM_HOST}..."
    _UFM_TEST="$(curl -sf -u "${UFM_USER}:${UFM_PASS}" \
      "https://${UFM_HOST}/ufmRest/app/ufm_version" \
      -k --max-time 8 2>/dev/null || true)"
    if [[ -n "${_UFM_TEST}" ]]; then
      _UFM_VER="$(echo "${_UFM_TEST}" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('ufm_release','unknown'))" \
        2>/dev/null || echo 'unknown')"
      success "UFM connected — version ${_UFM_VER}"
    else
      warn "Could not reach UFM API at ${UFM_HOST} — check credentials and network"
    fi

    # Cluster Minder plugin
    printf "\n  Is the UFM Cluster Minder plugin installed? [y/N]: "
    read -r _has_cm
    [[ "${_has_cm,,}" == "y" ]] && UFM_CLUSTER_MINDER=true
    if [[ "${UFM_CLUSTER_MINDER}" == "true" ]]; then
      _CM_TEST="$(curl -sf -u "${UFM_USER}:${UFM_PASS}" \
        "https://${UFM_HOST}/ufmRest/plugin/cluster_minder/api/v1/status" \
        -k --max-time 8 2>/dev/null || true)"
      if [[ -n "${_CM_TEST}" ]]; then
        success "Cluster Minder plugin responsive"
      else
        warn "Cluster Minder plugin not reachable — will configure but may need manual validation"
      fi
    fi
    success "UFM integration enabled (Cluster Minder: ${UFM_CLUSTER_MINDER})"
  else
    info "UFM integration skipped"
  fi

  # Grafana password — the one thing we must ask
  echo ""
  ask_secret "  Grafana admin password" GRAFANA_PASS

  # ---------------------------------------------------------------------------
  # STEP 5 — Summary + confirm
  # ---------------------------------------------------------------------------
  echo ""
  banner "Ready to deploy"
  echo -e "  ObsVM          : ${BOLD}${OBSVM_IP}${NC}"
  echo -e "  Cluster        : ${BOLD}${CLUSTER_NAME}${NC}  |  Namespace: ${BOLD}${NAMESPACE}${NC}"
  echo -e "  BCM            : ${BOLD}${BCM_HOST}${NC}  v${BCM_VERSION}  jump: ${BOLD}${BCM_JUMP:-none}${NC}"
  echo -e "  GPU nodes      : ${BOLD}${#GPU_NODES[@]}${NC}  (${GPU_NODES[*]:-none})"
  echo -e "  DCGM           : ${BOLD}${DCGM_EXISTS}${NC}  port ${DCGM_PORT}"
  echo -e "  node-exporter  : ${BOLD}${NODE_EXPORTER_EXISTS}${NC}  port ${NODE_EXPORTER_PORT}"
  echo -e "  Run.ai         : ${BOLD}${RUNAI_ENABLED}${NC}"
  [[ "${RUNAI_ENABLED}" == "true" ]] && \
    echo -e "  Run.ai Prom    : ${BOLD}${RUNAI_PROM_NS}/${RUNAI_PROM_SVC}${NC}"
  echo -e "  CMDaemon exp.  : ${BOLD}${CMDAEMON_ENABLED}${NC}"
  echo -e "  Redfish BMC    : ${BOLD}${REDFISH_ENABLED}${NC}$([ "${REDFISH_ENABLED}" == "true" ] && echo "  ${REDFISH_HOSTS}" || true)"
  echo -e "  UFM            : ${BOLD}${UFM_ENABLED}${NC}$([ "${UFM_ENABLED}" == "true" ] && echo "  ${UFM_HOST}  (Cluster Minder: ${UFM_CLUSTER_MINDER})" || true)"
  echo ""
  printf "Proceed? [Y/n]: "
  read -r confirm
  [[ "${confirm,,}" == "n" ]] && { info "Aborted."; exit 0; }

  # Save config
  cat > "${CONF_FILE}" <<EOF
# NVIS Observability Deployment Config
# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# Re-run interview: sudo bash scripts/nvis-setup.sh --reconfigure

OBSVM_IP="${OBSVM_IP}"
CLUSTER_NAME="${CLUSTER_NAME}"
GRAFANA_PASS="${GRAFANA_PASS}"
NAMESPACE="${NAMESPACE}"
BCM_HOST="${BCM_HOST}"
BCM_USER="${BCM_USER}"
BCM_JUMP="${BCM_JUMP:-}"
BCM_SSH_KEY="${BCM_SSH_KEY}"
BCM_VERSION="${BCM_VERSION}"
K8S_MASTER="${K8S_MASTER}"
GPU_SSH_USER="${GPU_SSH_USER}"
GPU_NODES_CSV="${GPU_NODES_CSV}"
DCGM_EXISTS="${DCGM_EXISTS}"
DCGM_DEPLOY="${DCGM_DEPLOY}"
DCGM_PORT="${DCGM_PORT}"
NODE_EXPORTER_EXISTS="${NODE_EXPORTER_EXISTS}"
NODE_EXPORTER_DEPLOY="${NODE_EXPORTER_DEPLOY}"
NODE_EXPORTER_PORT="${NODE_EXPORTER_PORT}"
NGC_API_KEY=""
RUNAI_ENABLED="${RUNAI_ENABLED}"
RUNAI_ON_BCM="${RUNAI_ON_BCM:-true}"
RUNAI_K8S_HOST="${RUNAI_K8S_HOST:-}"
RUNAI_K8S_JUMP="${RUNAI_K8S_JUMP:-}"
RUNAI_PROM_NS="${RUNAI_PROM_NS}"
RUNAI_PROM_SVC="${RUNAI_PROM_SVC}"
DOCKER_INSTALL_SOURCE="${DOCKER_INSTALL_SOURCE:-none}"
CMDAEMON_ENABLED="${CMDAEMON_ENABLED:-false}"
REDFISH_ENABLED="${REDFISH_ENABLED:-false}"
REDFISH_HOSTS="${REDFISH_HOSTS:-}"
REDFISH_USER="${REDFISH_USER:-root}"
REDFISH_PASS="${REDFISH_PASS:-}"
UFM_ENABLED="${UFM_ENABLED:-false}"
UFM_HOST="${UFM_HOST:-}"
UFM_USER="${UFM_USER:-ufmsystem}"
UFM_PASS="${UFM_PASS:-}"
UFM_CLUSTER_MINDER="${UFM_CLUSTER_MINDER:-false}"
EOF
  chmod 600 "${CONF_FILE}"
  success "Config saved to ${CONF_FILE}"
}

# If config doesn't exist yet OR reconfigure requested, run interview
if [[ ! -f "${CONF_FILE}" ]] || [[ "${RECONFIGURE}" == "true" ]]; then
  run_interview
else
  # Config already loaded above — rebuild GPU_NODES array
  IFS=',' read -ra GPU_NODES <<< "${GPU_NODES_CSV:-}"
fi

# Validate required variables are set
: "${OBSVM_IP:?OBSVM_IP not set — run with --reconfigure}"
: "${BCM_HOST:?BCM_HOST not set}"
: "${BCM_USER:=${BCM_USER:-root}}"
: "${GRAFANA_PASS:?GRAFANA_PASS not set}"
: "${CLUSTER_NAME:?CLUSTER_NAME not set}"
: "${NAMESPACE:=${NAMESPACE:-nvis-monitoring}}"
: "${K8S_MASTER:=${K8S_MASTER:-${BCM_HOST}}}"
: "${GPU_SSH_USER:=${GPU_SSH_USER:-root}}"
: "${DCGM_PORT:=${DCGM_PORT:-9400}}"
: "${DCGM_DEPLOY:=${DCGM_DEPLOY:-false}}"
: "${DCGM_EXISTS:=${DCGM_EXISTS:-false}}"
: "${RUNAI_ENABLED:=${RUNAI_ENABLED:-false}}"
: "${RUNAI_ON_BCM:=${RUNAI_ON_BCM:-true}}"
: "${RUNAI_K8S_HOST:=${RUNAI_K8S_HOST:-}}"
: "${RUNAI_K8S_JUMP:=${RUNAI_K8S_JUMP:-}}"

REG="${OBSVM_IP}:5000"

echo ""
banner "NVIS Observability — Deployment Starting"
info "Log: ${LOG_FILE}"

# ===========================================================================
# PHASE 0 — Pre-flight
# ===========================================================================
if phase_enabled 0; then
  step "PHASE 0: Pre-flight checks"

  # Install Docker on ObsVM if needed (decision was made in interview)
  if ! command -v docker &>/dev/null || ! docker info &>/dev/null 2>&1; then
    case "${DOCKER_INSTALL_SOURCE:-internet}" in
      none)
        error "Docker not found — install Docker and re-run" ;;
      mirror:*)
        _mirror="${DOCKER_INSTALL_SOURCE#mirror:}"
        info "Installing Docker from internal mirror: ${_mirror}..."
        if command -v apt-get &>/dev/null; then
          curl -fsSL "${_mirror}/gpg" | apt-key add - 2>/dev/null || true
          echo "deb [arch=amd64] ${_mirror} $(lsb_release -cs) stable" \
            > /etc/apt/sources.list.d/docker.list
          apt-get update -qq && apt-get install -y -qq docker-ce docker-ce-cli containerd.io
        else
          error "Internal mirror install only supported on apt-based systems"
        fi ;;
      internet|*)
        info "Installing Docker from internet..."
        if command -v apt-get &>/dev/null; then
          apt-get update -qq && apt-get install -y -qq docker.io
        elif command -v yum &>/dev/null; then
          yum install -y docker
        else
          error "Cannot install Docker: no apt-get or yum found"
        fi ;;
    esac
    systemctl --no-ask-password enable docker --now
    success "Docker installed"
  else
    success "Docker present: $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  fi

  # BCM connectivity already verified in interview — spot-check GPU nodes
  if [[ ${#GPU_NODES[@]} -gt 0 ]]; then
    info "Spot-checking GPU node reachability via BCM..."
    for node in "${GPU_NODES[@]}"; do
      if gpu_run "${node}" "echo ok" 2>/dev/null | grep -q "ok"; then
        success "GPU node ${node} reachable"
      else
        warn "GPU node ${node} not reachable from BCM — Helm deploy may be partial"
      fi
    done
  fi

  # Check/install Docker on BCM
  info "Checking Docker on BCM..."
  BCM_DOCKER_PATH="$(bcm_ssh "
    command -v docker 2>/dev/null ||
    ls /usr/bin/docker 2>/dev/null ||
    ls /usr/local/bin/docker 2>/dev/null ||
    true
  " 2>/dev/null | tr -d '[:space:]' | head -1 || true)"

  if [[ -n "${BCM_DOCKER_PATH}" ]]; then
    success "Docker found on BCM: ${BCM_DOCKER_PATH}"
    # Ensure daemon is running
    bcm_ssh "systemctl is-active docker &>/dev/null || systemctl --no-ask-password start docker 2>/dev/null || true" 2>/dev/null || true
  else
    info "Docker not found on BCM — attempting installation..."
    bcm_ssh "
      set -e
      if command -v apt-get &>/dev/null; then
        # Fix any broken deps first, then install with non-interactive flags to avoid held-package errors
        apt-get -f install -y -qq 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
          -o Dpkg::Options::='--force-confdef' \
          -o Dpkg::Options::='--force-confold' \
          --no-install-recommends \
          docker.io 2>/dev/null || \
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
          -o Dpkg::Options::='--force-confdef' \
          -o Dpkg::Options::='--force-confold' \
          docker-ce docker-ce-cli 2>/dev/null || \
        { echo 'APT install failed — BCM containers will be skipped'; exit 0; }
      elif command -v yum &>/dev/null; then
        yum install -y -q docker 2>/dev/null || true
      fi
      systemctl --no-ask-password enable docker --now 2>/dev/null || true
      command -v docker && echo 'DOCKER_OK' || echo 'DOCKER_MISSING'
    " 2>/dev/null | grep -q "DOCKER_OK" \
      && success "Docker installed on BCM" \
      || warn "Docker install on BCM failed — Phase 3 (BCM containers) will be skipped"
  fi

  # Ensure /root/.ssh/id_ed25519 MATCHES the working BCM_SSH_KEY.
  # Docker containers (bcm-exporter, slurm-job-exporter) mount /root/.ssh and use
  # /root/.ssh/id_ed25519 — if root has a different key it won't be authorized on BCM.
  # Always sync, not just when missing.
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  if [[ "${BCM_SSH_KEY}" != "/root/.ssh/id_ed25519" ]] && [[ -f "${BCM_SSH_KEY}" ]]; then
    if ! diff -q "${BCM_SSH_KEY}" /root/.ssh/id_ed25519 &>/dev/null; then
      cp "${BCM_SSH_KEY}" /root/.ssh/id_ed25519
      chmod 600 /root/.ssh/id_ed25519
      [[ -f "${BCM_SSH_KEY}.pub" ]] && cp "${BCM_SSH_KEY}.pub" /root/.ssh/id_ed25519.pub || true
      success "SSH key synced to /root/.ssh/id_ed25519 (from ${BCM_SSH_KEY})"
    else
      success "SSH key already matches at /root/.ssh/id_ed25519"
    fi
  elif [[ ! -f /root/.ssh/id_ed25519 ]]; then
    info "Generating new SSH keypair on ObsVM..."
    ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 -C "nvis-obsvm"
    OBSVM_PUBKEY="$(cat /root/.ssh/id_ed25519.pub)"
    bcm_ssh "
      mkdir -p /root/.ssh && chmod 700 /root/.ssh
      touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
      grep -qF '${OBSVM_PUBKEY}' /root/.ssh/authorized_keys 2>/dev/null \
        && echo 'Key already present' \
        || { echo '${OBSVM_PUBKEY}' >> /root/.ssh/authorized_keys; echo 'Key added'; }
    " && success "New SSH key pushed to BCM" || warn "Could not push SSH key to BCM"
  fi
  # Validate containers can SSH to BCM with the root key (catches wrong-key silently before Phase 3)
  if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
       -i /root/.ssh/id_ed25519 "root@${BCM_HOST}" "echo ok" 2>/dev/null | grep -q "ok"; then
    success "Container SSH key validated — /root/.ssh/id_ed25519 connects to BCM"
  else
    warn "Container SSH key /root/.ssh/id_ed25519 cannot reach BCM — bcm-exporter will show agent down"
    warn "Fix: sudo cp ${BCM_SSH_KEY} /root/.ssh/id_ed25519 && sudo chmod 600 /root/.ssh/id_ed25519"
  fi

  success "Phase 0 complete"
fi

# ===========================================================================
# PHASE 1 — Images + Local Registry
# ===========================================================================
if phase_enabled 1; then
  step "PHASE 1: Container images and local registry"

  # Load nvis-images.tar if present and registry:2 not yet loaded
  IMAGES_TAR="${NVIS_DIR}/nvis-images.tar"
  if [[ -f "${IMAGES_TAR}" ]]; then
    if ! docker image inspect registry:2 &>/dev/null; then
      info "Loading images from ${IMAGES_TAR} (may take several minutes)..."
      docker load -i "${IMAGES_TAR}"
      success "Images loaded from tar"
    else
      info "Images already loaded (registry:2 found) — skipping tar load"
    fi
  else
    warn "nvis-images.tar not found — assuming images are available in public registries"
  fi

  # Start local registry
  if ! docker ps --format '{{.Names}}' | grep -q "^nvis-registry$"; then
    info "Starting local registry at ${REG}..."
    docker rm -f nvis-registry 2>/dev/null || true
    docker run -d \
      --name nvis-registry \
      --restart=unless-stopped \
      -p 5000:5000 \
      -v registry-data:/var/lib/registry \
      registry:2
    sleep 2
    success "Local registry started at ${REG}"
  else
    success "Local registry already running at ${REG}"
  fi

  # Configure insecure-registries on ObsVM
  DAEMON_JSON="/etc/docker/daemon.json"
  info "Configuring Docker insecure-registries for ${REG}..."
  if [[ ! -f "${DAEMON_JSON}" ]]; then
    cat > "${DAEMON_JSON}" <<EOF
{
  "insecure-registries": ["${REG}"]
}
EOF
    systemctl --no-ask-password reload docker || systemctl --no-ask-password restart docker
    success "daemon.json created and Docker reloaded"
  else
    if ! grep -q "${REG}" "${DAEMON_JSON}"; then
      # Merge the registry into existing config using python3
      python3 - <<PYEOF
import json, sys
with open('${DAEMON_JSON}') as f:
    cfg = json.load(f)
regs = cfg.get('insecure-registries', [])
if '${REG}' not in regs:
    regs.append('${REG}')
cfg['insecure-registries'] = regs
with open('${DAEMON_JSON}', 'w') as f:
    json.dump(cfg, f, indent=2)
print('Updated')
PYEOF
      systemctl --no-ask-password reload docker || systemctl --no-ask-password restart docker
      success "daemon.json updated with ${REG}"
    else
      info "insecure-registry ${REG} already in daemon.json"
    fi
  fi

  # ---------------------------------------------------------------------------
  # GPU nodes are ALWAYS AIRGAPPED at customer sites.
  # They cannot reach the internet or any external registry.
  # ALL images used on GPU nodes MUST be staged to the local registry
  # at ${REG} before the Helm deploy (Phase 4) runs.
  # GPU containerd is configured to pull ONLY from ${REG}.
  # ---------------------------------------------------------------------------
  echo ""
  echo -e "${BOLD}${YELLOW}  ┌─────────────────────────────────────────────────────┐${NC}"
  echo -e "${BOLD}${YELLOW}  │  GPU nodes are AIRGAPPED                            │${NC}"
  echo -e "${BOLD}${YELLOW}  │  All images staged to local registry: ${REG}  │${NC}"
  echo -e "${BOLD}${YELLOW}  │  GPU nodes pull ONLY from this registry             │${NC}"
  echo -e "${BOLD}${YELLOW}  └─────────────────────────────────────────────────────┘${NC}"
  echo ""

  tag_and_push() {
    local src="$1" dest_tag="$2" required="${3:-false}"
    local dest="${REG}/${dest_tag}"
    if docker image inspect "${src}" &>/dev/null; then
      docker tag "${src}" "${dest}"
      docker push "${dest}"
      success "Staged → ${REG}/${dest_tag}"
    else
      if [[ "${required}" == "true" ]]; then
        warn "REQUIRED image not found locally: ${src}"
        warn "  This image is needed on GPU nodes. Include it in nvis-images.tar."
        warn "  On an internet-connected machine: docker pull ${src} && docker save ..."
      else
        warn "Optional image not found locally: ${src} — skipping"
      fi
    fi
  }

  # Always stage — needed for BCM containers (Phase 3) and potentially GPU node DaemonSets
  info "Staging BCM images → ${REG}..."
  tag_and_push "gcr.io/cadvisor/cadvisor:v0.49.1"          "cadvisor:v0.49.1"           "false"

  # Always stage — Alloy DaemonSet runs on every GPU node
  info "Staging GPU node images → ${REG} (GPU nodes are airgapped, must be pre-staged)..."
  tag_and_push "grafana/alloy:v1.3.0"                      "alloy:v1.3.0"               "true"
  tag_and_push "quay.io/prometheus/node-exporter:v1.8.1"   "node-exporter:v1.8.1"       "true"

  # DCGM — only if we need to deploy it (Run.ai/pre-existing DCGM not found)
  if [[ "${DCGM_DEPLOY}" == "true" ]]; then
    DCGM_SRC="nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04"
    if docker image inspect "${DCGM_SRC}" &>/dev/null; then
      tag_and_push "${DCGM_SRC}" "dcgm-exporter:3.3.5-3.4.0-ubuntu22.04" "true"
    else
      warn "DCGM image not in local Docker — attempting NGC pull..."
      if [[ -n "${NGC_API_KEY:-}" ]]; then
        echo "${NGC_API_KEY}" | docker login nvcr.io --username='$oauthtoken' --password-stdin \
          && docker pull "${DCGM_SRC}" \
          && tag_and_push "${DCGM_SRC}" "dcgm-exporter:3.3.5-3.4.0-ubuntu22.04" "true" \
          || warn "DCGM pull failed — GPU metrics panels will be empty until resolved"
      else
        warn "NGC_API_KEY not set — add DCGM image to nvis-images.tar and re-run Phase 1"
      fi
    fi
  else
    info "DCGM: pre-existing exporter detected — skipping DCGM image staging"
  fi

  # Pre-stage BCM images to BCM filesystem as a gzip tar.
  # This uses only SSH (no Docker on BCM needed) so Phase 3 can load them
  # from the pre-staged tar once Docker is available — no internet required on BCM.
  if [[ -n "${BCM_HOST}" ]]; then
    info "Pre-staging BCM images to BCM filesystem (SSH only, no Docker needed on BCM)..."
    BCM_STAGE_IMAGES=()
    for _img in "gcr.io/cadvisor/cadvisor:v0.49.1" "quay.io/prometheus/node-exporter:v1.8.1" "grafana/alloy:v1.3.0"; do
      docker image inspect "${_img}" &>/dev/null && BCM_STAGE_IMAGES+=("${_img}") || true
    done
    if [[ ${#BCM_STAGE_IMAGES[@]} -gt 0 ]]; then
      docker save "${BCM_STAGE_IMAGES[@]}" 2>/dev/null | gzip | \
        bcm_ssh "cat > /tmp/nvis-bcm-images.tar.gz && echo staged" 2>/dev/null | grep -q "staged" \
        && success "BCM images pre-staged to /tmp/nvis-bcm-images.tar.gz (${#BCM_STAGE_IMAGES[@]} images)" \
        || warn "Could not pre-stage BCM images to BCM filesystem — will transfer directly in Phase 3"
    fi
  fi

  # Verify required images are staged before proceeding
  echo ""
  info "Verifying staged images in local registry ${REG}..."
  _STAGE_OK=true
  for _img_tag in "alloy:v1.3.0" "node-exporter:v1.8.1"; do
    if curl -sf "http://${REG}/v2/${_img_tag%:*}/tags/list" 2>/dev/null | grep -q '"tags"'; then
      success "  ${REG}/${_img_tag} — staged ✓"
    else
      warn "  ${REG}/${_img_tag} — NOT in registry (GPU DaemonSet will fail ErrImagePull)"
      _STAGE_OK=false
    fi
  done
  [[ "${_STAGE_OK}" == "true" ]] && success "All required GPU node images staged" \
    || warn "Some images missing from registry — GPU DaemonSet pods may fail to start"

  success "Phase 1 complete"
fi

# ===========================================================================
# PHASE 2 — ObsVM Docker Compose
# ===========================================================================
if phase_enabled 2; then
  step "PHASE 2: ObsVM Docker Compose stack"

  # Write .env
  info "Writing .env..."
  cat > "${NVIS_DIR}/.env" <<EOF
GRAFANA_ADMIN_PASSWORD=${GRAFANA_PASS}
BCM_HOST=${BCM_HOST}
BCM_USER=${BCM_USER}
CLUSTER_NAME=${CLUSTER_NAME}
EOF
  chmod 600 "${NVIS_DIR}/.env"

  # Write prometheus.yml
  info "Writing prometheus/prometheus.yml..."
  mkdir -p "${NVIS_DIR}/prometheus"
  cat > "${NVIS_DIR}/prometheus/prometheus.yml" <<EOF
global:
  scrape_interval: 15s
  external_labels:
    cluster: "${CLUSTER_NAME}"

# Enable remote write receiver so Alloy agents can push metrics here
# (--web.enable-remote-write-receiver flag on CLI)

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]

  # BCM exporter — SSHes to BCM, collects node/GPU inventory
  - job_name: bcm-exporter
    scrape_interval: 60s
    scrape_timeout: 30s
    honor_labels: true
    static_configs:
      - targets: ["${OBSVM_IP}:9401"]

  # Slurm job exporter — squeue + sacct from BCM head node
  - job_name: slurm-job-exporter
    scrape_interval: 30s
    scrape_timeout: 25s
    honor_labels: true
    static_configs:
      - targets: ["${OBSVM_IP}:9402"]

  # ObsVM self-monitoring — node_exporter (installed by nvis-setup or pre-existing)
  - job_name: obsvm-node
    scrape_interval: 30s
    static_configs:
      - targets: ["${OBSVM_IP}:9100"]
        labels:
          instance: obsvm
          cluster: "${CLUSTER_NAME}"

$(if [[ "${CMDAEMON_ENABLED:-false}" == "true" ]]; then cat <<CMEOF
  # CMDaemon exporter — BCM node inventory via cmsh
  - job_name: cmdaemon-exporter
    scrape_interval: 30s
    scrape_timeout: 25s
    honor_labels: true
    static_configs:
      - targets: ["${OBSVM_IP}:9101"]
CMEOF
fi)

$(if [[ "${REDFISH_ENABLED:-false}" == "true" ]]; then cat <<RFEOF
  # Redfish BMC exporter — BIOS, boot order, firmware, thermals
  - job_name: redfish-exporter
    scrape_interval: 60s
    scrape_timeout: 55s
    honor_labels: true
    static_configs:
      - targets: ["${OBSVM_IP}:9102"]
RFEOF
fi)

$(if [[ "${UFM_ENABLED:-false}" == "true" ]]; then cat <<UFEOF
  # UFM exporter — fabric switches, ports, alarms, Cluster Minder
  - job_name: ufm-exporter
    scrape_interval: 30s
    scrape_timeout: 25s
    honor_labels: true
    static_configs:
      - targets: ["${OBSVM_IP}:9103"]
UFEOF
fi)

# Remote write to VictoriaMetrics for long-term storage
remote_write:
  - url: http://nvis-victoriametrics:8428/api/v1/write
EOF

  # Write grafana-provisioning/datasources/datasources.yaml
  info "Writing grafana-provisioning/datasources/datasources.yaml..."
  mkdir -p "${NVIS_DIR}/grafana-provisioning/datasources"
  cat > "${NVIS_DIR}/grafana-provisioning/datasources/datasources.yaml" <<EOF
apiVersion: 1

datasources:
  - name: Prometheus
    uid: nvis-prometheus
    type: prometheus
    url: http://nvis-prometheus:9090
    access: proxy
    isDefault: true
    editable: false

  - name: Loki
    uid: nvis-loki
    type: loki
    url: http://nvis-loki:3100
    access: proxy
    editable: false

  - name: VictoriaMetrics
    uid: nvis-victoriametrics
    type: prometheus
    url: http://nvis-victoriametrics:8428
    access: proxy
    editable: false
EOF

  # Write docker-compose.yml
  info "Writing docker-compose.yml..."
  cat > "${NVIS_DIR}/docker-compose.yml" <<EOF
services:
  loki:
    image: grafana/loki:3.1.0
    container_name: nvis-loki
    command: -config.file=/etc/loki/loki-config.yaml
    ports:
      - "3100:3100"
    volumes:
      - loki-data:/loki
      - ./loki/loki-config.yaml:/etc/loki/loki-config.yaml:ro
    restart: unless-stopped

  prometheus:
    image: prom/prometheus:v2.54.1
    container_name: nvis-prometheus
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --web.enable-remote-write-receiver
      - --web.enable-lifecycle
      - --web.enable-admin-api
    ports:
      - "9090:9090"
    volumes:
      - prom-data:/prometheus
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
    restart: unless-stopped

  grafana:
    image: grafana/grafana:11.1.4
    container_name: nvis-grafana
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=\${GRAFANA_ADMIN_PASSWORD:-changeme}
      - GF_PANELS_DISABLE_SANITIZE_HTML=true
      - GF_SECURITY_CONTENT_SECURITY_POLICY=false
    ports:
      - "3000:3000"
    volumes:
      - grafana-data:/var/lib/grafana
      - ./grafana-provisioning:/etc/grafana/provisioning:ro
    restart: unless-stopped

  victoriametrics:
    image: victoriametrics/victoria-metrics:v1.103.0
    container_name: nvis-victoriametrics
    restart: unless-stopped
    command:
      - '--storageDataPath=/vm-data'
      - '--retentionPeriod=12'
    volumes:
      - vm-data:/vm-data
    ports:
      - "8428:8428"

  bcm-exporter:
    image: python:3.11-slim
    container_name: nvis-bcm-exporter
    restart: unless-stopped
    network_mode: host
    environment:
      - BCM_HOST=\${BCM_HOST:-}
      - BCM_USER=\${BCM_USER:-root}
      - BCM_SSH_KEY=/root/.ssh/id_ed25519
      - CLUSTER_NAME=\${CLUSTER_NAME:-nvis-cluster}
      - SCRAPE_INTERVAL=60
      - PORT=9401
    volumes:
      - ~/.ssh:/root/.ssh:ro
      - ./scripts:/scripts:ro
    command: >
      bash -c "apt-get update -qq && apt-get install -y -qq openssh-client &&
               python3 /scripts/bcm_exporter.py"

  slurm-job-exporter:
    image: python:3.11-slim
    container_name: nvis-slurm-job-exporter
    restart: unless-stopped
    network_mode: host
    environment:
      - BCM_HOST=\${BCM_HOST:-}
      - BCM_USER=\${BCM_USER:-root}
      - BCM_SSH_KEY=/root/.ssh/id_ed25519
      - CLUSTER_NAME=\${CLUSTER_NAME:-nvis-cluster}
      - SLURM_PORT=9402
      - SCRAPE_INTERVAL=30
      - SACCT_HOURS=72
    volumes:
      - ~/.ssh:/root/.ssh:ro
      - ./scripts:/scripts:ro
    command: >
      bash -c "apt-get update -qq && apt-get install -y -qq openssh-client &&
               python3 /scripts/slurm_job_exporter.py"

volumes:
  loki-data:
  prom-data:
  grafana-data:
  vm-data:
EOF

  # Pre-flight: warn on port conflicts and kill stray processes before compose up
  for _p in 9090 3100; do
    if ss -tlnp 2>/dev/null | grep -qE ":${_p}[^0-9]"; then
      _pid="$(ss -tlnp 2>/dev/null | grep -E ":${_p}[^0-9]" | grep -oP 'pid=\K[0-9]+' | head -1 || true)"
      warn "Port ${_p} already in use (pid ${_pid:-unknown}) — attempting to free before compose up"
      [[ -n "${_pid}" ]] && kill "${_pid}" 2>/dev/null && sleep 2 || true
    fi
  done

  # Bring up the stack
  info "Starting ObsVM Docker Compose stack..."
  cd "${NVIS_DIR}"
  docker compose up -d 2>&1 || true
  cd - &>/dev/null

  # Detect containers stuck in Created state (port conflict aborted network setup) and retry
  sleep 3
  _STUCK="$(docker ps -a --format '{{.Names}} {{.Status}}' | awk '/^nvis-/ && /Created/{print $1}' || true)"
  if [[ -n "${_STUCK}" ]]; then
    warn "Containers stuck in Created (port conflict): ${_STUCK} — retrying"
    cd "${NVIS_DIR}" && docker compose up -d 2>&1 | tail -5 || true
    cd - &>/dev/null
    sleep 3
    _STILL="$(docker ps -a --format '{{.Names}} {{.Status}}' | awk '/^nvis-/ && /Created/{print $1}' || true)"
    [[ -n "${_STILL}" ]] && warn "Still stuck after retry: ${_STILL}" || info "All containers now running"
  fi

  # Wait for Grafana — Grafana 11 first-boot DB init can take 4-5 minutes
  # Fallback via docker exec covers cases where Docker host port forwarding is broken
  info "Waiting for Grafana (up to 300s)..."
  GRAFANA_UP=false
  for i in $(seq 1 150); do
    response=$(no_proxy='*' curl -sf --noproxy '*' "http://localhost:3000/api/health" 2>/dev/null || \
               no_proxy='*' curl -sf --noproxy '*' "http://${OBSVM_IP}:3000/api/health" 2>/dev/null || \
               docker exec nvis-grafana wget -qO- http://localhost:3000/api/health 2>/dev/null || true)
    if echo "${response}" | grep -q '"database":"ok"'; then
      success "Grafana is healthy (${i}x2s)"
      GRAFANA_UP=true
      break
    fi
    sleep 2
  done
  [[ "${GRAFANA_UP}" == "false" ]] && warn "Grafana did not report healthy within 300s — will retry in Phase 6"

  success "Phase 2 complete"
fi

# ===========================================================================
# PHASE 3 — BCM Deployment
# ===========================================================================
if phase_enabled 3; then
  step "PHASE 3: BCM Docker containers"

  # Get BCM hostname
  BCM_HOSTNAME="$(bcm_ssh 'hostname -s' 2>/dev/null | tr -d '[:space:]')"
  [[ -z "${BCM_HOSTNAME}" ]] && BCM_HOSTNAME="${BCM_HOST}"
  info "BCM hostname: ${BCM_HOSTNAME}"

  # Verify Docker is available on BCM before proceeding
  if ! bcm_ssh "command -v docker &>/dev/null && docker info &>/dev/null && echo ok" 2>/dev/null | grep -q "ok"; then
    warn "Docker not available on BCM — skipping Phase 3 (BCM containers)"
    warn "Install Docker on BCM and re-run with: sudo bash scripts/nvis-setup.sh --skip-phase 0,1,2"
  else

  # Transfer images to BCM — only those not already present
  info "Checking which images need to be transferred to BCM..."
  BCM_TRANSFER_IMAGES=()
  for img in "gcr.io/cadvisor/cadvisor:v0.49.1" "quay.io/prometheus/node-exporter:v1.8.1" "grafana/alloy:v1.3.0"; do
    if ! bcm_ssh "docker image inspect '${img}' &>/dev/null && echo found" 2>/dev/null | grep -q "found"; then
      BCM_TRANSFER_IMAGES+=("${img}")
    else
      info "BCM already has: ${img}"
    fi
  done

  if [[ ${#BCM_TRANSFER_IMAGES[@]} -gt 0 ]]; then
    # Load from pre-staged tar (placed by Phase 1 via SSH, no Docker needed then)
    if bcm_ssh "test -s /tmp/nvis-bcm-images.tar.gz && echo found" 2>/dev/null | grep -q "found"; then
      info "Loading BCM images from pre-staged tar (Phase 1 deposited this via SSH)..."
      bcm_ssh "gunzip -c /tmp/nvis-bcm-images.tar.gz | docker load && rm -f /tmp/nvis-bcm-images.tar.gz" \
        && success "BCM images loaded from pre-staged tar" \
        || { warn "Pre-staged tar load failed — falling back to live transfer...";
             docker save "${BCM_TRANSFER_IMAGES[@]}" 2>/dev/null | bcm_ssh "docker load" \
               && success "Images loaded on BCM (live transfer)" \
               || warn "Image transfer to BCM had errors"; }
    else
      info "Transferring ${#BCM_TRANSFER_IMAGES[@]} image(s) to BCM (this may take several minutes)..."
      docker save "${BCM_TRANSFER_IMAGES[@]}" 2>/dev/null | \
        bcm_ssh "docker load" \
        && success "Images loaded on BCM" \
        || warn "Image transfer to BCM had errors — check BCM Docker logs"
    fi
  else
    success "All required images already present on BCM"
  fi

  # Stop existing nvis- containers on BCM (clean slate)
  info "Removing any existing nvis- containers on BCM..."
  bcm_ssh "
    existing=\$(docker ps -a --format '{{.Names}}' | grep '^nvis-' 2>/dev/null || true)
    if [[ -n \"\${existing}\" ]]; then
      echo \"\${existing}\" | xargs docker rm -f
      echo 'Removed existing nvis- containers'
    else
      echo 'No existing nvis- containers'
    fi
  "

  # Detect if node-exporter is already listening on 9100 (e.g. Run.ai DaemonSet on BCM as K8s node)
  BCM_NE_PORT=9100
  BCM_NE_EXISTS=false
  if bcm_ssh "ss -tlnp 2>/dev/null | grep -q ':9100'" 2>/dev/null; then
    info "Port 9100 in use on BCM — Run.ai/existing node-exporter detected, latching on"
    BCM_NE_EXISTS=true
    BCM_NE_PORT=9100
    # Do NOT start our own node-exporter — we'll have Alloy scrape the existing one
  fi

  # Write Alloy config AFTER port detection so the correct port is used
  info "Writing BCM Alloy config (node-exporter port: ${BCM_NE_PORT})..."
  BCM_ALLOY_CONF="/tmp/nvis-bcm-alloy.conf"
  cat > "${BCM_ALLOY_CONF}" <<EOF
// BCM Alloy config — scrapes cAdvisor + node_exporter, pushes to ObsVM
// Generated by nvis-setup.sh on $(date -u '+%Y-%m-%d %H:%M:%S UTC')
// node-exporter port: ${BCM_NE_PORT} (${BCM_NE_EXISTS:+existing/Run.ai}${BCM_NE_EXISTS:-nvis-deployed})

prometheus.scrape "cadvisor" {
  targets = [{"__address__" = "localhost:8080"}]
  forward_to = [prometheus.relabel.nvis_labels.receiver]
  scrape_interval = "30s"
  job_name = "cadvisor"
}

prometheus.scrape "node_exporter" {
  targets = [{"__address__" = "localhost:${BCM_NE_PORT}"}]
  forward_to = [prometheus.relabel.nvis_labels.receiver]
  scrape_interval = "15s"
  job_name = "node-exporter"
}

prometheus.relabel "nvis_labels" {
  forward_to = [prometheus.remote_write.obsvm.receiver]

  rule {
    target_label = "cluster"
    replacement  = "${CLUSTER_NAME}"
  }
  rule {
    target_label = "node"
    replacement  = "${BCM_HOSTNAME}"
  }
  rule {
    target_label = "instance"
    replacement  = "${BCM_HOSTNAME}"
  }
}

prometheus.remote_write "obsvm" {
  endpoint {
    url = "http://${OBSVM_IP}:9090/api/v1/write"
  }
}

loki.source.journal "system_logs" {
  forward_to = [loki.write.obsvm.receiver]
  max_age    = "12h"
  labels = {
    job     = "systemd-journal",
    cluster = "${CLUSTER_NAME}",
    node    = "${BCM_HOSTNAME}",
  }
}

loki.write "obsvm" {
  endpoint {
    url = "http://${OBSVM_IP}:3100/loki/api/v1/push"
  }
}
EOF

  # Copy Alloy config to BCM
  info "Copying Alloy config to BCM..."
  bcm_ssh "mkdir -p /etc/nvis-alloy"
  bcm_scp "${BCM_ALLOY_CONF}" "${BCM_USER}@${BCM_HOST}:/etc/nvis-alloy/config.alloy"
  success "Alloy config copied to BCM:/etc/nvis-alloy/config.alloy"

  # Start cAdvisor on BCM — explicit docker socket + both cgroup v1 and v2 paths
  info "Starting cAdvisor on BCM..."
  bcm_ssh "
    CGROUP_MOUNT=''
    # Handle both cgroupv1 and cgroupv2
    if [ -d /sys/fs/cgroup/unified ]; then
      CGROUP_MOUNT='--volume /sys/fs/cgroup/unified:/sys/fs/cgroup:ro'
    elif [ -d /sys/fs/cgroup/memory ]; then
      CGROUP_MOUNT='--volume /sys/fs/cgroup:/sys/fs/cgroup:ro'
    else
      CGROUP_MOUNT='--volume /sys/fs/cgroup:/sys/fs/cgroup:ro'
    fi

    docker run -d \
      --name nvis-cadvisor \
      --restart=unless-stopped \
      --privileged \
      --pid=host \
      --volume /:/rootfs:ro \
      --volume /var/run/docker.sock:/var/run/docker.sock:ro \
      --volume /sys:/sys:ro \
      \${CGROUP_MOUNT} \
      --volume /dev/disk:/dev/disk:ro \
      -p 127.0.0.1:8080:8080 \
      gcr.io/cadvisor/cadvisor:v0.49.1 \
        --housekeeping_interval=30s \
        --docker_only=false \
        --store_container_labels=false \
        --allow_dynamic_housekeeping=false
  " && success "cAdvisor started on BCM" || warn "cAdvisor start failed on BCM"

  # Start node-exporter ONLY if not already running on BCM
  if [[ "${BCM_NE_EXISTS}" == "true" ]]; then
    info "Skipping nvis-node-exporter on BCM — port ${BCM_NE_PORT} already in use (Run.ai/existing)"
    success "BCM node metrics from existing exporter on :${BCM_NE_PORT}"
  else
    info "Starting node-exporter on BCM (port 9100)..."
    bcm_ssh "
      docker run -d \
        --name nvis-node-exporter \
        --restart=unless-stopped \
        --pid=host \
        --net=host \
        --volume /:/host:ro,rslave \
        quay.io/prometheus/node-exporter:v1.8.1 \
          --path.rootfs=/host \
          --web.listen-address=:9100
    " && success "node-exporter started on BCM" || warn "node-exporter start failed on BCM"
  fi

  # Start Alloy on BCM
  info "Starting Grafana Alloy on BCM..."
  # Detect journal log path (may vary by distro)
  BCM_JOURNAL_PATH="$(bcm_ssh "ls -d /run/log/journal /var/log/journal 2>/dev/null | head -1" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -z "${BCM_JOURNAL_PATH}" ]] && BCM_JOURNAL_PATH="/var/log/journal"

  bcm_ssh "
    docker run -d \
      --name nvis-alloy \
      --restart=unless-stopped \
      --net=host \
      --volume /etc/nvis-alloy:/etc/alloy:ro \
      --volume ${BCM_JOURNAL_PATH}:/var/log/journal:ro \
      --volume /etc/machine-id:/etc/machine-id:ro \
      grafana/alloy:v1.3.0 \
        run /etc/alloy/config.alloy \
          --storage.path=/tmp/alloy-data
  " && success "Alloy started on BCM" || warn "Alloy start failed on BCM"

  # Wait and verify
  info "Waiting 8s for BCM containers to stabilize..."
  sleep 8

  info "Verifying BCM containers..."
  BCM_RUNNING="$(bcm_ssh "docker ps --format '{{.Names}}' | grep '^nvis-'" 2>/dev/null || true)"
  # Expected: cadvisor + alloy always; node-exporter only if we deployed it
  EXPECTED=("nvis-cadvisor" "nvis-alloy")
  [[ "${BCM_NE_EXISTS}" == "false" ]] && EXPECTED+=("nvis-node-exporter")
  ALL_OK=true
  for cname in "${EXPECTED[@]}"; do
    if echo "${BCM_RUNNING}" | grep -q "${cname}"; then
      success "BCM: ${cname} running"
    else
      warn "BCM: ${cname} NOT running"
      ALL_OK=false
    fi
  done
  [[ "${ALL_OK}" == "true" ]] && success "All BCM containers running" || warn "Some BCM containers failed — check: bcm_ssh 'docker logs <name>'"

  success "Phase 3 complete"
  fi  # end Docker-available guard
fi

# ===========================================================================
# PHASE 4 — GPU Node K8s DaemonSets
# ===========================================================================
if phase_enabled 4 && [[ ${#GPU_NODES[@]} -gt 0 ]] && [[ -n "${K8S_MASTER}" ]]; then
  step "PHASE 4: GPU node Kubernetes DaemonSets"
  echo ""
  info "GPU nodes are airgapped — Helm chart images served from local registry: ${REG}"
  info "All image pulls go to ${REG} → no internet access required on GPU nodes"
  echo ""

  # ---- 4a. Configure containerd insecure registry on each GPU node ----
  CONTAINERD_SCRIPT="/tmp/nvis-containerd-registry.sh"
  cat > "${CONTAINERD_SCRIPT}" <<SCRIPT_EOF
#!/bin/bash
set -uo pipefail
REGISTRY="${OBSVM_IP}:5000"
mkdir -p "/etc/containerd/certs.d/\${REGISTRY}"
cat > "/etc/containerd/certs.d/\${REGISTRY}/hosts.toml" <<'TOML_EOF'
server = "http://${OBSVM_IP}:5000"
[host."http://${OBSVM_IP}:5000"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
TOML_EOF
systemctl --no-ask-password restart containerd 2>/dev/null || true
echo "containerd registry configured for ${OBSVM_IP}:5000"
SCRIPT_EOF
  chmod +x "${CONTAINERD_SCRIPT}"

  # Copy script to BCM, then from BCM to each node, execute
  BCM_SCRIPT_PATH="/tmp/nvis-containerd-registry.sh"
  bcm_scp "${CONTAINERD_SCRIPT}" "${BCM_USER}@${BCM_HOST}:${BCM_SCRIPT_PATH}"
  bcm_ssh "chmod +x ${BCM_SCRIPT_PATH}"

  for node in "${GPU_NODES[@]}"; do
    info "Configuring containerd registry on GPU node ${node}..."
    bcm_ssh "
      scp -o StrictHostKeyChecking=no ${BCM_SCRIPT_PATH} ${GPU_SSH_USER}@${node}:/tmp/nvis-containerd-registry.sh
      ssh -o StrictHostKeyChecking=no ${GPU_SSH_USER}@${node} 'chmod +x /tmp/nvis-containerd-registry.sh && /tmp/nvis-containerd-registry.sh'
    " && success "containerd configured on ${node}" || warn "containerd config failed on ${node}"
  done

  # ---- 4b. Write Helm values file ----
  info "Writing Helm values file..."
  HELM_VALUES="/tmp/nvis-helm-values.yaml"

  # Determine which components to deploy vs. latch onto
  # DCGM: deploy only if not pre-existing AND NGC key provided
  [[ "${DCGM_DEPLOY}" == "true" ]] && HELM_DCGM_ENABLED="true" || HELM_DCGM_ENABLED="false"
  # node-exporter: deploy only if not pre-existing (Run.ai, kube-prometheus, etc. may have it)
  [[ "${NODE_EXPORTER_DEPLOY:-true}" == "true" ]] && HELM_NE_ENABLED="true" || HELM_NE_ENABLED="false"
  # Alloy scrape ports: use existing exporter ports when latching on
  NE_SCRAPE_PORT="${NODE_EXPORTER_PORT:-9100}"
  # DCGM pod selector: set when using pre-existing DCGM (no hostPort — needs K8s discovery).
  # Our own DCGM uses hostNetwork+hostPort so localhost works; leave empty for that case.
  if [[ "${DCGM_DEPLOY}" == "false" ]]; then
    HELM_DCGM_POD_SELECTOR="app=nvidia-dcgm-exporter"
  else
    HELM_DCGM_POD_SELECTOR=""
  fi

  cat > "${HELM_VALUES}" <<EOF
imageRegistry: "${REG}"
cluster: "${CLUSTER_NAME}"
namespace: "${NAMESPACE}"

remote:
  prometheusUrl: "http://${OBSVM_IP}:9090/api/v1/write"
  lokiUrl: "http://${OBSVM_IP}:3100/loki/api/v1/push"

# DCGM: enabled=${HELM_DCGM_ENABLED} (deploy new) | existing scraped on port ${DCGM_PORT}
dcgmExporter:
  enabled: ${HELM_DCGM_ENABLED}
  image:
    repository: dcgm-exporter
    tag: "3.3.5-3.4.0-ubuntu22.04"
  port: ${DCGM_PORT}

# node-exporter: enabled=${HELM_NE_ENABLED} (deploy new) | existing scraped on port ${NE_SCRAPE_PORT}
nodeExporter:
  enabled: ${HELM_NE_ENABLED}
  image:
    repository: node-exporter
    tag: "v1.8.1"
  port: ${NE_SCRAPE_PORT}

alloy:
  enabled: true
  image:
    repository: alloy
    tag: "v1.3.0"
  # Only schedule on GPU nodes — BCM has Alloy as a Docker container (Phase 3)
  # and is a K8s node too. Restricting to GPU nodes prevents duplicate scraping
  # and avoids ErrImagePull on BCM (BCM containerd not configured for local registry)
  nodeSelector:
    nvidia.com/gpu.present: "true"
  # Scrape ports — used whether we deployed the exporter or latched onto existing
  dcgmScrapePort: "${DCGM_PORT}"
  nodeExporterScrapePort: "${NE_SCRAPE_PORT}"
  # K8s pod discovery for pre-existing DCGM (no hostPort).
  # When non-empty, Alloy discovers DCGM pods by label+nodeName instead of localhost.
  # Empty = use localhost (our own DCGM uses hostNetwork+hostPort).
  dcgmPodSelector: "${HELM_DCGM_POD_SELECTOR}"
EOF

  # ---- 4c. Extract helm binary and install on BCM (= K8s master) ----
  info "Extracting helm binary..."
  HELM_BIN="/tmp/helm-bin"
  docker run --rm -v /tmp:/out --entrypoint sh alpine/helm:3.15.4 \
    -c "cp /usr/bin/helm /out/helm-bin" 2>/dev/null \
  || warn "Could not extract helm binary — assuming helm already on BCM"

  if [[ -f "${HELM_BIN}" ]] && [[ -s "${HELM_BIN}" ]]; then
    chmod +x "${HELM_BIN}"
    bcm_scp "${HELM_BIN}" "${BCM_USER}@${BCM_HOST}:/usr/local/bin/helm"
    bcm_ssh "chmod +x /usr/local/bin/helm && helm version" \
      && success "helm installed on BCM" || warn "helm install on BCM failed"
  else
    warn "helm binary not extracted — assuming helm already installed on BCM"
  fi

  # ---- 4d. Copy helm values to BCM ----
  info "Copying Helm values to BCM..."
  bcm_scp "${HELM_VALUES}" "${BCM_USER}@${BCM_HOST}:/tmp/nvis-helm-values.yaml" \
    && success "Helm values copied to BCM" || warn "Helm values copy failed"

  # ---- 4e. Tar and copy Helm chart to BCM ----
  CHART_DIR="${NVIS_DIR}/helm/nvis-gpu-agents"
  if [[ -d "${CHART_DIR}" ]]; then
    info "Packaging Helm chart..."
    CHART_TAR="/tmp/nvis-gpu-agents-chart.tar.gz"
    tar -czf "${CHART_TAR}" -C "${NVIS_DIR}/helm" nvis-gpu-agents
    bcm_scp "${CHART_TAR}" "${BCM_USER}@${BCM_HOST}:/tmp/nvis-gpu-agents-chart.tar.gz"
    bcm_ssh "cd /tmp && tar -xzf nvis-gpu-agents-chart.tar.gz && echo 'Chart extracted'" \
      && success "Helm chart extracted on BCM" || warn "Helm chart copy failed"
  else
    warn "Helm chart directory not found: ${CHART_DIR}"
  fi

  # ---- 4f. Label GPU nodes ----
  info "Labeling GPU nodes with nvidia.com/gpu.present=true..."
  # Get all node names and IPs from K8s master
  NODE_JSON="$(k8s_cmd 'kubectl get nodes -o json' 2>/dev/null || echo '{}')"
  for node_ip in "${GPU_NODES[@]}"; do
    # Find K8s node name by IP
    NODE_NAME="$(echo "${NODE_JSON}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
target = '${node_ip}'
for item in data.get('items', []):
    for addr in item.get('status', {}).get('addresses', []):
        if addr.get('address') == target:
            print(item['metadata']['name'])
            sys.exit(0)
" 2>/dev/null || true)"
    if [[ -n "${NODE_NAME}" ]]; then
      k8s_cmd "kubectl label node ${NODE_NAME} nvidia.com/gpu.present=true --overwrite" \
        && success "Labeled node ${NODE_NAME} (${node_ip})" \
        || warn "Failed to label node ${NODE_NAME}"
    else
      warn "Could not find K8s node name for IP ${node_ip}"
    fi
  done

  # ---- 4g. Run Helm on BCM (= K8s master) ----
  info "Running Helm deploy on BCM..."
  _helm_out="$(bcm_ssh "
    HELM_BIN=\"\$(command -v helm 2>/dev/null || echo /usr/local/bin/helm)\"
    if \"\${HELM_BIN}\" upgrade --install nvis-gpu-agents /tmp/nvis-gpu-agents \
      -f /tmp/nvis-helm-values.yaml \
      --namespace '${NAMESPACE}' \
      --create-namespace \
      --wait \
      --timeout 5m0s 2>&1; then
      echo HELM_OK
    else
      echo HELM_FAIL
    fi
  " 2>&1 || true)"
  if echo "${_helm_out}" | grep -q "HELM_OK"; then
    success "Helm deploy complete"
  elif echo "${_helm_out}" | grep -qiE "deadline exceeded|timed out|timeout"; then
    warn "Helm deploy timed out — chart was installed but pods may still be starting"
    warn "Check pod status: kubectl get pods -n ${NAMESPACE} (run on BCM)"
  else
    warn "Helm deploy failed — check BCM logs. Output: $(echo "${_helm_out}" | tail -3)"
  fi

  success "Phase 4 complete"
elif phase_enabled 4; then
  warn "Phase 4 skipped — no GPU nodes or K8s master configured"
fi

# ===========================================================================
# PHASE 5 — Run.ai Integration
# ===========================================================================
if phase_enabled 5 && [[ "${RUNAI_ENABLED}" == "true" ]]; then
  step "PHASE 5: Run.ai Prometheus remote_write integration"

  info "Looking for Run.ai Prometheus CR in namespace ${RUNAI_PROM_NS} on ${RUNAI_ON_BCM:+BCM}${RUNAI_K8S_HOST:-BCM}..."
  RUNAI_PROM_NAME="$(runai_k8s_cmd "kubectl get prometheus -n ${RUNAI_PROM_NS} -o jsonpath='{.items[0].metadata.name}'" 2>/dev/null | tr -d "'" || true)"

  if [[ -n "${RUNAI_PROM_NAME}" ]]; then
    info "Found Prometheus CR: ${RUNAI_PROM_NAME}"
    info "Patching remote_write to forward runai_.* metrics to ObsVM..."
    PATCH_JSON="{\"spec\":{\"remoteWrite\":[{\"url\":\"http://${OBSVM_IP}:9090/api/v1/write\",\"writeRelabelConfigs\":[{\"sourceLabels\":[\"__name__\"],\"regex\":\"runai.*\",\"action\":\"keep\"}]}]}}"
    runai_k8s_cmd "kubectl patch prometheus ${RUNAI_PROM_NAME} -n ${RUNAI_PROM_NS} --type=merge -p '${PATCH_JSON}'" \
      && success "Run.ai Prometheus CR patched" \
      || warn "Run.ai Prometheus patch failed"
  else
    warn "No Prometheus CR found in namespace ${RUNAI_PROM_NS} — Run.ai integration skipped"
    warn "You may need to configure remote_write manually in your Run.ai Prometheus"
  fi

  success "Phase 5 complete"
elif phase_enabled 5; then
  info "Phase 5: Run.ai not enabled — skipping"
fi

# ===========================================================================
# PHASE 6 — Grafana Datasources, Folder & Dashboards (via Terraform)
# ===========================================================================
if phase_enabled 6; then
  step "PHASE 6: Grafana provisioning via Terraform"

  TF_DIR="${NVIS_DIR}/terraform"

  if [[ ! -d "${TF_DIR}" ]]; then
    warn "Terraform directory not found: ${TF_DIR} — skipping Phase 6"
  elif ! command -v terraform &>/dev/null; then
    warn "terraform binary not found — skipping Phase 6"
    warn "Install Terraform and re-run: sudo bash ${SCRIPT_DIR}/nvis-setup.sh --skip-phase 0,1,2,3,4,5"
  else
    # Wait for Grafana to be healthy before Terraform talks to it
    info "Waiting for Grafana API (up to 300s)..."
    GRAFANA_READY=false
    for i in $(seq 1 150); do
      response="$(no_proxy='*' curl -sf --noproxy '*' "http://localhost:3000/api/health" 2>/dev/null || \
                  no_proxy='*' curl -sf --noproxy '*' "http://${OBSVM_IP}:3000/api/health" 2>/dev/null || \
                  docker exec nvis-grafana wget -qO- http://localhost:3000/api/health 2>/dev/null || true)"
      if echo "${response}" | grep -q '"database":"ok"'; then
        GRAFANA_READY=true
        success "Grafana API ready (${i}x2s)"
        break
      fi
      sleep 2
    done

    if [[ "${GRAFANA_READY}" == "false" ]]; then
      warn "Grafana not ready after 300s — skipping Terraform apply"
      warn "Re-run: sudo bash ${SCRIPT_DIR}/nvis-setup.sh --skip-phase 0,1,2,3,4,5"
    else
      # Generate terraform.tfvars from installer config (overwrites any stale values)
      info "Writing terraform.tfvars..."
      cat > "${TF_DIR}/terraform.tfvars" << TFVARS
grafana_url         = "http://localhost:3000"
grafana_user        = "admin"
grafana_password    = "${GRAFANA_PASS}"
prometheus_url      = "http://nvis-prometheus:9090"
loki_url            = "http://nvis-loki:3100"
victoriametrics_url = "http://nvis-victoriametrics:8428"
TFVARS
      chmod 600 "${TF_DIR}/terraform.tfvars"

      # Init (only downloads provider if .terraform/ missing or provider version changed)
      info "Running terraform init..."
      terraform -chdir="${TF_DIR}" init -upgrade -input=false \
        -no-color 2>&1 | grep -E "Initializing|Installed|provider|Error|error" | head -10 || true

      # Apply — idempotent, safe to re-run
      info "Running terraform apply (datasources + folder + ${#} dashboards)..."
      DASH_COUNT="$(ls "${TF_DIR}/dashboards/"*.json 2>/dev/null | wc -l | tr -d ' ')"
      info "Dashboards to provision: ${DASH_COUNT}"
      if terraform -chdir="${TF_DIR}" apply -auto-approve -input=false -no-color 2>&1 \
          | tee /tmp/nvis_tf_apply.log \
          | grep -E "Apply complete|Error|error|grafana_dashboard|grafana_data_source|grafana_folder" \
          | head -30; then
        TF_SUMMARY="$(grep 'Apply complete' /tmp/nvis_tf_apply.log | tail -1)"
        success "Terraform apply complete — ${TF_SUMMARY:-resources provisioned}"
        # Final dashboard count check
        GRAFANA_DASH_COUNT="$(no_proxy='*' curl -sf --noproxy '*' -u "admin:${GRAFANA_PASS}" \
          'http://localhost:3000/api/search?type=dash-db&limit=100' 2>/dev/null \
          | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)"
        success "Grafana confirms ${GRAFANA_DASH_COUNT} dashboards"
      else
        warn "Terraform apply had errors — check /tmp/nvis_tf_apply.log"
        warn "Re-run: cd ${TF_DIR} && terraform apply -auto-approve"
      fi
    fi
  fi

  success "Phase 6 complete"
fi

# ===========================================================================
# PHASE 8 — CMDaemon Exporter (ObsVM, port 9101)
# ===========================================================================
if phase_enabled 8 && [[ "${CMDAEMON_ENABLED:-false}" == "true" ]]; then
  step "PHASE 8: CMDaemon Prometheus exporter"

  CMDAEMON_SCRIPT="${SCRIPT_DIR}/cmdaemon_exporter.py"
  CMDAEMON_SVC="${SCRIPT_DIR}/cmdaemon-exporter.service"
  CMDAEMON_DEST="/opt/nvis-monitoring/cmdaemon_exporter.py"
  CMDAEMON_ENV="/etc/nvis/cmdaemon-exporter.env"
  CMDAEMON_SVC_DEST="/etc/systemd/system/cmdaemon-exporter.service"

  if [[ ! -f "${CMDAEMON_SCRIPT}" ]]; then
    warn "cmdaemon_exporter.py not found at ${CMDAEMON_SCRIPT} — skipping phase 8"
  else
    # Install exporter
    mkdir -p /opt/nvis-monitoring
    cp "${CMDAEMON_SCRIPT}" "${CMDAEMON_DEST}"
    chmod +x "${CMDAEMON_DEST}"
    success "Copied cmdaemon_exporter.py → ${CMDAEMON_DEST}"

    # Write env file
    mkdir -p /etc/nvis
    cat > "${CMDAEMON_ENV}" <<ENVEOF
BCM_HOST=${BCM_HOST}
BCM_USER=${BCM_USER:-root}
JUMP_HOST=${BCM_JUMP:-}
SSH_KEY=${BCM_SSH_KEY:-/root/.ssh/id_ed25519}
CLUSTER_NAME=${CLUSTER_NAME}
PYTHONCM_PATH=/cm/local/apps/cmd/pythoncm/lib/python3.9/site-packages
PORT=9101
SCRAPE_INTERVAL=30
ENVEOF
    chmod 600 "${CMDAEMON_ENV}"
    success "Wrote ${CMDAEMON_ENV}"

    # Install systemd service
    cp "${CMDAEMON_SVC}" "${CMDAEMON_SVC_DEST}"
    success "Installed systemd service ${CMDAEMON_SVC_DEST}"

    # Enable and (re)start
    systemctl daemon-reload
    systemctl --no-ask-password enable cmdaemon-exporter
    systemctl reset-failed cmdaemon-exporter 2>/dev/null || true
    systemctl --no-ask-password restart cmdaemon-exporter
    sleep 3

    if systemctl is-active cmdaemon-exporter &>/dev/null; then
      success "cmdaemon-exporter running on port 9101"
    else
      warn "cmdaemon-exporter may not have started — check: journalctl -u cmdaemon-exporter -n 20"
    fi

    # Wait for first scrape to be ready (up to 90s — BCM SSH takes time)
    info "Waiting for first CMDaemon scrape (up to 90s)..."
    for i in $(seq 1 18); do
      if curl -sf "http://localhost:9101/-/healthy" &>/dev/null; then
        success "CMDaemon exporter healthy at localhost:9101"
        break
      fi
      sleep 5
    done

    success "Phase 8 complete — metrics at http://localhost:9101/metrics"
  fi
fi

# ===========================================================================
# PHASE 9 — Alloy Log Collector on BCM Head Node + GPU Nodes
# ===========================================================================
if phase_enabled 9; then
  step "PHASE 9: Alloy log forwarder (BCM head node + GPU nodes)"

  ALLOY_VERSION="v1.3.0"
  ALLOY_BCM_CONFIG="${NVIS_DIR}/head-node/config.alloy"
  ALLOY_GPU_TEMPLATE="${NVIS_DIR}/node-configs/gpu-syslog-alloy.template"

  # ---- helper: ensure Alloy binary on BCM (extracted from local Docker image) ----
  install_alloy_bcm() {
    stage_alloy_binary_to_bcm
  }

  # ---- deploy Alloy on BCM head node ----
  if [[ -f "${ALLOY_BCM_CONFIG}" ]]; then
    install_alloy_bcm || warn "Alloy binary install failed on BCM — config will still be written"

    # Substitute placeholders in BCM config
    BCM_ALLOY_CONF_TMP="$(mktemp)"
    sed \
      -e "s|OBSVM_IP|${OBSVM_IP}|g" \
      -e "s|CLUSTER_NAME|${CLUSTER_NAME}|g" \
      "${ALLOY_BCM_CONFIG}" > "${BCM_ALLOY_CONF_TMP}"

    # Copy config to BCM
    info "Copying Alloy config to BCM..."
    bcm_scp "${BCM_ALLOY_CONF_TMP}" "${BCM_USER}@${BCM_HOST}:/tmp/nvis-bcm-alloy.alloy"
    rm -f "${BCM_ALLOY_CONF_TMP}"

    # Detect first free port for Alloy HTTP on BCM (avoids conflict with existing Alloy DaemonSets)
    ALLOY_BCM_PORT="$(bcm_ssh 'p=12345; while ss -tlnp 2>/dev/null | grep -q ":$p[^0-9]"; do p=$((p+1)); [ $p -gt 12355 ] && break; done; echo $p' 2>/dev/null | tr -d '[:space:]' | grep -E '^[0-9]+$' | head -1)"
    [[ -z "${ALLOY_BCM_PORT}" || "${ALLOY_BCM_PORT:-0}" -gt 12355 ]] && ALLOY_BCM_PORT=12345
    info "BCM Alloy HTTP port: ${ALLOY_BCM_PORT}"

    # Write BCM setup script — SCP to BCM and run (avoids large inline heredoc)
    BCM_SETUP_TMP="/tmp/nvis-bcm-alloy-setup-$$.sh"
    cat > "${BCM_SETUP_TMP}" << EOF
#!/bin/bash
set -e
mkdir -p /etc/alloy /var/lib/alloy
cp /tmp/nvis-bcm-alloy.alloy /etc/alloy/config.alloy
chmod 644 /etc/alloy/config.alloy
cat > /etc/systemd/system/alloy.service << 'SVCEOF'
[Unit]
Description=Grafana Alloy — NVIS log & metrics forwarder
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/alloy run /etc/alloy/config.alloy --storage.path=/var/lib/alloy --server.http.listen-addr=127.0.0.1:${ALLOY_BCM_PORT}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl --no-ask-password enable alloy
systemctl reset-failed alloy 2>/dev/null || true
systemctl --no-ask-password restart alloy
sleep 3
systemctl is-active alloy && echo ALLOY_OK || echo ALLOY_FAIL
EOF
    bcm_scp "${BCM_SETUP_TMP}" "${BCM_USER}@${BCM_HOST}:/tmp/nvis-bcm-alloy-setup.sh"
    rm -f "${BCM_SETUP_TMP}"
    bcm_ssh "bash /tmp/nvis-bcm-alloy-setup.sh && rm -f /tmp/nvis-bcm-alloy-setup.sh" \
      2>&1 | grep -E "ALLOY_OK|ALLOY_FAIL|error|Error" | head -5

    BCM_ALLOY_STATUS="$(bcm_ssh "systemctl is-active alloy 2>/dev/null" 2>/dev/null || echo "unknown")"
    if [[ "${BCM_ALLOY_STATUS}" == "active" ]]; then
      success "Alloy log forwarder running on BCM head node"
    else
      warn "Alloy on BCM may not be running — check: bcm_ssh 'journalctl -u alloy -n 20'"
    fi
  else
    warn "BCM Alloy config not found at ${ALLOY_BCM_CONFIG} — skipping BCM Alloy"
  fi

  # ---- deploy Alloy on GPU nodes ----
  if [[ ! -f "${ALLOY_GPU_TEMPLATE}" ]]; then
    warn "GPU node Alloy template not found at ${ALLOY_GPU_TEMPLATE} — skipping GPU nodes"
  elif [[ ${#GPU_NODES[@]} -eq 0 ]]; then
    info "No GPU nodes defined — skipping GPU node Alloy log install"
  else
    for node_ip in "${GPU_NODES[@]}"; do
      info "Installing Alloy log forwarder on GPU node ${node_ip}..."

      # Derive short hostname from K8s node list
      NODE_SHORT="$(k8s_cmd "kubectl get nodes -o jsonpath='{.items[*].metadata.name}'" 2>/dev/null \
        | tr ' ' '\n' | while read -r nm; do
            k8s_cmd "kubectl get node ${nm} -o jsonpath='{.status.addresses[?(@.type==\"InternalIP\")].address}'" 2>/dev/null \
              | grep -q "${node_ip}" && echo "${nm}" && break
          done 2>/dev/null || echo "")"
      [[ -z "${NODE_SHORT}" ]] && NODE_SHORT="$(bcm_ssh "ssh -o StrictHostKeyChecking=no root@${node_ip} hostname -s" 2>/dev/null | tr -d '[:space:]')"
      [[ -z "${NODE_SHORT}" ]] && NODE_SHORT="${node_ip}"

      # Substitute config template
      GPU_ALLOY_CONF_TMP="$(mktemp)"
      sed \
        -e "s|OBSVM_IP|${OBSVM_IP}|g" \
        -e "s|CLUSTER_NAME|${CLUSTER_NAME}|g" \
        -e "s|NODE_HOSTNAME|${NODE_SHORT}|g" \
        "${ALLOY_GPU_TEMPLATE}" > "${GPU_ALLOY_CONF_TMP}"

      # Transfer config: ObsVM → BCM (stage it there first)
      BCM_TMP="/tmp/nvis-gpu-alloy-${node_ip}.alloy"
      bcm_scp "${GPU_ALLOY_CONF_TMP}" "${BCM_USER}@${BCM_HOST}:${BCM_TMP}" 2>/dev/null \
        || warn "Failed to copy alloy config to BCM temp — alloy config push to ${node_ip} may fail"
      rm -f "${GPU_ALLOY_CONF_TMP}"   # local temp no longer needed

      # Ensure alloy binary is present on this GPU node
      stage_alloy_binary_to_node "${node_ip}" || warn "Alloy binary staging failed for ${node_ip}"

      # Create /etc/alloy on GPU node, then push config BCM → GPU node directly
      # (do NOT reuse GPU_ALLOY_CONF_TMP here — it was already deleted above)
      bcm_ssh "ssh -o StrictHostKeyChecking=no ${GPU_SSH_USER}@${node_ip} 'mkdir -p /etc/alloy /var/lib/alloy'" 2>/dev/null || true
      bcm_ssh "scp -o StrictHostKeyChecking=no ${BCM_TMP} ${GPU_SSH_USER}@${node_ip}:/etc/alloy/config.alloy" \
        || warn "Failed to push alloy config to ${node_ip}:/etc/alloy/config.alloy"

      # Write setup script locally, push via BCM, run on node
      # Using SCP-based approach avoids large inline SSH heredocs that can be killed
      GPU_SETUP_TMP="/tmp/nvis-alloy-setup-${node_ip//./-}-$$.sh"
      cat > "${GPU_SETUP_TMP}" << 'SETUPEOF'
#!/bin/bash
set -e
# Find first free port >= 12345 (avoids conflict with existing Alloy DaemonSet on K8s GPU nodes)
ALLOY_PORT=12345
while ss -tlnp 2>/dev/null | grep -q ":${ALLOY_PORT}[^0-9]"; do
  ALLOY_PORT=$((ALLOY_PORT + 1))
  [ "${ALLOY_PORT}" -gt 12355 ] && { echo "WARN: no free port in 12345-12355, using 12355"; ALLOY_PORT=12355; break; }
done
echo "Alloy HTTP port: ${ALLOY_PORT}"
mkdir -p /etc/alloy /var/lib/alloy
cat > /etc/systemd/system/alloy-nvis-logs.service << SVCEOF
[Unit]
Description=Grafana Alloy — NVIS syslog forwarder
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/alloy run /etc/alloy/config.alloy --storage.path=/var/lib/alloy --server.http.listen-addr=127.0.0.1:${ALLOY_PORT}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl --no-ask-password enable alloy-nvis-logs
systemctl reset-failed alloy-nvis-logs 2>/dev/null || true
systemctl --no-ask-password restart alloy-nvis-logs
sleep 3
systemctl is-active alloy-nvis-logs && echo ALLOY_OK || echo ALLOY_FAIL
SETUPEOF
      push_to_node "${GPU_SETUP_TMP}" "/tmp/nvis-alloy-setup-${node_ip//./-}.sh" "${node_ip}" "/tmp/nvis-alloy-setup.sh"
      rm -f "${GPU_SETUP_TMP}"

      bcm_ssh "ssh -o StrictHostKeyChecking=no root@${node_ip} 'bash /tmp/nvis-alloy-setup.sh && rm -f /tmp/nvis-alloy-setup.sh'" \
        2>&1 | grep -E "ALLOY_OK|ALLOY_FAIL|Alloy HTTP port|WARN" | head -5

      GPU_ALLOY_OK="$(bcm_ssh "ssh -o StrictHostKeyChecking=no ${GPU_SSH_USER}@${node_ip} 'systemctl is-active alloy-nvis-logs 2>/dev/null'" 2>/dev/null || echo "unknown")"
      if [[ "${GPU_ALLOY_OK}" == "active" ]]; then
        success "Alloy log forwarder running on GPU node ${node_ip} (${NODE_SHORT})"
      else
        warn "Alloy log forwarder NOT running on ${node_ip} — check: bcm_ssh 'ssh root@${node_ip} journalctl -u alloy-nvis-logs -n 20'"
      fi
    done
  fi

  success "Phase 9 complete"
fi

# ===========================================================================
# PHASE 10 — Redfish BMC Exporter (ObsVM, port 9102)
# ===========================================================================
if phase_enabled 10 && [[ "${REDFISH_ENABLED:-false}" == "true" ]]; then
  step "PHASE 10: Redfish BMC Prometheus exporter"

  REDFISH_SCRIPT="${SCRIPT_DIR}/redfish_exporter.py"
  REDFISH_DEST="/opt/nvis-monitoring/redfish_exporter.py"
  REDFISH_ENV="/etc/nvis/redfish-exporter.env"
  REDFISH_SVC_DEST="/etc/systemd/system/redfish-exporter.service"

  if [[ ! -f "${REDFISH_SCRIPT}" ]]; then
    warn "redfish_exporter.py not found at ${REDFISH_SCRIPT} — skipping phase 10"
  else
    mkdir -p /opt/nvis-monitoring /etc/nvis

    cp "${REDFISH_SCRIPT}" "${REDFISH_DEST}"
    chmod +x "${REDFISH_DEST}"
    success "Copied redfish_exporter.py → ${REDFISH_DEST}"

    cat > "${REDFISH_ENV}" <<ENVEOF
BMC_HOSTS=${REDFISH_HOSTS}
BMC_USER=${REDFISH_USER}
BMC_PASS=${REDFISH_PASS}
CLUSTER_NAME=${CLUSTER_NAME}
PORT=9102
SCRAPE_INTERVAL=60
ENVEOF
    chmod 600 "${REDFISH_ENV}"
    success "Wrote ${REDFISH_ENV}"

    cat > "${REDFISH_SVC_DEST}" <<'SVCEOF'
[Unit]
Description=NVIS Redfish BMC Prometheus Exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/nvis-monitoring
EnvironmentFile=/etc/nvis/redfish-exporter.env
ExecStart=/usr/bin/python3 /opt/nvis-monitoring/redfish_exporter.py
Restart=always
RestartSec=15
StandardOutput=journal
StandardError=journal
SyslogIdentifier=redfish-exporter

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl --no-ask-password enable redfish-exporter
    systemctl --no-ask-password restart redfish-exporter
    sleep 3
    if systemctl is-active redfish-exporter &>/dev/null; then
      success "redfish-exporter running on port 9102"
    else
      warn "redfish-exporter may not have started — check: journalctl -u redfish-exporter -n 20"
    fi
    success "Phase 10 complete — metrics at http://localhost:9102/metrics"
  fi
fi

# ===========================================================================
# PHASE 11 — UFM + Cluster Minder Integration
# ===========================================================================
if phase_enabled 11 && [[ "${UFM_ENABLED:-false}" == "true" ]]; then
  step "PHASE 11: UFM Unified Fabric Manager integration"

  UFM_SCRIPT="${SCRIPT_DIR}/ufm_exporter.py"
  UFM_DEST="/opt/nvis-monitoring/ufm_exporter.py"
  UFM_ENV="/etc/nvis/ufm-exporter.env"
  UFM_SVC_DEST="/etc/systemd/system/ufm-exporter.service"

  if [[ ! -f "${UFM_SCRIPT}" ]]; then
    warn "ufm_exporter.py not found at ${UFM_SCRIPT} — skipping phase 11"
  else
    mkdir -p /opt/nvis-monitoring /etc/nvis

    cp "${UFM_SCRIPT}" "${UFM_DEST}"
    chmod +x "${UFM_DEST}"
    success "Copied ufm_exporter.py → ${UFM_DEST}"

    cat > "${UFM_ENV}" <<ENVEOF
UFM_HOST=${UFM_HOST}
UFM_USER=${UFM_USER}
UFM_PASS=${UFM_PASS}
UFM_CLUSTER_MINDER=${UFM_CLUSTER_MINDER}
CLUSTER_NAME=${CLUSTER_NAME}
PORT=9103
SCRAPE_INTERVAL=30
VERIFY_SSL=false
ENVEOF
    chmod 600 "${UFM_ENV}"
    success "Wrote ${UFM_ENV}"

    cat > "${UFM_SVC_DEST}" <<'SVCEOF'
[Unit]
Description=NVIS UFM Prometheus Exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/nvis-monitoring
EnvironmentFile=/etc/nvis/ufm-exporter.env
ExecStart=/usr/bin/python3 /opt/nvis-monitoring/ufm_exporter.py
Restart=always
RestartSec=15
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ufm-exporter

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl --no-ask-password enable ufm-exporter
    systemctl --no-ask-password restart ufm-exporter
    sleep 3
    if systemctl is-active ufm-exporter &>/dev/null; then
      success "ufm-exporter running on port 9103"
    else
      warn "ufm-exporter may not have started — check: journalctl -u ufm-exporter -n 20"
    fi
    success "Phase 11 complete — metrics at http://localhost:9103/metrics"
  fi
fi

# ===========================================================================
# PHASE 7 — Verification + Summary
# ===========================================================================
if phase_enabled 7; then
  step "PHASE 7: Verification and summary"

  echo ""
  echo -e "${BOLD}── ObsVM containers ──────────────────────────────${NC}"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "^(NAMES|nvis-)" || true

  echo ""
  echo -e "${BOLD}── BCM containers ────────────────────────────────${NC}"
  bcm_ssh "docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E '^(NAMES|nvis-)' 2>/dev/null" 2>/dev/null || warn "Could not query BCM containers"

  if [[ -n "${K8S_MASTER}" ]] && [[ ${#GPU_NODES[@]} -gt 0 ]]; then
    echo ""
    echo -e "${BOLD}── GPU node K8s pods ─────────────────────────────${NC}"
    k8s_cmd "kubectl get pods -n ${NAMESPACE} -o wide" 2>/dev/null || warn "Could not query K8s pods"
  fi

  # Query Prometheus for node count
  echo ""
  info "Querying Prometheus for active nodes..."
  sleep 5  # Give Prometheus a moment to receive first scrapes
  NODE_COUNT="$(no_proxy='*' curl -sf --noproxy '*' "http://localhost:9090/api/v1/query?query=count(count%20by(instance)(node_uname_info))" 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); r=d.get('data',{}).get('result',[]); print(r[0]['value'][1] if r else '0')" 2>/dev/null \
    || echo "unknown")"
  info "Prometheus sees ${NODE_COUNT} node(s) reporting node_uname_info"

  # Write report
  {
    echo "======================================================"
    echo "  NVIS Observability Deployment Report"
    echo "  $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "======================================================"
    echo ""
    echo "Cluster Name   : ${CLUSTER_NAME}"
    echo "ObsVM IP       : ${OBSVM_IP}"
    echo "BCM Host       : ${BCM_HOST}"
    echo "GPU Nodes      : ${GPU_NODES[*]:-none}"
    echo "K8s Namespace  : ${NAMESPACE}"
    echo "Nodes visible  : ${NODE_COUNT}"
    echo ""
    echo "Access:"
    echo "  Grafana        : http://${OBSVM_IP}:3000"
    echo "  Username       : admin"
    echo "  Password       : [as configured]"
    echo "  Prometheus     : http://${OBSVM_IP}:9090"
    echo "  Loki           : http://${OBSVM_IP}:3100"
    echo "  VictoriaMetrics: http://${OBSVM_IP}:8428"
    echo ""
    echo "Useful commands:"
    echo "  docker ps                           # ObsVM containers"
    echo "  docker compose -f ${NVIS_DIR}/docker-compose.yml logs -f"
    echo "  kubectl get pods -n ${NAMESPACE}    # (run on K8s master)"
    echo "  sudo bash ${SCRIPT_DIR}/nvis-setup.sh --reconfigure"
  } | tee "${REPORT_FILE}"

  echo ""
  banner "Deployment Complete"
  echo -e "  ${BOLD}Grafana${NC}         : http://${OBSVM_IP}:3000"
  echo -e "  ${BOLD}Username${NC}        : admin"
  echo -e "  ${BOLD}Prometheus${NC}      : http://${OBSVM_IP}:9090"
  echo -e "  ${BOLD}Loki${NC}            : http://${OBSVM_IP}:3100"
  echo -e "  ${BOLD}Debug log${NC}       : ${LOG_FILE}"
  echo -e "  ${BOLD}Report${NC}          : ${REPORT_FILE}"
  echo ""
fi
