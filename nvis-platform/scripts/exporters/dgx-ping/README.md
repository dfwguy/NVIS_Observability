# NVIS Platform -- DGX Ping Exporter

A small Prometheus exporter that probes a list of DGX OS hosts over ICMP
(via the system `ping` binary) and publishes latency, packet-loss, and
reachability metrics on `/metrics`. Each host is polled in its own thread
so a single unreachable target cannot stall the others.

## Metrics

| Metric                              | Type    | Description                                            |
|-------------------------------------|---------|--------------------------------------------------------|
| `dgx_node_up`                       | gauge   | 1 if the latest burst saw any reply, else 0            |
| `dgx_node_ping_latency_ms`          | gauge   | Last successful avg RTT in milliseconds                |
| `dgx_node_packet_loss_ratio`        | gauge   | Loss fraction (0..1) over the last burst               |
| `dgx_node_last_seen_timestamp`      | gauge   | Unix epoch seconds of last successful reply            |
| `dgx_ping_exporter_up`              | gauge   | Constant `1` while the exporter is serving             |
| `dgx_ping_probe_total{result=...}`  | counter | Probes counted by result (`ok` / `timeout` / `error`)  |

All series carry `node`, `host`, and `cluster` labels.

## Environment variables

| Variable          | Default     | Notes                                                                       |
|-------------------|-------------|-----------------------------------------------------------------------------|
| `DGX_HOSTS`       | *(required)*| `name=ip,name=ip` OR `@/path/to/file` (newline/comma separated; `#` = comment) |
| `CLUSTER_NAME`    | `""`        | Static `cluster` label on every metric                                      |
| `LISTEN_ADDR`     | `0.0.0.0`   | HTTP bind address                                                           |
| `LISTEN_PORT`     | `9116`      | HTTP listen port (`/metrics`, `/healthz`)                                   |
| `PING_INTERVAL`   | `30`        | Seconds between probe bursts                                                |
| `PING_COUNT`      | `5`         | ICMP packets per burst                                                      |
| `PING_TIMEOUT`    | `2`         | Per-packet wait (passed to `ping -W`)                                       |

Legacy aliases `NODE_HOSTS`, `PORT`, and `SCRAPE_INTERVAL` are still honoured.

## Ping privileges

`/bin/ping` needs `CAP_NET_RAW`. There are three deployment paths:

* **Docker image (this repo)** -- runs as UID 65534. The Debian
  `iputils-ping` package sets the `cap_net_raw=ep` file capability on
  `/bin/ping`, so no extra Pod capabilities are required *unless* you drop
  ALL capabilities (in which case add `NET_RAW` back).
* **Kubernetes** -- the bundled chart template
  (`helm/nvis-platform/templates/dgx-ping.yaml`) adds
  `capabilities.add: ["NET_RAW"]` to the container `securityContext`.
* **systemd (bare-metal)** -- the bundled unit
  (`dgx-ping-exporter.service`) sets `AmbientCapabilities=CAP_NET_RAW`.

## Build and run locally

```bash
docker build -t nvis-platform-dgx-ping .
docker run --rm \
    -e DGX_HOSTS=node-1=10.0.0.1,node-2=10.0.0.2 \
    -e CLUSTER_NAME=demo \
    -p 9116:9116 \
    --cap-add NET_RAW \
    nvis-platform-dgx-ping
curl -s http://localhost:9116/metrics | grep dgx_
```

## Kubernetes deployment

Toggle via `integrations.dgxPing.enabled=true` in the umbrella Helm chart
and set `integrations.dgxPing.hosts` to your DGX host list. See
`helm/nvis-platform/templates/dgx-ping.yaml`.

## Bare-metal systemd deployment

1. Copy this directory tree to `/opt/nvis-platform/scripts/exporters/dgx-ping/`.
2. Copy `dgx-ping.env.example` to `/etc/nvis-platform/dgx-ping.env` and edit.
3. Install the unit:

    ```bash
    install -m 0644 dgx-ping-exporter.service /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now dgx-ping-exporter.service
    ```

4. Scrape from Prometheus on port `9116`.
