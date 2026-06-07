#!/bin/bash
# =============================================================================
# airgap-images-save.sh
# Run this on a machine WITH internet access to pull and bundle all NVIS
# container images into a single tar file for transfer to airgapped environments.
#
# Output: nvis-images.tar (in current directory)
#
# Usage:
#   bash scripts/airgap-images-save.sh
#   bash scripts/airgap-images-save.sh --output /path/to/nvis-images.tar
#
# NOTE: DCGM Exporter requires an NGC API key from https://ngc.nvidia.com
#   Set NGC_API_KEY env var before running, or you'll be prompted.
# =============================================================================
set -euo pipefail

# ---- Colors -----------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ---- Defaults ---------------------------------------------------------------
OUTPUT_TAR="${PWD}/nvis-images.tar"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|-o) OUTPUT_TAR="$2"; shift 2 ;;
    *) echo "Usage: $0 [--output FILE]"; exit 1 ;;
  esac
done

# ---- Image list -------------------------------------------------------------
# Format: "image:tag"
OBSVM_IMAGES=(
  "quay.io/prometheus/prometheus:v2.53.0"
  "grafana/grafana:11.1.0"
  "grafana/loki:3.1.0"
  "victoriametrics/victoria-metrics:v1.102.0"
)

GPU_AGENT_IMAGES=(
  "quay.io/prometheus/node-exporter:v1.8.1"
  "grafana/alloy:v1.3.0"
  # DCGM — handled separately (requires NGC login)
)

# DCGM 4.x required for Blackwell (B100/B200/B300). Also works for Hopper (H100/H200).
# Verify latest at: https://catalog.ngc.nvidia.com/orgs/nvidia/teams/k8s/containers/dcgm-exporter
DCGM_IMAGE="nvcr.io/nvidia/k8s/dcgm-exporter:4.2.3-4.1.1-ubuntu22.04"

UTIL_IMAGES=(
  "busybox:1.36"
)

ALL_IMAGES=("${OBSVM_IMAGES[@]}" "${GPU_AGENT_IMAGES[@]}" "${DCGM_IMAGE}" "${UTIL_IMAGES[@]}")

# ---- NGC login for DCGM -----------------------------------------------------
echo -e "\n${BOLD}=== NVIS Airgap Image Packager ===${NC}"
echo -e "Output: ${OUTPUT_TAR}\n"

if ! docker info &>/dev/null; then
  error "Docker is not running. Please start Docker and retry."
fi

# NGC login for nvcr.io (needed for DCGM)
if [[ -z "${NGC_API_KEY:-}" ]]; then
  warn "DCGM Exporter image is hosted on NVIDIA NGC (nvcr.io) and requires an API key."
  warn "Get one free at: https://ngc.nvidia.com/setup/api-key"
  echo -n "Enter NGC API key (or press Enter to skip DCGM): "
  read -r NGC_API_KEY
fi

if [[ -n "${NGC_API_KEY}" ]]; then
  info "Logging in to nvcr.io..."
  echo "$NGC_API_KEY" | docker login nvcr.io --username='$oauthtoken' --password-stdin \
    && success "NGC login successful" \
    || { warn "NGC login failed — DCGM image will be skipped"; NGC_API_KEY=""; }
else
  warn "Skipping DCGM (no NGC key). GPU metrics will not be available until DCGM image is loaded."
  ALL_IMAGES=("${OBSVM_IMAGES[@]}" "${GPU_AGENT_IMAGES[@]}" "${UTIL_IMAGES[@]}")
fi

# ---- Pull all images ---------------------------------------------------------
echo -e "\n${BOLD}Pulling ${#ALL_IMAGES[@]} images...${NC}"
PULLED=()
FAILED=()

for img in "${ALL_IMAGES[@]}"; do
  echo -n "  Pulling ${img}... "
  if docker pull "${img}" &>/dev/null; then
    echo -e "${GREEN}OK${NC}"
    PULLED+=("${img}")
  else
    echo -e "${RED}FAILED${NC}"
    FAILED+=("${img}")
    warn "Failed to pull ${img} — it will be excluded from the archive"
  fi
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
  warn "The following images failed to pull and will NOT be in the archive:"
  for img in "${FAILED[@]}"; do echo "    - ${img}"; done
fi

if [[ ${#PULLED[@]} -eq 0 ]]; then
  error "No images were pulled. Cannot create archive."
fi

# ---- Save to tar -------------------------------------------------------------
echo -e "\n${BOLD}Saving ${#PULLED[@]} images to ${OUTPUT_TAR}...${NC}"
echo "  This may take a few minutes (images can be several GB total)..."

docker save "${PULLED[@]}" -o "${OUTPUT_TAR}"

SIZE=$(du -sh "${OUTPUT_TAR}" | cut -f1)
success "Archive created: ${OUTPUT_TAR} (${SIZE})"

# ---- Print manifest ----------------------------------------------------------
MANIFEST_FILE="${OUTPUT_TAR%.tar}-manifest.txt"
echo -e "\n${BOLD}Image manifest:${NC}"
{
  echo "# NVIS Airgap Image Manifest"
  echo "# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "# Archive: $(basename "${OUTPUT_TAR}")"
  echo ""
  for img in "${PULLED[@]}"; do
    echo "${img}"
  done
} | tee "${MANIFEST_FILE}"

success "Manifest saved: ${MANIFEST_FILE}"

echo -e "\n${BOLD}Next steps:${NC}"
echo "  1. Transfer ${OUTPUT_TAR} and ${MANIFEST_FILE} to the airgapped environment"
echo "  2. Transfer the nvis-observability package (nvis-observability-latest.tar)"
echo "  3. In airgapped env, run: bash scripts/airgap-images-load.sh --tar ${OUTPUT_TAR} --registry YOUR_REGISTRY:5000"
echo "  4. Install with Helm:"
echo "     helm install nvis-obsvm helm/nvis-obsvm/ --set imageRegistry=YOUR_REGISTRY:5000 -n nvis-monitoring"
echo "     helm install nvis-gpu-agents helm/nvis-gpu-agents/ --set imageRegistry=YOUR_REGISTRY:5000 --set cluster=CLUSTER_NAME -n nvis-monitoring"
