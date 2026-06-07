# NVIS Observability — Deployment Guide

## Overview

NVIS Observability is a unified GPU cluster monitoring stack. A single installer (`nvis-setup.sh`) deploys all components across three tiers of infrastructure with no manual configuration file editing.

### What gets deployed where

| Component | Location | Method | Purpose |
|-----------|----------|--------|---------|
| Prometheus | ObsVM | Docker Compose | Metrics storage and query engine |
| Grafana | ObsVM | Docker Compose | Dashboards and visualization |
| Loki | ObsVM | Docker Compose | Log aggregation |
| VictoriaMetrics | ObsVM | Docker Compose | Long-term metrics storage |
| bcm-exporter | ObsVM | Docker Compose | BCM cluster inventory metrics |
| slurm-job-exporter | ObsVM | Docker Compose | Slurm job metrics |
| Local registry | ObsVM | Docker | Serves images to airgapped GPU nodes |
| cAdvisor | BCM | Docker (standalone) | BCM container metrics |
| node-exporter | BCM | Docker (standalone) | BCM host metrics |
| Grafana Alloy | BCM | Docker (standalone) | Scrapes BCM, pushes to ObsVM |
| DCGM Exporter | GPU nodes | K8s DaemonSet (Helm) | GPU metrics (optional if pre-installed) |
| node-exporter | GPU nodes | K8s DaemonSet (Helm) | GPU node host metrics |
| Grafana Alloy | GPU nodes | K8s DaemonSet (Helm) | Scrapes each GPU node, pushes to ObsVM |

---

## Prerequisites

### Network requirements
- ObsVM must be reachable from BCM and all GPU nodes (ports 3000, 3100, 5000, 9090)
- BCM must be reachable from ObsVM via SSH (password auth)
- GPU nodes must be reachable from BCM via passwordless SSH
- GPU nodes do NOT need direct internet access (ObsVM serves the local registry)

### Software requirements
| Machine | Requirement |
|---------|-------------|
| ObsVM | Linux (Ubuntu 20.04+/RHEL 8+), `sudo` access |
| BCM | Docker installable via apt/yum (installer will install if missing) |
| GPU nodes | Kubernetes cluster running, `kubectl` on master node, `containerd` runtime |

### Bundle creation machine (internet-connected)
- Docker
- Internet access to pull images from Docker Hub, quay.io, gcr.io, nvcr.io

---

## Step 1: Create the bundle (on internet-connected machine)

Run this **once** on any machine with Docker and internet access:

```bash
git clone <nvis-observability-repo>
cd nvis-observability

# With DCGM (GPU metrics) — requires free NGC API key from ngc.nvidia.com
NGC_API_KEY=your_key_here bash scripts/create-bundle.sh

# Without DCGM (or if DCGM is already running on your nodes)
bash scripts/create-bundle.sh
```

This produces `nvis-observability-bundle.tar` (~4–8 GB depending on whether DCGM is included).

Transfer to the ObsVM:

```bash
scp nvis-observability-bundle.tar user@obsvm-ip:~/
```

---

## Step 2: Deploy (on ObsVM)

```bash
# Extract the bundle
tar -xf nvis-observability-bundle.tar
cd nvis-observability

# Run the unified installer
sudo bash scripts/nvis-setup.sh
```

The installer runs an interactive interview asking:

1. **ObsVM IP** — the IP other machines use to reach this ObsVM
2. **Cluster display name** — label used on all metrics and dashboards (e.g. `prod-h200-cluster`)
3. **Grafana admin password**
4. **Kubernetes namespace** (default: `nvis-monitoring`)
5. **BCM hostname or IP**
6. **BCM SSH user** (default: `root`)
7. **BCM root password** (not echoed)
8. **BCM version** (default: `11`)
9. **GPU node IPs** — one per line, type `done` when finished
10. **K8s master node IP** (defaults to first GPU node)
11. **GPU node SSH user from BCM** (default: `root`)
12. **DCGM status** — already running or should installer deploy it?
    - If already running: provide the port (default `9400`)
    - If not running: provide NGC API key, or leave blank to skip GPU metrics
13. **Run.ai** — if using Run.ai, provide the Prometheus namespace and service name
14. **Review and confirm** before anything is deployed
15. Settings are saved to `nvis-deploy.conf` (mode 600)

### What happens after you confirm

The installer proceeds through 7 automated phases:

| Phase | Description |
|-------|-------------|
| 0 | Pre-flight: install Docker/sshpass if missing, test SSH to BCM and GPU nodes, push ObsVM SSH key to BCM |
| 1 | Load bundled images, start local registry, push images to `OBSVM_IP:5000` |
| 2 | Write all config files, run `docker compose up -d`, wait for Grafana health |
| 3 | Transfer images to BCM, deploy cAdvisor + node-exporter + Alloy on BCM |
| 4 | Configure containerd on GPU nodes, install Helm, deploy DaemonSets via Helm |
| 5 | (Run.ai only) Patch Prometheus CR to forward `runai_*` metrics to ObsVM |
| 6 | Import Grafana dashboards |
| 7 | Print verification status and access URLs |

Total runtime is typically 5–15 minutes depending on image sizes and network speed.

---

## Step 3: Access Grafana

```
URL      : http://<OBSVM_IP>:3000
Username : admin
Password : (the password you entered during setup)
```

---

## Re-running and reconfiguring

To change any setting (new cluster name, different BCM IP, add GPU nodes, etc.):

```bash
sudo bash scripts/nvis-setup.sh --reconfigure
```

This re-runs the full interview and re-deploys all components with the new settings.

To skip specific phases (e.g. if ObsVM stack is already up and you only want to redeploy BCM):

```bash
sudo bash scripts/nvis-setup.sh --skip-phase 0,1,2
```

---

## Run.ai Integration

If you use Run.ai, the installer patches the Run.ai Prometheus `CustomResource` to forward all `runai_*` metrics to the NVIS Prometheus via `remoteWrite`. This enables Run.ai job and GPU utilization metrics to appear in NVIS Grafana dashboards.

Requirements:
- Run.ai Prometheus operator must be running in a known namespace
- The K8s master must have `kubectl` access to the Run.ai namespace

If the Run.ai Prometheus CR is not found automatically, you can add the remote_write manually:

```yaml
# Add to your Run.ai Prometheus CR spec:
remoteWrite:
  - url: "http://<OBSVM_IP>:9090/api/v1/write"
    writeRelabelConfigs:
      - sourceLabels: ["__name__"]
        regex: "runai.*"
        action: keep
```

---

## Troubleshooting

### Phase 0: SSH to BCM fails

```
[ERR ] Cannot reach BCM at <IP> — check host and password
```

- Verify BCM IP is reachable: `ping <BCM_IP>`
- Verify password auth is enabled on BCM sshd: `grep PasswordAuthentication /etc/ssh/sshd_config`
- Check that `sshpass` is installed on ObsVM: `sshpass -V`

### Phase 0: GPU node not reachable via BCM

```
[WARN] Cannot reach GPU node <IP> via BCM
```

This usually means passwordless SSH from BCM to GPU nodes is not set up. On BCM:

```bash
ssh-copy-id root@<GPU_NODE_IP>
# Or manually add BCM's public key to each node's ~/.ssh/authorized_keys
```

### Phase 2: Grafana not healthy

Check the Grafana logs:

```bash
docker logs nvis-grafana
docker compose -f /path/to/nvis-observability/docker-compose.yml ps
```

### Phase 3: Image transfer to BCM fails

If BCM already has the images, the transfer may show warnings but still succeed. Verify on BCM:

```bash
# SSH to BCM manually:
sshpass -p '<password>' ssh root@<BCM_IP> "docker images | grep -E 'cadvisor|node-exporter|alloy'"
```

### Phase 4: Helm deploy fails

Check on the K8s master:

```bash
# Via BCM:
sshpass -p '<password>' ssh root@<BCM_IP> "ssh root@<MASTER_IP> 'kubectl get pods -n nvis-monitoring'"
sshpass -p '<password>' ssh root@<BCM_IP> "ssh root@<MASTER_IP> 'kubectl describe pods -n nvis-monitoring'"
```

Common issues:
- containerd insecure registry not configured — re-run with `--skip-phase 0,1,2,3` to only redo GPU node setup
- GPU nodes cannot reach ObsVM port 5000 — check firewall rules on ObsVM
- Helm not found on K8s master — the installer attempts to copy it automatically

### No GPU metrics in Grafana

1. Check DCGM is running on GPU nodes: `kubectl get pods -n nvis-monitoring | grep dcgm`
2. Check Alloy is receiving DCGM data: `kubectl logs -n nvis-monitoring <alloy-pod> | grep dcgm`
3. Query Prometheus: `http://<OBSVM_IP>:9090/graph?g0.expr=DCGM_FI_DEV_GPU_UTIL`
4. If `DCGM_EXISTS=true` was set: ensure the DCGM port matches what you entered during setup

### BCM containers keep restarting

Check logs on BCM:

```bash
sshpass -p '<password>' ssh root@<BCM_IP> "docker logs nvis-alloy --tail 50"
sshpass -p '<password>' ssh root@<BCM_IP> "docker logs nvis-cadvisor --tail 20"
```

Alloy config issues (wrong ObsVM IP, unreachable Prometheus) will show in `nvis-alloy` logs.

### Log locations

| Log | Path |
|-----|------|
| nvis-setup.sh debug log | `<nvis-dir>/nvis-setup-debug-<timestamp>.log` |
| nvis-setup.sh summary report | `<nvis-dir>/nvis-setup-report-<timestamp>.log` |
| Grafana logs | `docker logs nvis-grafana` |
| Prometheus logs | `docker logs nvis-prometheus` |
| Loki logs | `docker logs nvis-loki` |
| BCM Alloy logs | `docker logs nvis-alloy` (on BCM) |
| K8s Alloy logs | `kubectl logs -n nvis-monitoring daemonset/nvis-alloy` (on master) |

---

## Uninstalling

### Remove ObsVM stack

```bash
cd nvis-observability
docker compose down -v   # -v also removes named volumes (metrics data)
docker rm -f nvis-registry
```

### Remove BCM containers

```bash
sshpass -p '<password>' ssh root@<BCM_IP> \
  "docker rm -f nvis-cadvisor nvis-node-exporter nvis-alloy"
```

### Remove GPU node DaemonSets

```bash
# On K8s master:
helm uninstall nvis-gpu-agents -n nvis-monitoring
kubectl delete namespace nvis-monitoring
```
