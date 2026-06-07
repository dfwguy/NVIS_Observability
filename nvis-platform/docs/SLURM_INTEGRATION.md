# Slurm Jobstats Integration

End-to-end wiring so the `Single Job Stats` and `Single Job Stats (multinode)` dashboards populate with real data on a freshly installed cluster.

## What ships in the helm chart

| Piece | Where it runs | Toggle |
|---|---|---|
| `nvis-slurm-exporter` (Deployment) | k3s on ObsVM | `integrations.slurm.enabled=true` |
| `nvis-cgroup-exporter` (DaemonSet) | k3s on every Slurm compute node | `integrations.cgroupExporter.enabled=true` |
| Prometheus scrape jobs | k3s on ObsVM | (auto-enabled with above) |

## What you wire on the cluster head (slurmctld)

The exporter correlates `squeue` rows with accounting attributes via per-job metadata files written by Slurm prolog/epilog hooks. Both scripts ship in the tarball at `scripts/slurm/`.

### 1. Copy the hooks onto the head node

```
sudo cp scripts/slurm/jobstats_prolog.sh /etc/slurm/jobstats_prolog.sh
sudo cp scripts/slurm/jobstats_epilog.sh /etc/slurm/jobstats_epilog.sh
sudo chmod 755 /etc/slurm/jobstats_{prolog,epilog}.sh
```

### 2. Register the hooks in `/etc/slurm/slurm.conf`

```
PrologSlurmctld=/etc/slurm/jobstats_prolog.sh
EpilogSlurmctld=/etc/slurm/jobstats_epilog.sh
```

### 3. Reload slurmctld

```
sudo systemctl reload slurmctld   # or 'restart' if reload is unsupported
sudo scontrol reconfigure
```

### 4. (Optional) Override the jobinfo directory

Default: `/cm/shared/apps/slurm/jobinfo` (BCM convention).

Non-BCM clusters: set `NVIS_JOBINFO_DIR` in the slurmctld service environment:

```
# /etc/systemd/system/slurmctld.service.d/override.conf
[Service]
Environment=NVIS_JOBINFO_DIR=/var/spool/slurm/jobinfo
```

Then mirror the same value into `integrations.slurm.jobinfoDir` in `values.yaml` so the exporter reads from the same path (the helm template forwards it to the Deployment as an env var).

## Verification

After install + a test job:

```
# 1. cgroup_exporter is reachable from inside the cluster
kubectl exec -n nvis -it deploy/nvis-prometheus -- \
    wget -qO- http://nvis-cgroup-exporter:9306/metrics | grep cgroup_info

# 2. slurm-job-exporter is populating
kubectl exec -n nvis -it deploy/nvis-prometheus -- \
    wget -qO- http://nvis-slurm-exporter:9402/metrics | grep slurm_jobs_running_total

# 3. Submit a sleep job, then watch the dashboard:
ssh head 'sbatch --wrap "sleep 600"'
# Grafana → Dashboards → Single Job Stats → select the JobID
```

If panels stay empty, in order:

1. Is the BCM SSH key Secret mounted on the exporter pod? `kubectl describe pod -l app=nvis-slurm-exporter`
2. Can the pod SSH to the head node? Check pod logs — `[slurm-exporter] ssh error: ...` indicates auth/network failure.
3. Is the prolog script running? `tail /var/log/slurm/slurmctld.log` on the head; you should see `jobstats_prolog: wrote ...`.
4. Is the jobinfo dir writable by SlurmUser? `ls -ld $NVIS_JOBINFO_DIR`.
5. Is `cgroup_info` populated? On a compute node: `curl -s localhost:9306/metrics | head`.

## Why two exporters

- `cgroup_exporter` runs **on each compute node** and walks `/sys/fs/cgroup/.../slurm/uid_*/job_*` itself — no prolog needed for cgroup metrics. The prolog is only for joining accounting metadata (user, account, nodes, ncpus) onto the jobid.
- `slurm_job_exporter` runs **once on ObsVM** and SSHes to the head — pulls `squeue` (live) + `sacct` (history) so dashboards have job-level rollups, not just per-cgroup memory/cpu.

Dashboards join the two by `jobid`: `cgroup_info{jobid=$JobID}` × `slurm_job_info{jobid=$JobID}` × DCGM `{instance}` (by node).
