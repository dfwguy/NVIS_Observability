#!/usr/bin/env bash
# lib/wizard.sh — interactive prompts library for nvis-platform installer.
#
# All functions write user-facing text to stderr and only echo final values
# to stdout, so callers can capture them safely with `$()`.
#
# Honors:
#   NVIS_NON_INTERACTIVE=1 — never block on user input; return defaults
#                            (fail with rc=2 if no default available).
#
# Primitives:
#   prompt LABEL DEFAULT VAR_NAME
#   prompt_silent LABEL VAR_NAME
#   prompt_bool LABEL DEFAULT_Y_OR_N VAR_NAME
#
# Validators:
#   wiz_validate_cluster_name <s>
#   wiz_validate_port <n>
#   wiz_validate_email <s>
#   wiz_validate_url <s>
#   wiz_validate_host <s>
#
# Composites:
#   prompt_smtp_block      — populates SMTP_* vars
#   prompt_teams_block     — populates TEAMS_WEBHOOK_URL
#   prompt_slack_block     — populates SLACK_WEBHOOK_URL
#   prompt_bmc_block       — populates BMC_HOSTS / BMC_USER / BMC_PASS
#   prompt_bcm_block       — populates BCM_HOST / BCM_USER / BCM_SSH_KEY
#   prompt_powershelf_block — populates POWERSHELF_HOSTS / POWERSHELF_USER / POWERSHELF_PASS
#   prompt_ufm_block       — populates UFM_HOST / UFM_USER / UFM_PASS
#   prompt_netq_block      — populates NETQ_URL / NETQ_TOKEN / NETQ_USER / NETQ_PASS
#   prompt_runai_block     — populates RUNAI_URL / RUNAI_TOKEN / RUNAI_CLUSTER_UUID / RUNAI_PROM_TARGET
#   prompt_nmc_block       — populates NMC_ENDPOINT
#
# ---------------------------------------------------------------------------

# Guard against being sourced twice.
if [[ -n "${_NVIS_WIZARD_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_NVIS_WIZARD_SH_LOADED=1

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------
_wiz_log() {
    printf '[wizard] %s\n' "$*" >&2
}

_wiz_err() {
    printf '[wizard][ERROR] %s\n' "$*" >&2
}

# ---------------------------------------------------------------------------
# validators
# ---------------------------------------------------------------------------
wiz_validate_cluster_name() {
    local s="${1:-}"
    [[ "$s" =~ ^[a-z0-9][a-z0-9-]*$ ]]
}

wiz_validate_port() {
    local n="${1:-}"
    [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 65535 ))
}

wiz_validate_email() {
    local s="${1:-}"
    # Cheap RFC-ish check — local@host.tld with at least one dot in domain.
    [[ "$s" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

wiz_validate_emails_list() {
    # Semicolon-separated list of addresses; every entry must pass.
    local list="${1:-}"
    [[ -z "$list" ]] && return 1
    local IFS=';'
    local addr
    for addr in $list; do
        addr="${addr#"${addr%%[![:space:]]*}"}"
        addr="${addr%"${addr##*[![:space:]]}"}"
        [[ -z "$addr" ]] && continue
        wiz_validate_email "$addr" || return 1
    done
    return 0
}

wiz_validate_url() {
    local s="${1:-}"
    [[ "$s" =~ ^https?://[^[:space:]]+$ ]]
}

wiz_validate_host() {
    # Accept hostnames, IPs, host:port. Must be non-empty, no whitespace.
    local s="${1:-}"
    [[ -n "$s" && "$s" != *[[:space:]]* ]]
}

# ---------------------------------------------------------------------------
# prompt LABEL DEFAULT VAR_NAME
#   Asks for a value. If NVIS_NON_INTERACTIVE=1, returns the default (or
#   the current value of VAR_NAME if already set in env).
# ---------------------------------------------------------------------------
prompt() {
    local label="$1"
    local default="${2:-}"
    local var_name="$3"
    local current="${!var_name:-}"
    local answer=""

    # Preloaded via env or --values-file?
    if [[ -n "$current" ]]; then
        _wiz_log "$var_name preloaded; using '$current'"
        printf -v "$var_name" '%s' "$current"
        return 0
    fi

    if [[ "${NVIS_NON_INTERACTIVE:-}" == "1" ]]; then
        if [[ -z "$default" ]]; then
            _wiz_err "$var_name has no default and non-interactive mode is on"
            return 2
        fi
        printf -v "$var_name" '%s' "$default"
        _wiz_log "$var_name=$default (non-interactive default)"
        return 0
    fi

    if [[ -n "$default" ]]; then
        printf '%s [%s]: ' "$label" "$default" >&2
    else
        printf '%s: ' "$label" >&2
    fi
    IFS= read -r answer || answer=""
    if [[ -z "$answer" ]]; then
        answer="$default"
    fi
    printf -v "$var_name" '%s' "$answer"
}

# ---------------------------------------------------------------------------
# prompt_silent LABEL VAR_NAME
#   Hidden read. No echo of the typed value. Empty input ⇒ empty result.
# ---------------------------------------------------------------------------
prompt_silent() {
    local label="$1"
    local var_name="$2"
    local current="${!var_name:-}"
    local answer=""

    if [[ -n "$current" ]]; then
        _wiz_log "$var_name preloaded (hidden); not re-prompting"
        return 0
    fi

    if [[ "${NVIS_NON_INTERACTIVE:-}" == "1" ]]; then
        _wiz_err "$var_name is a secret and not preloaded; cannot prompt in non-interactive mode"
        return 2
    fi

    printf '%s: ' "$label" >&2
    IFS= read -r -s answer || answer=""
    printf '\n' >&2
    printf -v "$var_name" '%s' "$answer"
}

# ---------------------------------------------------------------------------
# prompt_bool LABEL DEFAULT_Y_OR_N VAR_NAME
#   Yes/No prompt. Stores literal "true" or "false" in VAR_NAME.
# ---------------------------------------------------------------------------
prompt_bool() {
    local label="$1"
    local default="${2:-N}"
    local var_name="$3"
    local current="${!var_name:-}"

    # Normalize a preloaded value.
    if [[ -n "$current" ]]; then
        case "$(printf '%s' "$current" | tr '[:upper:]' '[:lower:]')" in
            y|yes|true|1)
                printf -v "$var_name" '%s' 'true'
                _wiz_log "$var_name preloaded ⇒ true"
                return 0
                ;;
            n|no|false|0)
                printf -v "$var_name" '%s' 'false'
                _wiz_log "$var_name preloaded ⇒ false"
                return 0
                ;;
        esac
    fi

    # Default normalized to single-char display.
    local def_char
    case "$(printf '%s' "$default" | tr '[:upper:]' '[:lower:]')" in
        y|yes|true|1) def_char='Y' ;;
        *)             def_char='N' ;;
    esac

    if [[ "${NVIS_NON_INTERACTIVE:-}" == "1" ]]; then
        if [[ "$def_char" == "Y" ]]; then
            printf -v "$var_name" '%s' 'true'
        else
            printf -v "$var_name" '%s' 'false'
        fi
        _wiz_log "$var_name=${!var_name} (non-interactive default)"
        return 0
    fi

    local hint
    if [[ "$def_char" == "Y" ]]; then hint='Y/n'; else hint='y/N'; fi
    local answer=""
    while :; do
        printf '%s [%s]: ' "$label" "$hint" >&2
        IFS= read -r answer || answer=""
        answer="${answer:-$def_char}"
        case "$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')" in
            y|yes) printf -v "$var_name" '%s' 'true';  return 0 ;;
            n|no)  printf -v "$var_name" '%s' 'false'; return 0 ;;
            *)
                printf 'Please answer y or n.\n' >&2
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# prompt_validated LABEL DEFAULT VAR_NAME VALIDATOR_FN
#   Like prompt() but re-asks until the validator passes.
# ---------------------------------------------------------------------------
prompt_validated() {
    local label="$1"
    local default="${2:-}"
    local var_name="$3"
    local validator="$4"

    while :; do
        prompt "$label" "$default" "$var_name" || return $?
        local val="${!var_name}"
        if "$validator" "$val"; then
            return 0
        fi
        if [[ "${NVIS_NON_INTERACTIVE:-}" == "1" ]]; then
            _wiz_err "$var_name='$val' failed validation by $validator"
            return 2
        fi
        printf 'Invalid value (%s rejected by %s); please retry.\n' \
            "$val" "$validator" >&2
        # Clear so prompt() will ask again instead of treating it as preloaded.
        printf -v "$var_name" '%s' ''
    done
}

# ---------------------------------------------------------------------------
# generate_password [LENGTH]
#   Emit a random alphanumeric password of LENGTH (default 20) on stdout.
# ---------------------------------------------------------------------------
generate_password() {
    local len="${1:-20}"
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null \
        | head -c "$len"
    printf '\n'
}

# ---------------------------------------------------------------------------
# Composite blocks
# ---------------------------------------------------------------------------

# Email / SMTP — populates SMTP_HOST SMTP_PORT SMTP_FROM SMTP_TO
# SMTP_AUTH ("true"/"false") + SMTP_USER SMTP_PASS (if SMTP_AUTH)
# SMTP_STARTTLS ("true"/"false", default true)
prompt_smtp_block() {
    _wiz_log "Collecting SMTP configuration"
    prompt_validated "SMTP host (e.g. mail.example.com)" "" SMTP_HOST wiz_validate_host
    prompt_validated "SMTP port" "25" SMTP_PORT wiz_validate_port
    prompt_validated "From address" "" SMTP_FROM wiz_validate_email
    prompt_validated "Recipient(s), semicolon-separated" "" SMTP_TO wiz_validate_emails_list

    prompt_bool "Does this SMTP server require auth?" "N" SMTP_AUTH
    if [[ "${SMTP_AUTH}" == "true" ]]; then
        prompt "SMTP username" "" SMTP_USER
        prompt_silent "SMTP password (hidden)" SMTP_PASS
    fi
    prompt_bool "Use STARTTLS?" "Y" SMTP_STARTTLS
}

prompt_teams_block() {
    _wiz_log "Collecting Teams webhook"
    prompt_silent "Teams Incoming Webhook URL (hidden)" TEAMS_WEBHOOK_URL
    if [[ -z "${TEAMS_WEBHOOK_URL:-}" ]]; then
        _wiz_err "Teams webhook URL is empty; disabling Teams alerts"
        return 1
    fi
    return 0
}

prompt_slack_block() {
    _wiz_log "Collecting Slack webhook"
    prompt_silent "Slack Incoming Webhook URL (hidden)" SLACK_WEBHOOK_URL
    if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
        _wiz_err "Slack webhook URL is empty; disabling Slack alerts"
        return 1
    fi
    return 0
}

prompt_bmc_block() {
    # Populates BMC_HOSTS BMC_USER BMC_PASS.
    # Idempotent: skips fields already populated (i.e. reuse across redfish-N
    # / IPMI prompts).
    if [[ -n "${BMC_HOSTS:-}" && -n "${BMC_USER:-}" && -n "${BMC_PASS:-}" ]]; then
        _wiz_log "BMC creds already collected; reusing"
        return 0
    fi
    _wiz_log "Collecting BMC credentials (shared across Redfish / IPMI)"
    prompt "BMC hosts (CSV / @file / CIDR)" "" BMC_HOSTS
    prompt "BMC username" "admin" BMC_USER
    prompt_silent "BMC password (hidden)" BMC_PASS
}

prompt_bcm_block() {
    _wiz_log "Collecting BCM/Slurm SSH configuration"
    prompt "BCM head node (hostname or IP)" "" BCM_HOST
    prompt "BCM SSH user" "root" BCM_USER
    prompt "BCM SSH private key path" "$HOME/.ssh/id_ed25519" BCM_SSH_KEY
}

prompt_powershelf_block() {
    _wiz_log "Collecting PowerShelf (LiteOn PF-1333-13RD) configuration"
    prompt "PowerShelf IPs (CSV) or @/path/to/file" "" POWERSHELF_HOSTS
    prompt "PowerShelf BMC username" "root" POWERSHELF_USER
    prompt_silent "PowerShelf BMC password (hidden)" POWERSHELF_PASS
}

prompt_ufm_block() {
    _wiz_log "Collecting UFM configuration"
    prompt "UFM host (host or host:port)" "" UFM_HOST
    prompt "UFM username" "admin" UFM_USER
    prompt_silent "UFM password (hidden)" UFM_PASS
}

prompt_netq_block() {
    _wiz_log "Collecting NetQ configuration"
    prompt_validated "NetQ base URL (https://...)" "" NETQ_URL wiz_validate_url
    prompt "NetQ bearer token (leave blank to use user/pass)" "" NETQ_TOKEN
    if [[ -z "${NETQ_TOKEN}" ]]; then
        prompt "NetQ username" "admin" NETQ_USER
        prompt_silent "NetQ password (hidden)" NETQ_PASS
    fi
}

prompt_runai_block() {
    _wiz_log "Collecting RunAI configuration"
    prompt_validated "RunAI base URL (https://...)" "" RUNAI_URL wiz_validate_url
    prompt_silent "RunAI API token (hidden)" RUNAI_TOKEN
    prompt "RunAI cluster UUID" "" RUNAI_CLUSTER_UUID
    prompt "RunAI Prometheus federation target (host:nodePort)" "" RUNAI_PROM_TARGET
}

prompt_nmc_block() {
    _wiz_log "Collecting NMC (NVIDIA Mission Control) federation configuration"
    prompt "NMC head node host" "" NMC_HOST
    prompt "NMC BCM exporter port" "8081" NMC_PORT
    prompt "NMC BCM exporter username" "apiuser" NMC_USER
    prompt_silent "NMC BCM exporter password (hidden)" NMC_PASS
}

# Exported public surface:
#   prompt, prompt_silent, prompt_bool, prompt_validated, generate_password,
#   wiz_validate_*, prompt_*_block
