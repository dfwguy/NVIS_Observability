#!/usr/bin/env bash
# lib/secrets.sh — k8s Secret creation for nvis-platform integrations.
#
# Every secret lives in namespace $SECRETS_NAMESPACE (default nvis-monitoring).
# All `create_secret_*` functions are idempotent:
#   `kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -`
#
# Public functions (per integration):
#   create_secret_bmc            — nvis-bmc-credentials (Redfish + IPMI shared)
#   create_secret_bmc_creds_json — nvis-bmc-credentials-json (IPMI SEL/SOL)
#   create_secret_bcm_ssh        — nvis-bcm-ssh-key
#   create_secret_ufm            — nvis-ufm-credentials
#   create_secret_netq           — nvis-netq-credentials
#   create_secret_runai          — nvis-runai-token
#   create_secret_smtp           — nvis-smtp-credentials
#   create_secret_teams          — nvis-teams-webhook
#   create_secret_slack          — nvis-slack-webhook
#   create_secret_grafana_admin  — nvis-grafana-admin
#   create_secret_ngc            — nvis-ngc-api-key
#
# Public env:
#   SECRETS_NAMESPACE — default nvis-monitoring
#   DRY_RUN=true      — print the YAML, never apply
# ---------------------------------------------------------------------------

if [[ -n "${_NVIS_SECRETS_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_NVIS_SECRETS_SH_LOADED=1

SECRETS_NAMESPACE="${SECRETS_NAMESPACE:-nvis-monitoring}"

_sec_log() {
    printf '[secrets] %s\n' "$*" >&2
}

_sec_err() {
    printf '[secrets][ERROR] %s\n' "$*" >&2
}

# _apply_secret NAME --from-literal=k=v --from-literal=k=v ...
#   Centralized idempotent apply with --dry-run=client | apply -f -.
#   Respects DRY_RUN=true (only prints YAML, doesn't apply).
_apply_secret() {
    local name="$1"; shift
    if ! command -v kubectl >/dev/null 2>&1; then
        _sec_err "kubectl not on PATH"
        return 1
    fi

    # Render manifest first (works in dry-run too).
    local yaml
    yaml=$(kubectl create secret generic "$name" \
        --namespace="$SECRETS_NAMESPACE" \
        "$@" \
        --dry-run=client -o yaml 2>/dev/null) || {
        _sec_err "Failed to render Secret $name"
        return 1
    }

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        _sec_log "[dry-run] would apply Secret $name to $SECRETS_NAMESPACE"
        printf '%s\n' "$yaml" >&2
        return 0
    fi

    printf '%s\n' "$yaml" | kubectl apply -f - >&2 \
        || { _sec_err "kubectl apply failed for Secret $name"; return 1; }
    _sec_log "Applied Secret $SECRETS_NAMESPACE/$name"
}

# _require_vars VAR1 VAR2 ... — fail if any are empty.
_require_vars() {
    local missing=()
    local v
    for v in "$@"; do
        [[ -z "${!v:-}" ]] && missing+=("$v")
    done
    if (( ${#missing[@]} > 0 )); then
        _sec_err "Required vars not set: ${missing[*]}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Per-integration secrets
# ---------------------------------------------------------------------------

create_secret_bmc() {
    _require_vars BMC_USER BMC_PASS BMC_HOSTS || return 1
    _apply_secret nvis-bmc-credentials \
        "--from-literal=BMC_USER=${BMC_USER}" \
        "--from-literal=BMC_PASS=${BMC_PASS}" \
        "--from-literal=BMC_HOSTS=${BMC_HOSTS}"
}

# Build BMC_CREDS_JSON for IPMI SEL/SOL — a JSON array of
#   {"bmc":"a.b.c.d","user":"...","pass":"..."}
# from the same BMC_HOSTS / BMC_USER / BMC_PASS already collected.
create_secret_bmc_creds_json() {
    _require_vars BMC_USER BMC_PASS BMC_HOSTS || return 1
    local json
    json=$(
        python3 - <<'PY' 2>/dev/null
import json, os, re, sys
src = os.environ.get("BMC_HOSTS", "")
user = os.environ.get("BMC_USER", "")
pw   = os.environ.get("BMC_PASS", "")
# Accept CSV, whitespace, newlines.
parts = [p.strip() for p in re.split(r"[,\s]+", src) if p.strip()]
out = [{"bmc": p, "user": user, "pass": pw} for p in parts]
sys.stdout.write(json.dumps(out))
PY
    )
    if [[ -z "$json" ]]; then
        # Fall back to single-host JSON if python3 unavailable.
        json="[{\"bmc\":\"${BMC_HOSTS}\",\"user\":\"${BMC_USER}\",\"pass\":\"${BMC_PASS}\"}]"
    fi
    _apply_secret nvis-bmc-credentials-json \
        "--from-literal=BMC_CREDS_JSON=${json}"
}

create_secret_bcm_ssh() {
    _require_vars BCM_SSH_KEY || return 1
    if [[ ! -r "${BCM_SSH_KEY}" ]]; then
        _sec_err "BCM_SSH_KEY not readable: ${BCM_SSH_KEY}"
        return 1
    fi
    if ! command -v kubectl >/dev/null 2>&1; then
        _sec_err "kubectl not on PATH"
        return 1
    fi
    local yaml
    yaml=$(kubectl create secret generic nvis-bcm-ssh-key \
        --namespace="$SECRETS_NAMESPACE" \
        "--from-file=id_rsa=${BCM_SSH_KEY}" \
        "--from-literal=BCM_USER=${BCM_USER:-root}" \
        "--from-literal=BCM_HOST=${BCM_HOST:-}" \
        --dry-run=client -o yaml 2>/dev/null) || {
        _sec_err "Failed to render Secret nvis-bcm-ssh-key"
        return 1
    }
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        _sec_log "[dry-run] would apply Secret nvis-bcm-ssh-key"
        return 0
    fi
    printf '%s\n' "$yaml" | kubectl apply -f - >&2 \
        || { _sec_err "kubectl apply failed for nvis-bcm-ssh-key"; return 1; }
    _sec_log "Applied Secret $SECRETS_NAMESPACE/nvis-bcm-ssh-key"
}

create_secret_ufm() {
    _require_vars UFM_HOST UFM_USER UFM_PASS || return 1
    _apply_secret nvis-ufm-credentials \
        "--from-literal=UFM_HOST=${UFM_HOST}" \
        "--from-literal=UFM_USER=${UFM_USER}" \
        "--from-literal=UFM_PASS=${UFM_PASS}"
}

create_secret_netq() {
    _require_vars NETQ_URL || return 1
    local args=( "--from-literal=NETQ_URL=${NETQ_URL}" )
    if [[ -n "${NETQ_TOKEN:-}" ]]; then
        args+=( "--from-literal=NETQ_TOKEN=${NETQ_TOKEN}" )
    elif [[ -n "${NETQ_USER:-}" && -n "${NETQ_PASS:-}" ]]; then
        args+=( "--from-literal=NETQ_USER=${NETQ_USER}" )
        args+=( "--from-literal=NETQ_PASS=${NETQ_PASS}" )
    else
        _sec_err "NetQ: need NETQ_TOKEN or NETQ_USER+NETQ_PASS"
        return 1
    fi
    _apply_secret nvis-netq-credentials "${args[@]}"
}

create_secret_runai() {
    _require_vars RUNAI_URL RUNAI_TOKEN RUNAI_CLUSTER_UUID || return 1
    _apply_secret nvis-runai-token \
        "--from-literal=RUNAI_URL=${RUNAI_URL}" \
        "--from-literal=RUNAI_TOKEN=${RUNAI_TOKEN}" \
        "--from-literal=RUNAI_CLUSTER_UUID=${RUNAI_CLUSTER_UUID}" \
        "--from-literal=RUNAI_PROM_TARGET=${RUNAI_PROM_TARGET:-}"
}

create_secret_smtp() {
    _require_vars SMTP_HOST SMTP_FROM SMTP_TO || return 1
    local args=(
        "--from-literal=SMTP_HOST=${SMTP_HOST}"
        "--from-literal=SMTP_PORT=${SMTP_PORT:-25}"
        "--from-literal=SMTP_FROM=${SMTP_FROM}"
        "--from-literal=SMTP_TO=${SMTP_TO}"
        "--from-literal=SMTP_STARTTLS=${SMTP_STARTTLS:-true}"
        "--from-literal=SMTP_AUTH=${SMTP_AUTH:-false}"
    )
    if [[ "${SMTP_AUTH:-false}" == "true" ]]; then
        args+=( "--from-literal=SMTP_USER=${SMTP_USER:-}" )
        args+=( "--from-literal=SMTP_PASS=${SMTP_PASS:-}" )
    fi
    _apply_secret nvis-smtp-credentials "${args[@]}"
}

create_secret_teams() {
    _require_vars TEAMS_WEBHOOK_URL || return 1
    _apply_secret nvis-teams-webhook \
        "--from-literal=TEAMS_WEBHOOK_URL=${TEAMS_WEBHOOK_URL}"
}

create_secret_slack() {
    _require_vars SLACK_WEBHOOK_URL || return 1
    _apply_secret nvis-slack-webhook \
        "--from-literal=SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL}"
}

create_secret_grafana_admin() {
    _require_vars GRAFANA_ADMIN_PASSWORD || return 1
    _apply_secret nvis-grafana-admin \
        "--from-literal=admin-user=admin" \
        "--from-literal=admin-password=${GRAFANA_ADMIN_PASSWORD}"
}

create_secret_ngc() {
    [[ -z "${NGC_API_KEY:-}" ]] && {
        _sec_log "No NGC_API_KEY set; skipping nvis-ngc-api-key Secret"
        return 0
    }
    _apply_secret nvis-ngc-api-key \
        "--from-literal=NGC_API_KEY=${NGC_API_KEY}"
}

# ---------------------------------------------------------------------------
# Dispatcher: create_all_enabled_secrets — looks at INT_* flags and calls
# the appropriate per-integration function.
# ---------------------------------------------------------------------------
create_all_enabled_secrets() {
    local errs=0

    [[ "${GRAFANA_ADMIN_PASSWORD:-}" != "" ]] && { create_secret_grafana_admin || ((errs++)); }
    [[ "${NGC_API_KEY:-}" != "" ]] && { create_secret_ngc || ((errs++)); }

    if [[ "${INT_BCM:-false}" == "true" ]]; then
        create_secret_bcm_ssh || ((errs++))
    fi

    if [[ "${INT_REDFISH_MAIN:-false}" == "true" \
       || "${INT_REDFISH_NM:-false}" == "true" \
       || "${INT_REDFISH_FAST:-false}" == "true" \
       || "${INT_REDFISH_SENSORS:-false}" == "true" ]]; then
        create_secret_bmc || ((errs++))
    fi

    if [[ "${INT_IPMI_SEL:-false}" == "true" || "${INT_IPMI_SOL:-false}" == "true" ]]; then
        create_secret_bmc_creds_json || ((errs++))
    fi

    [[ "${INT_UFM:-false}"   == "true" ]] && { create_secret_ufm   || ((errs++)); }
    [[ "${INT_NETQ:-false}"  == "true" ]] && { create_secret_netq  || ((errs++)); }
    [[ "${INT_RUNAI:-false}" == "true" ]] && { create_secret_runai || ((errs++)); }

    [[ "${INT_ALERT_EMAIL:-false}" == "true" ]] && { create_secret_smtp  || ((errs++)); }
    [[ "${INT_ALERT_TEAMS:-false}" == "true" ]] && { create_secret_teams || ((errs++)); }
    [[ "${INT_ALERT_SLACK:-false}" == "true" ]] && { create_secret_slack || ((errs++)); }

    if (( errs > 0 )); then
        _sec_err "$errs secret(s) failed"
        return 1
    fi
    _sec_log "All enabled secrets applied"
}
