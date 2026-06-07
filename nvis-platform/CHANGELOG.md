# Changelog

## [2.1.1] — 2026-05-27

PowerShelf integration + doc overhaul.

### Added
- `scripts/exporters/powershelf/` — containerized LiteOn PF-1333-13RD Redfish exporter (port 9103). Per-PSU input/output volts/amps/watts/frequency, current share, fan RPM, FW mismatch detection. Chassis-level derived aggregates (efficiency_pct, load_pct).
- `helm/nvis-platform/templates/powershelf.yaml` — Deployment + Service + ServiceMonitor + hosts ConfigMap. Toggle: `integrations.powershelf.enabled`. Credentials mounted from `nvis-powershelf-credentials` Secret (keys `username` + `password`).
- `install.sh` wizard prompt for PowerShelf + `prompt_powershelf_block` in `lib/wizard.sh` collecting `POWERSHELF_HOSTS` (CSV or `@file`), `POWERSHELF_USER`, `POWERSHELF_PASS`.
- Prometheus scrape job `powershelf` (gated on `integrations.powershelf.enabled`).
- `state.sh` schema extended with `INT_POWERSHELF`, `POWERSHELF_HOSTS`, `POWERSHELF_USER`.
- `docs/INSTALL.md` — operator install / upgrade / troubleshoot guide (covers all 11 install phases, every integration's credential set, common failure modes including PowerShelf-idle and Slurm wiring).
- `README.md` rewritten to reflect the full v2.1.x integration set (HW pack: Redfish main/NM/fast/sensors + IPMI SEL/SOL + PowerShelf + dgx-ping; obs pack: DCGM/Node/Alloy/BCM/Slurm/cgroup/UFM/NetQ/RunAI/NMC).

### Notes
- PowerShelf exporter runs idle (`nvis_powershelf_up=1` only) when `POWERSHELF_HOSTS` is empty — install path keeps the pod alive for clusters that don't have shelves provisioned yet.
- Account-lockout safety: a `401`/`403` from a shelf stops scraping that shelf for the rest of the cycle (LiteOn BMC locks out after 4 consecutive auth failures for 10 minutes).

## [2.1.0] — 2026-05-27

Slurm jobstats wiring + dgx-ping rescue + alert correctness.

### Added
- `scripts/exporters/slurm/` — containerized `slurm_job_exporter` (proven 397-line Python lifted from production). Helm template `slurm.yaml` already shipped in 2.0 but referenced an image with no source; this completes the loop. Metrics: `slurm_jobs_running_total`, `slurm_jobs_pending_total`, `slurm_job_{elapsed_seconds,cpu_seconds,maxrss_bytes,averss_bytes,ncpus}`, `slurm_job_info` (jobid/user/state/partition label carrier).
- `helm/nvis-platform/templates/cgroup-exporter.yaml` — `treydock/cgroup_exporter` DaemonSet on Slurm compute nodes (port 9306). Emits per-job `cgroup_info{jobid}` the existing observability dashboards already query. Toggle: `integrations.cgroupExporter.enabled`.
- `scripts/slurm/jobstats_prolog.sh` + `jobstats_epilog.sh` — slurmctld hooks that write per-job metadata to `${NVIS_JOBINFO_DIR:-/cm/shared/apps/slurm/jobinfo}` so the exporter can correlate live `squeue` rows with accounting attributes. Path is env-configurable for non-BCM clusters.
- `scripts/exporters/dgx-ping/` — portable replacement for the v1.5.2 orphan: containerized exporter, env-driven hosts list, k8s `templates/dgx-ping.yaml` Deployment, and a portable systemd unit (no longer hardcoded to a single user's `$HOME`). Heals the `dgx-ping` scrape job and `DGX-OS Health` dashboard that previously stayed `DOWN` on fresh installs.
- `docs/SLURM_INTEGRATION.md` — slurmctld prolog/epilog wiring + verification steps.

### Fixed
- `bmc-unreachable` alert: replaced incorrect `max by (bmc, cluster) (up{job="redfish-fast"}) == 0` (which loses the per-BMC dimension because the `up` metric has no `bmc` label) with the per-BMC `avg_over_time(redfish_fast_up{cluster=~".+"}[5m]) < 0.5`. Also `for: 2m` → `5m`, `noDataState: NoData` → `OK` (suppresses bootstrap false positives). Mirrors the v1.5.2 production patch.
- Install wizard: split the "BCM / Slurm integration" prompt into separate `INT_BCM` / `INT_SLURM` / `INT_CGROUP` toggles. Slurm + cgroup-exporter depend on BCM SSH but are independently disable-able.

### Notes
- `netq.json` dashboard added to `helm/nvis-platform/dashboards/obs/` so the chart packaging glob actually includes it.
- NetQ wizard block (URL + bearer token, falls back to user/pass) is shipped — was already present in `lib/wizard.sh`, but documenting now since the audit flagged it as missing.

## [2.0.0] — 2026-05-21 (in progress)

Unified rebuild. Single repo, single tarball, single Grafana on k3s.

### Added
- `nvis-deployment-hardware-validation/` folder with sanitized hardware-validation dashboards (cluster-health, sensors-temps, nm-power, temp-history, gpu-profiling, hw-config-mgmt, powershelf, hw-validation-home).
- `nvis-observability/` folder with sanitized observability dashboards (executive, superpod-cio, business-insights, impact-analysis, runai-intelligence, gpu-health, cluster-overview, bcm-cluster, live-topology, live-topology-v2, network-fabric, ib-fabric, node-deep-dive, cmdaemon-clusterminder, security-audit, single-job-stats, single-job-stats-multinode, demo-home, netq).
- Fully modular install wizard — every integration toggleable.
- Auto-detection of GPU server flavor (BCM cmsh probe, Redfish Model probe, prompt fallback).
- Containerized k3s deployments for all four Redfish sub-exporters (NM, Fast, Sensors) and the IPMI SEL / SOL pipelines (previously host-only).
- NetQ (Cumulus Linux fabric) integration — exporter, helm template, dashboard.
- Generic Grafana contact-points (email / Teams / Slack) — every parameter driven by install-time inputs.

### Removed
- All references to specific internal lab clusters, customer codenames, and historical site identifiers.
- All hardcoded private-subnet IPs that referred to internal infrastructure.
- All hardcoded internal email addresses and Microsoft Teams webhook tokens.
- Legacy Docker-compose-based standalone hardware-debug stack — folded into the k3s helm chart.

### Changed
- Merged the former standalone hardware-debug Docker stack into the main k3s helm chart on Grafana NodePort 30300.
- Helm chart renamed to `nvis-platform`.
- Dashboard cluster variable defaults: no longer hardcoded — driven by `label_values(up, cluster)` with All as default.
- Dashboard titles now use the `${dgx_flavor}` template variable so a single dashboard works for every supported NVIDIA GPU server family.
