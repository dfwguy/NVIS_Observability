# NVIS Platform — Operator Install Guide

End-to-end guide for installing NVIS Platform on a fresh Linux VM that has network access to the cluster's BMCs, BCM head, and any other integration endpoints you plan to enable.

## Prerequisites

| Requirement | Why |
|---|---|
| Linux x86_64 host with at least 8 vCPU / 32 GB RAM / 200 GB disk | Runs Prometheus + Loki + Grafana + every enabled exporter |
| `sudo` access on the install host | k3s install, systemd services, port binding |
| Network reach to every BMC and integration endpoint you enable | Per-integration scrape paths |
| SSH key on the install host that can `ssh root@<bcm-head>` (only if enabling BCM/Slurm) | The BCM/Slurm exporter SSHes the head |
| BMC credentials (single user/pass that covers every BMC) | Redfish + IPMI exporters |
| UFM REST credentials (only if enabling UFM) | InfiniBand fabric scrape |
| NetQ bearer token *or* user/pass (only if enabling NetQ) | Cumulus telemetry scrape |
| NMC BCM-exporter user/pass (only if enabling NMC) | NVIDIA Mission Control federation |
| Outbound to `gcr.io` / `docker.io` / `quay.io` / `ghcr.io` (or an air-gap mirror) | Container image pulls |

If `helm` is not installed, `install.sh` will install it. If `k3s` is not running, `install.sh` will install it.

## What the installer does

11 phases, in order:

1. **Detect** — `lib/detect.sh` probes BCM cmsh → Redfish Model → prompt for `DGX_FLAVOR`. Aborts on hard prereq failures.
2. **Prereqs** — installs k3s + helm if missing. Skipped on `--upgrade`.
3. **Cluster** — verifies the k3s cluster is healthy, creates namespace `nvis`.
4. **Wizard** — Y/N per integration. For every Y, prompts for endpoints + credentials. State is persisted to `state/install-state.env` (mode `600`) and to a k8s ConfigMap `nvis-install-state`.
5. **Secrets** — idempotently creates each k8s Secret (BMC creds, BCM SSH key, UFM creds, NetQ creds, NMC creds, PowerShelf creds, SMTP password, webhooks).
6. **Render values** — writes the merged helm values to `/tmp/nvis-install-*/values.yaml`.
7. **Helm install** — `helm upgrade --install nvis ./helm/nvis-platform/ --values <merged>`.
8. **Wait for health** — polls each enabled component's readiness endpoint with per-target timeouts.
9. **Provision** — uploads dashboards into Grafana via the file provider (mounted ConfigMap).
10. **Smoke** — `curl http://<obsvm-ip>:30300/api/health` + `curl http://<obsvm-ip>:9090/api/v1/query?query=up`.
11. **Print access info** — host/port table + initial Grafana password (auto-generated if not supplied).

All output is tee'd to `/tmp/nvis-install-<pid>.log`.

## Fresh install

```bash
sudo bash install.sh
```

You'll see prompts like:

```
[1/11] Detect environment
[1/11] DGX_FLAVOR detected: DGX_BLACKWELL
...
[4/11] Per-integration wizard
  Enable DCGM GPU exporter? [Y/n]:
  Enable node-exporter? [Y/n]:
  Enable Alloy logs collector? [Y/n]:
  Enable BCM (Bright Cluster Manager) integration? [y/N]: y
    [wizard] Collecting BCM/Slurm SSH configuration
    BCM head node (hostname or IP): bcm-head.example.com
    BCM SSH user [root]:
    BCM SSH private key path [/root/.ssh/id_ed25519]:
  Enable Slurm jobstats exporter (uses BCM SSH)? [y/N]: y
  Enable cgroup_exporter DaemonSet on compute nodes? [y/N]: y
  Enable Redfish-main exporter? [y/N]: y
    BMC IPs (CSV) or @/path/to/file: 10.0.0.10,10.0.0.11,10.0.0.12
    BMC username [admin]:
    BMC password (hidden): ****
  ...
```

When the wizard finishes, the installer prints a summary table of enabled integrations and a confirmation prompt before applying anything.

## Upgrade

```bash
sudo bash install.sh --upgrade
```

- Reads the prior `state/install-state.env` (no re-prompting for already-collected values).
- Only asks about integrations that were previously OFF or are new in this release.
- Re-applies the helm chart with the current values.
- Leaves PVCs (Grafana / Prometheus / Loki) untouched.

## Non-interactive install

For air-gap / CI / pre-configured environments:

```bash
sudo bash install.sh --non-interactive --values-file /path/to/state.env
```

The state file must define every `INT_*` toggle plus the matching credentials for each enabled integration. The schema is documented in [`lib/state.sh`](../lib/state.sh) (`_STATE_SAFE_KEYS` array).

## Slurm wiring (post-install)

After `install.sh` completes with Slurm enabled, see [`SLURM_INTEGRATION.md`](SLURM_INTEGRATION.md) to copy the prolog/epilog scripts onto the slurmctld head and register them in `slurm.conf`. The dashboards will populate as soon as a job runs through the updated slurmctld.

## Common install failures

| Symptom | Cause | Fix |
|---|---|---|
| `[detect] DGX_FLAVOR=UNKNOWN` | BCM unreachable AND no BMC reachable | Set `DGX_FLAVOR` manually in the prompt fallback, OR pass `--values-file` with `cluster.dgxFlavor=DGX_HOPPER` (etc) |
| `helm install` fails on PVC | Missing default StorageClass | `kubectl get sc` — set one as default, or override `storage.{prometheus,loki,grafana}.storageClass` |
| `bmc-unreachable` alert fires immediately after install | Redfish-fast hasn't started yet OR `cluster` label not set | Wait ~5 min; if persistent, check `kubectl -n nvis logs deploy/nvis-redfish-fast` |
| `slurm_jobs_*` panels show "No data" | Prolog/epilog not wired on slurmctld | See [`SLURM_INTEGRATION.md`](SLURM_INTEGRATION.md) |
| `cgroup_info` empty | cgroup_exporter pods not scheduling on Slurm compute nodes | Set `integrations.cgroupExporter.nodeSelector` to match your compute-node labels |
| PowerShelf pods running but `nvis_powershelf_up=1` only | `POWERSHELF_HOSTS` empty (expected if no shelves configured) | Configure `POWERSHELF_HOSTS` and re-run `--upgrade`, OR leave disabled |
| Pods stuck `ImagePullBackOff` on `ghcr.io/nvidia-nvis/*` | Internal images not pulled yet | Run `docker pull` + `docker save` + `ctr image import` in the air-gap path, OR override `image.registry` |
| `DiskPressure` evictions | Host root FS >85% full | Free disk on the host; PVC sizing doesn't matter — kubelet eviction is based on host FS % free, not PVC usage |

## Uninstall

```bash
sudo bash install.sh --cleanup
# or
sudo bash uninstall.sh
```

By default, PVCs are preserved (logs and metrics survive). Pass `--purge-data` to also delete persistent volumes.

## Logs

- Install: `/tmp/nvis-install-<pid>.log`
- State (post-install): `state/install-state.env` (mode `600`)
- ConfigMap state: `kubectl -n nvis get configmap nvis-install-state -o yaml`
