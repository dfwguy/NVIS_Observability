#!/usr/bin/env bash
# ============================================================================
# bootstrap-alloy-watchdog.sh — ONE-TIME install, run as ROOT on beacon-head-01
# ============================================================================
#   sudo CLUSTER_NAME=Beacon bash bootstrap-alloy-watchdog.sh
#
# Sets up the self-healing Alloy watchdog (alloy-watchdog.sh) so rebooted DGX
# nodes (which lose Alloy off ephemeral root) get it re-pushed within the hour.
#
# It DERIVES the canonical DGX Alloy artifacts from THIS head node's known-good,
# currently-running Alloy (binary + /etc/alloy/config.alloy + systemd unit) — so
# the staged config matches what actually works — then injects fabricmanager.log
# into the log set, and stages everything on /cm/shared (NFS, all nodes see it).
# No passwords are stored; the watchdog reuses head-root -> node-root key trust.
# ----------------------------------------------------------------------------
set -euo pipefail
STAGE="${ALLOY_STAGE:-/cm/shared/apps/nvis/alloy}"
CLUSTER="${CLUSTER_NAME:-Beacon}"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" = 0 ] || { echo "ERROR: run as root on beacon-head-01"; exit 1; }
command -v alloy >/dev/null || [ -x /usr/bin/alloy ] || { echo "ERROR: alloy binary not found on this head — run on a node that has a working Alloy"; exit 1; }
systemctl is-active --quiet alloy || echo "WARN: alloy not active on the head; staging its files anyway"

echo ">> staging dir: $STAGE"
install -d "$STAGE"

# 1) binary
cp -f "$(command -v alloy || echo /usr/bin/alloy)" "$STAGE/alloy"
chmod 0755 "$STAGE/alloy"
echo ">> staged alloy binary ($("$STAGE/alloy" --version 2>/dev/null | head -1))"

# 2) config — start from the head's working config, then ensure fabricmanager.log
CFG_SRC=/etc/alloy/config.alloy
[ -f "$CFG_SRC" ] || { echo "ERROR: $CFG_SRC missing"; exit 1; }
cp -f "$CFG_SRC" "$STAGE/config.alloy.template"
if ! grep -q 'fabricmanager.log' "$STAGE/config.alloy.template"; then
  # insert into the loki varlog path_targets list (after the slurm line if present,
  # else after kern.log). Matches the existing per-target line style.
  if grep -q '/var/log/slurm' "$STAGE/config.alloy.template"; then
    sed -i '\#/var/log/slurm#a\    {__path__ = "/var/log/fabricmanager.log",  job = "fabricmanager", log_type = "nvlink"},' "$STAGE/config.alloy.template"
  elif grep -q '/var/log/kern.log' "$STAGE/config.alloy.template"; then
    sed -i '\#/var/log/kern.log#a\    {__path__ = "/var/log/fabricmanager.log",  job = "fabricmanager", log_type = "nvlink"},' "$STAGE/config.alloy.template"
  else
    echo "WARN: could not find a varlog block to inject fabricmanager.log — edit $STAGE/config.alloy.template by hand"
  fi
  echo ">> injected /var/log/fabricmanager.log (job=fabricmanager) into staged config"
else
  echo ">> fabricmanager.log already present in head config"
fi
# normalize cluster label if the config hardcodes one
sed -i "s/<CLUSTER_NAME>/$CLUSTER/g" "$STAGE/config.alloy.template" 2>/dev/null || true

# 3) systemd unit (verbatim from head, falls back to a minimal unit)
if systemctl cat alloy >/dev/null 2>&1; then
  systemctl cat alloy | sed '1{/^# /d}' > "$STAGE/alloy.service"
else
  cat > "$STAGE/alloy.service" <<UNIT
[Unit]
Description=Grafana Alloy (NVIS)
After=network-online.target
[Service]
Environment=HOSTNAME=%H
Environment=NVIS_CLUSTER=$CLUSTER
ExecStart=/usr/bin/alloy run /etc/alloy/config.alloy --server.http.listen-addr=0.0.0.0:12345
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
fi
echo ">> staged systemd unit"

# 4) install the watchdog script on the head
install -m 0755 "$SELF_DIR/alloy-watchdog.sh" /usr/local/sbin/alloy-watchdog.sh
echo ">> installed /usr/local/sbin/alloy-watchdog.sh"

# 5) hourly cron (root) on the head
cat > /etc/cron.d/nvis-alloy-watchdog <<CRON
# NVIS: re-push Grafana Alloy to any DGX that lost it (ephemeral root wipes it on reboot)
SHELL=/bin/bash
ALLOY_STAGE=$STAGE
CLUSTER_NAME=$CLUSTER
LOKI_URL=http://10.184.70.241:3100/loki/api/v1/push
DGX_NODES=dgx-b300-01 dgx-b300-02 dgx-b300-03 dgx-b300-04
17 * * * * root /usr/local/sbin/alloy-watchdog.sh >> $STAGE/watchdog.cron.log 2>&1
CRON
chmod 0644 /etc/cron.d/nvis-alloy-watchdog
echo ">> installed hourly cron /etc/cron.d/nvis-alloy-watchdog (runs :17 each hour)"

# 6) run once now
echo ">> first run:"
ALLOY_STAGE="$STAGE" CLUSTER_NAME="$CLUSTER" /usr/local/sbin/alloy-watchdog.sh
echo ">> DONE. tail -f $STAGE/watchdog.log to watch."
