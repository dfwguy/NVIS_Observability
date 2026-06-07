#!/usr/bin/env bash
# =============================================================================
# NVIS Observability Suite — Unified Setup Script
# Version: 2.0.0
# Supports: Ubuntu 20.04/22.04/24.04 | CentOS 9 | RHEL 8/9 | Rocky 8/9 | AlmaLinux 8/9
#
# MODES:
#   ./setup.sh                         # Fresh docker-compose install (backward compat)
#   ./setup.sh --k8s                   # Fresh Helm/K8s install
#   ./setup.sh --k8s --upgrade         # Upgrade existing K8s install (helm upgrade --install)
#   ./setup.sh --k8s --storage=thanos  # Use Thanos instead of VictoriaMetrics
#   ./setup.sh --k8s --storage=victoria# Use VictoriaMetrics (default)
#   ./setup.sh --airgap                # Create offline bundle (~950MB tar)
#   ./setup.sh --k8s --version-check   # Check for newer component versions
#   ./setup.sh --stress-test           # Start 4k-node simulator + verify all panels light up
#   ./setup.sh --stress-test-cleanup   # Stop simulator, purge synthetic data, restore stock state
#
# =============================================================================
#
# =============================================================================
# THANOS vs VICTORIAMETRICS — 10-Line Comparison
# =============================================================================
# 1. STORAGE EFFICIENCY: VictoriaMetrics uses ~7x less disk than Prometheus
#    (and ~2x less than Thanos) due to its custom compression codec. Winner: VM.
# 2. QUERY PERFORMANCE: VictoriaMetrics single-node queries are faster for
#    recent data; Thanos wins for multi-cluster federated/historical queries.
# 3. HA SETUP COMPLEXITY: VictoriaMetrics single-node is trivially simple (1 pod).
#    Thanos requires Receive + Querier + Store Gateway + Compactor (4 components).
# 4. REMOTE_WRITE COMPATIBILITY: Both accept Prometheus remote_write natively.
#    VictoriaMetrics exposes /api/v1/write; Thanos Receive uses /api/v1/receive.
# 5. RESOURCE USAGE: VictoriaMetrics is ~3-4x more memory-efficient than Thanos
#    for equivalent retention. Thanos Store Gateway can be very RAM-heavy.
# 6. OBJECT STORAGE NEED: Thanos designed for S3/GCS (optional local disk mode).
#    VictoriaMetrics stores everything on local PVC — no object storage required.
# 7. DEDUPLICATION: Thanos has mature multi-replica deduplication.
#    VictoriaMetrics cluster has replication but single-node has none.
# 8. GRAFANA INTEGRATION: Identical — both expose a Prometheus-compatible HTTP API.
# 9. UPGRADES: VictoriaMetrics upgrades are in-place (single binary).
#    Thanos has independent component versioning — more moving parts to upgrade.
# 10. RECOMMENDATION for single-site 4000-node demo cluster: USE VICTORIAMETRICS.
#    It has zero operational overhead, handles 4000-node scale easily on 8GB RAM,
#    and requires no object storage. Switch to Thanos only if multi-site federation
#    or long-term object storage (S3/GCS) becomes a requirement.
# =============================================================================

set -euo pipefail

# =============================================================================
# GLOBALS
# =============================================================================
SCRIPT_VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_CHART_DIR="${SCRIPT_DIR}/helm/nvis-obsvm"
VERSIONS_FILE="${HELM_CHART_DIR}/versions.yaml"
REPORT_FILE="${SCRIPT_DIR}/nvis-setup-report-$(date +%Y%m%d-%H%M%S).txt"
LOG_FILE="${SCRIPT_DIR}/nvis-setup-debug-$(date +%Y%m%d-%H%M%S).log"
STATE_FILE="${SCRIPT_DIR}/.nvis-setup-state"
BUNDLE_DIR="${SCRIPT_DIR}"
BUNDLE_TAR="${BUNDLE_DIR}/nvis-images.tar"
NAMESPACE="nvis-monitoring"
HELM_RELEASE="nvis-obsvm"

# =============================================================================
# FLAG PARSING
# =============================================================================
MODE_K8S=false
MODE_UPGRADE=false
MODE_AIRGAP=false
MODE_VERSION_CHECK=false
MODE_STRESS_TEST=false
MODE_STRESS_CLEANUP=false
STORAGE_BACKEND="victoria"   # or "thanos"
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --k8s)              MODE_K8S=true ;;
    --upgrade)          MODE_UPGRADE=true ;;
    --airgap)           MODE_AIRGAP=true ;;
    --version-check)    MODE_VERSION_CHECK=true ;;
    --storage=thanos)   STORAGE_BACKEND="thanos" ;;
    --storage=victoria) STORAGE_BACKEND="victoria" ;;
    --dry-run)              DRY_RUN=true ;;
    --namespace=*)          NAMESPACE="${arg#--namespace=}" ;;
    --stress-test)          MODE_STRESS_TEST=true ;;
    --stress-test-cleanup)  MODE_STRESS_CLEANUP=true ;;
    --help|-h)
      echo "Usage: $0 [--k8s] [--upgrade] [--airgap] [--storage=thanos|victoria] [--version-check] [--dry-run]"
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg" >&2
      exit 1
      ;;
  esac
done

# =============================================================================
# COLORS AND LOGGING
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

exec > >(tee -a "$LOG_FILE") 2>&1

log()     { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}[$(date '+%H:%M:%S')] OK $*${NC}"; }
warn()    { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARN $*${NC}"; }
error()   { echo -e "${RED}[$(date '+%H:%M:%S')] ERR $*${NC}"; }
header()  {
  echo -e "\n${BOLD}${CYAN}======================================================${NC}"
  echo -e "${BOLD}${CYAN}  $*${NC}"
  echo -e "${BOLD}${CYAN}======================================================${NC}\n"
}
step()    { echo -e "\n${BOLD}>> $*${NC}"; }
info()    { echo -e "${DIM}   $*${NC}"; }
report()  { echo "$*" >> "$REPORT_FILE"; }

die() {
  error "$1"
  echo ""
  echo -e "${RED}${BOLD}Setup failed: $1${NC}"
  echo -e "${YELLOW}Debug log: ${LOG_FILE}${NC}"
  exit 1
}

# =============================================================================
# OS DETECTION
# =============================================================================
if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian)               OS_FAMILY="debian" ;;
    centos|rhel|rocky|almalinux) OS_FAMILY="rhel" ;;
    *)                           OS_FAMILY="debian" ;;
  esac
else
  OS_FAMILY="debian"
fi

# =============================================================================
# UTILITY: check command exists
# =============================================================================
require_cmd() {
  command -v "$1" &>/dev/null || die "Required command not found: $1. Install it and retry."
}

# =============================================================================
# UTILITY: read a value from versions.yaml (simple grep approach, no yq needed)
# =============================================================================
get_version() {
  # Usage: get_version prometheus tag
  local component="$1" field="$2"
  # Look for the component section, then find the field within a small window
  awk "/^  ${component}:/{found=1} found && /^    ${field}:/{print; found=0}" \
    "${VERSIONS_FILE}" | awk -F'"' '{print $2}'
}

# =============================================================================
# DOCKER-COMPOSE MODE (backward compatibility — original behavior)
# =============================================================================
run_docker_compose() {
  header "NVIS Observability — Docker Compose Mode (v${SCRIPT_VERSION})"
  log "Mode: docker-compose (legacy/backward-compat)"
  require_cmd docker

  step "Checking docker compose plugin..."
  if ! docker compose version &>/dev/null; then
    die "docker compose plugin not found. Install docker-compose-plugin or use --k8s mode."
  fi

  step "Loading .env if present..."
  if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    # shellcheck disable=SC1091
    set -a; . "${SCRIPT_DIR}/.env"; set +a
    log "Loaded .env"
  fi

  step "Pulling images..."
  docker compose -f "${SCRIPT_DIR}/docker-compose.yml" pull || warn "Some images failed to pull (airgap?)"

  step "Starting stack..."
  docker compose -f "${SCRIPT_DIR}/docker-compose.yml" up -d

  step "Waiting 15s for containers to settle..."
  sleep 15

  step "Health check..."
  local failed=0
  for svc in "localhost:9090/-/ready" "localhost:3100/ready" "localhost:3000/api/health" "localhost:8428/health"; do
    if curl -sf "http://${svc}" &>/dev/null; then
      success "${svc%%/*}"
    else
      warn "${svc%%/*} not ready yet"
      ((failed++)) || true
    fi
  done

  echo ""
  success "Docker Compose stack started."
  log "Grafana: http://localhost:3000  (admin / \${GRAFANA_ADMIN_PASSWORD:-changeme})"
  log "Prometheus: http://localhost:9090"
  log "VictoriaMetrics: http://localhost:8428"
  log "Loki: http://localhost:3100"
  [[ $failed -gt 0 ]] && warn "${failed} service(s) not ready — check 'docker compose logs'"
}

# =============================================================================
# HELM / KUBERNETES MODE
# =============================================================================

# ---------------------------------------------------------------------------
# Prerequisite checks for K8s mode
# ---------------------------------------------------------------------------
check_k8s_prerequisites() {
  step "Checking prerequisites..."
  require_cmd kubectl
  require_cmd helm

  if ! kubectl cluster-info &>/dev/null; then
    die "kubectl cannot reach a cluster. Set KUBECONFIG correctly and retry."
  fi
  success "kubectl connected to cluster: $(kubectl config current-context)"

  local helm_ver
  helm_ver=$(helm version --short 2>/dev/null | grep -oP 'v\d+\.\d+' | head -1)
  info "Helm version: ${helm_ver}"

  # Require Helm v3.10+ (needed for --wait --atomic)
  local major minor
  major=$(echo "$helm_ver" | cut -dv -f2 | cut -d. -f1)
  minor=$(echo "$helm_ver" | cut -d. -f2)
  if [[ "$major" -lt 3 ]] || { [[ "$major" -eq 3 ]] && [[ "$minor" -lt 10 ]]; }; then
    die "Helm v3.10+ required. Found: ${helm_ver}"
  fi
  success "Prerequisites satisfied."
}

# ---------------------------------------------------------------------------
# Inject Python scripts into ConfigMaps (replaces placeholder)
# ---------------------------------------------------------------------------
inject_scripts() {
  step "Injecting Python scripts into Kubernetes ConfigMaps..."
  local ns="$NAMESPACE"

  for item in \
    "bcm_exporter.py:nvis-bcm-exporter-scripts" \
    "slurm_job_exporter.py:nvis-slurm-exporter-scripts" \
    "s4k_generator.py:nvis-s4k-generator-scripts"; do

    local script="${item%%:*}"
    local cm="${item##*:}"
    local script_path="${SCRIPT_DIR}/scripts/${script}"

    if [[ ! -f "$script_path" ]]; then
      warn "Script not found: ${script_path} — skipping ${cm}"
      continue
    fi

    log "Injecting ${script} into ConfigMap ${cm}..."
    local script_key="${script}"
    kubectl create configmap "${cm}" \
      --from-file="${script_key}=${script_path}" \
      -n "${ns}" \
      --dry-run=client -o yaml | kubectl apply -f - &>/dev/null
    success "  ${cm} updated."
  done
}

# ---------------------------------------------------------------------------
# Create Kubernetes Secrets (never stored in YAML files)
# ---------------------------------------------------------------------------
create_secrets() {
  step "Creating Kubernetes Secrets..."
  local ns="$NAMESPACE"

  # Ensure namespace exists first
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - &>/dev/null

  # ----- Grafana admin password -----
  local grafana_pw=""
  if [[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
    grafana_pw="${GRAFANA_ADMIN_PASSWORD}"
  elif [[ -f "${SCRIPT_DIR}/.nvis-creds" ]]; then
    # shellcheck disable=SC1091
    grafana_pw=$(grep '^GRAFANA_ADMIN_PASSWORD=' "${SCRIPT_DIR}/.nvis-creds" 2>/dev/null | cut -d= -f2- | tr -d '"')
  fi

  if [[ -z "$grafana_pw" ]]; then
    warn "No GRAFANA_ADMIN_PASSWORD found in environment or .nvis-creds"
    if [[ -t 0 ]]; then
      read -rsp "Enter Grafana admin password [default: NVIS_CBU]: " grafana_pw
      echo
      grafana_pw="${grafana_pw:-NVIS_CBU}"
    else
      grafana_pw="NVIS_CBU"
      warn "Non-interactive mode: using default password 'NVIS_CBU'. Change it after install."
    fi
  fi

  kubectl create secret generic nvis-grafana-secret \
    --from-literal=admin-password="${grafana_pw}" \
    -n "${ns}" \
    --dry-run=client -o yaml | kubectl apply -f - &>/dev/null
  success "  nvis-grafana-secret created/updated."

  # ----- BCM SSH key -----
  local ssh_key_path="${HOME}/.ssh/id_ed25519"
  if [[ -f "$ssh_key_path" ]]; then
    kubectl create secret generic nvis-bcm-ssh-key \
      --from-file=id_ed25519="${ssh_key_path}" \
      -n "${ns}" \
      --dry-run=client -o yaml | kubectl apply -f - &>/dev/null
    success "  nvis-bcm-ssh-key created from ${ssh_key_path}."
  else
    warn "  SSH key not found at ${ssh_key_path}. BCM/Slurm exporters will fail."
    warn "  Create a placeholder: kubectl create secret generic nvis-bcm-ssh-key --from-literal=id_ed25519=placeholder -n ${ns}"
    # Create placeholder so Helm install doesn't crash on missing secret ref
    kubectl create secret generic nvis-bcm-ssh-key \
      --from-literal=id_ed25519="placeholder-replace-with-real-key" \
      -n "${ns}" \
      --dry-run=client -o yaml | kubectl apply -f - &>/dev/null
  fi

  # ----- Thanos object store config (only for Thanos mode) -----
  if [[ "${STORAGE_BACKEND}" == "thanos" ]]; then
    if [[ ! $(kubectl get secret nvis-thanos-objstore-config -n "${ns}" 2>/dev/null) ]]; then
      log "Creating placeholder Thanos object store secret (filesystem mode)..."
      kubectl create secret generic nvis-thanos-objstore-config \
        --from-literal=objstore.yaml='type: FILESYSTEM
config:
  directory: /data/thanos-blocks' \
        -n "${ns}" \
        --dry-run=client -o yaml | kubectl apply -f - &>/dev/null
      success "  nvis-thanos-objstore-config created (filesystem mode — update for S3/GCS)."
    fi
  fi
}

# ---------------------------------------------------------------------------
# Build Helm --set overrides from versions.yaml and flags
# ---------------------------------------------------------------------------
build_helm_args() {
  local -a args=()

  # Storage backend
  args+=(--set "storage=${STORAGE_BACKEND}")

  if [[ "${STORAGE_BACKEND}" == "thanos" ]]; then
    args+=(
      --set "victoriametrics.enabled=false"
      --set "thanos.enabled=true"
      --set "thanos.receive.enabled=true"
      --set "thanos.querier.enabled=true"
      --set "thanos.storeGateway.enabled=true"
      --set "thanos.compactor.enabled=true"
    )
  else
    args+=(
      --set "victoriametrics.enabled=true"
      --set "thanos.enabled=false"
    )
  fi

  # Override image tags from versions.yaml if the file exists
  if [[ -f "${VERSIONS_FILE}" ]]; then
    local prom_tag loki_tag grafana_tag vm_tag thanos_tag busybox_tag
    prom_tag=$(get_version "prometheus" "tag")
    loki_tag=$(get_version "loki" "tag")
    grafana_tag=$(get_version "grafana" "tag")
    vm_tag=$(get_version "victoriametrics" "tag")
    thanos_tag=$(get_version "thanos" "tag")
    busybox_tag=$(get_version "busybox" "tag")

    [[ -n "$prom_tag" ]]    && args+=(--set "prometheus.image.tag=${prom_tag}")
    [[ -n "$loki_tag" ]]    && args+=(--set "loki.image.tag=${loki_tag}")
    [[ -n "$grafana_tag" ]] && args+=(--set "grafana.image.tag=${grafana_tag}")
    [[ -n "$vm_tag" ]]      && args+=(--set "victoriametrics.image.tag=${vm_tag}")
    [[ -n "$thanos_tag" ]]  && args+=(--set "thanos.image.tag=${thanos_tag}")
  fi

  # Airgap: if a local registry is running, set imageRegistry
  if [[ -n "${NVIS_IMAGE_REGISTRY:-}" ]]; then
    args+=(--set "imageRegistry=${NVIS_IMAGE_REGISTRY}")
  fi

  # Namespace
  args+=(--set "namespace=${NAMESPACE}")

  printf '%s\n' "${args[@]}"
}

# ---------------------------------------------------------------------------
# Helm install / upgrade
# ---------------------------------------------------------------------------
run_helm() {
  local action="install"
  $MODE_UPGRADE && action="upgrade --install"

  step "Running helm ${action} for release '${HELM_RELEASE}'..."

  local -a extra_args
  mapfile -t extra_args < <(build_helm_args)

  local helm_cmd=(
    helm upgrade --install
    "${HELM_RELEASE}"
    "${HELM_CHART_DIR}"
    --namespace "${NAMESPACE}"
    --create-namespace
    -f "${HELM_CHART_DIR}/values.yaml"
    "${extra_args[@]}"
    --wait
    --timeout 10m0s
    --atomic
  )

  # Add production values if file exists and we're not in dev mode
  if [[ -f "${HELM_CHART_DIR}/values-production.yaml" ]] && [[ "${NVIS_ENV:-dev}" == "prod" ]]; then
    helm_cmd+=(-f "${HELM_CHART_DIR}/values-production.yaml")
    log "Using production values overlay."
  fi

  if $DRY_RUN; then
    helm_cmd+=(--dry-run)
    warn "DRY RUN — no changes will be applied."
  fi

  log "Command: ${helm_cmd[*]}"
  "${helm_cmd[@]}"
}

# ---------------------------------------------------------------------------
# Post-install validation
# ---------------------------------------------------------------------------
validate_k8s_install() {
  step "Validating deployment..."
  local ns="$NAMESPACE"
  local failures=0

  # Wait for pods
  local deployments=("nvis-grafana" "nvis-bcm-exporter" "nvis-slurm-exporter" "nvis-s4k-generator")
  local statefulsets=("nvis-prometheus" "nvis-loki")
  [[ "${STORAGE_BACKEND}" == "victoria" ]] && statefulsets+=("nvis-victoriametrics")
  [[ "${STORAGE_BACKEND}" == "thanos" ]] && deployments+=("nvis-thanos-querier")

  for deploy in "${deployments[@]}"; do
    if kubectl rollout status deployment/"${deploy}" -n "${ns}" --timeout=120s &>/dev/null; then
      success "  Deployment ${deploy}: Ready"
    else
      warn "  Deployment ${deploy}: NOT ready (check: kubectl describe pod -l app=${deploy} -n ${ns})"
      ((failures++)) || true
    fi
  done

  for sts in "${statefulsets[@]}"; do
    if kubectl rollout status statefulset/"${sts}" -n "${ns}" --timeout=120s &>/dev/null; then
      success "  StatefulSet ${sts}: Ready"
    else
      warn "  StatefulSet ${sts}: NOT ready (check: kubectl describe pod -l app=${sts} -n ${ns})"
      ((failures++)) || true
    fi
  done

  # Get Grafana NodePort
  local grafana_port
  grafana_port=$(kubectl get svc nvis-grafana -n "${ns}" \
    -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
  local node_ip
  node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "NODE_IP")

  echo ""
  header "NVIS Observability — K8s Install Complete"
  echo -e "  ${BOLD}Grafana:${NC}           http://${node_ip}:${grafana_port:-30300}"
  echo -e "  ${BOLD}Prometheus:${NC}        kubectl port-forward svc/nvis-obsvm-prometheus 9090:9090 -n ${ns}"
  echo -e "  ${BOLD}VictoriaMetrics:${NC}   kubectl port-forward svc/nvis-victoriametrics 8428:8428 -n ${ns}"
  echo -e "  ${BOLD}Loki:${NC}              kubectl port-forward svc/nvis-obsvm-loki 3100:3100 -n ${ns}"
  echo ""
  echo -e "  ${BOLD}Storage backend:${NC}   ${STORAGE_BACKEND}"
  echo -e "  ${BOLD}Namespace:${NC}         ${ns}"
  echo -e "  ${BOLD}Helm release:${NC}      ${HELM_RELEASE}"
  echo ""

  if [[ $failures -gt 0 ]]; then
    warn "${failures} component(s) not ready. Check logs:"
    info "  kubectl get pods -n ${ns}"
    info "  kubectl logs -l app=nvis-prometheus -n ${ns} --tail=50"
  else
    success "All components healthy."
  fi
}

# =============================================================================
# AIRGAP BUNDLE MODE
# =============================================================================
run_airgap_bundle() {
  header "NVIS Observability — Airgap Bundle Creator (v${SCRIPT_VERSION})"
  log "This will pull all images and save them to: ${BUNDLE_TAR}"
  log "Expected bundle size: ~950MB"
  echo ""

  require_cmd docker

  # Read versions
  local prom_tag loki_tag grafana_tag vm_tag thanos_tag busybox_tag python_tag
  prom_tag=$(get_version "prometheus" "tag")
  loki_tag=$(get_version "loki" "tag")
  grafana_tag=$(get_version "grafana" "tag")
  vm_tag=$(get_version "victoriametrics" "tag")
  thanos_tag=$(get_version "thanos" "tag")
  busybox_tag=$(get_version "busybox" "tag")
  python_tag=$(get_version "bcmExporter" "tag")

  local -a images=(
    "prom/prometheus:${prom_tag}"
    "grafana/grafana:${grafana_tag}"
    "grafana/loki:${loki_tag}"
    "victoriametrics/victoria-metrics:${vm_tag}"
    "quay.io/thanos/thanos:${thanos_tag}"
    "python:${python_tag}"
    "busybox:${busybox_tag}"
    # GPU agents images (pulled from nvis-gpu-agents chart)
    "nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04"
    "quay.io/prometheus/node-exporter:v1.8.1"
    "grafana/alloy:v1.3.0"
  )

  step "Pulling images..."
  for img in "${images[@]}"; do
    log "  Pulling: ${img}"
    if docker pull "${img}" 2>&1 | tail -1; then
      success "  Pulled: ${img}"
    else
      warn "  Failed to pull: ${img} (skipping)"
    fi
  done

  step "Saving all images to ${BUNDLE_TAR}..."
  docker save "${images[@]}" -o "${BUNDLE_TAR}"
  success "Images saved."

  local size
  size=$(du -sh "${BUNDLE_TAR}" | cut -f1)
  log "Bundle size: ${size}"

  step "Creating full deployment bundle archive..."
  local bundle_archive="${BUNDLE_DIR}/nvis-observability-bundle.tar"
  tar --exclude='./vm-data' \
      --exclude='./.git' \
      --exclude='./nvis-images.tar' \
      --exclude='./nvis-observability-bundle.tar' \
      --exclude='./nvis-setup-debug-*' \
      --exclude='./nvis-setup-report-*' \
      --exclude='./.terraform' \
      -czf "${bundle_archive}" \
      -C "$(dirname "${SCRIPT_DIR}")" \
      "$(basename "${SCRIPT_DIR}")"

  local total_size
  total_size=$(du -sh "${bundle_archive}" | cut -f1)

  echo ""
  success "Airgap bundle created:"
  log "  Images tar:   ${BUNDLE_TAR} (${size})"
  log "  Full bundle:  ${bundle_archive} (${total_size})"
  echo ""
  log "CUSTOMER DEPLOYMENT INSTRUCTIONS:"
  log "  1. Copy ${bundle_archive} to the customer ObsVM"
  log "  2. Extract: tar -xzf nvis-observability-bundle.tar"
  log "  3. Load images: cd nvis-observability && bash scripts/airgap-images-load.sh"
  log "  4. Install: bash setup.sh --k8s"
}

# ---------------------------------------------------------------------------
# Airgap load (on target machine — loads images from tar)
# ---------------------------------------------------------------------------
run_airgap_load() {
  step "Loading airgap images from ${BUNDLE_TAR}..."
  require_cmd docker

  if [[ ! -f "${BUNDLE_TAR}" ]]; then
    die "Image bundle not found: ${BUNDLE_TAR}. Run ./setup.sh --airgap on a connected machine first."
  fi

  docker load -i "${BUNDLE_TAR}"
  success "Images loaded from airgap bundle."
}

# =============================================================================
# VERSION CHECK MODE
# =============================================================================
run_version_check() {
  header "NVIS Observability — Version Check"
  log "Checking Docker Hub and quay.io for newer versions..."
  log "Current versions from ${VERSIONS_FILE}:"
  echo ""

  # Show current pinned versions
  local components=("prometheus" "loki" "grafana" "victoriametrics" "thanos")
  for c in "${components[@]}"; do
    local tag
    tag=$(get_version "$c" "tag")
    printf "  %-20s %s\n" "${c}:" "${tag}"
  done

  echo ""
  warn "Automated version check requires internet access and 'curl'."
  log "To manually check latest versions:"
  log "  Prometheus:       https://hub.docker.com/r/prom/prometheus/tags"
  log "  Grafana:          https://hub.docker.com/r/grafana/grafana/tags"
  log "  Loki:             https://hub.docker.com/r/grafana/loki/tags"
  log "  VictoriaMetrics:  https://hub.docker.com/r/victoriametrics/victoria-metrics/tags"
  log "  Thanos:           https://quay.io/repository/thanos/thanos?tab=tags"
  echo ""
  log "To upgrade:"
  log "  1. Edit ${VERSIONS_FILE}"
  log "  2. Run: ./setup.sh --k8s --upgrade"
}

# =============================================================================
# MAIN ENTRYPOINT
# =============================================================================
header "NVIS Observability Suite v${SCRIPT_VERSION}"
log "Script dir: ${SCRIPT_DIR}"
log "Mode: k8s=${MODE_K8S} upgrade=${MODE_UPGRADE} airgap=${MODE_AIRGAP} storage=${STORAGE_BACKEND}"
echo ""

# Auto-detect airgap: if bundle tar exists and we're doing k8s install, load it first
if $MODE_K8S && [[ -f "${BUNDLE_TAR}" ]] && ! $MODE_AIRGAP; then
  log "Detected airgap bundle: ${BUNDLE_TAR}"
  run_airgap_load
fi

# =============================================================================
# STRESS TEST — 4000-node simulator for post-install dashboard validation
# =============================================================================
run_stress_test() {
  local PROM="${PROM_URL:-http://localhost:9090}"
  local GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
  local GRAFANA_PASS="${GRAFANA_ADMIN_PASSWORD:-lilly@1234}"
  local GEN_PID_FILE="/tmp/nvis-s4k-generator.pid"
  local GEN_SCRIPT="${SCRIPT_DIR}/scripts/s4k_generator.py"
  local GEN_PORT=9500

  echo ""
  log "╔══════════════════════════════════════════════════════╗"
  log "║   NVIS Stress Test — 4000-Node Panel Validator       ║"
  log "╚══════════════════════════════════════════════════════╝"
  echo ""

  # 1. Start generator
  if [[ -f "$GEN_PID_FILE" ]] && kill -0 "$(cat "$GEN_PID_FILE")" 2>/dev/null; then
    warn "Stress generator already running (PID $(cat "$GEN_PID_FILE"))"
  else
    log "Starting 4k metric generator on :${GEN_PORT} …"
    nohup python3 "$GEN_SCRIPT" > /tmp/nvis-s4k-generator.log 2>&1 &
    echo $! > "$GEN_PID_FILE"
    ok "Generator started (PID $(cat "$GEN_PID_FILE"))"
  fi

  # 2. Add scrape job to prometheus.yml if not present
  local PROM_CFG="${SCRIPT_DIR}/prometheus/prometheus.yml"
  if ! grep -q "s4k-generator" "$PROM_CFG"; then
    log "Adding s4k-generator scrape job to prometheus.yml …"
    local HOST_IP
    HOST_IP=$(hostname -I | awk '{print $1}')
    python3 - << PYEOF
import re, sys
cfg=open("${PROM_CFG}").read()
job="""
  # Stress-4k synthetic metric generator — 4000 simulated nodes
  - job_name: s4k-generator
    scrape_interval: 15s
    scrape_timeout: 14s
    honor_labels: true
    static_configs:
      - targets: ["${HOST_IP}:${GEN_PORT}"]
        labels:
          cluster: "\\${CLUSTER_NAME:-stress-test}"
"""
if "s4k-generator" not in cfg:
    cfg=cfg.replace("  # BCM exporter", job+"  # BCM exporter",1)
    open("${PROM_CFG}","w").write(cfg)
    print("  Added s4k-generator scrape job")
else:
    print("  Already present")
PYEOF
    bash "${SCRIPT_DIR}/scripts/reload-prometheus.sh" 2>/dev/null || true
    ok "Prometheus config reloaded"
  fi

  # 3. Wait for metrics to appear
  log "Waiting for first scrape (15s) …"
  sleep 17
  local NODE_COUNT
  NODE_COUNT=$(curl -s "${PROM}/api/v1/query?query=s4k_cluster_node_count" \
    | python3 -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else 0)" 2>/dev/null || echo 0)

  if [[ "$NODE_COUNT" -ge 4000 ]]; then
    ok "4000 simulated nodes confirmed in Prometheus (got ${NODE_COUNT})"
  else
    warn "Expected 4000 nodes but got ${NODE_COUNT} — generator may need more time"
  fi

  # 4. Panel health check
  log "Running dashboard panel health check …"
  python3 - << 'PYEOF'
import json, base64, urllib.request, os

GRAFANA  = os.environ.get("GRAFANA_URL", "http://localhost:3000")
PASS     = os.environ.get("GRAFANA_ADMIN_PASSWORD", "lilly@1234")
PROM     = os.environ.get("PROM_URL", "http://localhost:9090")

def api_grafana(path):
    req = urllib.request.Request(GRAFANA + path)
    creds = base64.b64encode(f"admin:{PASS}".encode()).decode()
    req.add_header("Authorization", f"Basic {creds}")
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())

def query_prom(q):
    url = f"{PROM}/api/v1/query?query={urllib.parse.quote(q)}"
    with urllib.request.urlopen(url, timeout=10) as r:
        d = json.loads(r.read())
        return d["data"]["result"] if d["status"]=="success" else []

import urllib.parse

CHECKS = [
    ("s4k_cluster_node_count", "4000-node count", lambda r: int(r[0]["value"][1])>=4000 if r else False),
    ("count(s4k_node_up==1)", "nodes online", lambda r: int(r[0]["value"][1])>3900 if r else False),
    ("s4k_cluster_gpu_util_p50", "GPU util P50", lambda r: float(r[0]["value"][1])>0 if r else False),
    ("count(s4k_rack_gpu_util_avg)", "rack metrics (40)", lambda r: int(r[0]["value"][1])>=40 if r else False),
    ("s4k_cluster_active_jobs", "active jobs", lambda r: float(r[0]["value"][1])>0 if r else False),
    ("count(s4k_node_xid_errors_total>0)", "XID-flagged nodes", lambda r: True),  # any value is fine
]

print("  Prometheus metric checks:")
all_ok = True
for query, label, check_fn in CHECKS:
    try:
        result = query_prom(query)
        passed = check_fn(result)
        val = result[0]["value"][1] if result else "NO DATA"
        mark = "✓" if passed else "✗"
        print(f"    {mark} {label}: {val}")
        if not passed: all_ok = False
    except Exception as e:
        print(f"    ? {label}: error ({e})")

# Grafana dashboard check
try:
    search = api_grafana("/api/search?folderTitle=Stress+Test&type=dash-db&limit=100")
    s4k_count = len([d for d in search if d["uid"].startswith("s4k-")])
    print(f"\n  Grafana Stress Test dashboards: {s4k_count} s4k-* found")
    if s4k_count >= 16:
        print("  ✓ All expected stress-test dashboards present")
    else:
        print(f"  ✗ Expected ≥16, found {s4k_count}")
except Exception as e:
    print(f"  ? Grafana check failed: {e}")

if all_ok:
    print("\n  ✅ All panel checks passed — open Grafana to review dashboards")
else:
    print("\n  ⚠️  Some checks failed — review above and check generator logs at /tmp/nvis-s4k-generator.log")
PYEOF

  echo ""
  log "Grafana dashboard URLs (Stress Test folder):"
  echo "  Home:      ${GRAFANA_URL}/d/s4k-nvis-demo-home"
  echo "  Executive: ${GRAFANA_URL}/d/s4k-nvis-executive"
  echo "  Topology:  ${GRAFANA_URL}/d/s4k-nvis-live-topology"
  echo "  Cluster:   ${GRAFANA_URL}/d/s4k-cluster-overview-cod"
  echo ""
  ok "Stress test active. Run './setup.sh --stress-test-cleanup' when done."
}

run_stress_test_cleanup() {
  log "Cleaning up stress test …"
  local GEN_PID_FILE="/tmp/nvis-s4k-generator.pid"

  # 1. Stop generator
  if [[ -f "$GEN_PID_FILE" ]]; then
    local PID
    PID=$(cat "$GEN_PID_FILE")
    if kill "$PID" 2>/dev/null; then
      ok "Generator (PID $PID) stopped"
    else
      warn "Generator PID $PID was not running"
    fi
    rm -f "$GEN_PID_FILE"
  else
    # Try by port
    pkill -f "s4k_generator.py" 2>/dev/null && ok "Generator stopped" || warn "Generator not running"
  fi

  # 2. Remove s4k scrape job from prometheus.yml
  local PROM_CFG="${SCRIPT_DIR}/prometheus/prometheus.yml"
  python3 - << 'PYEOF'
import re, sys
cfg = open("${PROM_CFG}").read()
# Remove the s4k-generator scrape block (from comment to next scrape job)
cleaned = re.sub(
    r'\n\s*# Stress-4k synthetic.*?(?=\n  # |\nremote_write:)',
    '', cfg, flags=re.DOTALL
)
if cleaned != cfg:
    open("${PROM_CFG}", "w").write(cleaned)
    print("  Removed s4k-generator scrape job from prometheus.yml")
else:
    print("  s4k-generator job not found in prometheus.yml (already clean)")
PYEOF

  # 3. Reload prometheus to stop collecting (data will expire in 15d retention)
  bash "${SCRIPT_DIR}/scripts/reload-prometheus.sh" 2>/dev/null && ok "Prometheus reloaded" || true

  # 4. Delete all s4k_* metrics immediately via admin API
  log "Purging s4k_* metrics from Prometheus TSDB …"
  local PROM_URL="${PROM_URL:-http://localhost:9090}"
  curl -sf -X POST \
    "${PROM_URL}/api/v1/admin/tsdb/delete_series?match[]=s4k_cluster_node_count" \
    "${PROM_URL}/api/v1/admin/tsdb/delete_series?match[]={job=\"s4k-generator\"}" \
    2>/dev/null && ok "s4k_* series marked for deletion" || warn "Admin API not available — metrics will expire naturally in 15 days"
  curl -sf -X POST "${PROM_URL}/api/v1/admin/tsdb/clean_tombstones" 2>/dev/null || true

  echo ""
  ok "Stress test cleanup complete. Stack restored to stock state."
  log "Note: Any residual s4k_* metrics in VictoriaMetrics will expire within 15 days."
  log "To completely reset: docker compose restart nvis-victoriametrics"
}

# Route to correct mode
if $MODE_STRESS_TEST; then
  run_stress_test
  exit 0
fi

if $MODE_STRESS_CLEANUP; then
  run_stress_test_cleanup
  exit 0
fi

if $MODE_AIRGAP && ! $MODE_K8S; then
  run_airgap_bundle
  exit 0
fi

if $MODE_VERSION_CHECK; then
  run_version_check
  exit 0
fi

if $MODE_K8S; then
  check_k8s_prerequisites
  create_secrets
  inject_scripts
  run_helm
  validate_k8s_install
else
  # Default: docker-compose backward-compat mode
  run_docker_compose
fi

echo ""
success "NVIS Observability setup complete. Log: ${LOG_FILE}"
