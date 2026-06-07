#!/usr/bin/env bash
# ============================================================================
# alloy-watchdog.sh  — self-healing Grafana Alloy for GPU cluster nodes
# ============================================================================
# WHY: GPU nodes run Alloy off ephemeral root; every reboot WIPES the
# binary + /etc/alloy config + the systemd unit, so log shipping (syslog,
# kernel/Xid, nv-hostengine/DCGM, slurmd, fabricmanager) silently stops on the
# rebooted node and we go blind there. (The head node is NOT wiped, so it keeps
# Alloy.) This watchdog re-installs Alloy on any DGX that is missing it.
#
# WHERE IT RUNS: as root on the cluster head node. The head is the cluster pivot and
# has root trust to every compute node via existing head-root key.
# No passwords are stored — it reuses the existing
# head-root -> node-root key trust. Install via bootstrap-alloy-watchdog.sh.
#
# WHAT "missing" MEANS: `systemctl is-active alloy` != active OR the alloy binary
# is absent OR :12345 is not listening. On miss -> stage binary + render config
# (hostname/cluster substituted) + install unit + enable --now, then re-verify.
#
# STAGING (NFS, visible to all nodes): set by the bootstrap:
#   $STAGE/alloy                  the alloy binary (copied from a known-good node)
#   $STAGE/config.alloy.template  canonical DGX config (incl fabricmanager.log)
#   $STAGE/alloy.service          systemd unit
# Logs to $STAGE/watchdog.log and ships a heartbeat line to Loki on the ObsVM.
# ----------------------------------------------------------------------------
set -uo pipefail

STAGE="${ALLOY_STAGE:-/cm/shared/apps/nvis/alloy}"
CLUSTER="${CLUSTER_NAME:-my-cluster}"
LOKI="${LOKI_URL:-http://obsvm:3100/loki/api/v1/push}"   # ObsVM URL
DGX_NODES="${DGX_NODES:-compute-01 compute-02}"
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8"
LOG="$STAGE/watchdog.log"
ts(){ date '+%Y-%m-%dT%H:%M:%S%z'; }
log(){ echo "$(ts) $*" | tee -a "$LOG"; }

loki_push(){ # $1=level $2=node $3=msg
  local now; now=$(date +%s)000000000
  curl -sf --max-time 8 -H 'Content-Type: application/json' "$LOKI" -d @- >/dev/null 2>&1 <<JSON || true
{"streams":[{"stream":{"job":"alloy-watchdog","cluster":"$CLUSTER","node":"$2","level":"$1"},
"values":[["$now","$3"]]}]}
JSON
}

ensure_node(){
  local node="$1"
  # 1) reachable?
  if ! $SSH "root@$node" true 2>/dev/null; then
    log "[$node] UNREACHABLE (skip)"; loki_push warn "$node" "watchdog: node unreachable"; return
  fi
  # 2) NFS up? (alloy config + munge etc. live on /cm/shared & /home which the
  #    DGX drop on reboot) — remount so staging is visible and logs exist.
  $SSH "root@$node" 'mountpoint -q /cm/shared || mount /cm/shared 2>/dev/null; mountpoint -q /home || mount /home 2>/dev/null; mount -a 2>/dev/null' || true
  # 3) Alloy healthy?
  local state
  state=$($SSH "root@$node" 'a=$(systemctl is-active alloy 2>/dev/null); b=$([ -x /usr/bin/alloy ] && echo bin || echo nobin); p=$(ss -ltn 2>/dev/null | grep -c :12345); echo "$a/$b/$p"' 2>/dev/null)
  if [[ "$state" == active/bin/1* ]]; then
    log "[$node] OK (alloy $state)"; return
  fi
  log "[$node] MISSING/UNHEALTHY (state=$state) -> reinstalling"
  loki_push warn "$node" "watchdog: alloy missing (state=$state) -> reinstalling (post-reboot wipe)"
  # 4) render per-node config from the staged template
  local cfg="/tmp/.alloy-$node.alloy"
  sed -e "s/<NODE_HOSTNAME>/$node/g" -e "s/<CLUSTER_NAME>/$CLUSTER/g" "$STAGE/config.alloy.template" > "$cfg" 2>/dev/null \
    || { log "[$node] ERROR: staged template missing at $STAGE"; return; }
  # 5) push binary, config, unit; enable
  $SSH "root@$node" 'install -d /etc/alloy /var/lib/alloy' 2>/dev/null
  scp -q -o BatchMode=yes -o StrictHostKeyChecking=no "$STAGE/alloy"          "root@$node:/usr/bin/alloy" 2>/dev/null && \
  $SSH "root@$node" 'chmod 0755 /usr/bin/alloy' 2>/dev/null
  scp -q -o BatchMode=yes -o StrictHostKeyChecking=no "$cfg"                  "root@$node:/etc/alloy/config.alloy" 2>/dev/null
  scp -q -o BatchMode=yes -o StrictHostKeyChecking=no "$STAGE/alloy.service"  "root@$node:/etc/systemd/system/alloy.service" 2>/dev/null
  $SSH "root@$node" 'id alloy >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin alloy 2>/dev/null; \
                     systemctl daemon-reload; systemctl enable --now alloy 2>/dev/null; sleep 3; systemctl is-active alloy' >/tmp/.alloy-rc-$node 2>/dev/null
  rm -f "$cfg"
  # 6) re-verify
  local after; after=$($SSH "root@$node" 'systemctl is-active alloy 2>/dev/null; ss -ltn 2>/dev/null | grep -c :12345' 2>/dev/null | tr "\n" "/")
  if [[ "$after" == active/1* ]]; then
    log "[$node] RECOVERED (alloy active, :12345 up)"; loki_push info "$node" "watchdog: alloy reinstalled OK"
  else
    log "[$node] STILL DOWN after reinstall (after=$after)"; loki_push error "$node" "watchdog: alloy reinstall FAILED (after=$after)"
  fi
}

mkdir -p "$STAGE"
log "=== alloy-watchdog run start (nodes: $DGX_NODES) ==="
for n in $DGX_NODES; do ensure_node "$n"; done
log "=== alloy-watchdog run end ==="
