# cgroup_exporter

Prometheus exporter for Linux cgroup v2 metrics, providing per-job resource usage (CPU, memory, I/O) for Slurm workloads.

**Upstream**: https://github.com/treydock/cgroup_exporter

## Deployment

Deploy to Slurm head nodes and compute nodes. The exporter reads cgroup hierarchy under `/sys/fs/cgroup/system.slice/slurmstepd.scope/` to export per-job metrics.

### systemd service

The `cgroup_exporter.service` unit in this directory installs the exporter as a system service:

```bash
sudo cp cgroup_exporter.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now cgroup_exporter
```

Default metrics port: **9306**

## Prometheus Scrape Config

```yaml
- job_name: cgroup_exporter
  static_configs:
    - targets:
        - head-node-01:9306
        - compute-01:9306
  relabel_configs:
    - target_label: cluster
      replacement: YOUR_CLUSTER_NAME
```

## Key Metrics

| Metric | Description |
|--------|-------------|
| `cgroup_cpu_seconds_total` | CPU time used per Slurm job |
| `cgroup_memory_used_bytes` | RSS memory per job |
| `cgroup_memory_limit_bytes` | Memory limit set by Slurm |
| `cgroup_cpu_limit` | CPU core limit per job |

## Grafana Integration

Metrics appear in the **Single Job Stats** dashboard (`single-job-stats-cod1.json`) under the container/cgroup resource utilization panels. If cgroup_exporter is not deployed, those panels will show "No data" — `container_*` (cadvisor) metrics provide an alternative for containerized workloads.

## Notes

- Requires Slurm cgroup plugin enabled: `ProctrackType=proctrack/cgroup` in `slurm.conf`
- cgroup v2 required (Linux kernel ≥ 5.2, standard on RHEL 9 / Ubuntu 22.04+)
- Run as root or with `CAP_SYS_ADMIN` to read cgroup accounting files
