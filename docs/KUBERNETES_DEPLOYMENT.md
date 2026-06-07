# NVIS Observability — Kubernetes Deployment Guide

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│  ObsVM (10.131.132.232)                                      │
│                                                              │
│  Docker Compose (UNCHANGED from bare-metal setup):          │
│  ┌────────────┐ ┌──────┐ ┌────────────────┐ ┌──────────┐  │
│  │ Prometheus │ │ Loki │ │ VictoriaMetrics │ │ Grafana  │  │
│  │ :9090      │ │ :3100│ │ :8428           │ │ :3000    │  │
│  └────────────┘ └──────┘ └────────────────┘ └──────────┘  │
│                                                              │
│  K8s control-plane (k3s, tainted NoSchedule — no workloads):│
│  ┌──────────────────────────────────────┐                   │
│  │  k3s server :6443                    │                   │
│  │  Local Docker registry :5000         │                   │
│  │  (serves images to airgapped nodes)  │                   │
│  └──────────────────────────────────────┘                   │
└─────────────────────────────────────────────────────────────┘
                          ▲ remote_write (metrics)
                          ▲ push (logs)
┌─────────────────────────────────────────────────────────────┐
│  GPU worker nodes (k3s agents, DaemonSets)                  │
│                                                              │
│  node001  node002  node003  (one pod per node)              │
│  ┌──────┐ ┌──────┐ ┌──────┐                                │
│  │ DCGM │ │ DCGM │ │ DCGM │  GPU metrics :9400             │
│  └──────┘ └──────┘ └──────┘                                │
│  ┌──────┐ ┌──────┐ ┌──────┐                                │
│  │ node │ │ node │ │ node │  host metrics :9100             │
│  │ exp. │ │ exp. │ │ exp. │                                 │
│  └──────┘ └──────┘ └──────┘                                │
│  ┌──────┐ ┌──────┐ ┌──────┐                                │
│  │Alloy │ │Alloy │ │Alloy │  scrapes ↑, pushes to ObsVM ↑ │
│  └──────┘ └──────┘ └──────┘                                │
└─────────────────────────────────────────────────────────────┘
```

**Key design decisions:**
- ObsVM Docker Compose stack (Prometheus, Loki, Grafana, VictoriaMetrics) is **completely unchanged**
- GPU nodes run k3s agents — DaemonSets replace the old systemd services
- `hostNetwork: true` on all node agents — they see `localhost:9400` / `localhost:9100` exactly as before
- ObsVM k3s server is tainted `NoSchedule` — **zero workload pods run on ObsVM**
- Local Docker registry on ObsVM `:5000` serves images to airgapped GPU nodes — no internet needed on GPU nodes
- If GPU nodes already have a K8s cluster, k3s install is automatically skipped

**cAdvisor:** Built into kubelet on every node at `:10250/metrics/cadvisor`. No separate deployment needed.

---

## Quick Start

```bash
# ── Step 1: On a machine WITH internet ───────────────────────────────────────
NGC_API_KEY=your_ngc_key bash scripts/create-bundle.sh
# → produces: nvis-observability-bundle.tar (~5-8 GB, all images included)

# ── Step 2: Transfer to customer ObsVM ───────────────────────────────────────
scp nvis-observability-bundle.tar user@obsvm:~/

# ── Step 3: On ObsVM — three commands ────────────────────────────────────────
tar -xf nvis-observability-bundle.tar
vi nvis-observability/nvis-deploy.conf    # set your IPs, cluster name, SSH key
sudo bash nvis-observability/scripts/k3s-setup.sh
```

**`nvis-deploy.conf` is the only file the customer edits.** It contains:
- `OBSVM_IP` — IP of the ObsVM
- `CLUSTER_NAME` — shown in Grafana dashboards
- `GPU_NODES` — array of GPU node IPs
- `SSH_KEY` — path to SSH private key
- `JUMP_HOST` / `BCM_HOST` — jump chain (or set `DIRECT_SSH=true` if nodes are directly reachable)

`k3s-setup.sh` handles everything automatically:
1. Loads bundled images into Docker
2. Detects if GPU nodes already have K8s (skips k3s install if so)
3. Starts local registry, pushes images to it
4. Installs k3s server on ObsVM (control-plane only)
5. Pushes k3s agent to each GPU node via SSH
6. Deploys DCGM, node_exporter, Alloy as DaemonSets via Helm
7. Verifies pods running and metrics flowing

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| ObsVM with Docker | Docker Compose stack already running |
| SSH key access | `~/.ssh/id_ed25519` authorized on GPU nodes via jump chain |
| NGC API key | For DCGM image — free at ngc.nvidia.com |
| GPU nodes | No internet required — all images served from ObsVM:5000 |

### SSH access check (run before setup):
```bash
# Test SSH path works (from ObsVM, as your user — not root):
ssh -i ~/.ssh/id_ed25519 \
    -o BatchMode=yes \
    -J hlakshminara@krusty5.nvidia.com,root@10.63.83.209 \
    root@10.141.0.1 echo ok
```
If this prompts for a password, run `ssh-copy-id hlakshminara@krusty5.nvidia.com` first.

---

## Bundle Creation (internet machine)

```bash
# Pull all images + package everything into one tar
NGC_API_KEY=your_ngc_key bash scripts/create-bundle.sh

# Custom output path:
NGC_API_KEY=your_ngc_key bash scripts/create-bundle.sh --output /mnt/usb/nvis-bundle.tar
```

**Images bundled:**

| Image | Purpose |
|-------|---------|
| `registry:2` | Local Docker registry on ObsVM |
| `rancher/k3s:v1.30.2-k3s1` | k3s binary + CNI plugins (extracted at install) |
| `alpine/helm:3.15.4` | Helm binary (extracted at install) |
| `bitnami/kubectl:1.30` | kubectl binary (extracted at install) |
| `quay.io/prometheus/node-exporter:v1.8.1` | Host metrics DaemonSet |
| `grafana/alloy:v1.3.0` | Metrics/log shipping DaemonSet |
| `nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04` | GPU metrics DaemonSet |

---

## Customer Environment: Existing K8s Cluster

If the customer's GPU nodes are **already in a K8s cluster**, `k3s-setup.sh` detects this automatically and skips k3s install entirely.

```
Phase 0: kubelet detected on GPU nodes → SKIP_K3S=true
         Phases 2, 3, 4 (k3s) → skipped
         Phases 1, 5, 6, 7, 8 → run normally (registry + helm deploy)
```

**Requirements for existing-K8s path:**
- KUBECONFIG must be accessible (script checks `/etc/rancher/rke2/rke2.yaml`, `~/.kube/config`, `/root/.kube/config`)
- GPU nodes must be labeled or the script labels them: `nvidia.com/gpu.present=true`
- Image registry: customer provides their own (Harbor, Nexus, ECR) — update `imageRegistry` in helm values

**Deploy only (no k3s, customer handles their own cluster):**
```bash
# Load images into their registry first
bash scripts/airgap-images-load.sh \
  --tar nvis-images.tar \
  --registry their-registry.internal:5000

# Deploy Helm chart
kubectl create namespace nvis-monitoring
helm install nvis-gpu-agents helm/nvis-gpu-agents/ \
  --namespace nvis-monitoring \
  --set imageRegistry=their-registry.internal:5000 \
  --set cluster=their-cluster-name \
  --set remote.prometheusUrl=http://OBSVM_IP:9090/api/v1/write \
  --set remote.lokiUrl=http://OBSVM_IP:3100/loki/api/v1/push
```

---

## Post-install: Load Grafana Dashboards

Grafana dashboards are too large for K8s ConfigMaps (1MB limit). Load via API:

```bash
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
GRAFANA_URL="http://${NODE_IP}:30300"
GRAFANA_PASS=$(grep GRAFANA_PASSWORD /home/hlakshminara/nvis-observability/.nvis-creds | cut -d= -f2)

for f in terraform/dashboards/*.json; do
  curl -s -X POST "${GRAFANA_URL}/api/dashboards/import" \
    -H "Content-Type: application/json" \
    -u "admin:${GRAFANA_PASS}" \
    -d "{\"dashboard\": $(cat "$f"), \"overwrite\": true, \"folderId\": 0}" \
    | grep -q '"status":"success"' && echo "Loaded: $f" || echo "Failed: $f"
done
```

---

## Verify Deployment

```bash
KC="KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/kubectl-bin"

# All pods should be Running
${KC} get pods -n nvis-monitoring -o wide

# Expected (one DCGM + one node-exporter + one Alloy per GPU node):
# nvis-dcgm-exporter-xxx    1/1  Running   node001
# nvis-dcgm-exporter-xxx    1/1  Running   node002
# nvis-dcgm-exporter-xxx    1/1  Running   node003
# nvis-node-exporter-xxx    1/1  Running   node001
# ...
# nvis-alloy-xxx            1/1  Running   node001
# ...

# Check Alloy is pushing metrics
${KC} logs -n nvis-monitoring -l app=nvis-alloy --tail=20

# Query Prometheus for GPU metrics
curl -s 'http://10.131.132.232:9090/api/v1/query?query=DCGM_FI_DEV_GPU_UTIL' \
  | python3 -m json.tool | grep '"status"'

# Access Grafana
echo "http://10.131.132.232:3000  (admin / see .nvis-creds)"
```

---

## Upgrade

```bash
# Re-run create-bundle.sh to get latest images, then on ObsVM:
tar -xf nvis-observability-bundle.tar
sudo bash nvis-observability/scripts/k3s-setup.sh
# (idempotent — upgrades existing release via helm upgrade)
```

---

## Uninstall

```bash
KC="KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/kubectl-bin"

helm uninstall nvis-gpu-agents -n nvis-monitoring
${KC} delete namespace nvis-monitoring

# To fully remove k3s from ObsVM:
systemctl stop k3s && systemctl disable k3s
# To remove k3s agents from GPU nodes (via SSH):
# systemctl stop k3s-agent && systemctl disable k3s-agent
```

---

## Redfish (BMC) Integration

New in v2.2. The Redfish exporter collects BMC telemetry — temperatures, fans, per-component power, firmware inventory, and SEL — from every configured target and feeds the **NVIS GPU Profiling** (`nvis-gpu-profiling`) and **B300 Temperature History** (`nvis-b300-temp-history`) dashboards.

### Enabling at install / upgrade

The wizard prompts for Redfish credentials and targets on any `setup-k8s.sh --upgrade` run. Flags are also supported for non-interactive installs:

```bash
sudo bash setup-k8s.sh --upgrade \
  --enable-redfish \
  --redfish-user admin \
  --redfish-pass "$BMC_PASS" \
  --redfish-targets 10.114.132.240,10.114.132.241,10.114.132.242

# Or load targets from a file (one BMC host per line):
sudo bash setup-k8s.sh --upgrade \
  --enable-redfish \
  --redfish-user admin \
  --redfish-pass "$BMC_PASS" \
  --redfish-targets @/etc/nvis/redfish-targets.txt
```

| Flag | Description |
|---|---|
| `--enable-redfish` | Deploy the Redfish exporter (`INT_REDFISH=true`) |
| `--redfish-user <name>` | BMC username for Redfish basic auth |
| `--redfish-pass <secret>` | BMC password (read from env var or wizard prompt) |
| `--redfish-targets <csv\|@file>` | Comma-separated BMC hosts, or `@/path/to/file.txt` (one BMC per line) |

### Decoupled from CDU / liquid-cooling integration

Previously the Redfish exporter only deployed when `INT_CDU=true` (the CDU integration owned the exporter). It now also deploys when `INT_REDFISH=true`. Both integrations may be enabled simultaneously — the exporter is shared and target lists are merged.

```bash
# Both at once:
sudo bash setup-k8s.sh --upgrade --enable-cdu --enable-redfish \
  --redfish-user admin --redfish-pass "$BMC_PASS" \
  --redfish-targets @/etc/nvis/redfish-targets.txt
```

### Exporter (`scripts/redfish_exporter.py`) features

The exporter is rewritten in v2.2 and exposes the following:

- **HTTP `/refresh` endpoint** on `:9102` — triggers an on-demand scrape of all configured targets. Used by the Hardware Config Mgmt dashboard's refresh button.
- **SEL collection** — System Event Log entries are scraped per target. Disable with `SEL_DISABLED=true`.
- **Chassis cache** — chassis inventory is cached for `CHASSIS_TTL` seconds (default `1800`) to reduce BMC load.
- **Configurable sensor regex** — filter which Redfish sensors are collected.
- **Configurable SEL log path** — override the default SEL collection URL per BMC vendor.
- **Firmware-inventory toggle** — opt out of `FirmwareInventory` collection on BMCs where it is slow or unsupported.

### In-cluster service endpoint

Once deployed, the exporter is reachable inside the cluster at:

```
http://nvis-redfish-exporter.<namespace>.svc:9102/metrics
http://nvis-redfish-exporter.<namespace>.svc:9102/refresh
```

The **Hardware Config Mgmt** dashboard's refresh button is auto-wired to the `/refresh` endpoint — the installer substitutes the namespace-specific URL into the dashboard JSON at deploy time. No manual editing of the dashboard is required.

### Verify

```bash
KC="KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/kubectl-bin"

# Pod up
${KC} get pods -n nvis-monitoring -l app=nvis-redfish-exporter

# Metrics reachable
${KC} port-forward -n nvis-monitoring svc/nvis-redfish-exporter 9102:9102 &
curl -s http://localhost:9102/metrics | grep redfish_temperature_celsius | head

# Trigger an on-demand scrape (same call the dashboard refresh button makes)
curl -s -X POST http://localhost:9102/refresh
```

Then open Grafana → NVIS folder → **NVIS GPU Profiling** or **B300 Temperature History**.

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| DCGM pods Pending | Node missing `nvidia.com/gpu.present=true` label — script labels automatically |
| Alloy CrashLoopBackOff | `kubectl logs -n nvis-monitoring -l app=nvis-alloy` — usually wrong Prometheus/Loki URL |
| No metrics in Grafana | Check Alloy logs; verify Prometheus at `:9090/targets` shows GPU nodes |
| PVC Pending | k3s includes local-path-provisioner — should auto-provision; check `kubectl get pv` |
| Image pull error | Image not in local registry — check `curl http://ObsVM:5000/v2/_catalog` |
| k3s won't start | `journalctl -u k3s -n 50`; run `sudo bash scripts/k3s-fix-service.sh` |
| SSH Phase 4 hangs | Test jump chain manually (see Prerequisites above); may need `ssh-copy-id` |
| Phase 0 skips k3s wrongly | GPU node has stale kubelet binary — `which kubelet` on node; remove if not in use |
| Redfish exporter `401 Unauthorized` | Wrong `--redfish-user`/`--redfish-pass` — verify with `curl -k -u user:pass https://<BMC>/redfish/v1/Chassis` |
| Redfish dashboards empty | No targets configured — check `kubectl get cm -n nvis-monitoring nvis-redfish-config -o yaml` for the target list |
| Refresh button does nothing | Dashboard URL not substituted — check `kubectl get cm -n nvis-monitoring | grep dashboard` and re-run `setup-k8s.sh --upgrade` |
| SEL scrape times out | Disable SEL: set `SEL_DISABLED=true` in the exporter Deployment env, or raise `CHASSIS_TTL` to reduce frequency |
