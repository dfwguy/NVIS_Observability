#!/bin/bash
# =============================================================================
# airgap-images-load.sh
# Run this in the airgapped environment to load images from the tar archive
# and push them to a local container registry.
#
# Usage:
#   # Load into local Docker registry at registry.local:5000
#   bash scripts/airgap-images-load.sh --tar nvis-images.tar --registry registry.local:5000
#
#   # Load into Docker only (no registry push — useful for single-node testing)
#   bash scripts/airgap-images-load.sh --tar nvis-images.tar --no-push
#
#   # Load and push to Harbor
#   bash scripts/airgap-images-load.sh --tar nvis-images.tar --registry harbor.internal/nvis
#
# Prerequisites:
#   - Docker running
#   - If using a registry: the registry must be running and accessible
#   - If registry uses self-signed cert: add to Docker insecure-registries
#     Edit /etc/docker/daemon.json: {"insecure-registries": ["registry.local:5000"]}
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ---- Parse args -------------------------------------------------------------
IMAGES_TAR=""
REGISTRY=""
NO_PUSH=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tar|-t)      IMAGES_TAR="$2"; shift 2 ;;
    --registry|-r) REGISTRY="$2"; shift 2 ;;
    --no-push)     NO_PUSH=true; shift ;;
    -h|--help)
      echo "Usage: $0 --tar nvis-images.tar [--registry registry.local:5000 | --no-push]"
      exit 0 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

[[ -z "${IMAGES_TAR}" ]] && error "Required: --tar PATH_TO_IMAGES_TAR"
[[ ! -f "${IMAGES_TAR}" ]] && error "File not found: ${IMAGES_TAR}"
[[ "${NO_PUSH}" == "false" && -z "${REGISTRY}" ]] && error "Required: --registry REGISTRY_HOST or --no-push"

if ! docker info &>/dev/null; then
  error "Docker is not running. Please start Docker and retry."
fi

echo -e "\n${BOLD}=== NVIS Airgap Image Loader ===${NC}"
echo "  Archive:  ${IMAGES_TAR}"
echo "  Registry: ${REGISTRY:-"(no push — docker load only)"}"
echo ""

# ---- Load images from tar ---------------------------------------------------
info "Loading images from ${IMAGES_TAR} (this may take a few minutes)..."
docker load -i "${IMAGES_TAR}"
success "Images loaded into local Docker"

# ---- Get list of loaded images ----------------------------------------------
# Extract image names/tags from the tar manifest
LOADED_IMAGES=()
while IFS= read -r line; do
  # docker load output: "Loaded image: repo/name:tag"
  if [[ "${line}" =~ ^Loaded\ image:\ (.+)$ ]]; then
    LOADED_IMAGES+=("${BASH_REMATCH[1]}")
  fi
done < <(docker load -i "${IMAGES_TAR}" 2>&1 || true)

# Fallback: read manifest file if available
MANIFEST="${IMAGES_TAR%.tar}-manifest.txt"
if [[ -f "${MANIFEST}" ]]; then
  info "Using manifest file: ${MANIFEST}"
  while IFS= read -r line; do
    [[ "${line}" =~ ^# ]] && continue
    [[ -z "${line}" ]] && continue
    LOADED_IMAGES+=("${line}")
  done < "${MANIFEST}"
fi

if [[ "${NO_PUSH}" == "true" ]]; then
  success "Images loaded into Docker (no-push mode). Done."
  echo ""
  echo "To use these with Helm (no registry), set imageRegistry to empty string"
  echo "and ensure each K8s node has the images loaded."
  echo ""
  echo "To load on other nodes, copy the tar and run on each node:"
  echo "  docker load -i ${IMAGES_TAR}"
  exit 0
fi

# ---- Push to registry -------------------------------------------------------
echo ""
info "Pushing images to ${REGISTRY}..."
echo "  (Each image will be retagged and pushed)"
echo ""

PUSHED=()
FAILED=()

# Get all images currently in docker that match our expected list
# We'll look at all images and retag/push to the local registry
DOCKER_IMAGES=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -v '<none>')

while IFS= read -r img; do
  [[ -z "${img}" || "${img}" =~ ^\  ]] && continue

  # Compute the new tag: registry/original:tag
  new_tag="${REGISTRY}/${img}"

  echo -n "  ${img} → ${new_tag} ... "
  if docker tag "${img}" "${new_tag}" 2>/dev/null && \
     docker push "${new_tag}" &>/dev/null; then
    echo -e "${GREEN}OK${NC}"
    PUSHED+=("${new_tag}")
  else
    echo -e "${RED}FAILED${NC}"
    FAILED+=("${img}")
  fi
done <<< "${DOCKER_IMAGES}"

echo ""
if [[ ${#PUSHED[@]} -gt 0 ]]; then
  success "Pushed ${#PUSHED[@]} images to ${REGISTRY}"
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  warn "Failed to push ${#FAILED[@]} images:"
  for img in "${FAILED[@]}"; do echo "    - ${img}"; done
fi

# ---- Print helm install commands --------------------------------------------
echo ""
echo -e "${BOLD}Helm install commands (use these to deploy):${NC}"
echo ""
echo "  # Deploy central monitoring stack:"
echo "  helm install nvis-obsvm helm/nvis-obsvm/ \\"
echo "    --namespace nvis-monitoring --create-namespace \\"
echo "    --set imageRegistry=${REGISTRY} \\"
echo "    --set grafana.adminPassword=YOUR_SECURE_PASSWORD"
echo ""
echo "  # Deploy GPU node agents:"
echo "  helm install nvis-gpu-agents helm/nvis-gpu-agents/ \\"
echo "    --namespace nvis-monitoring \\"
echo "    --set imageRegistry=${REGISTRY} \\"
echo "    --set cluster=YOUR_CLUSTER_NAME \\"
echo "    --set remote.prometheusUrl=http://nvis-obsvm-prometheus.nvis-monitoring.svc:9090/api/v1/write \\"
echo "    --set remote.lokiUrl=http://nvis-obsvm-loki.nvis-monitoring.svc:3100/loki/api/v1/push"
echo ""
echo "  # Access Grafana:"
echo "  kubectl get nodes -o wide  # get a node IP"
echo "  # Open browser: http://NODE_IP:30300  (admin / YOUR_SECURE_PASSWORD)"
