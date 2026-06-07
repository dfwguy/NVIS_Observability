# Git Push Instructions

These files are drop-in replacements for the same paths in your existing repo.

## Option A — If repo already exists remotely

```bash
# 1. Clone your repo
git clone <your-repo-url> nvis-observability-repo
cd nvis-observability-repo

# 2. Copy changed files over
cp /path/to/nvis-observability-git/setup-k8s.sh .
cp /path/to/nvis-observability-git/scripts/nvis-cleanup.sh scripts/
cp /path/to/nvis-observability-git/scripts/ufm_exporter.py scripts/
cp /path/to/nvis-observability-git/grafana/dashboards/nvis-ib-fabric.json grafana/dashboards/
cp /path/to/nvis-observability-git/grafana/dashboards/nvis-live-topology.json grafana/dashboards/

# 3. Commit
git add setup-k8s.sh scripts/nvis-cleanup.sh scripts/ufm_exporter.py \
    grafana/dashboards/nvis-ib-fabric.json \
    grafana/dashboards/nvis-live-topology.json

git commit -m "OBBB-20260407: installer fixes, UFM metrics, IB fabric dashboard

setup-k8s.sh:
- Fix port conflict pre-check before helm deploy
- Fix Grafana health check with kubectl exec fallback
- Fix Alloy health check substring match (was exact match, always failed)

scripts/nvis-cleanup.sh:
- Fix conf snapshot before Step 7 deletes nvis-deploy.conf (GPU cleanup was skipping all nodes)
- Add Step 11 post-uninstall validation (namespace, Alloy, ports)
- Remove nvis-observability/ directory on clean uninstall

scripts/ufm_exporter.py:
- Add per-port: tier, severity, high_ber, peer_node
- Add per-switch: uptime_seconds, model
- Add per-alarm: reason, object_path, event_count
- Add 8 new Prometheus metrics (port counts by tier/speed/state, switch uptime, alarm breakdown)

grafana/dashboards/nvis-ib-fabric.json (NEW):
- 19-panel InfiniBand Fabric dashboard (uid: nvis-ib-fabric-v1)
- Fabric overview, topology donuts, switch health table, alarm analysis, port health, trends

grafana/dashboards/nvis-live-topology.json:
- 6 fixes: flow-bar panel removed, cluster filter removed, ObsVM IP hardcoded,
  event delegation, esc() for safe HTML, rack heatmap normalization"

git push origin main
```

## Option B — Fresh repo

```bash
cd /path/to/nvis-observability-git
git init
git add .
git commit -m "OBBB-20260407: installer fixes, UFM metrics, IB fabric dashboard"
git remote add origin <your-repo-url>
git push -u origin main
```

## What NOT to commit from the full install directory

- `nvis-deploy.conf` — contains customer IP/credentials, root-owned 600
- `.env` — secrets
- `helm/charts/` — vendored helm deps, use helm dependency update
- Any `/tmp/nvis-install-*/` logs
