#!/usr/bin/env python3
"""
nvis-dgx-ping: ping all cluster nodes every 60s, emit Prometheus metrics.
Metrics:
  dgx_node_up{node,host,cluster}               1=reachable 0=unreachable
  dgx_node_ping_latency_ms{node,host,cluster}  avg RTT ms
  dgx_node_packet_loss_ratio{node,host,cluster} 0.0-1.0
  dgx_node_last_seen_timestamp{node,host,cluster} unix ts of last ping OK

Deploy on ObsVM:
  sudo cp dgx_ping_exporter.py /opt/nvis/dgx_ping_exporter.py
  sudo chmod +x /opt/nvis/dgx_ping_exporter.py
  sudo cp nvis-dgx-ping.service /etc/systemd/system/
  sudo systemctl daemon-reload && sudo systemctl enable --now nvis-dgx-ping
"""
import os, re, subprocess, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer

CLUSTER  = os.environ.get("CLUSTER_NAME", "Beacon")
PORT     = int(os.environ.get("PING_EXPORTER_PORT", "9113"))
COUNT    = int(os.environ.get("PING_COUNT", "5"))
INTERVAL = int(os.environ.get("POLL_INTERVAL", "60"))

NODES = [
    ("dgx-b300-01",    "10.184.153.68"),
    ("dgx-b300-02",    "10.184.153.69"),
    ("dgx-b300-03",    "10.184.153.70"),
    ("dgx-b300-04",    "10.184.153.71"),
    ("beacon-head-01", "10.184.153.7"),
    ("beacon-head-02", "10.184.153.8"),
    ("slogin-01",      "10.184.153.9"),
    ("slogin-02",      "10.184.153.5"),
    ("k8s-control-01", "10.184.153.10"),
    ("k8s-control-02", "10.184.153.11"),
    ("k8s-control-03", "10.184.153.4"),
]

state = {}
lock  = threading.Lock()


def ping_node(name, ip):
    try:
        out = subprocess.run(
            ["ping", "-c", str(COUNT), "-W", "2", ip],
            capture_output=True, text=True, timeout=COUNT * 3 + 5
        ).stdout
        loss_m  = re.search(r"(\d+(?:\.\d+)?)% packet loss", out)
        rtt_m   = re.search(r"rtt min/avg/max/mdev = [\d.]+/([\d.]+)/", out)
        loss    = float(loss_m.group(1)) / 100.0 if loss_m else 1.0
        latency = float(rtt_m.group(1)) if rtt_m else float("nan")
        up      = 1 if loss < 1.0 else 0
    except Exception:
        loss, latency, up = 1.0, float("nan"), 0
    now = time.time()
    with lock:
        prev = state.get(name, {})
        state[name] = {
            "host": ip, "up": up,
            "latency": latency, "loss": loss,
            "last_seen": now if up else prev.get("last_seen", float("nan")),
        }


def poll_loop():
    while True:
        threads = [threading.Thread(target=ping_node, args=(n, ip), daemon=True)
                   for n, ip in NODES]
        for t in threads: t.start()
        for t in threads: t.join()
        time.sleep(INTERVAL)


def metrics_text():
    lines = []

    def add(name, help_, type_, samples):
        lines.append(f"# HELP {name} {help_}")
        lines.append(f"# TYPE {name} {type_}")
        for lbs, val in samples:
            if val != val:  # NaN check
                continue
            lines.append(f'{name}{{{lbs}}} {val}')

    with lock:
        snap = dict(state)

    up_s, lat_s, loss_s, seen_s = [], [], [], []
    for node, d in sorted(snap.items()):
        lbs = f'node="{node}",host="{d["host"]}",cluster="{CLUSTER}"'
        up_s.append((lbs, d["up"]))
        if d["up"]:
            lat_s.append((lbs, round(d["latency"], 3)))
        loss_s.append((lbs, round(d["loss"], 4)))
        ls = d.get("last_seen")
        if ls and ls == ls:
            seen_s.append((lbs, int(ls)))

    add("dgx_node_up",                  "1=node OS reachable via ICMP", "gauge", up_s)
    add("dgx_node_ping_latency_ms",     "Average ping RTT in ms",       "gauge", lat_s)
    add("dgx_node_packet_loss_ratio",   "Packet loss ratio 0.0-1.0",    "gauge", loss_s)
    add("dgx_node_last_seen_timestamp", "Unix ts of last ping OK",      "gauge", seen_s)
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/metrics", "/"):
            body = metrics_text().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", len(body))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    threading.Thread(target=poll_loop, daemon=True).start()
    time.sleep(3)  # one poll before first scrape
    print(f"nvis-dgx-ping listening :{PORT} cluster={CLUSTER}")
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
