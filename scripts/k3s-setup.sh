#!/bin/bash
# =============================================================================
# k3s-setup.sh — Deploy NVIS Observability GPU agents on Kubernetes
#
# On first run this script interviews you for all required settings,
# saves them to nvis-deploy.conf, then proceeds automatically.
# On subsequent runs it reads nvis-deploy.conf and skips the interview.
#
# Run as ROOT on ObsVM:
#   sudo bash scripts/k3s-setup.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR ]${NC} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${BLUE}════════════════════════════════${NC}"; \
            echo -e "${BOLD}${BLUE}  $*${NC}"; \
            echo -e "${BOLD}${BLUE}════════════════════════════════${NC}"; }
ask() {
  # ask VAR_NAME "Question" "default"
  local var=$1 prompt=$2 default=${3:-}
  local answer
  if [[ -n "${default}" ]]; then
    echo -ne "  ${BOLD}${prompt}${NC} [${default}]: "
  else
    echo -ne "  ${BOLD}${prompt}${NC}: "
  fi
  read -r answer </dev/tty
  [[ -z "${answer}" && -n "${default}" ]] && answer="${default}"
  [[ -z "${answer}" ]] && { echo "  (required — cannot be empty)"; ask "$@"; return; }
  printf -v "${var}" '%s' "${answer}"
}

[[ $EUID -ne 0 ]] && error "Must run as root: sudo bash $0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NVIS_DIR="$(dirname "${SCRIPT_DIR}")"
CONF="${NVIS_DIR}/nvis-deploy.conf"

# ============================================================================
# Interview — runs only if conf doesn't exist or user requests reconfigure
# ============================================================================

RECONFIGURE=false
if [[ "${1:-}" == "--reconfigure" ]]; then
  RECONFIGURE=true
fi

if [[ ! -f "${CONF}" || "${RECONFIGURE}" == "true" ]]; then
  echo ""
  echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${BLUE}║   NVIS Observability — Deployment Configuration  ║${NC}"
  echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════╝${NC}"
  echo -e "  Answer each question. Press Enter to accept the default shown in [brackets].\n"

  # -- ObsVM
  echo -e "${BOLD}── ObsVM (this machine) ─────────────────────────────${NC}"
  ask OBSVM_IP      "IP address of this ObsVM (must be reachable by GPU nodes)"
  ask CLUSTER_NAME  "Cluster name (shown in Grafana dashboards, e.g. prod-h200-cluster)"

  # -- GPU nodes
  echo ""
  echo -e "${BOLD}── GPU Nodes ────────────────────────────────────────${NC}"
  echo -e "  Enter GPU node IPs one per line. Type ${BOLD}done${NC} when finished."
  GPU_NODES=()
  while true; do
    echo -ne "  Node IP (or 'done'): "
    read -r node_ip </dev/tty
    [[ "${node_ip}" == "done" || -z "${node_ip}" ]] && break
    GPU_NODES+=("${node_ip}")
  done
  [[ ${#GPU_NODES[@]} -eq 0 ]] && error "At least one GPU node IP is required."
  success "  ${#GPU_NODES[@]} node(s) entered: ${GPU_NODES[*]}"

  # -- SSH
  echo ""
  echo -e "${BOLD}── SSH Access to GPU Nodes ──────────────────────────${NC}"
  # Default key: find the key owned by the invoking user
  DEFAULT_KEY="/home/${SUDO_USER:-$(logname 2>/dev/null || echo '')}/.ssh/id_ed25519"
  [[ ! -f "${DEFAULT_KEY}" ]] && DEFAULT_KEY="/root/.ssh/id_ed25519"
  ask SSH_KEY "Path to SSH private key on this ObsVM" "${DEFAULT_KEY}"
  [[ ! -f "${SSH_KEY}" ]] && warn "Key not found at ${SSH_KEY} — make sure it exists before running"

  echo ""
  echo -ne "  ${BOLD}Can GPU nodes be reached directly (no jump host)?${NC} [y/N]: "
  read -r direct </dev/tty
  if [[ "${direct,,}" == "y" || "${direct,,}" == "yes" ]]; then
    DIRECT_SSH="true"
    JUMP_HOST=""
    BCM_HOST=""
    BCM_USER=""
  else
    DIRECT_SSH="false"
    ask JUMP_HOST "First jump host (user@hostname, e.g. alice@bastion.example.com)"
    echo ""
    echo -ne "  ${BOLD}Is there a second hop (BCM/bastion) between jump host and GPU nodes?${NC} [y/N]: "
    read -r second_hop </dev/tty
    if [[ "${second_hop,,}" == "y" || "${second_hop,,}" == "yes" ]]; then
      ask BCM_HOST "Second hop IP address"
      ask BCM_USER "Second hop SSH user" "root"
    else
      BCM_HOST=""
      BCM_USER=""
    fi
  fi

  # -- Namespace
  echo ""
  echo -e "${BOLD}── Kubernetes ───────────────────────────────────────${NC}"
  ask NAMESPACE "Kubernetes namespace for NVIS components" "nvis-monitoring"

  # -- Review
  echo ""
  echo -e "${BOLD}${BLUE}── Review ───────────────────────────────────────────${NC}"
  echo -e "  ObsVM IP:      ${OBSVM_IP}"
  echo -e "  Cluster name:  ${CLUSTER_NAME}"
  echo -e "  GPU nodes:     ${GPU_NODES[*]}"
  echo -e "  SSH key:       ${SSH_KEY}"
  if [[ "${DIRECT_SSH}" == "true" ]]; then
    echo -e "  SSH path:      direct (no jump host)"
  elif [[ -n "${BCM_HOST}" ]]; then
    echo -e "  SSH path:      ${JUMP_HOST} → ${BCM_USER}@${BCM_HOST} → GPU nodes"
  else
    echo -e "  SSH path:      ${JUMP_HOST} → GPU nodes"
  fi
  echo -e "  Namespace:     ${NAMESPACE}"
  echo ""
  echo -ne "  ${BOLD}Looks good? Proceed with deployment?${NC} [Y/n]: "
  read -r confirm </dev/tty
  [[ "${confirm,,}" == "n" || "${confirm,,}" == "no" ]] && { echo "Aborted."; exit 0; }

  # -- Save conf
  GPU_NODES_BASH="($(printf '"%s" ' "${GPU_NODES[@]}"))"
  cat > "${CONF}" << CONFEOF
# nvis-deploy.conf — generated by k3s-setup.sh on $(date)
# Re-run interview: sudo bash scripts/k3s-setup.sh --reconfigure

OBSVM_IP="${OBSVM_IP}"
CLUSTER_NAME="${CLUSTER_NAME}"
GPU_NODES=${GPU_NODES_BASH}
SSH_KEY="${SSH_KEY}"
DIRECT_SSH="${DIRECT_SSH}"
JUMP_HOST="${JUMP_HOST}"
BCM_HOST="${BCM_HOST}"
BCM_USER="${BCM_USER}"
NAMESPACE="${NAMESPACE}"
CONFEOF
  success "Config saved to ${CONF}"
  echo ""

else
  # Conf exists — load it silently
  source "${CONF}"
  info "Loaded config from ${CONF}  (re-run with --reconfigure to change)"
  info "  ObsVM: ${OBSVM_IP}  |  Cluster: ${CLUSTER_NAME}  |  Nodes: ${GPU_NODES[*]}"
  echo ""
fi

# ---- Derived config (do not edit) -------------------------------------------
REG="${OBSVM_IP}:5000"

# Images — source names → local registry destinations
DCGM_SRC="nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04"
DCGM_DST="${REG}/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04"
NODE_EXP_SRC="quay.io/prometheus/node-exporter:v1.8.1"
NODE_EXP_DST="${REG}/node-exporter:v1.8.1"
ALLOY_SRC="grafana/alloy:v1.3.0"
ALLOY_DST="${REG}/alloy:v1.3.0"

# ---- SSH helpers -------------------------------------------------------------
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15 -o IdentitiesOnly=yes"
# Run SSH as the original user so SSH agent + key work inside sudo
SUDO_USER_NAME="${SUDO_USER:-$(stat -c '%U' "${SSH_KEY}" 2>/dev/null || echo hlakshminara)}"

if [[ "${DIRECT_SSH:-false}" == "true" ]]; then
  # Direct SSH — no jump host needed
  bcm_ssh()  { :; }  # no BCM in direct mode
  node_ssh() { local ip=$1; shift
    sudo -u "${SUDO_USER_NAME}" ssh ${SSH_OPTS} "root@${ip}" "$@"; }
  node_scp() { local src=$1 ip=$2 dst=$3
    sudo -u "${SUDO_USER_NAME}" scp -q ${SSH_OPTS} "$src" "root@${ip}:$dst"; }
elif [[ -z "${BCM_HOST:-}" ]]; then
  # Single jump host only
  bcm_ssh()  { :; }
  node_ssh() { local ip=$1; shift
    sudo -u "${SUDO_USER_NAME}" ssh ${SSH_OPTS} -J "${JUMP_HOST}" "root@${ip}" "$@"; }
  node_scp() { local src=$1 ip=$2 dst=$3
    sudo -u "${SUDO_USER_NAME}" scp -q ${SSH_OPTS} -J "${JUMP_HOST}" "$src" "root@${ip}:$dst"; }
else
  # Two-hop: JUMP_HOST → BCM → GPU node
  bcm_ssh()  { sudo -u "${SUDO_USER_NAME}" ssh ${SSH_OPTS} -J "${JUMP_HOST}" "${BCM_USER}@${BCM_HOST}" "$@"; }
  node_ssh() { local ip=$1; shift
    sudo -u "${SUDO_USER_NAME}" ssh ${SSH_OPTS} -J "${JUMP_HOST},${BCM_USER}@${BCM_HOST}" "root@${ip}" "$@"; }
  node_scp() { local src=$1 ip=$2 dst=$3
    sudo -u "${SUDO_USER_NAME}" scp -q ${SSH_OPTS} -J "${JUMP_HOST},${BCM_USER}@${BCM_HOST}" "$src" "root@${ip}:$dst"; }
fi

# ============================================================================
header "Pre-flight — Load bundled images (airgap support)"
# ============================================================================
# If nvis-images.tar exists alongside this script (from create-bundle.sh),
# load it into Docker now so all subsequent phases work without internet.

IMAGES_TAR="${SCRIPT_DIR}/../nvis-images.tar"
# Normalise path
IMAGES_TAR="$(cd "$(dirname "${IMAGES_TAR}")" 2>/dev/null && pwd)/$(basename "${IMAGES_TAR}")" 2>/dev/null || true

if [[ -f "${IMAGES_TAR}" ]]; then
  # Use rancher/k3s as sentinel — if it's already loaded, skip
  if docker image inspect rancher/k3s:v1.30.2-k3s1 &>/dev/null 2>&1; then
    success "Bundled images already loaded — skipping docker load"
  else
    info "Loading bundled images from ${IMAGES_TAR} (may take a few minutes)..."
    docker load -i "${IMAGES_TAR}"
    success "Bundled images loaded"
  fi
else
  info "No nvis-images.tar found — images will be pulled from internet (or must already be present)"
fi

# ============================================================================
header "Phase 0 — Detect existing K8s on GPU nodes (skip k3s if found)"
# ============================================================================

SKIP_K3S=false
EXISTING_KUBECONFIG=""

info "Probing GPU nodes for existing kubelet..."
for NODE_IP in "${GPU_NODES[@]}"; do
  K8S_VER=$(node_ssh "${NODE_IP}" "
    if systemctl is-active kubelet &>/dev/null; then
      kubelet --version 2>/dev/null || echo 'unknown'
    elif command -v kubelet &>/dev/null; then
      kubelet --version 2>/dev/null || echo 'unknown'
    else
      echo ''
    fi
  " 2>/dev/null || echo "")

  if [[ -n "${K8S_VER}" ]]; then
    success "  ${NODE_IP}: K8s detected — ${K8S_VER}"
    SKIP_K3S=true
  else
    info "  ${NODE_IP}: no kubelet found"
  fi
done

if [[ "${SKIP_K3S}" == "true" ]]; then
  warn "Existing K8s detected on GPU nodes — skipping k3s install (Phases 2-4)"
  warn "Using existing cluster. Ensure KUBECONFIG is set or provide path via --kubeconfig."
  # Try to find a usable kubeconfig for the existing cluster
  if [[ -f /etc/rancher/rke2/rke2.yaml ]]; then
    EXISTING_KUBECONFIG=/etc/rancher/rke2/rke2.yaml
  elif [[ -f /home/${SUDO_USER_NAME}/.kube/config ]]; then
    EXISTING_KUBECONFIG=/home/${SUDO_USER_NAME}/.kube/config
  elif [[ -f /root/.kube/config ]]; then
    EXISTING_KUBECONFIG=/root/.kube/config
  else
    warn "No kubeconfig found — set KUBECONFIG env var before this script or copy kubeconfig to /root/.kube/config"
    warn "Continuing anyway — helm install may fail if KUBECONFIG is not set"
  fi
  [[ -n "${EXISTING_KUBECONFIG}" ]] && success "Using kubeconfig: ${EXISTING_KUBECONFIG}"
  export KUBECONFIG="${EXISTING_KUBECONFIG:-${KUBECONFIG:-}}"
  export KUBECTL="KUBECONFIG=${KUBECONFIG} kubectl"
else
  info "No existing K8s found — proceeding with k3s install"
fi

# ============================================================================
header "Phase 1 — Local Docker registry + image push"
# ============================================================================

# Verify registry is running (was started in prep step)
if ! docker ps | grep -q nvis-registry; then
  info "Starting local registry..."
  mkdir -p /var/lib/nvis-registry
  docker run -d --name nvis-registry --restart=always \
    -p 5000:5000 -v /var/lib/nvis-registry:/var/lib/registry \
    registry:2
  sleep 3
fi
success "Local registry running at ${REG}"

# Add insecure registry to Docker daemon (ObsVM side)
# Using "reload" (SIGHUP) — does NOT kill running containers
DAEMON_JSON=/etc/docker/daemon.json
if [[ -f "${DAEMON_JSON}" ]] && grep -q "insecure-registries" "${DAEMON_JSON}"; then
  info "insecure-registries already configured"
else
  info "Adding ${REG} to Docker insecure-registries (will reload daemon, containers keep running)..."
  cat > "${DAEMON_JSON}" << EOF
{
  "insecure-registries": ["${REG}"]
}
EOF
  systemctl reload docker
  sleep 3
  success "Docker daemon reloaded (running containers unaffected)"
fi

# Tag and push all images to local registry
info "Pushing images to local registry..."
for pair in \
  "${DCGM_SRC}|${DCGM_DST}" \
  "${NODE_EXP_SRC}|${NODE_EXP_DST}" \
  "${ALLOY_SRC}|${ALLOY_DST}"; do
  src="${pair%%|*}"
  dst="${pair##*|}"
  docker tag "$src" "$dst" 2>/dev/null || true
  docker push "$dst" 2>&1 | tail -1
  success "  ${dst##*/}"  # just the name:tag part
done

# Verify
info "Registry catalog: $(curl -sf http://${REG}/v2/_catalog | python3 -m json.tool 2>/dev/null || echo 'check above')"

# ============================================================================
header "Phase 2 — Install k3s server on ObsVM (control-plane only)"
# ============================================================================

if [[ "${SKIP_K3S}" == "true" ]]; then
  info "Skipping Phase 2 — existing K8s detected"
else

export HTTPS_PROXY=http://localhost:3128
export HTTP_PROXY=http://localhost:3128
# No_proxy: skip proxy for local registry + GPU nodes
export NO_PROXY="localhost,127.0.0.1,${OBSVM_IP},10.141.0.0/24,${REG}"

if command -v k3s &>/dev/null && KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/kubectl-bin get nodes &>/dev/null 2>&1; then
  success "k3s server already running"
else
  # get.k3s.io and raw.githubusercontent.com are blocked by the proxy.
  # Extract the k3s binary directly from the Docker image (already in local Docker).
  K3S_IMAGE="rancher/k3s:v1.30.2-k3s1"
  info "Extracting k3s binary from Docker image ${K3S_IMAGE}..."
  docker pull "${K3S_IMAGE}" 2>&1 | tail -1
  CID=$(docker create "${K3S_IMAGE}")
  docker cp "${CID}:/bin/k3s" /usr/local/bin/k3s
  docker rm "${CID}" >/dev/null
  chmod +x /usr/local/bin/k3s
  success "k3s binary installed: $(k3s --version | head -1)"

  # Extract standalone kubectl binary
  # k3s binary from Docker image lacks the kubectl subcommand, so we need this.
  # Fallback: if bitnami/kubectl isn't available, wrap k3s kubectl instead.
  if [[ ! -x /usr/local/bin/kubectl-bin ]]; then
    KUBECTL_IMAGE="bitnami/kubectl:1.30.2"
    if docker image inspect "${KUBECTL_IMAGE}" &>/dev/null 2>&1 || docker pull "${KUBECTL_IMAGE}" &>/dev/null 2>&1; then
      info "Extracting kubectl from ${KUBECTL_IMAGE}..."
      CID_KCT=$(docker create --entrypoint="" "${KUBECTL_IMAGE}" sh)
      docker cp "${CID_KCT}:/opt/bitnami/kubectl/bin/kubectl" /usr/local/bin/kubectl-bin
      docker rm "${CID_KCT}" >/dev/null
      chmod +x /usr/local/bin/kubectl-bin
      success "kubectl-bin installed: $(/usr/local/bin/kubectl-bin version --client --short 2>/dev/null | head -1)"
    else
      warn "bitnami/kubectl not available — creating wrapper around k3s kubectl"
      printf '#!/bin/bash\nexec /usr/local/bin/k3s kubectl "$@"\n' > /usr/local/bin/kubectl-bin
      chmod +x /usr/local/bin/kubectl-bin
    fi
  else
    success "kubectl-bin already installed"
  fi

  # Create required directories
  mkdir -p /etc/rancher/k3s
  mkdir -p /var/lib/rancher/k3s/server
  mkdir -p /var/lib/rancher/k3s/agent

  # Extract CNI plugins from k3s Docker image (installer normally handles this)
  # k3s needs host-local, flannel, bridge etc — they live in /bin/ inside the image
  info "Extracting CNI plugins from Docker image..."
  mkdir -p /opt/cni/bin
  CID_CNI=$(docker create "${K3S_IMAGE}")
  for cni_bin in cni flannel host-local bridge loopback portmap; do
    docker cp "${CID_CNI}:/bin/${cni_bin}" /opt/cni/bin/ 2>/dev/null || true
  done
  docker rm "${CID_CNI}" >/dev/null
  chmod +x /opt/cni/bin/* 2>/dev/null || true
  success "CNI plugins extracted: $(ls /opt/cni/bin/ | tr '\n' ' ')"

  # Write k3s server systemd service
  # NOTE: --cni-bin-dir does not exist in k3s v1.30 — use Environment PATH instead
  cat > /etc/systemd/system/k3s.service << 'SVEOF'
[Unit]
Description=Lightweight Kubernetes
Documentation=https://k3s.io
Wants=network-online.target
After=network-online.target

[Install]
WantedBy=multi-user.target

[Service]
Type=notify
Environment="PATH=/opt/cni/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EnvironmentFile=-/etc/default/k3s
KillMode=process
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=always
RestartSec=5s
ExecStartPre=-/sbin/modprobe br_netfilter
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/k3s server \
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode 644 \
  --tls-san OBSVM_IP_PLACEHOLDER \
  --node-taint node-role.kubernetes.io/control-plane=:NoSchedule
SVEOF
  # Substitute the actual IP (heredoc can't expand vars safely with special chars)
  sed -i "s/OBSVM_IP_PLACEHOLDER/${OBSVM_IP}/" /etc/systemd/system/k3s.service

  info "Starting k3s server..."
  systemctl daemon-reload
  systemctl enable k3s
  systemctl start k3s

  info "Waiting for k3s API to become ready..."
  for i in $(seq 1 60); do
    KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/kubectl-bin get nodes --no-headers 2>/dev/null | grep -q "Ready" && break
    sleep 3
  done
  KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/kubectl-bin get nodes || error "k3s failed to start — check: journalctl -u k3s -n 30"
  success "k3s server running"
fi

unset HTTPS_PROXY HTTP_PROXY NO_PROXY

K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
K3S_URL="https://${OBSVM_IP}:6443"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export KUBECTL="KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/kubectl-bin"

fi  # end SKIP_K3S Phase 2

# ============================================================================
header "Phase 3 — Download k3s binary for GPU nodes"
# ============================================================================

if [[ "${SKIP_K3S}" == "true" ]]; then
  info "Skipping Phase 3 — existing K8s detected"
else

K3S_BIN="/tmp/k3s-agent-bin"

# Binary was already extracted from Docker image in Phase 2 and is at /usr/local/bin/k3s
# Just copy it to the staging path
if [[ ! -f "${K3S_BIN}" ]]; then
  cp /usr/local/bin/k3s "${K3S_BIN}"
  success "k3s binary staged: $(du -sh ${K3S_BIN} | cut -f1)"
else
  success "k3s binary already staged: $(du -sh ${K3S_BIN} | cut -f1)"
fi

fi  # end SKIP_K3S Phase 3

# ============================================================================
header "Phase 4 — Configure GPU nodes"
# ============================================================================

if [[ "${SKIP_K3S}" == "true" ]]; then
  info "Skipping Phase 4 — existing K8s detected on GPU nodes"
else

for NODE_IP in "${GPU_NODES[@]}"; do
  echo ""
  info "━━━ Node ${NODE_IP} ━━━"

  # 4a. Stop old NVIS agents
  info "  Stopping old NVIS agents..."
  node_ssh "${NODE_IP}" "
    for svc in alloy node-exporter cgroup-exporter grafana-alloy; do
      systemctl stop \$svc 2>/dev/null && echo '    stopped: '\$svc || true
      systemctl disable \$svc 2>/dev/null || true
    done
    # Stop Docker DCGM container
    docker stop dcgm-exporter 2>/dev/null && echo '    stopped: docker dcgm-exporter' || true
    docker rm   dcgm-exporter 2>/dev/null || true
    echo '  agents cleared'
  "

  # 4b. Transfer k3s binary
  if node_ssh "${NODE_IP}" "test -x /usr/local/bin/k3s" 2>/dev/null; then
    info "  k3s already on node, skipping transfer"
  else
    info "  Transferring k3s binary (~100MB)..."
    node_scp "${K3S_BIN}" "${NODE_IP}" "/usr/local/bin/k3s"
    node_ssh "${NODE_IP}" "chmod +x /usr/local/bin/k3s"
    success "  k3s binary installed"
  fi

  # 4c. Configure local registry (registries.yaml) — BEFORE starting k3s-agent
  #     This tells k3s containerd to use ObsVM:5000 with HTTP (not HTTPS)
  info "  Configuring local registry..."
  node_ssh "${NODE_IP}" "
    mkdir -p /etc/rancher/k3s
    cat > /etc/rancher/k3s/registries.yaml << 'REGEOF'
mirrors:
  \"${REG}\":
    endpoint:
      - \"http://${REG}\"
configs:
  \"${REG}\":
    tls:
      insecure_skip_verify: true
REGEOF
    echo '  registries.yaml written'
  "

  # 4d. Install k3s agent service
  if node_ssh "${NODE_IP}" "systemctl is-active k3s-agent &>/dev/null" 2>/dev/null; then
    info "  k3s-agent already running, skipping install"
  else
    info "  Installing k3s-agent service..."
    node_ssh "${NODE_IP}" "
      cat > /etc/systemd/system/k3s-agent.service << 'SVCEOF'
[Unit]
Description=Lightweight Kubernetes Agent
Documentation=https://k3s.io
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=exec
EnvironmentFile=/etc/systemd/system/k3s-agent.env
ExecStartPre=-/sbin/modprobe br_netfilter
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/k3s agent
KillMode=process
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
SVCEOF

      cat > /etc/systemd/system/k3s-agent.env << ENVEOF
K3S_URL=${K3S_URL}
K3S_TOKEN=${K3S_TOKEN}
ENVEOF

      systemctl daemon-reload
      systemctl enable k3s-agent
      systemctl start k3s-agent
      echo '  k3s-agent service started'
    "
  fi

  # 4e. Configure NVIDIA container runtime for k3s containerd
  #     GPU nodes already have nvidia-container-runtime (was used by Docker for DCGM)
  #     k3s uses its own containerd instance — we patch its config template
  info "  Configuring NVIDIA runtime for k3s containerd..."
  node_ssh "${NODE_IP}" "
    # Wait for k3s agent to create its directories (up to 60s)
    for i in \$(seq 1 30); do
      test -d /var/lib/rancher/k3s/agent && break || sleep 2
    done

    mkdir -p /var/lib/rancher/k3s/agent/etc/containerd

    # config.toml.tmpl: k3s uses this as a Go template to generate containerd config
    # We add the nvidia runtime alongside the default runc runtime
    cat > /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl << 'CTEOF'
version = 2

[plugins]
  [plugins.\"io.containerd.grpc.v1.cri\"]
    [plugins.\"io.containerd.grpc.v1.cri\".containerd]
      [plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes]
        [plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.runc]
          runtime_type = \"io.containerd.runc.v2\"
          [plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.runc.options]
            SystemdCgroup = true

        [plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.nvidia]
          runtime_type = \"io.containerd.runc.v2\"
          [plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.nvidia.options]
            BinaryName = \"/usr/bin/nvidia-container-runtime\"
            SystemdCgroup = true
CTEOF

    systemctl restart k3s-agent
    echo '  NVIDIA runtime configured, k3s-agent restarted'
  "

  success "  Node ${NODE_IP} configured"
done

fi  # end SKIP_K3S Phase 4

# ============================================================================
header "Phase 5 — Wait for GPU nodes to join cluster"
# ============================================================================

if [[ "${SKIP_K3S}" == "true" ]]; then
  info "Skipping Phase 5 wait — using existing K8s cluster"
  info "Current nodes:"
  ${KUBECTL} get nodes -o wide 2>/dev/null || warn "Could not list nodes — check KUBECONFIG"
else

info "Waiting for nodes (this can take up to 2 minutes)..."
EXPECTED=$(( ${#GPU_NODES[@]} + 1 ))  # GPU nodes + ObsVM control-plane

for i in $(seq 1 60); do
  READY=$(KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/kubectl-bin get nodes --no-headers 2>/dev/null | grep -c " Ready" || true)
  printf "  [%2d/60] Nodes ready: %d/%d\r" "$i" "$READY" "$EXPECTED"
  [[ ${READY} -ge ${EXPECTED} ]] && { echo ""; break; }
  sleep 3
done
echo ""

KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/kubectl-bin get nodes -o wide
echo ""

fi  # end SKIP_K3S Phase 5

# Label GPU nodes with nvidia.com/gpu.present=true
# (DCGM DaemonSet nodeSelector uses this label)
info "Labeling GPU nodes..."
for NODE_IP in "${GPU_NODES[@]}"; do
  # Find node name by InternalIP
  NODE_NAME=$(${KUBECTL} get nodes -o json | python3 -c "
import sys, json
d=json.load(sys.stdin)
for n in d['items']:
  for a in n['status']['addresses']:
    if a['type']=='InternalIP' and a['address']=='${NODE_IP}':
      print(n['metadata']['name']); break
" 2>/dev/null || echo "")

  if [[ -n "${NODE_NAME}" ]]; then
    ${KUBECTL} label node "${NODE_NAME}" nvidia.com/gpu.present=true --overwrite 2>/dev/null
    success "  ${NODE_NAME} (${NODE_IP}) → nvidia.com/gpu.present=true"
  else
    warn "  Could not find K8s node name for ${NODE_IP} — label it manually after"
  fi
done

# ============================================================================
header "Phase 6 — Install helm"
# ============================================================================

if command -v helm &>/dev/null; then
  success "helm already installed: $(helm version --short)"
else
  # raw.githubusercontent.com is blocked by proxy — extract helm from Docker image
  info "Extracting helm binary from alpine/helm:3.15.4 Docker image..."
  docker pull alpine/helm:3.15.4 2>&1 | tail -1
  CID=$(docker create --entrypoint="" alpine/helm:3.15.4 sh)
  docker cp "${CID}:/usr/bin/helm" /usr/local/bin/helm
  docker rm "${CID}" >/dev/null
  chmod +x /usr/local/bin/helm
  success "helm installed: $(helm version --short)"
fi

# ============================================================================
header "Phase 7 — Deploy nvis-gpu-agents Helm chart"
# ============================================================================
# - imageRegistry points to ObsVM local registry (GPU nodes pull from here)
# - remote URLs point to Docker Compose Prometheus + Loki on ObsVM
# - nodeSelector restricts node_exporter + alloy to GPU nodes only
#   (ObsVM is tainted as control-plane, so they won't schedule there anyway)

HELM_ARGS=(
  "--namespace" "${NAMESPACE}"
  "--create-namespace"
  "--set" "imageRegistry=${REG}"
  "--set" "cluster=${CLUSTER_NAME}"
  "--set" "remote.prometheusUrl=http://${OBSVM_IP}:9090/api/v1/write"
  "--set" "remote.lokiUrl=http://${OBSVM_IP}:3100/loki/api/v1/push"
  # Image short names only — imageRegistry is prepended by the _helpers.tpl nvis.image helper
  # Do NOT include registry in repository — that causes double prefix (InvalidImageName)
  "--set" "dcgmExporter.image.repository=dcgm-exporter"
  "--set" "dcgmExporter.image.tag=3.3.5-3.4.0-ubuntu22.04"
  "--set" "nodeExporter.image.repository=node-exporter"
  "--set" "nodeExporter.image.tag=v1.8.1"
  "--set" "alloy.image.repository=alloy"
  "--set" "alloy.image.tag=v1.3.0"
)

if helm status nvis-gpu-agents -n "${NAMESPACE}" &>/dev/null 2>&1; then
  info "Upgrading existing nvis-gpu-agents release..."
  helm upgrade nvis-gpu-agents "${NVIS_DIR}/helm/nvis-gpu-agents/" "${HELM_ARGS[@]}"
else
  info "Installing nvis-gpu-agents..."
  helm install nvis-gpu-agents "${NVIS_DIR}/helm/nvis-gpu-agents/" "${HELM_ARGS[@]}"
fi
success "nvis-gpu-agents deployed"

# ============================================================================
header "Phase 8 — Verify"
# ============================================================================

info "Waiting 60s for DaemonSet pods to start..."
sleep 60

echo ""
echo "── Pod status ──────────────────────────────────"
${KUBECTL} get pods -n "${NAMESPACE}" -o wide
echo ""
echo "── DaemonSet status ────────────────────────────"
${KUBECTL} get daemonset -n "${NAMESPACE}"
echo ""

# Check metrics arriving in Prometheus
info "Querying Prometheus for GPU node metrics..."
RESULT=$(curl -sf "http://${OBSVM_IP}:9090/api/v1/query?query=node_uname_info" 2>/dev/null | \
  python3 -c "
import sys,json
d=json.load(sys.stdin)
nodes=[r['metric'].get('instance','?') for r in d.get('data',{}).get('result',[])]
print('  Nodes reporting: ' + ', '.join(nodes) if nodes else '  No metrics yet (may need 30s more)')
" 2>/dev/null || echo "  Prometheus not responding")
echo "${RESULT}"

echo ""
success "Done! Grafana: http://${OBSVM_IP}:3000  (admin / check .nvis-creds)"
echo ""
echo "Useful commands:"
echo "  ${KUBECTL} get pods -n ${NAMESPACE} -o wide"
echo "  ${KUBECTL} logs -n ${NAMESPACE} -l app=nvis-alloy --tail=30"
echo "  ${KUBECTL} logs -n ${NAMESPACE} -l app=nvis-dcgm-exporter --tail=20"
echo "  ${KUBECTL} describe pod -n ${NAMESPACE} <pod-name>"
echo ""
echo "If DCGM pods are Pending, check:"
echo "  ${KUBECTL} describe pod -n ${NAMESPACE} -l app=nvis-dcgm-exporter"
echo "  (must have node labeled: nvidia.com/gpu.present=true)"
