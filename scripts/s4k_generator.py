#!/usr/bin/env python3
"""
Stress-4k Metric Generator
Generates synthetic Prometheus metrics for a simulated 4000-node, 32000-GPU cluster.
Runs as an HTTP server at :9500 that Prometheus scrapes every 15s.

Node layout:
  - 4000 nodes: node0001 – node4000
  - 40 racks:   rack01   – rack40  (100 nodes each)
  - 8 GPUs per node = 32,000 GPUs total

~20 nodes are "down", ~50 are "hot" (high XID/ECC), rest are healthy under load.
"""

import random
import time
import math
from http.server import BaseHTTPRequestHandler, HTTPServer

CLUSTER    = "stress-4k"
NUM_NODES  = 4000
GPUS_NODE  = 8
NUM_RACKS  = 40
NODES_RACK = NUM_NODES // NUM_RACKS  # 100

# Seeded for reproducible topology — hot/down nodes stay consistent per run
_rng = random.Random(42)

# Pre-compute node profiles (static topology, varies every scrape slightly)
DOWN_NODES  = set(_rng.sample(range(1, NUM_NODES + 1), 22))   # 22 nodes offline
HOT_NODES   = set(_rng.sample([n for n in range(1, NUM_NODES + 1)
                                if n not in DOWN_NODES], 48))  # high XID/ECC
IDLE_NODES  = set(_rng.sample([n for n in range(1, NUM_NODES + 1)
                                if n not in DOWN_NODES and n not in HOT_NODES], 180))  # idle GPUs


def rack_for(n: int) -> str:
    return f"rack{((n - 1) // NODES_RACK) + 1:02d}"


def gauss_clamp(mu, sigma, lo, hi):
    return max(lo, min(hi, random.gauss(mu, sigma)))


def generate_metrics() -> str:
    ts = time.time()
    lines = []

    # ---------- cluster-wide gauges ----------
    down_count = len(DOWN_NODES)
    active_jobs = int(gauss_clamp((NUM_NODES - down_count) * 0.80, 50, 0, NUM_NODES - down_count))
    queued_jobs = int(gauss_clamp(140, 30, 0, 800))

    def cg(name, val, extra=""):
        lbl = f'cluster="{CLUSTER}"'
        if extra:
            lbl += f",{extra}"
        lines.append(f'{name}{{{lbl}}} {val}')

    cg("s4k_cluster_node_count",       NUM_NODES)
    cg("s4k_cluster_node_up_count",    NUM_NODES - down_count)
    cg("s4k_cluster_node_down_count",  down_count)
    cg("s4k_cluster_gpu_count",        NUM_NODES * GPUS_NODE)
    cg("s4k_cluster_active_jobs",      active_jobs)
    cg("s4k_cluster_queued_jobs",      queued_jobs)
    cg("s4k_cluster_completed_jobs_total",
       int(ts / 3600) * 420 + int(gauss_clamp(0, 5, 0, 999)))

    # ---------- per-rack aggregates ----------
    rack_util_sum  = {}
    rack_temp_max  = {}
    rack_down      = {}
    for rack_id in range(1, NUM_RACKS + 1):
        rack_util_sum[rack_id]  = 0.0
        rack_temp_max[rack_id]  = 0.0
        rack_down[rack_id]      = 0

    # ---------- per-node metrics ----------
    for n in range(1, NUM_NODES + 1):
        rack    = rack_for(n)
        rack_id = ((n - 1) // NODES_RACK) + 1
        lbl     = f'node="node{n:04d}",rack="{rack}",cluster="{CLUSTER}"'

        # H200 NVL: 141 GiB HBM per GPU, 8 GPUs = 1128 GiB per node
        GPU_MEM_TOTAL_GIB = 141.0 * GPUS_NODE

        if n in DOWN_NODES:
            lines.append(f's4k_node_up{{{lbl}}} 0')
            lines.append(f's4k_node_gpu_util_avg{{{lbl}}} 0')
            lines.append(f's4k_node_gpu_util_max{{{lbl}}} 0')
            lines.append(f's4k_node_gpu_temp_max{{{lbl}}} 0')
            lines.append(f's4k_node_gpu_power_w{{{lbl}}} 0')
            lines.append(f's4k_node_gpu_mem_used_pct{{{lbl}}} 0')
            lines.append(f's4k_node_gpu_mem_used_gib{{{lbl}}} 0')
            lines.append(f's4k_node_gpu_mem_total_gib{{{lbl}}} {GPU_MEM_TOTAL_GIB:.0f}')
            lines.append(f's4k_node_xid_errors_total{{{lbl}}} {_rng.randint(1, 9999)}')
            lines.append(f's4k_node_ecc_dbe_total{{{lbl}}} {_rng.randint(0, 50)}')
            lines.append(f's4k_node_ecc_sbe_total{{{lbl}}} {_rng.randint(0, 200)}')
            lines.append(f's4k_node_throttle_reasons{{{lbl}}} 0')
            lines.append(f's4k_node_ib_rx_gbps{{{lbl}}} 0')
            lines.append(f's4k_node_ib_tx_gbps{{{lbl}}} 0')
            rack_down[rack_id] += 1
            continue

        lines.append(f's4k_node_up{{{lbl}}} 1')

        if n in IDLE_NODES:
            util_avg  = gauss_clamp(4,  3, 0, 15)
            util_max  = gauss_clamp(8,  4, 0, 20)
            temp_max  = gauss_clamp(38, 3, 25, 55)
            power_w   = gauss_clamp(90, 20, 50, 200)
            mem_pct   = gauss_clamp(5,  2, 0, 20)
            xid       = 0
            ecc_dbe   = 0
            ecc_sbe   = 0
            throttle  = 0
            ib_rx     = gauss_clamp(0.5, 0.2, 0, 5)
            ib_tx     = gauss_clamp(0.5, 0.2, 0, 5)
        elif n in HOT_NODES:
            util_avg  = gauss_clamp(92, 3, 75, 100)
            util_max  = gauss_clamp(99, 1, 90, 100)
            temp_max  = gauss_clamp(87, 3, 80, 95)
            power_w   = gauss_clamp(790, 25, 700, 900)
            mem_pct   = gauss_clamp(95, 3, 85, 100)
            xid       = _rng.randint(20, 500)
            ecc_dbe   = _rng.randint(2, 40)
            ecc_sbe   = _rng.randint(10, 200)
            throttle  = _rng.choice([4, 8, 12])  # HW thermal=4, SW thermal=8, both=12
            ib_rx     = gauss_clamp(185, 10, 140, 200)
            ib_tx     = gauss_clamp(185, 10, 140, 200)
        else:
            # Normal training workload
            util_avg  = gauss_clamp(83, 6, 60, 99)
            util_max  = gauss_clamp(95, 3, 80, 100)
            temp_max  = gauss_clamp(74, 4, 60, 85)
            power_w   = gauss_clamp(680, 40, 550, 800)
            mem_pct   = gauss_clamp(78, 8, 50, 98)
            xid       = _rng.choices([0, 0, 0, 0, 1, 2, 5], weights=[70,10,5,5,5,3,2])[0]
            ecc_dbe   = _rng.choices([0, 0, 1], weights=[90, 8, 2])[0]
            ecc_sbe   = _rng.choices([0, 0, 0, 1, 2], weights=[70, 15, 8, 5, 2])[0]
            throttle  = 0
            ib_rx     = gauss_clamp(155, 20, 80, 200)
            ib_tx     = gauss_clamp(155, 20, 80, 200)

        mem_used_gib = GPU_MEM_TOTAL_GIB * mem_pct / 100.0

        lines.append(f's4k_node_gpu_util_avg{{{lbl}}} {util_avg:.2f}')
        lines.append(f's4k_node_gpu_util_max{{{lbl}}} {util_max:.2f}')
        lines.append(f's4k_node_gpu_temp_max{{{lbl}}} {temp_max:.2f}')
        lines.append(f's4k_node_gpu_power_w{{{lbl}}} {power_w:.1f}')
        lines.append(f's4k_node_gpu_mem_used_pct{{{lbl}}} {mem_pct:.2f}')
        lines.append(f's4k_node_gpu_mem_used_gib{{{lbl}}} {mem_used_gib:.1f}')
        lines.append(f's4k_node_gpu_mem_total_gib{{{lbl}}} {GPU_MEM_TOTAL_GIB:.0f}')
        lines.append(f's4k_node_xid_errors_total{{{lbl}}} {xid}')
        lines.append(f's4k_node_ecc_dbe_total{{{lbl}}} {ecc_dbe}')
        lines.append(f's4k_node_ecc_sbe_total{{{lbl}}} {ecc_sbe}')
        lines.append(f's4k_node_throttle_reasons{{{lbl}}} {throttle}')
        lines.append(f's4k_node_ib_rx_gbps{{{lbl}}} {ib_rx:.2f}')
        lines.append(f's4k_node_ib_tx_gbps{{{lbl}}} {ib_tx:.2f}')

        rack_util_sum[rack_id]  += util_avg
        rack_temp_max[rack_id]   = max(rack_temp_max[rack_id], temp_max)

    # ---------- per-rack aggregates ----------
    for rack_id in range(1, NUM_RACKS + 1):
        rack = f"rack{rack_id:02d}"
        online = NODES_RACK - rack_down[rack_id]
        avg_util = rack_util_sum[rack_id] / max(online, 1)
        lbl = f'rack="{rack}",cluster="{CLUSTER}"'
        lines.append(f's4k_rack_gpu_util_avg{{{lbl}}} {avg_util:.2f}')
        lines.append(f's4k_rack_temp_max{{{lbl}}} {rack_temp_max[rack_id]:.2f}')
        lines.append(f's4k_rack_node_count{{{lbl}}} {NODES_RACK}')
        lines.append(f's4k_rack_node_down{{{lbl}}} {rack_down[rack_id]}')

    # ---------- cluster-wide percentile approximations ----------
    # Prometheus can compute quantiles from per-node data, but let's also
    # emit them directly so single-stat panels can reference without heavy queries
    all_utils = []
    for n in range(1, NUM_NODES + 1):
        if n in DOWN_NODES:
            continue
        if n in IDLE_NODES:
            all_utils.append(gauss_clamp(4, 3, 0, 15))
        elif n in HOT_NODES:
            all_utils.append(gauss_clamp(92, 3, 75, 100))
        else:
            all_utils.append(gauss_clamp(83, 6, 60, 99))
    all_utils.sort()
    def pct(data, p):
        idx = int(len(data) * p / 100)
        return data[min(idx, len(data)-1)]

    # Cluster power total (kW) and memory
    GPU_MEM_TOTAL_GIB = 141.0 * GPUS_NODE
    total_power_kw = sum(
        gauss_clamp(680, 40, 550, 800) if n not in DOWN_NODES and n not in HOT_NODES and n not in IDLE_NODES
        else (gauss_clamp(790, 25, 700, 900) if n in HOT_NODES
              else (gauss_clamp(90, 20, 50, 200) if n in IDLE_NODES else 0))
        for n in range(1, NUM_NODES + 1)
    ) / 1000.0
    total_mem_used_gib = sum(
        GPU_MEM_TOTAL_GIB * (gauss_clamp(78, 8, 50, 98) / 100.0) if n not in DOWN_NODES and n not in HOT_NODES and n not in IDLE_NODES
        else (GPU_MEM_TOTAL_GIB * 0.95 if n in HOT_NODES
              else (GPU_MEM_TOTAL_GIB * 0.05 if n in IDLE_NODES else 0))
        for n in range(1, NUM_NODES + 1)
    )
    total_mem_total_gib = (NUM_NODES - len(DOWN_NODES)) * GPU_MEM_TOTAL_GIB
    total_ib_rx = sum(
        gauss_clamp(155, 20, 80, 200) if n not in DOWN_NODES and n not in HOT_NODES and n not in IDLE_NODES
        else (gauss_clamp(185, 10, 140, 200) if n in HOT_NODES
              else (gauss_clamp(0.5, 0.2, 0, 5) if n in IDLE_NODES else 0))
        for n in range(1, NUM_NODES + 1)
    )
    cg("s4k_cluster_gpu_power_total_kw",  f"{total_power_kw:.1f}")
    cg("s4k_cluster_gpu_mem_used_gib",    f"{total_mem_used_gib:.0f}")
    cg("s4k_cluster_gpu_mem_total_gib",   f"{total_mem_total_gib:.0f}")
    cg("s4k_cluster_ib_rx_gbps_total",    f"{total_ib_rx:.0f}")
    cg("s4k_cluster_ib_tx_gbps_total",    f"{total_ib_rx:.0f}")
    cg("s4k_cluster_throttled_node_count", len(HOT_NODES))
    cg("s4k_cluster_ecc_nodes",           sum(1 for n in HOT_NODES) + sum(1 for n in DOWN_NODES))

    cg("s4k_cluster_gpu_util_p50",  f"{pct(all_utils,50):.2f}")
    cg("s4k_cluster_gpu_util_p75",  f"{pct(all_utils,75):.2f}")
    cg("s4k_cluster_gpu_util_p90",  f"{pct(all_utils,90):.2f}")
    cg("s4k_cluster_gpu_util_p95",  f"{pct(all_utils,95):.2f}")
    cg("s4k_cluster_gpu_util_p99",  f"{pct(all_utils,99):.2f}")
    cg("s4k_cluster_gpu_util_max",  f"{pct(all_utils,100):.2f}")
    cg("s4k_cluster_gpu_util_avg",  f"{sum(all_utils)/len(all_utils):.2f}")

    # Anomaly density: nodes > 80% util
    anomaly_nodes = sum(1 for u in all_utils if u > 80)
    cg("s4k_cluster_anomaly_node_count", anomaly_nodes)

    return "\n".join(lines) + "\n"


class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/metrics", "/"):
            self.send_response(404)
            self.end_headers()
            return
        body = generate_metrics().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass  # silence per-request logs


if __name__ == "__main__":
    import os
    port = int(os.environ.get("PORT", 9500))
    print(f"[s4k-generator] Listening on :{port} — serving metrics for {NUM_NODES} simulated nodes")
    HTTPServer(("0.0.0.0", port), MetricsHandler).serve_forever()
