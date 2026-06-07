```
╔══════════════════════════════════════════════════════════════════════════════════════╗
║                                                                                      ║
║    ███╗   ██╗██╗   ██╗██╗███████╗    ██████╗ ██████╗ ███████╗                       ║
║    ████╗  ██║██║   ██║██║██╔════╝   ██╔═══██╗██╔══██╗██╔════╝                       ║
║    ██╔██╗ ██║██║   ██║██║███████╗   ██║   ██║██████╔╝███████╗                       ║
║    ██║╚██╗██║╚██╗ ██╔╝██║╚════██║   ██║   ██║██╔══██╗╚════██║                       ║
║    ██║ ╚████║ ╚████╔╝ ██║███████║   ╚██████╔╝██████╔╝███████║                       ║
║    ╚═╝  ╚═══╝  ╚═══╝  ╚═╝╚══════╝    ╚═════╝ ╚═════╝ ╚══════╝                       ║
║                                                                                      ║
║         Full-Stack GPU Cluster Observability · Deploy Anywhere in Minutes            ║
║                                                                                      ║
╚══════════════════════════════════════════════════════════════════════════════════════╝
```

```
┌─────────────────────────────── NVIS HOME DASHBOARD ────────────────────────────────┐
│                                                                                     │
│  ◉ Cluster Health  ████████████████████░░  92%    GPU Util  ████████████░░░  76%   │
│  ◉ Node Status     16/16 online                  Temp (avg) ██████░░░░░░░░  42°C   │
│  ◉ Active Jobs     24 running · 6 queued         NVLink      ████████████░░  OK     │
│  ◉ Fabric Links    48/48 up · 0 errors           ECC Events  ░░░░░░░░░░░░░░  0      │
│                                                                                     │
│  ┌── Compute & GPU ──────┐  ┌── SPX Network Fabric ────┐  ┌── Infrastructure ────┐ │
│  │ GPU Status            │  │ SPX Topology             │  │ NVIS Home            │ │
│  │ GPU Health (ECC/XID)  │  │ SPX Traffic & Health     │  │ Node Deep Dive       │ │
│  │ NVLink Health         │  │ SPX Events & Alarms      │  │ Hardware Config Mgmt │ │
│  │ GPU Profiling         │  │ SPX Live Topology        │  │ Security & Audit     │ │
│  │ Cluster Overview      │  │ Network Fabric · UFM     │  │ BCM ClusterMinder    │ │
│  │ Single Job Stats      │  │ Live Topology v2         │  │ BMC Sensor History   │ │
│  │ Run.ai Intelligence   │  │                          │  │ Operational Intel    │ │
│  │ SuperPOD Command Ctr  │  │                          │  │ Executive Overview   │ │
│  └───────────────────────┘  └──────────────────────────┘  └──────────────────────┘ │
│                                                                                     │
│  Stack: VictoriaMetrics · Loki · Grafana · Alloy · DCGM · Terraform · k3s          │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

> **NVIS Observability** is a production-grade, full-stack monitoring platform for NVIDIA GPU clusters.
> It covers every layer of the stack — from BMC sensors and GPU die temperature up through Slurm jobs,
> SPX/Ethernet fabric health, InfiniBand UFM, run.ai workload intelligence, BCM cluster management,
> and executive-level ROI dashboards — deployed with a single script and driven entirely by a
> single `cluster_name` variable. No hard-coding. Drop it on any cluster and it works.

---

## [00] quick start

```bash
# 1. Clone
git clone https://github.com/dfwguy/nvis-observability.git
cd nvis-observability

# 2. Deploy to your ObsVM (dedicated observability node)
bash setup.sh

# 3. Open Grafana
#    http://<OBSVM_IP>:3000   →  admin / <your-password>

# 4. Deploy Grafana dashboards via Terraform
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars → set grafana_url, grafana_auth, cluster_name
terraform init && terraform apply -auto-approve
```

> `cluster_name` in `terraform.tfvars` is the **single variable** that propagates through every dashboard,
> every scrape config, every Alloy config, and every Helm value across the entire stack.

---

## [01] what it does

- **Full-stack GPU cluster observability** from BMC hardware sensors to executive ROI dashboards
- **26 production Grafana dashboards** covering GPU, Slurm, SPX fabric, IB/UFM, BCM, run.ai, security, and operations
- **Push-based log shipping** via Grafana Alloy on every node — no inbound firewall holes required
- **Terraform-managed dashboards** — drop a JSON file in `terraform/dashboards/`, run `terraform apply`, done
- **SPX Ethernet fabric monitoring** via LLDPq v3.7.4 — LLDP topology, BGP, optical BER, link flap detection
- **Per-Slurm-job resource tracking** via cgroup_exporter — CPU, memory, I/O per job on every node
- **BCM / BrightCluster Manager** integration — node health, CMDaemon, ClusterMinder, provisioning state
- **Redfish BMC integration** — 171 temperature sensors, fan RPM, per-component power, SEL event history
- **Run.ai workload intelligence** — GPU allocation, queue depth, utilization efficiency, scheduler backlog
- **InfiniBand / UFM** federation — fabric health, port counters, congestion, link flap events
- **Cluster-neutral** — one `cluster_name` variable, works on DGX SuperPOD, HGX, BCM-managed HPC, bare-metal

---

## [02] observability coverage

| Domain | What Is Monitored | Data Sources |
|---|---|---|
| **GPU** | Utilization, memory, temperature, ECC errors, XID events, NVLink throughput, throttle state, power | DCGM Exporter :9400 |
| **GPU Profiling** | 171 per-component temperatures (HGX), 32 fan RPM channels, per-GPU power rails, SEL history | Redfish BMC Exporter |
| **Slurm Jobs** | Per-job GPU/CPU/memory, runtime, node assignment, log correlation, prolog/epilog events | cgroup_exporter :9306, Loki |
| **SPX Fabric** | Link utilization, BGP state, optical BER/FEC errors, port flap events, config change alarms | LLDPq, nvis-spx-metrics |
| **InfiniBand / UFM** | Port counters, fabric health, congestion, link errors, switch inventory | UFM REST Exporter |
| **BCM / BrightCluster** | Node provisioning state, CMDaemon health, ClusterMinder alerts, service status | BCM Exporter :9401 |
| **BMC / Redfish** | Temperature, fans, power, firmware inventory, SEL events, chassis state | Redfish Exporter :9102/9103 |
| **Run.ai** | GPU allocation by project/user, queue utilization, workload scheduling efficiency | Run.ai REST Exporter |
| **Logs** | Syslog, kernel/XID, DCGM, Slurm, Fabric Manager, SPX events, auth, IPMI SOL | Grafana Alloy → Loki |
| **Infrastructure** | CPU, memory, disk I/O, network throughput, filesystem usage per node | node_exporter :9100 |
| **Containers/cAdvisor** | Per-Slurm-job container cgroup stats (CPU, memory, blkio, network) | cAdvisor :9280 |
| **Security** | SSH logins, auth failures, sudo events, certificate expiry, service changes | Loki (syslog/auth streams) |
| **Operations** | Cluster uptime, GPU hours, allocation efficiency, cost per job, availability trends | VictoriaMetrics |

---

## [03] dashboards (26 production dashboards)

All dashboards live in `grafana/dashboards/NVIS/` (k8s configmap provisioning)
and `terraform/dashboards/` (Terraform apply). They are identical — update either, redeploy both.

### Compute & GPU

| Dashboard | UID | Key Panels |
|---|---|---|
| **GPU Status** | `gpu-status-beacon` | Per-GPU utilization heatmap, memory %, SM occupancy, power draw |
| **GPU Health — ECC, Throttle, NVLink** | `gpu-health-cod` | ECC error rate, XID event timeline, thermal throttle state, NVLink bandwidth |
| **GPU Error & NVLink Health** | `gpu-nvlink-health` | NVLink RX/TX per lane, FEC correctable/uncorrectable, per-GPU error log |
| **NVIS GPU Profiling** | `nvis-gpu-profiling` | 171 Redfish temp sensors (HGX board + GPU die), 32 fan channels, SEL event log |
| **Cluster Overview** | `cluster-overview-cod` | All-node GPU util, active jobs, queue depth, cluster-wide power draw |
| **Single Job Stats** | `single-job-stats-cod1` | Per-job GPU/CPU/memory from cgroup + container, slurmctld/slurmd/XID log correlation |
| **SuperPOD Command Center** | `nvis-superpod-cio` | CIO-level cluster health, SLA tracking, top consumers, incident summary |
| **Executive Overview** | `nvis-executive` | GPU hours delivered, allocation efficiency, utilization trends, cost/job |
| **Operational Intelligence** | `nvis-business-insights` | Allocation vs. capacity, usage heatmap, project-level breakdown, idle GPU tracking |
| **Run.ai Intelligence** | `nvis-runai-intelligence` | Queue utilization, per-project GPU allocation, workload backlog, scheduler efficiency |

### SPX Network Fabric

| Dashboard | UID | Key Panels |
|---|---|---|
| **SPX Fabric — Live Topology** | `spx-topology` | LLDP-derived adjacency graph, 2-plane spine-leaf layout, link state |
| **SPX Fabric — Live Topology (embedded)** | `spx-topology-live` | iFrame-embedded real-time LLDPq topology canvas |
| **SPX Fabric — Traffic & Health** | `spx-traffic-health` | Leaf-spine link utilization %, interface counters (TX/RX bytes/errors) |
| **SPX Fabric — Health (BGP/Optical/BER)** | `spx-fabric-health` | BGP session state per switch, optical BER/FEC, log severity by switch |
| **SPX Fabric — Events, Alarms & Config Changes** | `spx-events-alarms` | Switch event timeline, alarm count by severity, config change audit log |
| **Network Fabric — UFM · IB · Spectrum-X** | `nvis-network-fabric` | IB port counters, UFM fabric health, congestion events, link flap history |
| **Live Cluster Topology** | `nvis-live-topology` | Full cluster node-link diagram, fault visualization, neighbor discovery |
| **Live Cluster Topology v2** | `nvis-live-topology-v2` | Updated topology with color-coded fault state and switch/compute layers |

### Infrastructure & Operations

| Dashboard | UID | Key Panels |
|---|---|---|
| **Node Deep Dive** | `nvis-node-deep-dive` | Per-node CPU/memory/disk/network drill-down, process top, dmesg log |
| **Hardware Config Management** | `nvis-hw-config-mgmt` | Firmware versions, driver inventory, hardware drift, Redfish refresh |
| **Temperature & Sensor History** | `nvis-b300-temp-history` | Platform temp history by node and BMC target, fan/PSU state over time |
| **BCM Cluster** | `bcm-lillypod-v1` | BrightCluster node provisioning state, node health grid, rack layout |
| **NVIS CMDaemon & ClusterMinder** | `nvis-cmdaemon-cm` | BCM daemon health, ClusterMinder alert feed, service up/down timeline |
| **Cross-Domain Impact Analysis** | `nvis-impact-analysis` | Correlate job failures → GPU XID → fabric events → node health in one view |
| **Security, Compliance & Audit** | `nvis-security-audit` | SSH auth failures, sudo log, cert expiry countdown, service change audit |

---

## [04] component stack

```
┌────────────────────────────────────────────────────────────────────┐
│  GPU Compute Nodes                                                  │
│  ├─ DCGM Exporter        :9400   GPU metrics (util/mem/temp/ECC)   │
│  ├─ node_exporter         :9100   CPU/mem/disk/network              │
│  ├─ cgroup_exporter       :9306   Per-Slurm-job cgroup v2 metrics  │
│  ├─ cAdvisor              :9280   Container cgroup stats            │
│  └─ Grafana Alloy               Log shipping → Loki (push)         │
│                                                                     │
│  Head / Management Nodes                                            │
│  ├─ BCM Exporter          :9401   BrightCluster Manager REST API   │
│  ├─ Slurm Exporter        :9402   squeue/sinfo/sacct metrics        │
│  ├─ slurmctld log               → Alloy → Loki (syslog stream)     │
│  └─ cgroup_exporter       :9306   (also on head for prolog/epilog) │
│                                                                     │
│  ObsVM (Observer VM)                                                │
│  ├─ nvis-spx-metrics      :9111   SSH→switch node_exporter bridge  │
│  ├─ nvis-spx-lldpq-bridge :9112   LLDPq→Prometheus bridge          │
│  ├─ Redfish Exporter      :9102   BMC telemetry (fast path)         │
│  ├─ Redfish Exporter      :9103   BMC telemetry (head/slow path)    │
│  ├─ NVLink Exporter       :9106   nvidia-smi nvlink -e SSH poll     │
│  ├─ UFM Exporter          :9109   UFM REST API → Prometheus         │
│  ├─ Run.ai Exporter       :9105   Run.ai control plane REST API     │
│  ├─ CMDaemon Exporter     :9108   BCM cmsh SSH read-only            │
│  ├─ Custom/Compliance     :9110   BCM drift + cert expiry           │
│  └─ LLDPq                :8080   LLDP topology + switch SSH         │
│                                                                     │
│  Kubernetes (k3s on ObsVM)                                          │
│  ├─ VictoriaMetrics       :8428   Long-term metrics storage         │
│  ├─ Loki                  :3100   Log aggregation                   │
│  └─ Grafana               :3000   Dashboards (Terraform-managed)    │
└────────────────────────────────────────────────────────────────────┘
```

---

## [05] infrastructure — kubernetes & storage

Deployed as a **k3s** single-node Kubernetes cluster on the ObsVM.
Helm charts are in `helm/nvis-obsvm/` (observability core) and `helm/nvis-gpu-agents/` (per-node agents).

```bash
# Deploy the full observability stack
bash setup-k8s.sh

# Upgrade with new integrations
bash setup-k8s.sh --upgrade \
  --enable-redfish --redfish-user admin --redfish-pass <secret> \
  --redfish-targets 10.0.0.100,10.0.0.101 \
  --enable-bcm \
  --enable-runai

# Redeploy dashboards only (after JSON edits)
cd terraform && terraform apply -auto-approve
```

**Storage configuration** (`helm/nvis-obsvm/values.yaml`):

| Component | Default PVC | Retention | Notes |
|---|---|---|---|
| VictoriaMetrics | 200 Gi | 90 days | Prometheus-compatible TSDB; replaces Prometheus for long retention |
| Loki | 100 Gi | 30 days | Log chunks + index; configurable in `loki/loki-config.yaml` |
| Grafana | 5 Gi | persistent | Dashboard state, annotations, user prefs |
| Prometheus | 20 Gi | 15 days | Short-term scrape buffer (federated to VictoriaMetrics) |

Storage class defaults to `local-path` (k3s built-in).
Override with `--set storageClass=<class>` for NFS, Ceph, or Longhorn.

---

## [06] BCM — BrightCluster Manager

BCM integration uses a read-only `cmsh` SSH session from the ObsVM to the BCM head node.
No BCM license modifications required. Exports node provisioning state, service health,
ClusterMinder alerts, and hardware inventory.

```bash
# Deploy BCM exporters to head node
bash setup_bcm.sh <OBSVM_IP> <CLUSTER_NAME>

# Or via setup-k8s.sh upgrade
bash setup-k8s.sh --upgrade --enable-bcm
```

**Exporters deployed:**

| Service | Port | Metrics |
|---|---|---|
| `bcm-exporter` | 9401 | Node state (UP/DOWN/INSTALLING/ERROR), rack layout, OS image version |
| `cmdaemon-exporter` | 9108 | CMDaemon process health, BCM daemon up/down timeline |
| `slurm-exporter` | 9402 | squeue job counts, sinfo node state, partition utilization |
| `s4k-generator` | — | Custom BCM compliance scoring and hardware drift detection |

**Dashboards:** `BCM Cluster` · `NVIS CMDaemon & ClusterMinder` · `Cluster Overview`

---

## [07] BMC & Redfish

Full Redfish integration for IPMI/BMC telemetry.
Two exporter paths: **fast** (DGX BMC, 10s scrape) and **slow** (head/CDU, 60s scrape).

```bash
# Enable at install
bash setup-k8s.sh --upgrade \
  --enable-redfish \
  --redfish-user    admin \
  --redfish-pass    <bmc-password> \
  --redfish-targets 10.0.0.100,10.0.0.101,10.0.0.102
```

**What is collected:**

| Category | Metrics | Dashboard |
|---|---|---|
| Temperature | 171 sensors per DGX (GPU die, HGX board, inlet, outlet, VR) | GPU Profiling |
| Fan | 32 RPM channels per chassis | GPU Profiling |
| Power | Per-component power rails, PSU input, chassis total | GPU Profiling |
| SEL | System Event Log — hardware faults, DIMM errors, correctable/uncorrectable | GPU Profiling |
| Firmware | BIOS, BMC, NIC, GPU driver versions — change detection | Hardware Config Mgmt |
| Sensors | Aggregate per-node sensor history with `node` dropdown filter | Temperature & Sensor History |

**Additional IPMI integrations:**
- `ipmi-sel/` — SEL event exporter (systemd service, exports to Loki)
- `ipmi-sol/` — Serial Over LAN capture → Loki (console crash logs)
- `redfish-nm/` — Node Manager power capping metrics (GB200/GB300 NVL72)

---

## [08] SPX Ethernet fabric & LLDPq

SPX is NVIDIA's SuperPOD Ethernet fabric — 2-plane spine-leaf Cumulus Linux / NVOS topology.
NVIS monitors it via **LLDPq v3.7.4** (SSH/LLDP polling) and a custom **nvis-spx-metrics** bridge.

### LLDPq setup

```bash
cd lldpq

# 1. Configure switches
cp lldpq-config/devices.yaml.example     lldpq-config/devices.yaml
cp lldpq-config/topology_config.yaml.example lldpq-config/topology_config.yaml

# Edit devices.yaml — add switch management IPs, hostnames, roles
# username: 'cumulus' for Cumulus Linux, 'admin' for NVIDIA NVOS/SPX

# 2. Add SSH key for switch access
mkdir -p lldpq-ssh-keys
cp ~/.ssh/id_rsa lldpq-ssh-keys/   && chmod 600 lldpq-ssh-keys/id_rsa

# 3. Start
docker compose up -d
# UI: http://ObsVM-IP:8080   Metrics: http://ObsVM-IP:8080/metrics
```

**SPX topology structure (2-plane spine-leaf):**

```
   PL1-SPINE          PL2-SPINE
      │                   │
  ┌───┴───┐           ┌───┴───┐
 PL1-L1  PL1-L2     PL2-L1  PL2-L2
  │  │    │  │       │  │    │  │
  └──┴────┴──┴───────┴──┴────┴──┘
     DGX-01  DGX-02  DGX-03  DGX-04
```

**What LLDPq monitors:**

| Metric | Description |
|---|---|
| LLDP adjacency | Link state between every switch port and neighbor |
| BGP sessions | BGP peering state per switch (Cumulus/NVOS FRR) |
| Optical BER/FEC | Bit error rate and FEC correctable/uncorrectable counters |
| Link flap events | Port up/down event timeline, flap frequency detection |
| Config changes | Running-config diff alerts (NVOS `nv show` / Cumulus `net show`) |
| Log severity | Per-switch syslog severity distribution (info/warning/error/critical) |
| Interface counters | TX/RX bytes, errors, drops per port |

**Prometheus scrape config** (add to `obsvm-values.yaml`):

```yaml
- job_name: spx-lldpq-bridge
  scrape_interval: 60s
  honor_labels: true
  static_configs:
    - { targets: ["127.0.0.1:9112"], labels: { cluster: "my-cluster" } }
```

---

## [09] Slurm & per-job stats

NVIS gives you **per-job** resource telemetry at the Slurm level — not just cluster-wide averages.

### cgroup_exporter

Deployed to every Slurm-managed node (compute + head). Reads cgroup v2 hierarchy
under `/sys/fs/cgroup/system.slice/slurmstepd.scope/` per job.

```bash
# Deploy to all nodes (BCM clusters — runs via BCM root trust from head)
for NODE in compute-01 compute-02 compute-03; do
  scp cgroup_exporter/cgroup_exporter.service root@${NODE}:/etc/systemd/system/
  ssh root@${NODE} "systemctl daemon-reload && systemctl enable --now cgroup_exporter"
done
```

| Metric | Description |
|---|---|
| `cgroup_cpu_seconds_total` | Accumulated CPU time per Slurm job |
| `cgroup_memory_used_bytes` | RSS memory used per job |
| `cgroup_memory_limit_bytes` | Slurm memory limit set for the job |
| `cgroup_cpu_limit` | CPU core count allocated by Slurm |

### Log correlation in Single Job Stats

All four Loki log panels in `single-job-stats-cod1` stream from the live `syslog` job:

```
slurmctld events  →  {job="syslog"} |~ "slurmctld"
slurmd/stepd      →  {job="syslog"} |~ "(?i)(slurmd|slurmstepd|JobId)"
XID / NVRM errors →  {job="syslog"} |~ "(?i)(NVRM|XID|nvml|nv-hostengine)"
kernel / OOM      →  {job="syslog"} |~ "(?i)(OOM|oom-kill|Killed process|mce)"
```

---

## [10] InfiniBand & UFM

For InfiniBand fabrics, NVIS integrates with **NVIDIA UFM** (Unified Fabric Manager)
via REST API. UFM federation is also supported for multi-fabric deployments.

```bash
# Enable at install
bash setup-k8s.sh --upgrade --enable-ufm --ufm-host <UFM_IP> --ufm-user admin
```

**UFM Exporter** (`exporters/ufm_rest_exporter.py`):

| Metric | Source |
|---|---|
| Port state (ACTIVE / INIT / DOWN) | UFM `/resources/ports` |
| Port counters (TX/RX bytes, errors) | UFM `/monitoring/` |
| Fabric health score | UFM `/ufmRest/app/health` |
| Link flap events | UFM event feed |
| Switch inventory | UFM `/resources/systems` |

**Dashboard:** `Network Fabric — UFM · IB · Spectrum-X · NCCL`

> The IB/UFM dashboard is included even on SPX (Ethernet) deployments — it simply shows
> "no data" when UFM is not enabled. Leave it in place for clusters that may migrate or
> run a hybrid IB + SPX fabric.

---

## [11] Run.ai

NVIS integrates with the **Run.ai** scheduler REST API to surface workload intelligence
that Run.ai's built-in dashboards don't provide alongside GPU health and fabric data.

```bash
# Enable (uses a tunnel or direct route to the Run.ai control plane)
bash setup-k8s.sh --upgrade --enable-runai
```

**Run.ai Exporter** (polls Run.ai REST API, exposes Prometheus metrics on `:9105`):

| Metric | Description |
|---|---|
| GPU allocation by project | Requested vs. allocated GPU count per Run.ai project |
| Queue depth | Pending jobs waiting for GPU resources |
| Utilization efficiency | Allocated GPUs actually running kernels vs. idle |
| Workload backlog | Jobs stuck in queue > threshold (default 30 min) |
| Scheduler events | Preemptions, evictions, rescheduling events |

**Dashboard:** `Run.ai Intelligence — GPU Allocation, Utilization & Workloads`

---

## [12] log shipping — Grafana Alloy

Grafana Alloy is deployed as a systemd service on every node.
It ships logs to Loki on the ObsVM via HTTP push (no firewall holes on compute nodes).

**Alloy is self-healing** via `alloy-watchdog.sh` — if a node reboots and wipes the binary
or config, the watchdog (running on the head node) re-deploys it automatically within the
next check interval.

```bash
# Bootstrap the watchdog on the head node
ALLOY_STAGE=/cm/shared/apps/nvis/alloy \
DGX_NODES="compute-01 compute-02 compute-03" \
LOKI_URL="http://obsvm:3100/loki/api/v1/push" \
bash bootstrap-alloy-watchdog.sh
```

**Active Loki streams on each node:**

| Stream `{job=...}` | Content |
|---|---|
| `syslog` | All syslog messages (incl. slurmctld, slurmd, Fabric Manager) |
| `journal` | systemd journal (service start/stop, kernel messages) |
| `kernel` | Kernel ring buffer — MCE, GPU XID via dmesg |
| `auth` | PAM auth — SSH logins, sudo, su, failed auth |
| `redfish-sel` | BMC System Event Log — hardware faults |
| `spx-events` | SPX switch event log (via nvis-spx bridge) |
| `ipmi-sol` | Serial Over LAN — console crash dumps |

**Alloy config template:** `node-configs/config.alloy.template`

---

## [13] security & compliance

The **Security, Compliance & Audit** dashboard (`nvis-security-audit`) consolidates:

- SSH login attempts (successful and failed) per node, per user, per source IP
- `sudo` command audit log — who ran what, when, on which node
- `su` privilege escalation events
- Certificate expiry countdown — TLS certs across all services
- BCM service state changes (provisioning daemon events)
- Custom compliance scoring via `scripts/bcm_exporter.py`

Alloy ships `auth` logs from all nodes with label `{job="auth", node="..."}`.
No agents or secondary collectors — everything rides the existing Alloy pipeline.

---

## [14] Terraform dashboard management

All dashboards are managed by **Terraform** using the Grafana provider `~> 3.0`.
The `fileset()` pattern means a new dashboard JSON dropped in `terraform/dashboards/`
is deployed on the next `terraform apply` — no code changes needed.

```hcl
# terraform/main.tf (key section)
locals {
  dashboard_files = fileset("${path.module}/dashboards", "*.json")
}

resource "grafana_dashboard" "nvis" {
  for_each    = local.dashboard_files
  folder      = grafana_folder.nvis.uid
  config_json = file("${path.module}/dashboards/${each.value}")
  overwrite   = true
}
```

**Terraform variables:**

| Variable | Default | Description |
|---|---|---|
| `grafana_url` | `http://localhost:3000` | Grafana base URL |
| `grafana_auth` | — | `"admin:<password>"` or service-account token |
| `cluster_name` | `my-cluster` | Propagates to all dashboard `$cluster` defaults |
| `grafana_folder_name` | `NVIS` | Grafana folder display name |
| `victoriametrics_url` | `http://nvis-victoriametrics:8428` | VictoriaMetrics endpoint |
| `loki_url` | `http://nvis-loki:3100` | Loki endpoint |

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Set: grafana_url, grafana_auth, cluster_name
terraform init
terraform apply -auto-approve
```

---

## [15] GPU hardware support

| GPU Family | DCGM Version Required | Notes |
|---|---|---|
| Hopper (H100 / H200) | 3.x or 4.x | Full support — all counters available |
| Blackwell (B100 / B200 / B300) | **4.x required** | DCGM 3.x has NO Blackwell support |
| Blackwell (GB200 / GB300 NVL72) | 4.x + NMC | Liquid cooling metrics via `redfish-nm` exporter |
| Ampere (A100 / A30 / A10) | 3.x or 4.x | Full support |
| Ada Lovelace (L40 / L40S) | 3.x or 4.x | Full support |

DCGM counters used are defined in `dcgm/dcgm-counters.csv` — edit to add/remove metrics.

---

## [16] requirements

- **ObsVM:** Ubuntu 22.04+ / RHEL 9+ · 16 GB RAM · 300 GB disk · 4 cores
- **Kubernetes:** k3s (auto-installed by `setup-k8s.sh`) or bring your own k8s cluster
- **GPU nodes:** Linux · DCGM Exporter 4.x (Blackwell) or 3.x (Hopper/Ampere) · SSH from ObsVM
- **Network:** ObsVM reachable from GPU nodes on port 3100 (Loki push) and 9090 (Prometheus)
- **Terraform:** >= 1.3.0 (for `fileset()` + `jsonencode()` reliability)
- **BCM:** BrightCluster Manager with REST API enabled (optional — for BCM dashboards)
- **SPX:** Cumulus Linux or NVIDIA NVOS with LLDP enabled and SSH access from ObsVM
- **Run.ai:** Run.ai control plane API reachable from ObsVM (direct or tunnel)

---

## [17] Slurm test jobs

Validation and demo jobs in `slurm/`:

```bash
# Real GPU workloads
sbatch slurm/gpu_burn.sbatch           # sustained GPU burn (all GPUs, all nodes)
sbatch slurm/nvis_demo_10mins.sbatch   # 10-minute demo: GPU + NVLink + log events

# Fault simulation
sbatch slurm/nvis_fault_demo.sbatch    # full fault cascade: XID → NVLink → OOM → RAID
sbatch slurm/xid_storm.sbatch          # XID error injection
sbatch slurm/nvlink_storm.sbatch       # NVLink fault simulation
sbatch slurm/gpu_tensor_storm.sbatch   # tensor core saturation
sbatch slurm/nccl_connection_storm.sbatch  # NCCL all-reduce fault simulation
sbatch slurm/cpu_mem_storm.sbatch      # CPU + memory pressure (OOM scenario)
sbatch slurm/log_storm.sbatch          # high-volume syslog injection

# Compliance / security tests
sbatch slurm/cert_expiry_sim.sbatch    # TLS certificate expiry simulation
sbatch slurm/job2_audit_compliance.sbatch  # BCM compliance scoring trigger
```

---

## [18] directory structure

```
nvis-observability/
├── terraform/                  # Grafana-as-code (Terraform grafana provider ~> 3.0)
│   ├── dashboards/             # 26 dashboard JSONs (auto-discovered via fileset())
│   ├── main.tf                 # Provider + folder + dashboard resources
│   ├── datasources.tf          # VictoriaMetrics + Loki datasource resources
│   ├── variables.tf            # cluster_name, grafana_auth, endpoints
│   └── terraform.tfvars.example
│
├── grafana/dashboards/NVIS/    # Same 26 JSONs — k8s configmap provisioning
├── helm/nvis-obsvm/            # Helm chart: Grafana, Loki, VictoriaMetrics, Prometheus
├── helm/nvis-gpu-agents/       # Helm chart: DCGM, node_exporter, Alloy per-node DaemonSet
│
├── lldpq/                      # LLDPq v3.7.4 integration (SPX/Ethernet fabric topology)
│   ├── docker-compose.yml
│   └── lldpq-config/           # devices.yaml.example, topology_config.yaml.example
│
├── cgroup_exporter/            # Per-Slurm-job cgroup v2 exporter (systemd service)
├── alloy/                      # Grafana Alloy log shipping config
├── node-configs/               # Per-node Alloy config templates
├── dcgm/                       # DCGM counter definitions (dcgm-counters.csv)
│
├── exporters/                  # Custom Python exporters
│   ├── ufm_rest_exporter.py    # UFM REST → Prometheus
│   └── ufm-rest-exporter.service
│
├── scripts/                    # Standalone exporters (run on ObsVM as systemd services)
│   ├── bcm_exporter.py         # BrightCluster Manager metrics
│   ├── cmdaemon_exporter.py    # CMDaemon health
│   ├── redfish_exporter.py     # Redfish BMC telemetry
│   ├── slurm_job_exporter.py   # Slurm squeue/sacct metrics
│   └── ufm_exporter.py         # UFM fabric metrics
│
├── slurm/                      # Slurm test + demo jobs
├── docs/                       # Deployment guide, setup instructions, dashboard inventory
├── alloy-watchdog.sh           # Self-healing Alloy re-deployer (runs on head node)
├── bootstrap-alloy-watchdog.sh # One-time watchdog installation
├── setup-k8s.sh                # Full k8s stack installer (interactive + flags)
├── setup.sh                    # Entry-point installer
├── obsvm-values.yaml.example   # Site-specific helm values template
└── .gitignore                  # Excludes: terraform.tfvars, obsvm-values.yaml, ssh keys
```

---

## [19] deployment notes

**Site-specific files** (not committed — copy from `.example` and fill in):

```
obsvm-values.yaml              ← copy from obsvm-values.yaml.example
terraform/terraform.tfvars     ← copy from terraform/terraform.tfvars.example
lldpq/lldpq-config/devices.yaml          ← copy from devices.yaml.example
lldpq/lldpq-config/topology_config.yaml  ← copy from topology_config.yaml.example
lldpq/lldpq-ssh-keys/id_rsa              ← your SSH key for switch access
```

**The one variable that rules them all:**

```bash
# In terraform/terraform.tfvars
cluster_name = "my-cluster"

# In helm install
helm upgrade nvis-obsvm ./helm/nvis-obsvm -f obsvm-values.yaml --set clusterName=my-cluster

# In Alloy config (auto-injected by setup-k8s.sh)
CLUSTER_NAME=my-cluster bash setup-k8s.sh
```

Setting `cluster_name` propagates through: dashboard `$cluster` variable defaults ·
VictoriaMetrics labels · Loki stream selectors · Alloy relabeling · all scrape configs.

---

## [20] license

MIT License — see [LICENSE](LICENSE).

---

*Built by Harish · NVIDIA Enterprise Infrastructure*
