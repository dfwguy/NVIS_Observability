#!/bin/bash
# =============================================================================
# nvis-cleanup.sh — NVIS Observability Stack Complete Teardown
# =============================================================================
# Removes EVERYTHING deployed by nvis-setup.sh for a clean re-install:
#   - GPU K8s namespace + Helm release (via BCM)
#   - BCM: Docker containers, images, /etc/nvis-alloy, helm binary, temp files
#   - GPU nodes: containerd insecure-registry config, temp files
#   - ObsVM: Docker Compose stack + volumes, local registry + data, k3s
#   - nvis-deploy.conf
#
# Usage:
#   sudo bash scripts/nvis-cleanup.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NVIS_DIR="$(dirname "${SCRIPT_DIR}")"
CONF_FILE="${NVIS_DIR}/nvis-deploy.conf"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()     { echo -e "${RED}[ERR ]${NC} $*"; }

# ---------------------------------------------------------------------------
# Load conf (optional — cleanup continues without it)
# ---------------------------------------------------------------------------
NAMESPACE="nvis-monitoring"
BCM_HOST=""; BCM_USER="root"; BCM_JUMP=""; BCM_SSH_KEY=""
K8S_MASTER=""; GPU_SSH_USER="root"; GPU_NODES_CSV=""; OBSVM_IP=""

if [[ -f "${CONF_FILE}" ]]; then
  info "Loading ${CONF_FILE}"
  # shellcheck source=/dev/null
  source "${CONF_FILE}" || true
  success "Config loaded — BCM=${BCM_HOST}, NAMESPACE=${NAMESPACE}"
else
  warn "nvis-deploy.conf not found — BCM/GPU cleanup will be skipped (no connection info)"
  warn "Pass BCM_HOST=x.x.x.x on the command line to override, e.g.:"
  warn "  BCM_HOST=10.63.83.209 BCM_SSH_KEY=/home/user/.ssh/id_ed25519 sudo -E bash scripts/nvis-cleanup.sh"
fi

# Apply defaults
NAMESPACE="${NAMESPACE:-nvis-monitoring}"
BCM_USER="${BCM_USER:-root}"
GPU_SSH_USER="${GPU_SSH_USER:-root}"

# Use env overrides if conf wasn't found
BCM_HOST="${BCM_HOST:-}"
BCM_SSH_KEY="${BCM_SSH_KEY:-}"
GPU_NODES_CSV="${GPU_NODES_CSV:-}"

# Snapshot conf values NOW — Step 7 deletes nvis-deploy.conf before Step 9 runs,
# which caused GPU node Alloy cleanup to be silently skipped.
_SNAP_BCM_HOST="${BCM_HOST}"
_SNAP_BCM_USER="${BCM_USER}"
_SNAP_BCM_SSH_KEY="${BCM_SSH_KEY}"
_SNAP_GPU_NODES_CSV="${GPU_NODES_CSV}"
_SNAP_GPU_SSH_USER="${GPU_SSH_USER}"
_SNAP_NAMESPACE="${NAMESPACE}"
_SNAP_OBSVM_IP="${OBSVM_IP:-}"

# Auto-detect SSH key if not set
if [[ -z "${BCM_SSH_KEY}" ]]; then
  REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
  REAL_HOME="$(getent passwd "${REAL_USER}" 2>/dev/null | cut -d: -f6 || echo "/home/${REAL_USER}")"
  for _k in "${REAL_HOME}/.ssh/id_ed25519" "${REAL_HOME}/.ssh/id_rsa" "/root/.ssh/id_ed25519"; do
    [[ -f "${_k}" ]] && { BCM_SSH_KEY="${_k}"; break; }
  done
fi

# SSH helper for BCM
_bcm_ssh() {
  [[ -z "${BCM_HOST}" ]] && return 1
  local jump_opt=()
  [[ -n "${BCM_JUMP:-}" ]] && jump_opt=(-J "${BCM_JUMP}")
  ssh "${jump_opt[@]}" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -o BatchMode=yes \
    -i "${BCM_SSH_KEY}" \
    "${BCM_USER}@${BCM_HOST}" \
    "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH; $*"
}

# ---------------------------------------------------------------------------
# Step 1 — GPU K8s: Helm uninstall + namespace deletion (via BCM)
# ---------------------------------------------------------------------------
echo ""
info "━━━ Step 1: GPU K8s — Helm uninstall + namespace ━━━"

if [[ -z "${BCM_HOST}" ]]; then
  warn "BCM_HOST not set — skipping Steps 1–3 (no BCM connection info)"
else
  if _bcm_ssh "helm version &>/dev/null && echo ok" 2>/dev/null | grep -q "ok"; then
    info "Uninstalling nvis-gpu-agents Helm release..."
    _bcm_ssh "helm uninstall nvis-gpu-agents -n ${NAMESPACE} 2>/dev/null || true"
    success "Helm uninstall done (or release was not present)"
  else
    warn "helm not found on BCM — skipping Helm uninstall"
    # Still try kubectl
    _bcm_ssh "kubectl delete namespace ${NAMESPACE} --ignore-not-found 2>/dev/null || true" 2>/dev/null || true
  fi

  info "Deleting namespace '${NAMESPACE}'..."
  _bcm_ssh "kubectl delete namespace ${NAMESPACE} --ignore-not-found --timeout=60s 2>/dev/null || true" 2>/dev/null || true
  success "Namespace deletion done"

  # ---------------------------------------------------------------------------
  # Step 2 — BCM: containers, images, config, binaries, temp files
  # ---------------------------------------------------------------------------
  echo ""
  info "━━━ Step 2: BCM containers, images, config, binaries ━━━"

  info "Removing BCM nvis- Docker containers..."
  _bcm_ssh "
    for c in nvis-cadvisor nvis-node-exporter nvis-alloy; do
      docker rm -f \"\$c\" 2>/dev/null && echo \"Removed \$c\" || true
    done
  " 2>/dev/null || true
  success "BCM containers removed"

  info "Removing BCM Docker images (cadvisor, node-exporter, alloy)..."
  _bcm_ssh "
    for img in \
      'gcr.io/cadvisor/cadvisor:v0.49.1' \
      'quay.io/prometheus/node-exporter:v1.8.1' \
      'grafana/alloy:v1.3.0'; do
      docker rmi -f \"\$img\" 2>/dev/null && echo \"Removed \$img\" || true
    done
  " 2>/dev/null || true
  success "BCM images removed"

  info "Removing BCM /etc/nvis-alloy..."
  _bcm_ssh "rm -rf /etc/nvis-alloy" 2>/dev/null || true

  info "Removing BCM helm binary..."
  _bcm_ssh "rm -f /usr/local/bin/helm /usr/local/bin/helm-bin" 2>/dev/null || true

  info "Removing BCM temp files (charts, values, scripts, alloy configs)..."
  _bcm_ssh "rm -rf /tmp/nvis-gpu-agents* /tmp/nvis-helm-values.yaml \
    /tmp/nvis-bcm-alloy.conf /tmp/nvis-bcm-alloy.alloy /tmp/nvis-gpu-alloy-*.alloy \
    /tmp/nvis-containerd-registry.sh /tmp/nvis-bcm-images.tar.gz" 2>/dev/null || true
  success "BCM cleanup done"

  # ---------------------------------------------------------------------------
  # Step 3 — GPU nodes: containerd registry config, temp files
  # ---------------------------------------------------------------------------
  echo ""
  info "━━━ Step 3: GPU nodes — containerd config, temp files ━━━"

  if [[ -z "${GPU_NODES_CSV}" ]]; then
    warn "GPU_NODES_CSV not set — skipping GPU node cleanup"
    warn "If needed, manually run on each node: rm -rf /etc/containerd/certs.d/<obsvm-ip>:5000"
  else
    IFS=',' read -ra _GPU_NODES <<< "${GPU_NODES_CSV}"
    OBSVM_REGISTRY="${OBSVM_IP:-}:5000"
    for node in "${_GPU_NODES[@]}"; do
      info "Cleaning GPU node ${node}..."
      _bcm_ssh "
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ${GPU_SSH_USER}@${node} \
          'rm -rf /etc/containerd/certs.d/${OBSVM_REGISTRY} /tmp/nvis-containerd-registry.sh 2>/dev/null || true
           systemctl --no-ask-password reload containerd 2>/dev/null || true
           echo done'
      " 2>/dev/null && success "GPU node ${node} cleaned" || warn "Could not clean GPU node ${node}"
    done
  fi
fi

# ---------------------------------------------------------------------------
# Step 3b — Terraform destroy (Grafana folder, datasources, dashboards)
#            Must run BEFORE Docker Compose goes down so Grafana is still up.
# ---------------------------------------------------------------------------
echo ""
info "━━━ Step 3b: Terraform destroy — Grafana resources ━━━"

TF_DIR="${NVIS_DIR}/terraform"
if ! command -v terraform &>/dev/null; then
  warn "terraform not found — skipping (Grafana resources will be wiped with the volume)"
elif [[ ! -f "${TF_DIR}/terraform.tfvars" ]]; then
  warn "terraform.tfvars not found — skipping Terraform destroy"
  warn "Grafana resources will be wiped when the Docker volume is removed"
else
  if command -v terraform &>/dev/null && [[ -f "${TF_DIR}/.terraform/terraform.tfstate" || -f "${TF_DIR}/terraform.tfstate" ]]; then
    info "Running terraform destroy..."
    terraform -chdir="${TF_DIR}" destroy -auto-approve -input=false -no-color 2>&1 \
      | grep -E "Destroy complete|Error|error|grafana_" | head -20 || true
    success "Terraform destroy complete"
  else
    info "No Terraform state found — nothing to destroy"
  fi
fi

# ---------------------------------------------------------------------------
# Step 4 — ObsVM Docker Compose stack + volumes
# ---------------------------------------------------------------------------
echo ""
info "━━━ Step 4: ObsVM Docker Compose stack + volumes ━━━"

COMPOSE_FILE=""
[[ -f "${NVIS_DIR}/docker-compose.yml" ]]  && COMPOSE_FILE="${NVIS_DIR}/docker-compose.yml"
[[ -f "${NVIS_DIR}/docker-compose.yaml" ]] && COMPOSE_FILE="${NVIS_DIR}/docker-compose.yaml"

if [[ -n "${COMPOSE_FILE}" ]]; then
  info "Running 'docker compose down -v' (removes containers AND volumes)..."
  (cd "${NVIS_DIR}" && docker compose down -v --remove-orphans) || true
  success "Docker Compose stack + volumes torn down"

  # Also explicitly remove any lingering nvis- containers
  LINGERING="$(docker ps -a --format '{{.Names}}' | grep '^nvis-' 2>/dev/null || true)"
  if [[ -n "${LINGERING}" ]]; then
    info "Removing lingering nvis- containers..."
    echo "${LINGERING}" | xargs docker rm -f 2>/dev/null || true
  fi
else
  warn "No docker-compose.yml found — skipping Compose teardown"
fi

# ---------------------------------------------------------------------------
# Step 5 — ObsVM local Docker registry
# ---------------------------------------------------------------------------
echo ""
info "━━━ Step 5: ObsVM local Docker registry ━━━"

docker rm -f nvis-registry 2>/dev/null && info "nvis-registry container removed" || true

# Remove registry volume
docker volume rm nvis-observability_registry-data registry-data 2>/dev/null || true

info "Removing /var/lib/nvis-registry..."
rm -rf /var/lib/nvis-registry 2>/dev/null || true
success "Registry cleaned"

# ---------------------------------------------------------------------------
# Step 6 — k3s (if installed)
# ---------------------------------------------------------------------------
echo ""
info "━━━ Step 6: k3s ━━━"

if [[ -x /usr/local/bin/k3s ]]; then
  info "k3s found — stopping and removing..."
  systemctl --no-ask-password stop k3s k3s-agent 2>/dev/null || true
  systemctl --no-ask-password disable k3s k3s-agent 2>/dev/null || true
  rm -f /usr/local/bin/k3s /usr/local/bin/kubectl-bin /etc/systemd/system/k3s.service || true
  systemctl daemon-reload || true
  rm -rf /etc/rancher /var/lib/rancher /run/k3s || true
  success "k3s removed"
else
  info "k3s not installed — skipping"
fi

# ---------------------------------------------------------------------------
# Step 7 — Generated config + log files
# ---------------------------------------------------------------------------
echo ""
info "━━━ Step 7: Generated configs and temp files ━━━"

rm -f "${CONF_FILE}" && info "nvis-deploy.conf removed" || true
rm -f "${NVIS_DIR}/.env" 2>/dev/null || true
# Installer-generated config files (regenerated on fresh install)
rm -f "${NVIS_DIR}/docker-compose.yml" 2>/dev/null || true
rm -f "${NVIS_DIR}/prometheus/prometheus.yml" 2>/dev/null || true
rm -f "${NVIS_DIR}/grafana-provisioning/datasources/datasources.yaml" 2>/dev/null || true
# Installer debug/report logs
rm -f "${NVIS_DIR}"/nvis-setup-debug-*.log "${NVIS_DIR}"/nvis-setup-report-*.txt 2>/dev/null || true
# ObsVM /tmp files (both old .conf and new .alloy naming)
rm -f /tmp/nvis_grafana_cookies.txt \
      /tmp/nvis-bcm-alloy.conf /tmp/nvis-bcm-alloy.alloy \
      /tmp/nvis-helm-values.yaml \
      /tmp/nvis-containerd-registry.sh \
      /tmp/nvis-gpu-agents-chart.tar.gz \
      /tmp/helm-bin 2>/dev/null || true
success "Temp files cleaned"

# ---------------------------------------------------------------------------
# Step 7b — ObsVM native systemd exporters (node_exporter, redfish, ufm)
# These may have been installed as systemd services directly on ObsVM
# ---------------------------------------------------------------------------
echo ""
info "━━━ Step 7b: ObsVM native systemd exporters ━━━"

for _svc in node_exporter redfish-exporter ufm-exporter; do
  if systemctl list-unit-files "${_svc}.service" &>/dev/null 2>&1 | grep -q "${_svc}"; then
    systemctl --no-ask-password stop    "${_svc}" 2>/dev/null || true
    systemctl --no-ask-password disable "${_svc}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${_svc}.service"
    info "${_svc} removed"
  fi
done

# node_exporter: only remove if WE installed it (binary under /usr/local/node_exporter/)
# If it was installed by Run.ai, kube-prometheus, or a package manager — leave it alone
_NE_BIN="$(readlink -f /usr/local/bin/node_exporter 2>/dev/null || true)"
if [[ "${_NE_BIN}" == /usr/local/node_exporter/* ]]; then
  systemctl --no-ask-password stop    node_exporter 2>/dev/null || true
  systemctl --no-ask-password disable node_exporter 2>/dev/null || true
  rm -f /etc/systemd/system/node_exporter.service
  rm -f /usr/local/bin/node_exporter
  rm -rf /usr/local/node_exporter
  info "node_exporter removed (was nvis-installed)"
else
  info "node_exporter present but not nvis-installed — leaving intact"
fi

# Remove binaries and config dirs
rm -rf /opt/nvis-monitoring
rm -rf /etc/nvis
systemctl daemon-reload 2>/dev/null || true
success "ObsVM native exporters cleaned"

# Step 8 — CMDaemon exporter (Phase 8 of nvis-setup.sh)
# ---------------------------------------------------------------------------
echo ""
info "━━━ Step 8: CMDaemon exporter (ObsVM) ━━━"

systemctl --no-ask-password stop cmdaemon-exporter 2>/dev/null && info "cmdaemon-exporter stopped" || true
systemctl --no-ask-password disable cmdaemon-exporter 2>/dev/null || true
rm -f /etc/systemd/system/cmdaemon-exporter.service && info "cmdaemon-exporter.service removed" || true
rm -f /opt/nvis-monitoring/cmdaemon_exporter.py && info "cmdaemon_exporter.py removed" || true
rm -f /etc/nvis/cmdaemon-exporter.env && info "cmdaemon-exporter.env removed" || true
systemctl daemon-reload 2>/dev/null || true
success "CMDaemon exporter cleaned"

# ---------------------------------------------------------------------------
# Step 9 — Alloy log forwarders: BCM head node + GPU nodes (Phase 9)
# ---------------------------------------------------------------------------
echo ""
info "━━━ Step 9: Alloy log forwarders (BCM + GPU nodes) ━━━"

# Use snapshotted vars (nvis-deploy.conf was deleted in Step 7)
BCM_HOST="${_SNAP_BCM_HOST}"
BCM_USER="${_SNAP_BCM_USER}"
BCM_SSH_KEY="${_SNAP_BCM_SSH_KEY}"
GPU_NODES_CSV="${_SNAP_GPU_NODES_CSV}"
GPU_SSH_USER="${_SNAP_GPU_SSH_USER}"

if [[ -z "${BCM_HOST}" ]]; then
  warn "BCM_HOST not set — skipping Alloy cleanup on BCM and GPU nodes"
else
  # BCM head node — stop/disable alloy.service and remove config, binary, data dir
  info "Removing Alloy from BCM head node..."
  _bcm_ssh "
    systemctl --no-ask-password stop alloy 2>/dev/null || true
    systemctl --no-ask-password disable alloy 2>/dev/null || true
    rm -f /etc/systemd/system/alloy.service 2>/dev/null || true
    rm -rf /etc/alloy /var/lib/alloy 2>/dev/null || true
    rm -f /usr/local/bin/alloy 2>/dev/null || true
    systemctl reset-failed alloy 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    echo bcm-alloy-done
  " 2>/dev/null && success "BCM Alloy removed" || warn "BCM Alloy cleanup had errors (may not have been installed)"

  # GPU nodes — stop/disable alloy-nvis-logs.service and remove config
  if [[ -z "${GPU_NODES_CSV}" ]]; then
    warn "GPU_NODES_CSV not set — skipping GPU node Alloy cleanup"
  else
    IFS=',' read -ra _ALLOY_NODES <<< "${GPU_NODES_CSV}"
    for node in "${_ALLOY_NODES[@]}"; do
      info "Removing alloy-nvis-logs from GPU node ${node}..."
      _bcm_ssh "
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ${GPU_SSH_USER}@${node} \
          'systemctl --no-ask-password stop alloy-nvis-logs 2>/dev/null || true
           systemctl --no-ask-password disable alloy-nvis-logs 2>/dev/null || true
           rm -f /etc/systemd/system/alloy-nvis-logs.service 2>/dev/null || true
           rm -rf /etc/alloy /var/lib/alloy 2>/dev/null || true
           rm -f /usr/local/bin/alloy 2>/dev/null || true
           systemctl reset-failed alloy-nvis-logs 2>/dev/null || true
           systemctl daemon-reload 2>/dev/null || true
           echo done'
      " 2>/dev/null && success "GPU node ${node} Alloy removed" || warn "Could not clean Alloy from GPU node ${node}"
    done
  fi
fi

# ---------------------------------------------------------------------------
# Step 10 — Optional ObsVM image cleanup hint
# ---------------------------------------------------------------------------
echo ""
info "━━━ Step 10: ObsVM Docker images (manual) ━━━"
echo -e "${YELLOW}To also remove ObsVM Docker images (saves disk, slows next install):${NC}"
echo "  docker rmi -f registry:2 grafana/loki:3.1.0 prom/prometheus:v2.54.1 \\"
echo "    grafana/grafana:11.1.4 victoriametrics/victoria-metrics:v1.103.0 \\"
echo "    quay.io/prometheus/node-exporter:v1.8.1 grafana/alloy:v1.3.0 \\"
echo "    gcr.io/cadvisor/cadvisor:v0.49.1 alpine/helm:3.15.4"
echo "(Skipped by default — images are cached for faster re-install)"

# ---------------------------------------------------------------------------
# Step 11 — Post-uninstall validation
# ---------------------------------------------------------------------------
echo ""
info "━━━ Step 11: Post-uninstall validation ━━━"

_PASS=0; _FAIL=0
_chk() {
  local label="$1"; local cmd="$2"; local expect_empty="${3:-yes}"
  local out
  out="$(eval "$cmd" 2>&1 | grep -v '^$' || true)"
  if [[ "${expect_empty}" == "yes" ]]; then
    if [[ -z "$out" ]]; then
      echo -e "  ${GREEN}OK  ${NC} ${label}"
      (( _PASS++ )) || true
    else
      echo -e "  ${RED}FAIL${NC} ${label}"
      echo "       → ${out}" | head -3
      (( _FAIL++ )) || true
    fi
  else
    # expect_empty=no: command output IS the pass/fail indicator (non-empty = pass)
    if [[ -n "$out" ]]; then
      echo -e "  ${GREEN}OK  ${NC} ${label}"
      (( _PASS++ )) || true
    else
      echo -e "  ${RED}FAIL${NC} ${label}"
      (( _FAIL++ )) || true
    fi
  fi
}

echo ""
echo -e "  ${BLUE}--- ObsVM: Docker ---${NC}"
_chk "No nvis- containers"    "docker ps -a --format '{{.Names}}' | grep '^nvis-'"
_chk "No nvis- volumes"       "docker volume ls --format '{{.Name}}' | grep nvis"
_chk "No nvis-registry"       "docker ps -a --format '{{.Names}}' | grep 'nvis-registry\|^registry'"

echo ""
echo -e "  ${BLUE}--- ObsVM: systemd services ---${NC}"
for _svc in node_exporter cmdaemon-exporter redfish-exporter ufm-exporter; do
  _chk "Service gone: ${_svc}" \
    "systemctl list-unit-files ${_svc}.service 2>/dev/null | grep -v '^$' | grep -v 'unit files listed' | grep '${_svc}'"
done

echo ""
echo -e "  ${BLUE}--- ObsVM: files and dirs ---${NC}"
_chk "Gone: /etc/nvis"              "[ -e /etc/nvis ] && echo exists"
_chk "Gone: /opt/nvis-monitoring"   "[ -e /opt/nvis-monitoring ] && echo exists"
_chk "Gone: /var/lib/nvis-registry" "[ -e /var/lib/nvis-registry ] && echo exists"
_chk "Gone: nvis-deploy.conf"       "[ -f '${NVIS_DIR}/nvis-deploy.conf' ] && echo exists"
_chk "Gone: docker-compose.yml"     "[ -f '${NVIS_DIR}/docker-compose.yml' ] && echo exists"
_chk "Gone: prometheus/prometheus.yml" \
  "[ -f '${NVIS_DIR}/prometheus/prometheus.yml' ] && echo exists"
_chk "Gone: grafana-provisioning/datasources/datasources.yaml" \
  "[ -f '${NVIS_DIR}/grafana-provisioning/datasources/datasources.yaml' ] && echo exists"

echo ""
echo -e "  ${BLUE}--- ObsVM: ports ---${NC}"
_chk "Port 9090 (Prometheus) down" "curl -sf --max-time 3 http://localhost:9090/-/healthy && echo up"
_chk "Port 3000 (Grafana) down"    "curl -sf --max-time 3 http://localhost:3000/api/health && echo up"
_chk "Port 3100 (Loki) down"       "curl -sf --max-time 3 http://localhost:3100/ready && echo up"

echo ""
echo -e "  ${BLUE}--- BCM: ${_SNAP_BCM_HOST:-not configured} ---${NC}"
if [[ -z "${_SNAP_BCM_HOST}" ]]; then
  echo -e "  ${YELLOW}SKIP${NC} BCM checks — BCM_HOST not set"
else
  _bcm_check() {
    local label="$1"; local cmd="$2"
    local out
    out="$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
           -i "${_SNAP_BCM_SSH_KEY}" \
           "${_SNAP_BCM_USER}@${_SNAP_BCM_HOST}" \
           "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH; $cmd" 2>&1 \
         | grep -v '^$' || true)"
    if [[ -z "$out" ]]; then
      echo -e "  ${GREEN}OK  ${NC} ${label}"
      (( _PASS++ )) || true
    else
      echo -e "  ${RED}FAIL${NC} ${label}"
      echo "       → ${out}" | head -3
      (( _FAIL++ )) || true
    fi
  }
  _bcm_check "BCM alloy service gone"       "systemctl is-active alloy 2>&1 | grep -v 'inactive\|Unit.*not found'"
  _bcm_check "BCM /etc/alloy gone"          "[ -e /etc/alloy ] && echo exists"
  _bcm_check "BCM /etc/nvis-alloy gone"     "[ -e /etc/nvis-alloy ] && echo exists"
  _bcm_check "BCM /usr/local/bin/alloy gone" "[ -f /usr/local/bin/alloy ] && echo exists"
  _bcm_check "BCM nvis- containers gone"    "docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^nvis-'"
  _bcm_check "BCM helm gone"                "[ -f /usr/local/bin/helm ] && echo exists"
fi

echo ""
echo -e "  ${BLUE}--- GPU nodes ---${NC}"
if [[ -z "${_SNAP_BCM_HOST}" || -z "${_SNAP_GPU_NODES_CSV}" ]]; then
  echo -e "  ${YELLOW}SKIP${NC} GPU node checks — BCM_HOST or GPU_NODES_CSV not set"
else
  IFS=',' read -ra _VAL_NODES <<< "${_SNAP_GPU_NODES_CSV}"
  for _vnode in "${_VAL_NODES[@]}"; do
    _gpu_check() {
      local label="$1"; local cmd="$2"
      local out
      out="$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
             -i "${_SNAP_BCM_SSH_KEY}" \
             "${_SNAP_BCM_USER}@${_SNAP_BCM_HOST}" \
             "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 ${_SNAP_GPU_SSH_USER}@${_vnode} '$cmd'" \
             2>&1 | grep -v '^$' || true)"
      if [[ -z "$out" ]]; then
        echo -e "  ${GREEN}OK  ${NC} ${_vnode}: ${label}"
        (( _PASS++ )) || true
      else
        echo -e "  ${RED}FAIL${NC} ${_vnode}: ${label}"
        echo "       → ${out}" | head -2
        (( _FAIL++ )) || true
      fi
    }
    _gpu_check "alloy-nvis-logs unit gone"     "systemctl list-unit-files alloy-nvis-logs.service 2>/dev/null | grep alloy-nvis-logs"
    _gpu_check "/etc/alloy gone"               "[ -e /etc/alloy ] && echo exists"
    _gpu_check "/usr/local/bin/alloy gone"     "[ -f /usr/local/bin/alloy ] && echo exists"
  done
fi

echo ""
echo -e "  ${BLUE}--- Kubernetes ---${NC}"
if command -v kubectl &>/dev/null; then
  _ns_out="$(kubectl get namespace "${_SNAP_NAMESPACE}" 2>&1 || true)"
  if echo "${_ns_out}" | grep -q "NotFound"; then
    echo -e "  ${GREEN}OK  ${NC} Namespace '${_SNAP_NAMESPACE}' gone"
    (( _PASS++ )) || true
  else
    echo -e "  ${RED}FAIL${NC} Namespace '${_SNAP_NAMESPACE}' still exists"
    (( _FAIL++ )) || true
  fi
else
  echo -e "  ${YELLOW}SKIP${NC} kubectl not found"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [[ ${_FAIL} -eq 0 ]]; then
  echo -e "${GREEN}  Validation PASSED — ${_PASS} checks OK, 0 failures${NC}"
  echo -e "${GREEN}  Ready for fresh install${NC}"
else
  echo -e "${RED}  Validation INCOMPLETE — ${_PASS} OK, ${_FAIL} FAILED${NC}"
  echo -e "${YELLOW}  Resolve the FAIL items above before reinstalling${NC}"
fi
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
[[ ${_FAIL} -eq 0 ]] && echo -e "To reinstall, run:  ${BLUE}tar -xzf <OBBB.tar.gz> && sudo bash nvis-observability/scripts/nvis-setup.sh${NC}" || true
echo ""

# ---------------------------------------------------------------------------
# Final — Remove nvis-observability directory for a clean re-extract
# Must be last: we cd away first since we're running from inside it.
# ---------------------------------------------------------------------------
if [[ ${_FAIL} -eq 0 ]]; then
  echo ""
  info "Removing ${NVIS_DIR} for clean re-extract..."
  cd / && rm -rf "${NVIS_DIR}" && \
    echo -e "${GREEN}[ OK ]${NC} ${NVIS_DIR} removed — ready for fresh untar" || \
    echo -e "${YELLOW}[WARN]${NC} Could not remove ${NVIS_DIR} — remove manually: rm -rf ${NVIS_DIR}"
  echo ""
fi
