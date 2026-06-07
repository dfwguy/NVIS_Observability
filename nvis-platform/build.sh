#!/usr/bin/env bash
# build.sh — reproducible tarball builder for nvis-platform.
#
# Produces:
#   /tmp/nvis-builds/nvis-platform-<VERSION>.tar.gz
#   /tmp/nvis-builds/nvis-platform-<VERSION>.tar.gz.sha256
#
# Pipeline:
#   1. Validate every .sh with `bash -n`
#   2. Validate every .py with `python3 -m py_compile`
#   3. Validate every dashboard .json with `python3 -c 'import json; json.load(...)'`
#   4. helm lint on the chart
#   5. helm template with all integrations ON, then OFF
#   6. Scan for forbidden customer strings (refuse to build if found)
#   7. tar (reproducible flags) + sha256 sidecar
#
# Usage:
#   ./build.sh                  Build VERSION as-is
#   ./build.sh --skip-helm      Skip helm lint/template (e.g. when helm not installed)
#   ./build.sh --output DIR     Override /tmp/nvis-builds
#   ./build.sh --help
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo unknown)"
OUT_DIR="${OUT_DIR:-/tmp/nvis-builds}"
SKIP_HELM=false

usage() {
    cat <<'USAGE'
build.sh — reproducible tarball builder for nvis-platform

Usage:
  build.sh                Build VERSION (from ./VERSION) → /tmp/nvis-builds/
  build.sh --skip-helm    Skip helm lint/template steps
  build.sh --output DIR   Override output directory
  build.sh --help

Output:
  <OUT_DIR>/nvis-platform-<VERSION>.tar.gz
  <OUT_DIR>/nvis-platform-<VERSION>.tar.gz.sha256
USAGE
}

while (( $# > 0 )); do
    case "$1" in
        --skip-helm)     SKIP_HELM=true ;;
        --output)        shift; OUT_DIR="${1:-}" ;;
        --output=*)      OUT_DIR="${1#*=}" ;;
        -h|--help)       usage; exit 0 ;;
        *)
            printf '[build][ERROR] Unknown flag: %s\n' "$1" >&2
            usage
            exit 2
            ;;
    esac
    shift
done

log()  { printf '[build] %s\n' "$*" >&2; }
errl() { printf '[build][ERROR] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Forbidden customer / internal-infra strings.
#
# Any occurrence in the staged tarball aborts the build. We do NOT write these
# strings as bare source text — that would self-trip every scan of this file.
# The list is base64-encoded; we decode it once at runtime.
# The audit/ folder is excluded from packaging on purpose: those reports
# document past customer leaks and would otherwise trip this scan.
# ---------------------------------------------------------------------------
_FORBIDDEN_B64='YjMwMApsbHkKbGlsbHkKTGlsbHkKaG9ob2hvCnZpa2luZwpsaWxseXBvZApobGFrc2htaW5hcmEKbnZpZGlhLmNvbQpudmlkaWEud2ViaG9vawptYWlsZ3cubnZpZGlhLmNvbQoxMC4xMzEuCjEwLjExNC4KMTAuMTQxLgoxMC42My4K'
FORBIDDEN_STRINGS=()
while IFS= read -r _line; do
    [[ -n "$_line" ]] && FORBIDDEN_STRINGS+=( "$_line" )
done < <(printf '%s' "$_FORBIDDEN_B64" | base64 -d 2>/dev/null)
unset _line

# ---------------------------------------------------------------------------
# REQUIRED_FILES — enumerated explicitly so the tarball never ends up
# with stray files (or misses something we meant to ship).
# ---------------------------------------------------------------------------
REQUIRED_FILES=(
    VERSION
    README.md
    CHANGELOG.md
    install.sh
    build.sh
)

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# Append files matching a glob from a directory to REQUIRED_FILES.
_collect_glob() {
    local dir="$1"; shift
    local pat
    local f
    for pat in "$@"; do
        # shellcheck disable=SC2086
        for f in "${SCRIPT_DIR}/${dir}"/${pat}; do
            [[ -e "$f" ]] || continue
            REQUIRED_FILES+=( "${f#${SCRIPT_DIR}/}" )
        done
    done
}

collect_required() {
    _collect_glob lib '*.sh'
    _collect_glob nvis-deployment-hardware-validation/dashboards '*.json'
    _collect_glob nvis-deployment-hardware-validation/docs '*.md'
    _collect_glob nvis-observability/dashboards '*.json'
    _collect_glob nvis-observability/docs '*.md'
    _collect_glob helm/nvis-platform 'Chart.yaml' 'values.yaml'
    _collect_glob helm/nvis-platform/templates '*.yaml'
    _collect_glob docs '*.md'

    # Exporters: each subdir's *.py, Dockerfile, requirements.txt.
    local d
    if [[ -d "${SCRIPT_DIR}/scripts/exporters" ]]; then
        for d in "${SCRIPT_DIR}"/scripts/exporters/*/; do
            local rel="${d#${SCRIPT_DIR}/}"
            rel="${rel%/}"
            local f
            for f in "$d"*.py "$d"Dockerfile "$d"requirements.txt; do
                [[ -e "$f" ]] || continue
                REQUIRED_FILES+=( "${f#${SCRIPT_DIR}/}" )
            done
        done
    fi
}

validate_shell() {
    log "Validating shell scripts with 'bash -n'..."
    local f errs=0
    for f in "${REQUIRED_FILES[@]}"; do
        [[ "$f" == *.sh ]] || continue
        if ! bash -n "${SCRIPT_DIR}/${f}" 2>&1; then
            errl "bash -n failed for $f"
            errs=$((errs+1))
        fi
    done
    return $errs
}

validate_python() {
    log "Validating Python sources with py_compile..."
    if ! command -v python3 >/dev/null 2>&1; then
        log "python3 not installed; skipping py_compile"
        return 0
    fi
    local f errs=0
    for f in "${REQUIRED_FILES[@]}"; do
        [[ "$f" == *.py ]] || continue
        if ! python3 -m py_compile "${SCRIPT_DIR}/${f}" 2>&1; then
            errl "py_compile failed for $f"
            errs=$((errs+1))
        fi
    done
    return $errs
}

validate_json() {
    log "Validating dashboard JSONs..."
    if ! command -v python3 >/dev/null 2>&1; then
        log "python3 not installed; skipping JSON validation"
        return 0
    fi
    local f errs=0
    for f in "${REQUIRED_FILES[@]}"; do
        [[ "$f" == *.json ]] || continue
        if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" \
                "${SCRIPT_DIR}/${f}" 2>&1; then
            errl "json.load failed for $f"
            errs=$((errs+1))
        fi
    done
    return $errs
}

validate_helm() {
    if "$SKIP_HELM"; then
        log "Skipping helm lint/template (--skip-helm)"
        return 0
    fi
    if ! command -v helm >/dev/null 2>&1; then
        log "helm not installed; skipping helm lint/template"
        return 0
    fi
    if [[ ! -d "${SCRIPT_DIR}/helm/nvis-platform" ]]; then
        log "No helm/nvis-platform directory; skipping helm validation"
        return 0
    fi
    log "Running helm lint..."
    helm lint "${SCRIPT_DIR}/helm/nvis-platform" >&2 || return 1

    log "Running helm template (all integrations ON)..."
    helm template "${SCRIPT_DIR}/helm/nvis-platform" \
        --set integrations.dcgm.enabled=true \
        --set integrations.nodeExporter.enabled=true \
        --set integrations.alloy.enabled=true \
        --set integrations.bcm.enabled=true \
        --set integrations.redfishMain.enabled=true \
        --set integrations.redfishNm.enabled=true \
        --set integrations.redfishFast.enabled=true \
        --set integrations.redfishSensors.enabled=true \
        --set integrations.ipmiSel.enabled=true \
        --set integrations.ipmiSol.enabled=true \
        --set integrations.ufm.enabled=true \
        --set integrations.netq.enabled=true \
        --set integrations.runai.enabled=true \
        --set integrations.nmc.enabled=true >/dev/null \
        || { errl "helm template (all ON) failed"; return 1; }

    log "Running helm template (all integrations OFF)..."
    helm template "${SCRIPT_DIR}/helm/nvis-platform" \
        --set integrations.dcgm.enabled=false \
        --set integrations.nodeExporter.enabled=false \
        --set integrations.alloy.enabled=false \
        --set integrations.bcm.enabled=false \
        --set integrations.redfishMain.enabled=false \
        --set integrations.redfishNm.enabled=false \
        --set integrations.redfishFast.enabled=false \
        --set integrations.redfishSensors.enabled=false \
        --set integrations.ipmiSel.enabled=false \
        --set integrations.ipmiSol.enabled=false \
        --set integrations.ufm.enabled=false \
        --set integrations.netq.enabled=false \
        --set integrations.runai.enabled=false \
        --set integrations.nmc.enabled=false >/dev/null \
        || { errl "helm template (all OFF) failed"; return 1; }
}

# Scan the **staged** files (REQUIRED_FILES only — i.e. exactly what will be
# tarred up) for forbidden strings.
# Per-file exemptions: the detection script must spell out product flavor
# tokens so it can recognize them at install time. No other file is exempt.
# build.sh is also exempt because it contains documentation tokens and the
# base64-encoded forbidden list itself.
SCAN_EXEMPT_FILES=("lib/detect.sh" "build.sh")

# Short tokens that show up as substrings of common English words need
# word-boundary matching. Longer unique tokens match by substring.
_short_tokens=("lly" "lilly" "Lilly" "LLY" "viking" "Viking" "b300" "B300")

_is_short_token() {
    local t=$1 s
    for s in "${_short_tokens[@]}"; do
        [[ "$t" == "$s" ]] && return 0
    done
    return 1
}

_is_exempt() {
    local f=$1 e
    for e in "${SCAN_EXEMPT_FILES[@]}"; do
        [[ "$f" == "$e" ]] && return 0
    done
    return 1
}

scan_forbidden_strings() {
    log "Scanning for forbidden customer / internal-infra strings..."
    local needle hits=0
    for needle in "${FORBIDDEN_STRINGS[@]}"; do
        local f matched grep_args
        matched=0
        if _is_short_token "$needle"; then
            # word boundary, case-insensitive — avoid "fully"/"literally"/"locally"
            grep_args=( -i -P "\\b${needle}\\b" )
        else
            grep_args=( -F -- "$needle" )
        fi
        for f in "${REQUIRED_FILES[@]}"; do
            [[ -f "${SCRIPT_DIR}/${f}" ]] || continue
            _is_exempt "$f" && continue
            if grep "${grep_args[@]}" -q "${SCRIPT_DIR}/${f}" 2>/dev/null; then
                if (( matched == 0 )); then
                    errl "Forbidden string '$needle' found in:"
                    matched=1
                fi
                printf '       %s\n' "$f" >&2
                hits=$((hits+1))
            fi
        done
    done
    if (( hits > 0 )); then
        errl "$hits forbidden-string occurrence(s) detected — refusing to build."
        return 1
    fi
    log "Forbidden-string scan clean."
}

build_tarball() {
    mkdir -p "$OUT_DIR"
    local tar_name="nvis-platform-${VERSION}.tar.gz"
    local tar_path="${OUT_DIR}/${tar_name}"
    local staging
    staging=$(mktemp -d)
    trap 'rm -rf "$staging"' EXIT

    log "Staging files to $staging/nvis-platform-${VERSION}/"
    local root="${staging}/nvis-platform-${VERSION}"
    mkdir -p "$root"

    local f
    for f in "${REQUIRED_FILES[@]}"; do
        [[ -f "${SCRIPT_DIR}/${f}" ]] || continue
        mkdir -p "$(dirname "${root}/${f}")"
        cp -p "${SCRIPT_DIR}/${f}" "${root}/${f}"
    done

    # Reproducible-tar flags.
    # --sort=name + fixed --mtime + numeric owner/group=0 makes the output stable.
    log "Creating reproducible tarball: $tar_path"
    ( cd "$staging" && \
      tar \
          --sort=name \
          --mtime='UTC 2026-01-01' \
          --owner=0 --group=0 --numeric-owner \
          --exclude-vcs \
          --exclude='__pycache__' \
          --exclude='.DS_Store' \
          --exclude='*.swp' \
          --exclude='*.pyc' \
          -czf "$tar_path" "nvis-platform-${VERSION}"
    )

    if command -v sha256sum >/dev/null 2>&1; then
        ( cd "$OUT_DIR" && sha256sum "$tar_name" > "${tar_name}.sha256" )
        log "Wrote sha256: ${tar_path}.sha256"
    else
        log_warn "sha256sum not present; skipping sidecar"
    fi

    log "Build OK"
    log "  Tarball:  $tar_path"
    log "  Size:     $(du -h "$tar_path" | cut -f1)"
    log "  Files:    ${#REQUIRED_FILES[@]} entries"
}

main() {
    log "build.sh — nvis-platform tarball builder (VERSION=$VERSION)"

    collect_required
    log "Staged ${#REQUIRED_FILES[@]} files for packaging."

    validate_shell  || { errl "Shell validation failed"; exit 1; }
    validate_python || { errl "Python validation failed"; exit 1; }
    validate_json   || { errl "JSON validation failed"; exit 1; }
    validate_helm   || { errl "Helm validation failed"; exit 1; }
    scan_forbidden_strings || exit 1

    build_tarball
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
