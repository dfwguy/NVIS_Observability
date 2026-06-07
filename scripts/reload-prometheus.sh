#!/bin/bash
# reload-prometheus.sh — sync prometheus.yml into the container and hot-reload.
#
# The Docker bind mount holds the inode from container start time.
# If prometheus.yml is replaced (new inode), the container sees the old file.
# This script always writes the file in-place (preserving the inode) so that
# hot-reload works without a container restart.
#
# Usage:
#   ./reload-prometheus.sh              # sync and reload
#   ./reload-prometheus.sh --restart    # sync and restart (if hot-reload fails)

set -euo pipefail

CONTAINER="nvis-prometheus"
HOST_CFG="$HOME/nvis-observability/prometheus/prometheus.yml"
CONTAINER_CFG="/etc/prometheus/prometheus.yml"
RELOAD_URL="http://localhost:9090/-/reload"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$HOST_CFG" ]] || die "Config not found: $HOST_CFG"
docker inspect "$CONTAINER" &>/dev/null || die "Container $CONTAINER not running"

echo "→ Validating config..."
docker exec "$CONTAINER" promtool check config "$CONTAINER_CFG" 2>/dev/null || {
  # Container has old config — validate host config via temp container
  docker run --rm -v "$HOST_CFG:/tmp/check.yml" --entrypoint promtool \
    prom/prometheus:v2.54.1 check config /tmp/check.yml \
    || die "Config validation failed — not reloading"
}

echo "→ Writing config in-place (inode-safe)..."
# tee into the container preserves the inode the container holds
docker run --rm \
  --volumes-from "$CONTAINER" \
  --entrypoint sh \
  prom/prometheus:v2.54.1 \
  -c "cat > $CONTAINER_CFG" < "$HOST_CFG" 2>/dev/null || {
    # Fallback: restart if can't write (read-only FS in some setups)
    echo "  in-place write not available — will restart"
    RESTART=1
  }

if [[ "${1:-}" == "--restart" ]] || [[ "${RESTART:-0}" == "1" ]]; then
  echo "→ Restarting container..."
  docker restart "$CONTAINER"
  sleep 5
else
  echo "→ Hot-reloading..."
  curl -sf -X POST --noproxy '*' "$RELOAD_URL" && echo "  reload OK" || {
    echo "  hot-reload failed — restarting..."
    docker restart "$CONTAINER"
    sleep 5
  }
fi

echo "→ Verifying targets..."
sleep 3
curl -s --noproxy '*' 'http://localhost:9090/api/v1/targets' | python3 -c "
import sys,json
data=json.load(sys.stdin)
targets=data['data']['activeTargets']
print(f'  {len(targets)} active targets:')
for t in targets:
    pool=t['scrapePool']; h=t['health']; err=t.get('lastError','') or 'OK'
    mark='✓' if h=='up' else '✗' if h=='down' else '?'
    print(f'  {mark} {pool:35s} {h} — {err[:50]}')
"
