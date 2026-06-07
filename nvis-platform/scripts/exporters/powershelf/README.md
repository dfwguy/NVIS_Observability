# nvis-powershelf-exporter

Scrapes LiteOn PF-1333-13RD PowerShelves over Redfish and exposes Prometheus
metrics on `:9103`. Each shelf reports 6 PSUs and ~72 sensors (per-PSU input
voltage/current/power, output voltage/current/power, frequency, current share,
plus chassis-level aggregates and fan RPM + thermal data).

## Environment

| Var | Default | Meaning |
|---|---|---|
| `POWERSHELF_HOSTS` | (empty — exporter runs idle) | CSV of shelf IPs or `@/path/to/hosts.txt`. IPs of `0.0.0.0` / blank are skipped. |
| `POWERSHELF_USER` | `root` | Redfish username on the shelf BMC. |
| `POWERSHELF_PASS` | (empty) | Redfish password (LiteOn factory default: `0penBmc`). |
| `CLUSTER_NAME` | (empty) | Cluster label stamped on every metric. |
| `PORT` | `9103` | Listen port. |
| `SCRAPE_INTERVAL` | `30` | Seconds between scrape cycles. |
| `VERIFY_SSL` | `false` | TLS verification — shelves typically use self-signed. |
| `POWERSHELF_TIMEOUT` | `10` | Per-HTTP-call timeout (seconds). |
| `POWERSHELF_MAX_WORKERS` | `16` | Concurrent shelves per cycle. |
| `POWERSHELF_SENSOR_WORKERS` | `8` | Concurrent per-shelf sensor fetches (BMC PMC caps at ~8). |
| `POWERSHELF_PSU_FW_EXPECTED` | `0xf1 / 0xf1` | Expected PSU FW string; mismatches surface as a `*_psu_fw_mismatch` metric. |
| `POWERSHELF_META_REFRESH` | `60` | Cycles between ServiceRoot+Chassis re-fetches. |

## Endpoints

- `GET /metrics` — Prometheus text format
- `GET /` — same as `/metrics`

## Metrics

Per-PSU: `nvis_powershelf_psu_input_volts`, `nvis_powershelf_psu_input_amps`,
`nvis_powershelf_psu_input_watts`, `nvis_powershelf_psu_output_volts`,
`nvis_powershelf_psu_output_amps`, `nvis_powershelf_psu_output_watts`,
`nvis_powershelf_psu_frequency_hz`, `nvis_powershelf_psu_temp_celsius`,
`nvis_powershelf_psu_fan_rpm`, `nvis_powershelf_psu_current_share_pct`,
`nvis_powershelf_psu_fw_mismatch`.

Chassis-level: `nvis_powershelf_input_power_watts`, `nvis_powershelf_output_power_watts`,
`nvis_powershelf_efficiency_pct`, `nvis_powershelf_load_pct`,
`nvis_powershelf_input_current_amps`, `nvis_powershelf_output_current_amps`.

Health: `nvis_powershelf_up{shelf=<ip>}`, `nvis_powershelf_scrape_duration_seconds`.

## Operational notes

- A `401`/`403` from a shelf is recorded once per scrape cycle and the shelf
  is then SKIPPED for the rest of that cycle. LiteOn BMC enforces an account
  lockout (4 consecutive auth failures → 10-minute lockout), so the exporter
  errs on the side of stopping early to avoid locking the operator out.
- If `POWERSHELF_HOSTS` is empty, the exporter runs idle (still serves
  `/metrics` with `nvis_powershelf_up=1`) — the install path keeps it running
  for deployments that don't have shelves provisioned yet.

## Deployment

Use the `nvis-platform` helm chart with `integrations.powershelf.enabled=true`.
Credentials are mounted from the `nvis-powershelf-credentials` Secret (keys
`username` and `password`).
