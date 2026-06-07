#!/usr/bin/env bash
# lib/prereqs.sh — prerequisite check + k3s + helm installation for nvis-platform.
#
# Public functions:
#   prereqs_detect_os     — populates OS_ID, OS_FAMILY (debian|rhel|unknown)
#   prereqs_check_resources — fails if disk<50G or RAM<8G
#   prereqs_ensure_pkg PKG ... — apt-get/dnf install on demand
#   prereqs_ensure_curl_jq    — ensure curl + jq present
#   prereqs_ensure_k3s        — install k3s if not already up
#   prereqs_ensure_helm       — install helm CLI if missing
#   prereqs_wait_k8s_ready    — wait until `kubectl get nodes` shows Ready
#   prereqs_run               — orchestrator: runs the full prereq pipeline
#
# Respects:
#   DRY_RUN=true — never installs anything, only reports state.
# ---------------------------------------------------------------------------

if [[ -n "${_NVIS_PREREQS_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_NVIS_PREREQS_SH_LOADED=1

# Disk/memory thresholds in GiB.
PREREQ_MIN_DISK_GB="${PREREQ_MIN_DISK_GB:-50}"
PREREQ_MIN_RAM_GB="${PREREQ_MIN_RAM_GB:-8}"

OS_ID=""        # ubuntu / debian / rhel / centos / rocky / alma / unknown
OS_FAMILY=""    # debian / rhel / unknown

_pre_log() { printf '[prereqs] %s\n' "$*" >&2; }
_pre_err() { printf '[prereqs][ERROR] %s\n' "$*" >&2; }

# prereqs_detect_os — set OS_ID / OS_FAMILY from /etc/os-release.
prereqs_detect_os() {
    if [[ ! -r /etc/os-release ]]; then
        OS_ID="unknown"
        OS_FAMILY="unknown"
        _pre_err "/etc/os-release not readable"
        return 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    case "$OS_ID" in
        ubuntu|debian)            OS_FAMILY="debian" ;;
        rhel|centos|rocky|alma|fedora) OS_FAMILY="rhel" ;;
        *)                        OS_FAMILY="unknown" ;;
    esac
    _pre_log "Detected OS: $OS_ID (family=$OS_FAMILY)"
    [[ "$OS_FAMILY" == "unknown" ]] && {
        _pre_err "Unsupported OS '$OS_ID'; install may fail"
        return 1
    }
    return 0
}

# prereqs_check_resources — disk under / and RAM
prereqs_check_resources() {
    local disk_gb ram_gb
    disk_gb=$(df -BG --output=avail / 2>/dev/null | tail -n 1 | tr -dc '0-9')
    if [[ -z "$disk_gb" ]]; then disk_gb=0; fi
    ram_gb=$(awk '/^MemTotal:/ {printf("%d", $2/1024/1024)}' /proc/meminfo 2>/dev/null)
    if [[ -z "$ram_gb" ]]; then ram_gb=0; fi

    _pre_log "Disk free on / : ${disk_gb} GiB (min ${PREREQ_MIN_DISK_GB})"
    _pre_log "RAM total      : ${ram_gb} GiB (min ${PREREQ_MIN_RAM_GB})"

    local fail=0
    if (( disk_gb < PREREQ_MIN_DISK_GB )); then
        _pre_err "Insufficient disk: ${disk_gb} GiB < ${PREREQ_MIN_DISK_GB} GiB"
        fail=1
    fi
    if (( ram_gb < PREREQ_MIN_RAM_GB )); then
        _pre_err "Insufficient RAM: ${ram_gb} GiB < ${PREREQ_MIN_RAM_GB} GiB"
        fail=1
    fi
    return $fail
}

# prereqs_ensure_pkg PKG ... — install packages via the family's manager.
prereqs_ensure_pkg() {
    [[ $# -eq 0 ]] && return 0
    local missing=()
    local p
    for p in "$@"; do
        if ! command -v "$p" >/dev/null 2>&1; then
            missing+=("$p")
        fi
    done
    if (( ${#missing[@]} == 0 )); then
        _pre_log "All packages present: $*"
        return 0
    fi
    _pre_log "Installing missing packages: ${missing[*]}"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        _pre_log "[dry-run] would install ${missing[*]} via $OS_FAMILY package manager"
        return 0
    fi
    case "$OS_FAMILY" in
        debian)
            DEBIAN_FRONTEND=noninteractive apt-get update -y >&2 \
                && DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >&2
            ;;
        rhel)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y "${missing[@]}" >&2
            else
                yum install -y "${missing[@]}" >&2
            fi
            ;;
        *)
            _pre_err "Cannot install packages on family=$OS_FAMILY"
            return 1
            ;;
    esac
}

# Ensure curl + jq.
prereqs_ensure_curl_jq() {
    prereqs_ensure_pkg curl jq
}

# Ensure helm CLI present.
prereqs_ensure_helm() {
    if command -v helm >/dev/null 2>&1; then
        _pre_log "helm already installed: $(helm version --short 2>&1 || true)"
        return 0
    fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        _pre_log "[dry-run] would install helm via get-helm-3 script"
        return 0
    fi
    _pre_log "Installing helm via official get_helm.sh"
    local tmp
    tmp=$(mktemp) || return 1
    if curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o "$tmp"; then
        chmod +x "$tmp"
        if HELM_INSTALL_DIR="/usr/local/bin" "$tmp" >&2; then
            rm -f "$tmp"
            _pre_log "helm installed: $(helm version --short 2>&1 || true)"
            return 0
        fi
    fi
    rm -f "$tmp"
    _pre_err "helm install failed; please install by hand"
    return 1
}

# Ensure k3s present + running. Uses the official curl|sh installer.
prereqs_ensure_k3s() {
    if command -v kubectl >/dev/null 2>&1 \
        && kubectl get nodes >/dev/null 2>&1; then
        _pre_log "kubectl already connects to a cluster; skipping k3s install"
        return 0
    fi
    if systemctl is-active --quiet k3s 2>/dev/null; then
        _pre_log "k3s service already active; will reuse"
    else
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            _pre_log "[dry-run] would install k3s via get.k3s.io"
            return 0
        fi
        _pre_log "Installing k3s (curl -sfL https://get.k3s.io | sh -)"
        if ! curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode=644" sh - >&2; then
            _pre_err "k3s installer exited non-zero"
            return 1
        fi
    fi

    # Make sure kubectl points at k3s.
    if ! command -v kubectl >/dev/null 2>&1; then
        if [[ -x /usr/local/bin/k3s ]]; then
            ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl 2>/dev/null || true
        fi
    fi
    export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
    _pre_log "KUBECONFIG=$KUBECONFIG"
    return 0
}

# Wait until at least one node shows Ready (timeout default 180s).
prereqs_wait_k8s_ready() {
    local timeout="${1:-180}"
    local elapsed=0
    if ! command -v kubectl >/dev/null 2>&1; then
        _pre_err "kubectl not available"
        return 1
    fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        _pre_log "[dry-run] skipping k8s ready wait"
        return 0
    fi
    while (( elapsed < timeout )); do
        if kubectl get nodes 2>/dev/null | awk 'NR>1 && $2=="Ready"{found=1} END{exit !found}'; then
            _pre_log "k8s nodes Ready (took ${elapsed}s)"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed+5))
    done
    _pre_err "Timed out waiting for k8s Ready after ${timeout}s"
    return 1
}

# Orchestrator.
prereqs_run() {
    prereqs_detect_os || return 1
    prereqs_check_resources || return 1
    prereqs_ensure_curl_jq    || return 1
    prereqs_ensure_helm       || return 1
    prereqs_ensure_k3s        || return 1
    prereqs_wait_k8s_ready 180 || return 1
    return 0
}
