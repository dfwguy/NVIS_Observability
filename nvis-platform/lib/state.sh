#!/usr/bin/env bash
# lib/state.sh — install state persistence for nvis-platform.
#
# Two storage tiers:
#   1. Local file (atomic write)     — /var/lib/nvis-platform/install-state.env
#   2. K8s ConfigMap (once up)       — namespace/nvis-install-state
#
# Plaintext secrets NEVER go into either. They live in k8s Secrets only.
#
# Public functions:
#   state_init                    — choose state dir, ensure exists
#   save_state                    — atomic write of safe vars to STATE_FILE
#   load_state [path]             — source STATE_FILE if present
#   save_state_configmap [ns]     — apply ConfigMap from STATE_FILE
#   redact_state [path]           — print contents w/ pw-like values masked
#   state_get KEY [default]       — read one key from STATE_FILE
#
# Public env:
#   STATE_DIR     default /var/lib/nvis-platform
#   STATE_FILE    default $STATE_DIR/install-state.env
#   STATE_NS      default nvis-monitoring
#   STATE_CM_NAME default nvis-install-state
# ---------------------------------------------------------------------------

if [[ -n "${_NVIS_STATE_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_NVIS_STATE_SH_LOADED=1

STATE_DIR="${STATE_DIR:-/var/lib/nvis-platform}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/install-state.env}"
STATE_NS="${STATE_NS:-nvis-monitoring}"
STATE_CM_NAME="${STATE_CM_NAME:-nvis-install-state}"

# Vars considered secret — NEVER serialized to STATE_FILE.
# Keep this list in sync with secrets.sh.
_STATE_SECRET_KEYS=(
    BMC_PASS
    UFM_PASS
    NETQ_PASS
    NETQ_TOKEN
    RUNAI_TOKEN
    SMTP_PASS
    TEAMS_WEBHOOK_URL
    SLACK_WEBHOOK_URL
    GRAFANA_ADMIN_PASSWORD
    NGC_API_KEY
)

# Vars that may be persisted to STATE_FILE & ConfigMap.
_STATE_SAFE_KEYS=(
    CLUSTER_NAME
    OBSVM_HOST
    DGX_FLAVOR
    INT_DCGM
    INT_NODE_EXPORTER
    INT_ALLOY
    INT_BCM
    INT_SLURM
    INT_CGROUP
    INT_REDFISH_MAIN
    INT_REDFISH_NM
    INT_REDFISH_FAST
    INT_REDFISH_SENSORS
    INT_IPMI_SEL
    INT_IPMI_SOL
    INT_POWERSHELF
    INT_UFM
    INT_NETQ
    INT_RUNAI
    INT_NMC
    INT_ALERT_EMAIL
    INT_ALERT_TEAMS
    INT_ALERT_SLACK
    BMC_HOSTS
    BMC_USER
    POWERSHELF_HOSTS
    POWERSHELF_USER
    BCM_HOST
    BCM_USER
    BCM_SSH_KEY
    UFM_HOST
    UFM_USER
    NETQ_URL
    NETQ_USER
    RUNAI_URL
    RUNAI_CLUSTER_UUID
    RUNAI_PROM_TARGET
    NMC_HOST
    NMC_PORT
    NMC_USER
    SMTP_HOST
    SMTP_PORT
    SMTP_FROM
    SMTP_TO
    SMTP_AUTH
    SMTP_USER
    SMTP_STARTTLS
    INSTALL_VERSION
    INSTALL_TIMESTAMP
)

_state_log() {
    printf '[state] %s\n' "$*" >&2
}

_state_err() {
    printf '[state][ERROR] %s\n' "$*" >&2
}

# state_init — ensure $STATE_DIR exists (mode 0700 since some collected
# values could be sensitive, even after redaction).
state_init() {
    if [[ -d "$STATE_DIR" ]]; then
        return 0
    fi
    if mkdir -p "$STATE_DIR" 2>/dev/null; then
        chmod 0700 "$STATE_DIR" 2>/dev/null || true
        _state_log "Created $STATE_DIR"
        return 0
    fi
    # Fallback for tests / non-root.
    STATE_DIR="${HOME}/.nvis-platform"
    STATE_FILE="${STATE_DIR}/install-state.env"
    mkdir -p "$STATE_DIR"
    chmod 0700 "$STATE_DIR" 2>/dev/null || true
    _state_log "Falling back to $STATE_DIR (no perms for /var/lib)"
}

# _state_is_secret_key KEY → 0 if listed in _STATE_SECRET_KEYS
_state_is_secret_key() {
    local k="$1"
    local s
    for s in "${_STATE_SECRET_KEYS[@]}"; do
        [[ "$k" == "$s" ]] && return 0
    done
    return 1
}

# _state_shell_quote VAL → emit `'VAL'`, escaping embedded single quotes.
_state_shell_quote() {
    local v="${1-}"
    v=${v//\'/\'\\\'\'}
    printf "'%s'" "$v"
}

# save_state — atomic write of safe vars to STATE_FILE.
save_state() {
    state_init
    local tmp
    tmp=$(mktemp "${STATE_FILE}.XXXXXX") || {
        _state_err "Could not mktemp next to $STATE_FILE"
        return 1
    }

    {
        printf '# nvis-platform install state — DO NOT EDIT BY HAND\n'
        printf '# Generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '# Plaintext secrets are NOT stored here; see k8s Secrets.\n'
        local k
        for k in "${_STATE_SAFE_KEYS[@]}"; do
            if _state_is_secret_key "$k"; then continue; fi
            local v="${!k:-}"
            printf '%s=%s\n' "$k" "$(_state_shell_quote "$v")"
        done
    } > "$tmp"

    chmod 0600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$STATE_FILE"
    _state_log "Wrote $STATE_FILE"
}

# load_state [path] — source the state file if present.
load_state() {
    local path="${1:-$STATE_FILE}"
    if [[ ! -f "$path" ]]; then
        _state_log "No state file at $path"
        return 1
    fi
    # shellcheck disable=SC1090
    . "$path"
    _state_log "Loaded $path"
}

# save_state_configmap [namespace]
save_state_configmap() {
    local ns="${1:-$STATE_NS}"
    if [[ ! -f "$STATE_FILE" ]]; then
        _state_err "No $STATE_FILE to upload"
        return 1
    fi
    if ! command -v kubectl >/dev/null 2>&1; then
        _state_err "kubectl not on PATH; skipping ConfigMap upload"
        return 1
    fi
    kubectl create configmap "$STATE_CM_NAME" \
        --namespace="$ns" \
        --from-file=install-state.env="$STATE_FILE" \
        --dry-run=client -o yaml \
        | kubectl apply -f - >&2 \
        || { _state_err "kubectl apply failed for ConfigMap $STATE_CM_NAME"; return 1; }
    _state_log "Synced state to ConfigMap $ns/$STATE_CM_NAME"
}

# redact_state [path] — print the state file with any *PASS / *TOKEN /
# *WEBHOOK_URL lines masked. (For display only.)
redact_state() {
    local path="${1:-$STATE_FILE}"
    [[ -f "$path" ]] || { _state_err "No $path"; return 1; }
    awk '
        /^\s*#/ { print; next }
        /^[A-Z_][A-Z0-9_]*=/ {
            key = $0
            sub(/=.*/, "", key)
            if (key ~ /(PASS|TOKEN|WEBHOOK_URL|API_KEY)$/) {
                printf("%s=<REDACTED>\n", key)
            } else {
                print
            }
            next
        }
        { print }
    ' "$path"
}

# state_get KEY [default]
state_get() {
    local key="$1"
    local def="${2:-}"
    [[ -f "$STATE_FILE" ]] || { printf '%s' "$def"; return 0; }
    local line
    line=$(grep -E "^${key}=" "$STATE_FILE" 2>/dev/null | tail -n 1) || true
    if [[ -z "$line" ]]; then printf '%s' "$def"; return 0; fi
    # Strip key= and surrounding single-quotes.
    local val="${line#${key}=}"
    if [[ "$val" =~ ^\'(.*)\'$ ]]; then
        val="${BASH_REMATCH[1]}"
        val="${val//\'\\\'\'/\'}"
    fi
    printf '%s' "$val"
}
