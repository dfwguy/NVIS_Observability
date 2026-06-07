#!/usr/bin/env bash
# lib/detect.sh — DGX flavor probe
#
# Detects the DGX hardware flavor at install time and exports a stable token
# (e.g. B300, H200, B200, H100, A100, custom, UNKNOWN) used by:
#   - Grafana templating var `dgx_flavor`
#   - Prometheus `external_labels.dgx_flavor`
#   - Alert label `dgx_flavor`
#
# Usage:
#   source lib/detect.sh
#   DGX_FLAVOR=$(detect_dgx_flavor)
#   validate_dgx_flavor "$DGX_FLAVOR" || exit 1
#
# Standalone (for testing):
#   bash lib/detect.sh
#
# Environment inputs (all optional):
#   DGX_FLAVOR_OVERRIDE — short-circuit; emitted verbatim if set.
#   BCM_HOST, BCM_USER, BCM_SSH_KEY — enable BCM cmsh probe.
#   BMC_HOSTS, BMC_USER, BMC_PASS  — enable Redfish probe.
#                                   BMC_HOSTS may be CSV, newline-list,
#                                   "@/path/to/file", or CIDR.
#   NVIS_NON_INTERACTIVE=1 — skip the interactive prompt; emit UNKNOWN.

set -euo pipefail

# ---------------------------------------------------------------------------
# logging — everything except the final flavor token goes to stderr
# ---------------------------------------------------------------------------
_detect_log() {
    printf '[detect] %s\n' "$*" >&2
}

# ---------------------------------------------------------------------------
# validate_dgx_flavor <token>
#   Returns 0 if token matches ^[A-Z0-9][A-Z0-9-]*$, 1 otherwise.
# ---------------------------------------------------------------------------
validate_dgx_flavor() {
    local v="${1:-}"
    if [[ "$v" =~ ^[A-Z0-9][A-Z0-9-]*$ ]]; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# _sanitize_flavor <raw>
#   Uppercase, strip everything but [A-Z0-9-], collapse runs of '-',
#   trim leading/trailing '-'. Echoes the sanitized token.
# ---------------------------------------------------------------------------
_sanitize_flavor() {
    local raw="${1:-}"
    local out
    out=$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]' \
        | tr -c 'A-Z0-9-' '-' \
        | sed -E 's/-+/-/g; s/^-+//; s/-+$//')
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# _first_bmc_host
#   Resolve BMC_HOSTS into a single IP/hostname.
#   Supports: CSV, newline-separated, "@/path/to/file", CIDR (a.b.c.d/NN).
# ---------------------------------------------------------------------------
_first_bmc_host() {
    local src="${BMC_HOSTS:-}"
    [[ -z "$src" ]] && return 1

    # @file form
    if [[ "$src" == @* ]]; then
        local f="${src#@}"
        if [[ ! -r "$f" ]]; then
            _detect_log "BMC_HOSTS file not readable: $f"
            return 1
        fi
        src=$(grep -vE '^\s*(#|$)' "$f" | head -n 1 || true)
        [[ -z "$src" ]] && return 1
    fi

    # Normalize separators (commas, whitespace, newlines) into newlines,
    # take the first non-empty token.
    local first
    first=$(printf '%s' "$src" | tr ',\n\r\t ' '\n' \
        | grep -vE '^$' | head -n 1 || true)
    [[ -z "$first" ]] && return 1

    # CIDR? expand to network address's first usable host (network + 1).
    if [[ "$first" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)/([0-9]+)$ ]]; then
        local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
        local c="${BASH_REMATCH[3]}" d="${BASH_REMATCH[4]}"
        local prefix="${BASH_REMATCH[5]}"
        # 32-bit numeric address
        local ip_num=$(( (a<<24) | (b<<16) | (c<<8) | d ))
        local mask=$(( 0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF ))
        local net=$(( ip_num & mask ))
        local host_ip=$(( net + 1 ))
        first=$(printf '%d.%d.%d.%d' \
            $(( (host_ip>>24) & 0xFF )) \
            $(( (host_ip>>16) & 0xFF )) \
            $(( (host_ip>>8) & 0xFF )) \
            $(( host_ip & 0xFF )))
    fi

    printf '%s' "$first"
}

# ---------------------------------------------------------------------------
# _probe_bcm
#   Try BCM cmsh `category list`, parse for known dgx-* tokens.
#   Echoes the winning flavor on success (B300/B200/B100/H200/H100/A100),
#   returns non-zero on any failure.
# ---------------------------------------------------------------------------
_probe_bcm() {
    if [[ -z "${BCM_HOST:-}" || -z "${BCM_USER:-}" || -z "${BCM_SSH_KEY:-}" ]]; then
        _detect_log "BCM probe skipped (BCM_HOST/BCM_USER/BCM_SSH_KEY not all set)"
        return 1
    fi
    if [[ ! -r "$BCM_SSH_KEY" ]]; then
        _detect_log "BCM probe skipped (BCM_SSH_KEY not readable: $BCM_SSH_KEY)"
        return 1
    fi

    _detect_log "BCM probe: ssh ${BCM_USER}@${BCM_HOST} cmsh -c 'category list'"
    local out rc=0
    out=$(timeout 15 ssh \
        -i "$BCM_SSH_KEY" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 \
        "${BCM_USER}@${BCM_HOST}" \
        "cmsh -c 'category list'" 2>/dev/null) || rc=$?

    if [[ $rc -ne 0 ]]; then
        _detect_log "BCM probe failed (exit $rc)"
        return 1
    fi
    if [[ -z "$out" ]]; then
        _detect_log "BCM probe returned empty output"
        return 1
    fi

    # Lowercase the haystack once for case-insensitive matching.
    local lc
    lc=$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')

    local flavors=(dgx-b300 dgx-b200 dgx-b100 dgx-h200 dgx-h100 dgx-a100)
    local best="" best_count=0
    local f count
    for f in "${flavors[@]}"; do
        count=$(printf '%s' "$lc" | grep -o -F "$f" | wc -l | tr -d ' ')
        if (( count > best_count )); then
            best_count=$count
            best="$f"
        fi
    done

    if [[ -z "$best" ]]; then
        _detect_log "BCM probe: no known dgx-* flavor in cmsh output"
        return 1
    fi

    # dgx-b300 -> B300
    local token="${best#dgx-}"
    token=$(printf '%s' "$token" | tr '[:lower:]' '[:upper:]')
    _detect_log "BCM probe: matched '$best' x$best_count -> $token"
    printf '%s' "$token"
    return 0
}

# ---------------------------------------------------------------------------
# _map_redfish_model <raw model string>
#   Map well-known Redfish Model strings to our canonical tokens.
#   On no match, sanitize and return whatever we got.
# ---------------------------------------------------------------------------
_map_redfish_model() {
    local m="${1:-}"
    local lc
    lc=$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')
    case "$lc" in
        *"b300"*)  printf 'B300'; return 0 ;;
        *"b200"*)  printf 'B200'; return 0 ;;
        *"b100"*)  printf 'B100'; return 0 ;;
        *"h200"*)  printf 'H200'; return 0 ;;
        *"h100"*)  printf 'H100'; return 0 ;;
        *"a100"*)  printf 'A100'; return 0 ;;
    esac
    # unknown — sanitize raw
    _sanitize_flavor "$m"
}

# ---------------------------------------------------------------------------
# _probe_redfish
#   Hit /redfish/v1/Systems/, follow Members[0], read Model.
# ---------------------------------------------------------------------------
_probe_redfish() {
    if [[ -z "${BMC_HOSTS:-}" || -z "${BMC_USER:-}" || -z "${BMC_PASS:-}" ]]; then
        _detect_log "Redfish probe skipped (BMC_HOSTS/BMC_USER/BMC_PASS not all set)"
        return 1
    fi

    local ip
    ip=$(_first_bmc_host) || {
        _detect_log "Redfish probe: could not resolve first BMC host"
        return 1
    }
    if [[ -z "$ip" ]]; then
        _detect_log "Redfish probe: empty BMC host"
        return 1
    fi

    _detect_log "Redfish probe: GET https://$ip/redfish/v1/Systems/"
    local systems rc=0
    systems=$(curl -sk -u "${BMC_USER}:${BMC_PASS}" \
        --connect-timeout 10 --max-time 30 \
        "https://${ip}/redfish/v1/Systems/" 2>/dev/null) || rc=$?
    if [[ $rc -ne 0 || -z "$systems" ]]; then
        _detect_log "Redfish probe: Systems collection unreachable (exit $rc)"
        return 1
    fi

    # Pull the first Members[*].@odata.id without a JSON lib.
    # Look for the first occurrence of "@odata.id":"..." after "Members"
    local member_path
    member_path=$(printf '%s' "$systems" \
        | tr -d '\n' \
        | grep -oE '"Members"[^]]*' \
        | grep -oE '"@odata\.id"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | head -n 1 \
        | sed -E 's/.*"@odata\.id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

    if [[ -z "$member_path" ]]; then
        _detect_log "Redfish probe: no Members[0].@odata.id found"
        return 1
    fi

    _detect_log "Redfish probe: GET https://$ip${member_path}"
    local sys
    rc=0
    sys=$(curl -sk -u "${BMC_USER}:${BMC_PASS}" \
        --connect-timeout 10 --max-time 30 \
        "https://${ip}${member_path}" 2>/dev/null) || rc=$?
    if [[ $rc -ne 0 || -z "$sys" ]]; then
        _detect_log "Redfish probe: system endpoint unreachable (exit $rc)"
        return 1
    fi

    local model
    model=$(printf '%s' "$sys" \
        | tr -d '\n' \
        | grep -oE '"Model"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | head -n 1 \
        | sed -E 's/.*"Model"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

    if [[ -z "$model" ]]; then
        _detect_log "Redfish probe: no Model field"
        return 1
    fi
    _detect_log "Redfish probe: raw Model='$model'"

    local token
    token=$(_map_redfish_model "$model")
    if [[ -z "$token" ]]; then
        _detect_log "Redfish probe: model sanitized to empty string"
        return 1
    fi
    _detect_log "Redfish probe: mapped -> $token"
    printf '%s' "$token"
    return 0
}

# ---------------------------------------------------------------------------
# _prompt_flavor
#   Interactive `select` menu. Honors NVIS_NON_INTERACTIVE=1 (returns UNKNOWN).
# ---------------------------------------------------------------------------
_prompt_flavor() {
    if [[ "${NVIS_NON_INTERACTIVE:-}" == "1" ]]; then
        _detect_log "Prompt skipped (NVIS_NON_INTERACTIVE=1); defaulting to UNKNOWN"
        printf 'UNKNOWN'
        return 0
    fi
    if [[ ! -t 0 || ! -t 2 ]]; then
        _detect_log "Non-TTY stdin/stderr; defaulting to UNKNOWN"
        printf 'UNKNOWN'
        return 0
    fi

    echo "Could not auto-detect DGX flavor. Choose:" >&2
    local f result=""
    PS3="Select flavor: "
    select f in B300 B200 B100 H200 H100 A100 custom; do
        case "${f:-}" in
            custom)
                local raw=""
                read -r -p "Enter custom flavor token (alphanum+dash only): " raw
                result=$(_sanitize_flavor "$raw")
                if [[ -z "$result" ]]; then
                    echo "Empty/invalid token; using UNKNOWN" >&2
                    result="UNKNOWN"
                fi
                break
                ;;
            B300|B200|B100|H200|H100|A100)
                result="$f"
                break
                ;;
            *)
                echo "Invalid selection; please choose a number from the list." >&2
                ;;
        esac
    done
    printf '%s' "$result"
}

# ---------------------------------------------------------------------------
# detect_dgx_flavor
#   Public entry point. Echoes the chosen flavor token on stdout.
#   All diagnostics go to stderr.
# ---------------------------------------------------------------------------
detect_dgx_flavor() {
    # 0. Explicit override always wins.
    if [[ -n "${DGX_FLAVOR_OVERRIDE:-}" ]]; then
        _detect_log "Using DGX_FLAVOR_OVERRIDE='${DGX_FLAVOR_OVERRIDE}'"
        printf '%s' "${DGX_FLAVOR_OVERRIDE}"
        return 0
    fi

    local result=""

    # 1. BCM cmsh
    if result=$(_probe_bcm); then
        if [[ -n "$result" ]]; then
            printf '%s' "$result"
            return 0
        fi
    fi

    # 2. Redfish
    if result=$(_probe_redfish); then
        if [[ -n "$result" ]]; then
            printf '%s' "$result"
            return 0
        fi
    fi

    # 3. Interactive prompt (or UNKNOWN under NVIS_NON_INTERACTIVE)
    result=$(_prompt_flavor)
    printf '%s' "$result"
    return 0
}

# ---------------------------------------------------------------------------
# main — standalone runner for manual testing.
# ---------------------------------------------------------------------------
main() {
    local flavor
    flavor=$(detect_dgx_flavor)
    if ! validate_dgx_flavor "$flavor"; then
        _detect_log "WARNING: detected flavor '$flavor' failed validation"
    fi
    printf '%s\n' "$flavor"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

# Exported: detect_dgx_flavor, validate_dgx_flavor
