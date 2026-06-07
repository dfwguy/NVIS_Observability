#!/usr/bin/env python3
"""NVIS Platform -- DGX OS host ICMP ping exporter.

Probes each configured DGX OS host with a small burst of ICMP echoes via the
system ``ping`` binary and exposes latency / loss / up metrics on a Prometheus
scrape endpoint.

Each host is polled in a ``ThreadPoolExecutor`` so one slow / unreachable host
does not block the others.

Environment variables
---------------------
DGX_HOSTS         Comma-separated ``name=ip`` pairs, OR ``@/path/to/file`` to
                  read newline-/comma-separated entries from a file. Required.
                  e.g. ``"node-1=10.0.0.1,node-2=10.0.0.2"``
                  or ``"@/etc/nvis-platform/dgx-hosts.txt"``.
PING_INTERVAL     Seconds between probe bursts (default ``30``).
LISTEN_PORT       HTTP listen port (default ``9116``).
LISTEN_ADDR       Bind address (default ``0.0.0.0``).
CLUSTER_NAME      Label value applied to every series (default ``""``).
PING_COUNT        ICMP packets per burst (default ``5``).
PING_TIMEOUT      Per-packet wait in seconds (``ping -W``) (default ``2``).

Legacy aliases ``NODE_HOSTS`` / ``SCRAPE_INTERVAL`` / ``PORT`` are also honoured.

Metrics emitted
---------------
* ``dgx_node_up{node,host,cluster}`` -- 1 if the most recent burst saw any
  reply, else 0.
* ``dgx_node_ping_latency_ms{node,host,cluster}`` -- last successful avg RTT
  in milliseconds (series omitted until first success).
* ``dgx_node_packet_loss_ratio{node,host,cluster}`` -- loss fraction (0..1)
  over the last burst.
* ``dgx_node_last_seen_timestamp{node,host,cluster}`` -- unix epoch seconds
  of the last successful reply.
* ``dgx_ping_exporter_up{cluster}`` -- always 1 while serving.
* ``dgx_ping_probe_total{node,host,cluster,result}`` -- counter
  (``result=ok|timeout|error``).
"""
import os
import re
import socketserver
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler


def _env(*names: str, default: str = "") -> str:
    """Return the first non-empty value from a list of env-var names."""
    for n in names:
        v = os.environ.get(n)
        if v not in (None, ""):
            return v
    return default


DGX_HOSTS_RAW   = _env("DGX_HOSTS", "NODE_HOSTS", default="")
CLUSTER_NAME    = _env("CLUSTER_NAME", default="")
LISTEN_ADDR     = _env("LISTEN_ADDR", default="0.0.0.0")
LISTEN_PORT     = int(_env("LISTEN_PORT", "PORT", default="9116"))
PING_INTERVAL   = int(_env("PING_INTERVAL", "SCRAPE_INTERVAL", default="30"))
PING_COUNT      = int(_env("PING_COUNT", default="5"))
PING_TIMEOUT    = int(_env("PING_TIMEOUT", default="2"))
# Total wall-clock budget per host: PING_COUNT * PING_TIMEOUT + slack
HOST_BUDGET     = PING_COUNT * PING_TIMEOUT + 2


def log(msg: str) -> None:
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)


def _load_hosts_raw(spec: str) -> str:
    """Resolve ``@/path/to/file`` indirection. Returns the raw text spec."""
    spec = spec.strip()
    if spec.startswith("@"):
        path = spec[1:]
        try:
            with open(path, "r", encoding="utf-8") as fh:
                return fh.read()
        except OSError as exc:
            log(f"ERROR: could not read DGX_HOSTS file {path}: {exc}")
            return ""
    return spec


def parse_hosts(raw: str) -> list[tuple[str, str]]:
    """Parse ``name=ip,name=ip`` (commas or newlines) into ``[(name, ip), ...]``.

    Lines starting with ``#`` are treated as comments. Whitespace is trimmed.
    """
    out: list[tuple[str, str]] = []
    # Allow commas and newlines as separators; strip comments.
    text = raw.replace("\r", "\n")
    for line in text.split("\n"):
        line = line.split("#", 1)[0]
        for chunk in line.split(","):
            chunk = chunk.strip()
            if not chunk or "=" not in chunk:
                continue
            name, ip = chunk.split("=", 1)
            name, ip = name.strip(), ip.strip()
            if name and ip:
                out.append((name, ip))
    return out


DGX_HOSTS = parse_hosts(_load_hosts_raw(DGX_HOSTS_RAW))


_RE_RTT = re.compile(
    r"rtt min/avg/max/mdev\s*=\s*([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)"
)
_RE_LOSS = re.compile(r"(\d+(?:\.\d+)?)% packet loss")


def ping_host(name: str, ip: str) -> dict:
    """Run one ping burst against ``ip`` and return a structured result."""
    res = {
        "node": name,
        "host": ip,
        "up": False,
        "latency_ms": None,   # avg RTT on success
        "loss_ratio": 1.0,    # 0..1
        "result": "error",    # ok | timeout | error
    }
    cmd = ["ping", "-c", str(PING_COUNT), "-W", str(PING_TIMEOUT), ip]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=HOST_BUDGET,
        )
    except subprocess.TimeoutExpired:
        res["result"] = "timeout"
        return res
    except Exception as e:
        log(f"  ping {name} ({ip}) exec error: {e}")
        res["result"] = "error"
        return res

    out = proc.stdout or ""

    m_loss = _RE_LOSS.search(out)
    if m_loss:
        try:
            res["loss_ratio"] = float(m_loss.group(1)) / 100.0
        except ValueError:
            pass

    m_rtt = _RE_RTT.search(out)
    if m_rtt:
        try:
            res["latency_ms"] = float(m_rtt.group(2))   # avg
            res["up"] = True
            res["result"] = "ok"
            return res
        except ValueError:
            pass

    # No RTT line -- either 100% loss or ping refused to run.
    if proc.returncode == 1:
        # ping convention: 1 == all packets lost (host unreachable / timeout)
        res["result"] = "timeout"
    else:
        res["result"] = "error"
    return res


# Latest per-node snapshot keyed by node name
_LATEST: dict[str, dict] = {}
_LATEST_LOCK = threading.Lock()

# Per-(node, host, result) counter for dgx_ping_probe_total
_PROBE_COUNTS: dict[tuple[str, str, str], int] = {}
_LAST_SEEN: dict[str, float] = {}   # node -> unix ts of last successful reply


def poll_loop() -> None:
    while True:
        start = time.time()
        try:
            with ThreadPoolExecutor(max_workers=max(4, len(DGX_HOSTS))) as ex:
                results = list(ex.map(lambda nh: ping_host(*nh), DGX_HOSTS))
            now = time.time()
            with _LATEST_LOCK:
                for r in results:
                    _LATEST[r["node"]] = r
                    key = (r["node"], r["host"], r["result"])
                    _PROBE_COUNTS[key] = _PROBE_COUNTS.get(key, 0) + 1
                    if r["up"]:
                        _LAST_SEEN[r["node"]] = now
            up = sum(1 for r in results if r["up"])
            log(
                f"poll: {up}/{len(DGX_HOSTS)} up, "
                f"took {time.time()-start:.2f}s"
            )
        except Exception as e:
            log(f"poll loop error: {e}")
        elapsed = time.time() - start
        time.sleep(max(1.0, PING_INTERVAL - elapsed))


def _esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def render_metrics() -> str:
    with _LATEST_LOCK:
        snapshot = list(_LATEST.values())
        last_seen = dict(_LAST_SEEN)
        probe_counts = dict(_PROBE_COUNTS)

    lines: list[str] = []

    lines.append("# HELP dgx_ping_exporter_up 1 while the dgx-ping exporter process is serving")
    lines.append("# TYPE dgx_ping_exporter_up gauge")
    lines.append(f'dgx_ping_exporter_up{{cluster="{_esc(CLUSTER_NAME)}"}} 1')

    lines.append("\n# HELP dgx_node_up 1 if the latest ping burst saw any reply")
    lines.append("# TYPE dgx_node_up gauge")
    for r in snapshot:
        lbls = (f'node="{_esc(r["node"])}",host="{_esc(r["host"])}",'
                f'cluster="{_esc(CLUSTER_NAME)}"')
        lines.append(f'dgx_node_up{{{lbls}}} {1 if r["up"] else 0}')

    lines.append("\n# HELP dgx_node_ping_latency_ms Last successful avg RTT in milliseconds")
    lines.append("# TYPE dgx_node_ping_latency_ms gauge")
    for r in snapshot:
        if r["latency_ms"] is None:
            continue
        lbls = (f'node="{_esc(r["node"])}",host="{_esc(r["host"])}",'
                f'cluster="{_esc(CLUSTER_NAME)}"')
        lines.append(f'dgx_node_ping_latency_ms{{{lbls}}} {r["latency_ms"]}')

    lines.append("\n# HELP dgx_node_packet_loss_ratio Packet loss fraction (0..1) over the last burst")
    lines.append("# TYPE dgx_node_packet_loss_ratio gauge")
    for r in snapshot:
        lbls = (f'node="{_esc(r["node"])}",host="{_esc(r["host"])}",'
                f'cluster="{_esc(CLUSTER_NAME)}"')
        lines.append(f'dgx_node_packet_loss_ratio{{{lbls}}} {r["loss_ratio"]}')

    lines.append("\n# HELP dgx_node_last_seen_timestamp Unix epoch seconds of last successful ping reply")
    lines.append("# TYPE dgx_node_last_seen_timestamp gauge")
    for r in snapshot:
        ts = last_seen.get(r["node"])
        if ts is None:
            continue
        lbls = (f'node="{_esc(r["node"])}",host="{_esc(r["host"])}",'
                f'cluster="{_esc(CLUSTER_NAME)}"')
        lines.append(f'dgx_node_last_seen_timestamp{{{lbls}}} {ts}')

    lines.append("\n# HELP dgx_ping_probe_total Total ping probes by result (ok|timeout|error)")
    lines.append("# TYPE dgx_ping_probe_total counter")
    for (node, host, result), count in sorted(probe_counts.items()):
        lbls = (f'node="{_esc(node)}",host="{_esc(host)}",'
                f'cluster="{_esc(CLUSTER_NAME)}",result="{_esc(result)}"')
        lines.append(f'dgx_ping_probe_total{{{lbls}}} {count}')

    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args, **kwargs):
        return

    def do_GET(self):
        if self.path == "/healthz":
            body = b"ok\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        body = render_metrics().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


class ThreadingServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main() -> int:
    if not DGX_HOSTS:
        log("ERROR: DGX_HOSTS env var is empty or unparseable "
            "(expected 'name=ip,name=ip,...' or '@/path/to/file')")
        return 1
    log(f"NVIS Platform DGX Ping Exporter starting "
        f"(addr={LISTEN_ADDR}, port={LISTEN_PORT}, "
        f"interval={PING_INTERVAL}s, hosts={len(DGX_HOSTS)}, "
        f"count={PING_COUNT}, per-packet timeout={PING_TIMEOUT}s)")
    for name, ip in DGX_HOSTS:
        log(f"  node: {name} -> {ip}")
    threading.Thread(target=poll_loop, daemon=True).start()
    server = ThreadingServer((LISTEN_ADDR, LISTEN_PORT), Handler)
    log(f"Metrics available at http://{LISTEN_ADDR}:{LISTEN_PORT}/metrics")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
