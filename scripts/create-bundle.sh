#!/bin/bash
# =============================================================================
# create-bundle.sh
# Run on a machine WITH internet access to pull all images and create a
# single tar file for airgapped customer delivery.
#
# What the customer receives (ONE file):
#   nvis-observability-bundle.tar
#     ├── nvis-observability/              — full project (helm charts, scripts, dashboards)
#     ├── nvis-observability/bin/k3s       — k3s binary (auto-installed by setup-k8s.sh)
#     ├── nvis-observability/bin/helm      — helm binary (auto-installed by setup-k8s.sh)
#     └── nvis-observability/nvis-images.tar — all container images pre-pulled
#
# Customer install (fully airgapped — no internet, no pre-requisites):
#   tar -xf nvis-observability-bundle.tar
#   cd nvis-observability
#   sudo bash setup-k8s.sh      # interactive wizard — installs k3s+helm, then stack
#
# Architecture deployed by setup-k8s.sh:
#   ObsVM/k8s  : Helm — Prometheus, Grafana, Loki, VictoriaMetrics
#                       BCM exporter, Slurm exporter, Redfish exporter
#   GPU nodes  : Helm DaemonSets — DCGM 4.x, node-exporter, Grafana Alloy
#                (DCGM pre-loaded to GPU nodes via BCM in parallel during install)
#
# Images bundled:
#   Core observability stack:
#     prom/prometheus:v2.54.1
#     grafana/grafana:11.1.4
#     grafana/loki:3.1.0
#     victoriametrics/victoria-metrics:v1.103.0
#     quay.io/thanos/thanos:v0.36.1    (Thanos mode)
#   GPU agents (DaemonSets):
#     quay.io/prometheus/node-exporter:v1.8.1
#     grafana/alloy:v1.3.0
#     nvcr.io/nvidia/k8s/dcgm-exporter:4.2.3-4.1.1-ubuntu22.04  (NGC key required)
#   Exporters (Python-based):
#     python:3.11-slim
#   Utilities:
#     busybox:1.36
#
# Usage:
#   bash scripts/create-bundle.sh
#   bash scripts/create-bundle.sh --output /path/to/bundle.tar
#   NGC_API_KEY=xxx bash scripts/create-bundle.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR ]${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NVIS_DIR="$(dirname "${SCRIPT_DIR}")"
OUTPUT_BUNDLE="${PWD}/nvis-observability-bundle.tar"
IMAGES_TAR="${NVIS_DIR}/nvis-images.tar"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|-o) OUTPUT_BUNDLE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--output FILE]"
      echo "  Set NGC_API_KEY env var for DCGM image (required for GPU metrics)"
      exit 0 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

echo -e "\n${BOLD}════════════════════════════════════════════${NC}"
echo -e "${BOLD}  NVIS Observability — Bundle Creator${NC}"
echo -e "${BOLD}════════════════════════════════════════════${NC}"
echo -e "  Source:  ${NVIS_DIR}"
echo -e "  Output:  ${OUTPUT_BUNDLE}\n"

if ! docker info &>/dev/null; then
  error "Docker is not running. Start Docker and retry."
fi

# ---- NGC login for DCGM -------------------------------------------------------
# DCGM 4.x required for Blackwell (B100/B200/B300). Also works for Hopper (H100/H200).
DCGM_IMAGE="nvcr.io/nvidia/k8s/dcgm-exporter:4.2.3-4.1.1-ubuntu22.04"

if [[ -z "${NGC_API_KEY:-}" ]]; then
  warn "DCGM Exporter requires an NGC API key (free at ngc.nvidia.com)."
  echo -n "  Enter NGC API key (or press Enter to skip DCGM): "
  read -r NGC_API_KEY
fi

if [[ -n "${NGC_API_KEY}" ]]; then
  info "Logging in to nvcr.io..."
  echo "${NGC_API_KEY}" | docker login nvcr.io --username='$oauthtoken' --password-stdin \
    && success "NGC login OK" \
    || { warn "NGC login failed — DCGM will be excluded"; NGC_API_KEY=""; }
else
  warn "Skipping DCGM — GPU metrics will NOT work without it"
fi

# ---- Download k3s + helm binaries for airgap ----------------------------------
ARCH=$(uname -m)
K3S_ARCH="amd64"; [[ "$ARCH" == "aarch64" ]] && K3S_ARCH="arm64"
HELM_ARCH="amd64"; [[ "$ARCH" == "aarch64" ]] && HELM_ARCH="arm64"

K3S_VERSION="v1.30.2+k3s1"
HELM_VERSION="v3.15.3"

BIN_DIR="${NVIS_DIR}/bin"
mkdir -p "${BIN_DIR}"

info "Downloading k3s ${K3S_VERSION} (${K3S_ARCH})..."
K3S_URL="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION/+/%2B}/k3s"
[[ "$K3S_ARCH" == "arm64" ]] && K3S_URL="${K3S_URL}-arm64"
curl -sfL "${K3S_URL}" -o "${BIN_DIR}/k3s" && chmod +x "${BIN_DIR}/k3s" \
  && success "k3s binary: ${BIN_DIR}/k3s" \
  || warn "k3s download failed — airgap install will fall back to download"

info "Downloading k3s install script..."
curl -sfL https://get.k3s.io -o "${BIN_DIR}/k3s-install.sh" \
  && chmod +x "${BIN_DIR}/k3s-install.sh" \
  && success "k3s-install.sh: ${BIN_DIR}/k3s-install.sh" \
  || warn "k3s-install.sh download failed"

info "Downloading helm ${HELM_VERSION} (${HELM_ARCH})..."
HELM_TAR="/tmp/helm-bundle-$$.tar.gz"
curl -sfL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${HELM_ARCH}.tar.gz" -o "${HELM_TAR}" \
  && tar -xzf "${HELM_TAR}" -C /tmp "linux-${HELM_ARCH}/helm" \
  && mv "/tmp/linux-${HELM_ARCH}/helm" "${BIN_DIR}/helm" \
  && chmod +x "${BIN_DIR}/helm" \
  && rm -f "${HELM_TAR}" \
  && success "helm binary: ${BIN_DIR}/helm" \
  || { warn "helm download failed — connected-mode fallback will be used"; rm -f "${HELM_TAR}"; }

# ---- Full image list ----------------------------------------------------------
# Core observability stack (matches helm/nvis-obsvm/versions.yaml)
CORE_IMAGES=(
  "prom/prometheus:v2.54.1"
  "grafana/grafana:11.1.4"
  "grafana/loki:3.1.0"
  "victoriametrics/victoria-metrics:v1.103.0"
  "quay.io/thanos/thanos:v0.36.1"
  "python:3.11-slim"
  "busybox:1.36"
)

# GPU agent DaemonSets (nvis-gpu-agents helm chart)
GPU_AGENT_IMAGES=(
  "quay.io/prometheus/node-exporter:v1.8.1"
  "grafana/alloy:v1.3.0"
)

ALL_IMAGES=("${CORE_IMAGES[@]}" "${GPU_AGENT_IMAGES[@]}")
[[ -n "${NGC_API_KEY}" ]] && ALL_IMAGES+=("${DCGM_IMAGE}")

# ---- Pull all images ----------------------------------------------------------
echo -e "\n${BOLD}Pulling ${#ALL_IMAGES[@]} images...${NC}"
PULLED=()
FAILED=()

for img in "${ALL_IMAGES[@]}"; do
  echo -n "  ${img} ... "
  if docker pull "${img}" &>/dev/null; then
    echo -e "${GREEN}OK${NC}"
    PULLED+=("${img}")
  else
    echo -e "${RED}FAILED${NC}"
    FAILED+=("${img}")
    warn "  Pull failed — will be excluded from bundle"
  fi
done

[[ ${#FAILED[@]} -gt 0 ]] && warn "Excluded images: ${FAILED[*]}"
[[ ${#PULLED[@]} -eq 0 ]] && error "No images pulled — cannot create bundle"

# ---- Save images to tar -------------------------------------------------------
echo -e "\n${BOLD}Saving ${#PULLED[@]} images to ${IMAGES_TAR}...${NC}"
echo "  (May take several minutes — images are several GB)"
docker save "${PULLED[@]}" -o "${IMAGES_TAR}"
IMG_SIZE=$(du -sh "${IMAGES_TAR}" | cut -f1)
success "Images saved: ${IMAGES_TAR} (${IMG_SIZE})"

# Write manifest next to images tar for reference
MANIFEST="${NVIS_DIR}/nvis-images-manifest.txt"
{
  echo "# NVIS Image Manifest"
  echo "# Created: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo ""
  for img in "${PULLED[@]}"; do echo "${img}"; done
} > "${MANIFEST}"

# ---- Create bundle tar --------------------------------------------------------
echo -e "\n${BOLD}Creating bundle tar...${NC}"

# Exclude things that don't belong in the bundle
tar -cf "${OUTPUT_BUNDLE}" \
  --exclude='.git' \
  --exclude='*.log' \
  --exclude='node_modules' \
  --exclude='terraform/.terraform' \
  --exclude='vm-data' \
  --exclude='certs' \
  -C "$(dirname "${NVIS_DIR}")" \
  "$(basename "${NVIS_DIR}")"

BUNDLE_SIZE=$(du -sh "${OUTPUT_BUNDLE}" | cut -f1)
success "Bundle created: ${OUTPUT_BUNDLE} (${BUNDLE_SIZE})"

# ---- Summary -----------------------------------------------------------------
echo ""
echo -e "${BOLD}Bundle contents:${NC}"
echo "  - nvis-observability/            (helm charts, scripts, docs, dashboards)"
echo "  - nvis-observability/bin/k3s     (k3s single-node Kubernetes)"
echo "  - nvis-observability/bin/helm    (helm package manager)"
echo "  - nvis-observability/nvis-images.tar (${IMG_SIZE}, ${#PULLED[@]} images)"
echo ""
echo -e "${BOLD}Bundled images:${NC}"
for img in "${PULLED[@]}"; do echo "  ✓ ${img}"; done
[[ ${#FAILED[@]} -gt 0 ]] && { echo ""; for img in "${FAILED[@]}"; do echo "  ✗ ${img} (excluded)"; done; }
echo ""
echo -e "${BOLD}Transfer and deploy:${NC}"
echo "  1. scp ${OUTPUT_BUNDLE} user@obsvm:~/"
echo "  2. On ObsVM (airgapped — no internet, no pre-requisites needed):"
echo "       tar -xf $(basename "${OUTPUT_BUNDLE}")"
echo "       cd nvis-observability"
echo "       sudo bash setup-k8s.sh"
echo ""
echo "  The installer:"
echo "    - Auto-installs k3s (single-node Kubernetes) from bundled binary"
echo "    - Auto-installs helm from bundled binary"
echo "    - Loads all container images from nvis-images.tar (no registry needed)"
echo "    - Runs interactive wizard for integrations — no flags to memorize"
echo ""
echo "  To add integrations later or upgrade:"
echo "       sudo bash setup-k8s.sh --upgrade"
echo "  To remove everything:"
echo "       sudo bash setup-k8s.sh --cleanup"
