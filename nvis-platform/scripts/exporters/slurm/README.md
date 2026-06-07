# nvis-slurm-exporter

Collects Slurm job telemetry by SSHing to the cluster head node (BCM /
slurmctld), running `squeue` (live) + `sacct` (historical window), and
exposing Prometheus metrics on `:9402/metrics`.

## Environment

| Var | Default | Meaning |
|---|---|---|
| `BCM_HOST` | (empty) | Cluster head hostname/IP. Required; exporter emits `up=0` until set. |
| `BCM_USER` | `root` | SSH user on the head node. |
| `BCM_JUMP` | (empty) | Optional `-J` jump host. |
| `BCM_SSH_KEY` | `/ssh/id_ed25519` | Path to private key (mount via k8s Secret). |
| `BCM_SSH_PORT` | `22` | SSH port. |
| `BCM_TIMEOUT` | `30` | SSH connect timeout (seconds). |
| `CLUSTER_NAME` | `nvis-cluster` | Cluster label on every emitted metric. |
| `SLURM_PORT` | `9402` | HTTP listen port. |
| `SCRAPE_INTERVAL` | `30` | Seconds between collects. |
| `SACCT_HOURS` | `72` | Historical window passed to `sacct --starttime=now-Nhours`. |

## Endpoints

- `GET /metrics` — Prometheus text format
- `GET /health` (also `/healthz`) — 200 OK if a successful collect occurred in the last `3*SCRAPE_INTERVAL` seconds, else 503

## Metrics

`slurm_jobs_running_total`, `slurm_jobs_pending_total`, `slurm_jobs_active_total`,
`slurm_users_active_total`, `slurm_users_running_total`,
`slurm_jobs_active_by_user`, `slurm_jobs_active_by_partition`,
`slurm_jobs_recent_by_user_state`, `slurm_jobs_recent_total`,
`slurm_users_recent_total`, `slurm_jobs_recent_by_user`,
`slurm_job_elapsed_seconds`, `slurm_job_cpu_seconds`,
`slurm_job_maxrss_bytes`, `slurm_job_averss_bytes`, `slurm_job_ncpus`,
`slurm_job_info` (label carrier: jobid, user, state, partition, nnodes, ncpus),
`slurm_exporter_last_success_timestamp`, `up`.

## Deployment

Use the `nvis-platform` helm chart with `integrations.slurm.enabled=true`.
SSH key is mounted from the `nvis-bcm-ssh-key` Secret at `/ssh/id_ed25519`.
