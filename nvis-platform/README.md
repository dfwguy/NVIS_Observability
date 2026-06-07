# NVIS Platform

Unified observability + deployment-hardware-validation stack for NVIDIA DGX / Cumulus / BCM clusters.

**Current version:** see [`VERSION`](VERSION) — release notes in [`CHANGELOG.md`](CHANGELOG.md).

## What this is

A single deployable that runs on a fresh Linux VM and stands up two coherent Grafana sections in one stack:

1. **Deployment Hardware Validation** — BMC health, full Redfish sensor walk (per-component temps, fans, power), IPMI SEL / SOL log streams, PowerShelf telemetry, DGX-OS reachability, cluster-health BMC grid + email / Teams / Slack alerts. Use when you arrive at a new cluster and need to know *"is the hardware OK before I deploy anything else."*
2. **Observability** — DCGM GPU metrics, node-exporter, Alloy log shipping, BCM cluster inventory, Slurm jobstats (cgroup_exporter + slurm_job_exporter), RunAI federation, UFM (InfiniBand), NetQ (Cumulus), NMC (NVIDIA Mission Control) federation, plus executive / business / impact-analysis dashboards. Use once the cluster is live to run a workload-aware customer-facing view.

One install. One Grafana. Pick the integrations you want; the rest stay off.

## Quick start

```bash
sudo bash install.sh
```

The wizard asks Y/N per integration. For every YES it collects the endpoint + credentials it needs. Nothing is hardcoded — no IPs, no emails, no webhooks, no cluster names baked in. You supply everything.

For a re-run that only asks about new integrations you didn't enable last time:

```bash
sudo bash install.sh --upgrade
```

Other flags:

```bash
bash install.sh --help              # full usage
bash install.sh --detect-only       # run lib/detect.sh and exit (no install)
bash install.sh --non-interactive   # read state file only; abort if missing values
bash install.sh --values-file PATH  # supply helm values overrides
bash install.sh --dry-run           # render manifests, do not apply
bash install.sh --cleanup           # exec uninstall.sh
```

Grafana defaults to NodePort `30300`. Browse to `http://<host-ip>:30300/`.

## Integrations

### Observability

| Integration | Default | What you supply | Notes |
|---|---|---|---|
| DCGM GPU exporter | Y | NGC API key (optional, only for pull-from-NGC) | Delegated to `nvis-gpu-agents` subchart, DaemonSet on GPU nodes |
| Node Exporter | Y | — | Per-host CPU / mem / disk / net |
| Alloy logs | Y | — | Per-node DaemonSet; tails `/var/log/{syslog,kern,auth,nv-hostengine,slurmd}` |
| BCM | N | BCM head IP, SSH user, SSH key | `cmsh` event scrape via SSH |
| Slurm jobstats | N | (reuses BCM SSH creds) | SSHes head, runs `squeue` + `sacct`; needs `INT_BCM` enabled |
| cgroup-exporter | N | — | DaemonSet on Slurm compute nodes; walks `/sys/fs/cgroup/.../slurm/uid_*/job_*` for per-job CPU/mem |
| UFM (InfiniBand) | N | UFM host, user, pass | Fabric switches, alarms, FW |
| NetQ (Cumulus) | N | NetQ URL, bearer token (or user/pass) | Fabric telemetry |
| RunAI | N | RunAI URL, token, cluster UUID, Prom federation target | DCGM + workload federation |
| NMC (NVIDIA Mission Control) | N | NMC head host, BCM-exporter user, password | Prometheus federation against NMC's BCM exporter (port 8081 HTTPS Basic Auth) |

### Hardware validation

| Integration | Default | Port | What it captures |
|---|---|---|---|
| Redfish main | N | 9102 | Full BMC inventory (10-minute slow walk): firmware, SEL, sensor catalog, chassis |
| Redfish NM (NodeManager) | N | 9106 | Fast power telemetry — dcPlatformPower, FixPwr, CPU package power, DRAM power, GPU power, PSU |
| Redfish Fast | N | 9107 | Thermal/fan/power (30s cycle): per-sensor temperatures, fan RPM, power draw — feeds the `bmc-unreachable` alert |
| Redfish Sensors | N | 9108 | Granular per-component temperatures via `/Chassis/*/Sensors` (80s cycle, 200+ sensors per BMC) |
| IPMI SEL | N | (push-only) | Per-BMC `ipmitool sel elist` → Loki. Catches IERR + Nvidia OEM events Redfish drops |
| IPMI SOL | N | 9104 (healthz) | Serial-over-LAN console capture → Loki |
| PowerShelf | N | 9103 | LiteOn PF-1333-13RD: per-PSU input/output volts, amps, watts, frequency, fan RPM, current share, FW mismatch detection |
| DGX-OS ping | N | 9116 | Host-level reachability ping for each DGX node — feeds the `DGX-OS Health` dashboard |

### Alerts

| Channel | Default | What you supply |
|---|---|---|
| Email | N | SMTP host:port, from address, recipients (semicolon-separated), optional auth |
| Microsoft Teams | N | Incoming webhook URL |
| Slack | N | Incoming webhook URL |

Built-in alert rules: `bmc-unreachable` (per-BMC, fires after 5 min of >50% scrape failures), `gpu-temp-high` (>80°C for 5 min), `node-down` (5 min), `loki-ingestion-stalled` (10 min).

## Auto-detection

At install time the platform tries to detect the GPU server flavor (the value of `DGX_FLAVOR`) from the cluster:

1. SSH BCM head, run `cmsh -c 'category list'`, parse the model token.
2. If BCM is unreachable: probe one BMC's `/redfish/v1/Systems/{id}` `Model` field.
3. Fallback: wizard prompt with a menu of common flavors plus a custom option.

The detected flavor flows into Prometheus `external_labels`, dashboard titles (via the `${dgx_flavor}` template variable), and alert labels. One dashboard set works for every supported GPU server family.

## Slurm jobstats wiring

The Slurm exporter pulls `squeue` + `sacct` over SSH, but joining accounting metadata onto live job IDs requires slurmctld prolog/epilog hooks. See [`docs/SLURM_INTEGRATION.md`](docs/SLURM_INTEGRATION.md) for the slurmctld wiring (1 copy + 2 lines in `slurm.conf`).

The shipped scripts at `scripts/slurm/jobstats_{prolog,epilog}.sh` are idempotent and honour `NVIS_JOBINFO_DIR` (default `/cm/shared/apps/slurm/jobinfo` per BCM convention).

## Repo layout

```
nvis-platform/
├── install.sh                              # master entry — wizard + helm install (11 phases)
├── build.sh                                # reproducible tarball builder
├── VERSION
├── CHANGELOG.md
├── lib/
│   ├── detect.sh                           # DGX flavor probe (BCM → Redfish → prompt)
│   ├── wizard.sh                           # interactive prompts per integration
│   ├── state.sh                            # install state persisted in ConfigMap + 600 state file
│   ├── secrets.sh                          # idempotent k8s Secret generation
│   └── prereqs.sh                          # OS detect + k3s install
├── nvis-deployment-hardware-validation/
│   └── dashboards/                         # HW validation dashboards (sanitized)
├── nvis-observability/
│   └── dashboards/                         # observability dashboards (sanitized)
├── helm/nvis-platform/
│   ├── Chart.yaml
│   ├── values.yaml                         # every integration toggleable
│   ├── dashboards/{hw,obs}/                # JSON dashboards packaged into ConfigMaps
│   └── templates/
│       ├── alert-rules.yaml                # Grafana alert rules (provisioned)
│       ├── alloy.yaml                      # log shipper DaemonSet
│       ├── bcm.yaml                        # BCM exporter Deployment
│       ├── cgroup-exporter.yaml            # cgroup_exporter DaemonSet (Slurm)
│       ├── cmdaemon.yaml                   # cmdaemon exporter Deployment
│       ├── contact-points.yaml             # Grafana alert contact points
│       ├── dashboards-{hw,obs}.yaml        # dashboard ConfigMap providers
│       ├── dgx-ping.yaml                   # DGX reachability exporter
│       ├── grafana.yaml                    # Grafana StatefulSet
│       ├── ipmi-{sel,sol}.yaml             # IPMI log pipelines
│       ├── loki.yaml                       # log aggregation
│       ├── netq.yaml                       # NetQ exporter
│       ├── notification-policies.yaml      # alert routing
│       ├── powershelf.yaml                 # PowerShelf exporter
│       ├── prometheus.yaml                 # Prometheus + scrape config
│       ├── redfish-{main,nm,fast,sensors}.yaml   # 4 Redfish exporter shapes
│       ├── runai.yaml                      # RunAI federation values
│       ├── slurm.yaml                      # slurm-job-exporter Deployment
│       ├── storage-pvc.yaml                # PVCs for Grafana/Prometheus/Loki
│       └── ufm.yaml                        # UFM exporter
├── scripts/
│   ├── exporters/                          # containerized exporter sources
│   │   ├── dgx-ping/
│   │   ├── ipmi-sel/
│   │   ├── ipmi-sol/
│   │   ├── netq/
│   │   ├── powershelf/
│   │   ├── redfish-fast/
│   │   ├── redfish-main/
│   │   ├── redfish-nm/
│   │   ├── redfish-sensors/
│   │   └── slurm/
│   └── slurm/                              # slurmctld hooks (jobstats prolog/epilog)
└── docs/
    └── SLURM_INTEGRATION.md                # slurmctld wiring guide
```

## Tarball build

```bash
bash build.sh                # → /tmp/nvis-builds/nvis-platform-<VERSION>.tar.gz + .sha256
bash build.sh --output DIR   # override output directory
bash build.sh --skip-helm    # skip helm lint/template steps (e.g. helm not installed)
```

Every build runs: `bash -n` on shell, `python3 -m py_compile` on Python, `json.load` on dashboards, `helm lint`, `helm template` (min + max), and a forbidden-string scan that aborts on any customer / internal-infra reference.

## License

(TBD — placeholder)
