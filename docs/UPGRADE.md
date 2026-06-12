# Upgrade Guide — 2.2.0 → 2.3.0

Target audience: operators upgrading an existing NVIS Observability deployment.

---

## 1. Before you start

**Back up your values file and any custom dashboards.**

```bash
cp obsvm-values.yaml obsvm-values.yaml.bak-2.2.0
```

If you have customized any Grafana dashboards outside of the NVIS folder, export them from the Grafana UI (Dashboard → Share → Export JSON) before upgrading.

Verify the current release:

```bash
helm list -n <namespace>
```

Expected: `nvis-obsvm   ...   2.2.0`

---

## 2. Helm upgrade

```bash
helm upgrade nvis-obsvm ./helm/nvis-obsvm -f obsvm-values.yaml -n <namespace>
```

**The `-f obsvm-values.yaml` flag is required.** Without it, Helm applies the chart defaults and your site-specific configuration (node IPs, credentials, storage backend, NodePorts, etc.) will be lost.

The new 2.3.0 values keys (DGX Ping Exporter, `dgx-ping` scrape job) all have safe defaults and are **opt-in** — omitting them from your values file is safe; the exporter simply will not be scraped until you add it.

Verify the upgrade completed:

```bash
helm list -n <namespace>
# nvis-obsvm should now show CHART nvis-obsvm-2.3.0

kubectl rollout status deployment/nvis-prometheus -n <namespace>
kubectl rollout status deployment/nvis-grafana -n <namespace>
```

---

## 3. New values keys in 2.3.0

Add these to `obsvm-values.yaml` only if you are deploying the DGX Ping Exporter. They are not required for the helm upgrade to succeed.

```yaml
dgxPingExporter:
  enabled: false          # set true to deploy the exporter pod/service
  port: 9113
  scrapeInterval: 60s

prometheus:
  additionalScrapeConfigs:
    - job_name: dgx-ping
      static_configs:
        - targets:
            - localhost:9113   # replace with ObsVM IP if exporter runs outside the pod
```

All other existing keys are unchanged and carry over from your `obsvm-values.yaml.bak-2.2.0`.

---

## 4. Install the DGX Ping Exporter (optional)

Skip this section if you do not need per-node ping health metrics.

The exporter runs on the ObsVM (not inside Kubernetes). It requires Python 3 and `ping` in `$PATH`.

```bash
# Copy the exporter
sudo cp scripts/dgx_ping_exporter.py /opt/nvis/dgx_ping_exporter.py
sudo chmod +x /opt/nvis/dgx_ping_exporter.py

# Copy the systemd unit
sudo cp scripts/nvis-dgx-ping.service /etc/systemd/system/nvis-dgx-ping.service

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable nvis-dgx-ping.service
sudo systemctl start nvis-dgx-ping.service

# Confirm it is running and exposing metrics
systemctl status nvis-dgx-ping.service
curl -s http://localhost:9113/metrics | grep dgx_node_up
```

The exporter reads the node list from the environment variable `DGX_PING_TARGETS` (comma-separated hostnames or IPs). Set this in `/etc/systemd/system/nvis-dgx-ping.service` under `[Service]`:

```ini
Environment="DGX_PING_TARGETS=node001,node002,node003"
```

After editing the unit file, reload and restart:

```bash
sudo systemctl daemon-reload
sudo systemctl restart nvis-dgx-ping.service
```

---

## 5. Push new dashboards

Three new dashboards ship in this release:

| File | Dashboard |
|------|-----------|
| `grafana/dashboards/NVIS/alloy-check-beacon.json` | Alloy watchdog status |
| `grafana/dashboards/NVIS/bcm-status-beacon.json` | BCM cluster health |
| `grafana/dashboards/NVIS/nvis-dgx-os-health.json` | DGX OS ping health |

**Option A — script (recommended):**

```bash
bash scripts/upgrade-dashboards.sh
```

The script imports all JSON files from `grafana/dashboards/NVIS/` into the NVIS folder via the Grafana HTTP API. Existing dashboards are never deleted or overwritten unless the UID matches and you confirm.

**Option B — Grafana UI:**

1. Open Grafana → Dashboards → Import.
2. Upload each JSON file from `grafana/dashboards/NVIS/` listed above.
3. Select the `NVIS` folder on the import screen.
4. Click Import.

Existing dashboards in the NVIS folder are not affected by either method.

---

## 6. Fix the Alloy watchdog cron schedule (if applicable)

If you previously ran `bootstrap-alloy-watchdog.sh` on any GPU node, re-run it to update the cron from `17 * * * *` to `17 */2 * * *`:

```bash
# Run on each GPU node where the watchdog was bootstrapped
bash scripts/bootstrap-alloy-watchdog.sh
```

If you never ran `bootstrap-alloy-watchdog.sh`, skip this step.

---

## 7. What is safe to skip

| Item | Safe to skip? | Impact |
|------|---------------|--------|
| DGX Ping Exporter install (section 4) | Yes | `nvis-dgx-os-health` dashboard will show no data. Everything else works normally. |
| Alloy watchdog cron fix (section 6) | Yes, if watchdog was never bootstrapped | If watchdog was bootstrapped, the cron fires hourly instead of every 2 hours — functional but noisier. |
| New dashboard import (section 5) | Yes | The 3 new dashboards will not appear in Grafana. All existing dashboards are unaffected. |

---

## 8. Rollback

```bash
helm rollback nvis-obsvm -n <namespace>
```

This rolls back to the previous Helm release (2.2.0). To confirm:

```bash
helm history nvis-obsvm -n <namespace>
```

Restore your values backup if needed:

```bash
cp obsvm-values.yaml.bak-2.2.0 obsvm-values.yaml
```

If you installed `nvis-dgx-ping.service` and want to remove it:

```bash
sudo systemctl stop nvis-dgx-ping.service
sudo systemctl disable nvis-dgx-ping.service
sudo rm /etc/systemd/system/nvis-dgx-ping.service
sudo rm /opt/nvis/dgx_ping_exporter.py
sudo systemctl daemon-reload
```

The 3 new Grafana dashboards do not affect existing dashboards. You can delete them from the Grafana UI without any rollback impact.
