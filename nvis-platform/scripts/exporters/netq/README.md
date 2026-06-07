# NVIS Platform -- NetQ Exporter

Prometheus exporter for the NVIDIA Cumulus NetQ REST API. It polls the
NetQ telemetry server every `SCRAPE_INTERVAL` seconds and exposes the
results on `/metrics`.

## What it scrapes

| NetQ endpoint                         | Prometheus metric                       |
|---------------------------------------|-----------------------------------------|
| `GET /netq/api/v1/endpoints/devices`    | `netq_device_info`, `netq_device_up`    |
| `GET /netq/api/v1/endpoints/events`     | `netq_event_count{severity,type}`       |
| `GET /netq/api/v1/endpoints/links`      | `netq_link_up{src,dst,...}`             |
| `GET /netq/api/v1/endpoints/interfaces` | `netq_interface_bytes_in/out`, `netq_interface_oper_up` |

A `netq_up` gauge and `netq_scrape_errors_total` / `netq_scrape_duration_seconds`
are emitted for self-monitoring.

## Environment variables

| Variable          | Default  | Notes                                                          |
|-------------------|----------|----------------------------------------------------------------|
| `NETQ_URL`        | *(req)*  | Base URL, e.g. `https://netq.example.com`                      |
| `NETQ_TOKEN`      | *(opt)*  | Bearer token; takes priority over username/password            |
| `NETQ_USER`       | *(opt)*  | API username; used with `NETQ_PASS` when no token is supplied  |
| `NETQ_PASS`       | *(opt)*  | API password                                                   |
| `CLUSTER_NAME`    | `""`     | Static `cluster` label on every metric                         |
| `PORT`            | `9109`   | Listen port for `/metrics` and `/healthz`                      |
| `SCRAPE_INTERVAL` | `30`     | Seconds between full NetQ polls                                |
| `HTTP_TIMEOUT`    | `15`     | Per-request timeout (seconds)                                  |
| `VERIFY_SSL`      | `true`   | Verify NetQ TLS certificate                                    |

## Ports

* `9109/tcp` -- Prometheus scrape (`/metrics`) and health (`/healthz`).

## Build and run on a workstation

```
docker build -t nvis-platform-netq .
docker run --rm \
    -e NETQ_URL=https://netq.example.com \
    -e NETQ_TOKEN=<bearer> \
    -e CLUSTER_NAME=demo \
    -p 9109:9109 \
    nvis-platform-netq
curl -s http://localhost:9109/metrics | grep netq_
```

## Kubernetes deployment

Toggle via `integrations.netq.enabled=true` in the umbrella Helm chart and
populate the `nvis-netq-credentials` secret with `url`, plus either `token`
or (`user`, `pass`). See `helm/nvis-platform/templates/netq.yaml`.
