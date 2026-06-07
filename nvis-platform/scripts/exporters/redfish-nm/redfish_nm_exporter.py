#!/usr/bin/env python3
"""Dedicated NodeManager telemetry scraper for Redfish-capable BMCs.

Single endpoint: /redfish/v1/TelemetryService/MetricReports/NvidiaNMMetrics_0
Emits one Prometheus gauge per MetricId as redfish_nm_<MetricId> with labels
{bmc, cluster, serial}.

Env vars:
  BMC_HOSTS        CSV of BMC IPs (or "@file" for newline-separated)
  BMC_USER         default "admin"
  BMC_PASS         required
  CLUSTER_NAME     label value, default ""
  PORT             default 9106
  SCRAPE_INTERVAL  seconds, default 15
  BMC_TIMEOUT      HTTP timeout per call, default 8
  VERIFY_SSL       "true"/"false", default false
"""
import base64
import json
import os
import socketserver
import ssl
import sys
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler


BMC_HOSTS_RAW   = os.environ.get("BMC_HOSTS",       "")
BMC_USER        = os.environ.get("BMC_USER",        "admin")
BMC_PASS        = os.environ.get("BMC_PASS",        "")
CLUSTER_NAME    = os.environ.get("CLUSTER_NAME",    "")
PORT            = int(os.environ.get("PORT",        "9106"))
SCRAPE_INTERVAL = int(os.environ.get("SCRAPE_INTERVAL", "15"))
TIMEOUT         = int(os.environ.get("BMC_TIMEOUT", "8"))
VERIFY_SSL      = os.environ.get("VERIFY_SSL",      "false").lower() == "true"


def log(msg: str) -> None:
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)


def expand_hosts(raw: str) -> list[str]:
    raw = raw.strip()
    if raw.startswith("@"):
        with open(raw[1:]) as f:
            return [ln.strip() for ln in f if ln.strip()]
    return [h.strip() for h in raw.split(",") if h.strip()]


BMC_HOSTS = expand_hosts(BMC_HOSTS_RAW)


def redfish_get(bmc_ip: str, path: str) -> dict | None:
    url = f"https://{bmc_ip}{path}"
    ctx = ssl.create_default_context()
    if not VERIFY_SSL:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    token = base64.b64encode(f"{BMC_USER}:{BMC_PASS}".encode()).decode()
    req = urllib.request.Request(url, headers={
        "Authorization": f"Basic {token}",
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=TIMEOUT) as r:
            return json.loads(r.read())
    except Exception as e:
        log(f"  {bmc_ip} GET {path} failed: {e}")
        return None


def discover_serial(bmc_ip: str) -> str:
    sys_root = redfish_get(bmc_ip, "/redfish/v1/Systems")
    if not sys_root:
        return ""
    members = sys_root.get("Members", [])
    if not members:
        return ""
    sys_path = members[0].get("@odata.id", "")
    if not sys_path:
        return ""
    system = redfish_get(bmc_ip, sys_path) or {}
    return system.get("SerialNumber", "")


_SERIAL_CACHE: dict[str, str] = {}


def _mv_stale(mv: dict) -> bool:
    """True if any MetricValueStale key anywhere under this MetricValue is truthy."""
    def truthy(v) -> bool:
        if isinstance(v, bool):
            return v
        if isinstance(v, (int, float)):
            return bool(v)
        if isinstance(v, str):
            return v.strip().lower() in ("true", "1", "yes")
        return False

    def walk(o) -> bool:
        if isinstance(o, dict):
            for k, v in o.items():
                if isinstance(k, str) and k.lower() == "metricvaluestale" and truthy(v):
                    return True
                if isinstance(v, (dict, list)) and walk(v):
                    return True
        elif isinstance(o, list):
            for x in o:
                if walk(x):
                    return True
        return False

    return walk(mv)


def poll_bmc(bmc_ip: str) -> dict:
    serial = _SERIAL_CACHE.get(bmc_ip)
    if not serial:
        serial = discover_serial(bmc_ip) or ""
        if serial:
            _SERIAL_CACHE[bmc_ip] = serial
    result = {"ip": bmc_ip, "serial": serial, "reachable": False, "metrics": []}
    nm = redfish_get(bmc_ip,
        "/redfish/v1/TelemetryService/MetricReports/NvidiaNMMetrics_0")
    if not nm:
        return result
    result["reachable"] = True
    for mv in nm.get("MetricValues", []):
        mid = mv.get("MetricId", "")
        val = mv.get("MetricValue", "")
        if not mid or val in ("", None):
            continue
        try:
            num = float(val)
        except (TypeError, ValueError):
            continue
        result["metrics"].append({"id": mid, "value": num})
    return result


_LATEST: dict[str, dict] = {}
_LATEST_LOCK = threading.Lock()


def render_metrics() -> str:
    lines: list[str] = []
    with _LATEST_LOCK:
        snapshot = {k: v for k, v in _LATEST.items()}

    lines.append("# HELP redfish_nm_up 1 if NvidiaNMMetrics_0 endpoint responded")
    lines.append("# TYPE redfish_nm_up gauge")
    for ip, r in snapshot.items():
        lines.append(
            f'redfish_nm_up{{bmc="{ip}",cluster="{CLUSTER_NAME}",'
            f'serial="{r.get("serial","")}"}} {1 if r.get("reachable") else 0}'
        )

    seen: set[str] = set()
    for ip, r in snapshot.items():
        if not r.get("reachable"):
            continue
        for m in r["metrics"]:
            mid = m["id"]
            if mid not in seen:
                lines.append(f"# HELP redfish_nm_{mid} NodeManager telemetry "
                             f"value (Redfish MetricId {mid})")
                lines.append(f"# TYPE redfish_nm_{mid} gauge")
                seen.add(mid)
            lines.append(
                f'redfish_nm_{mid}{{bmc="{ip}",cluster="{CLUSTER_NAME}",'
                f'serial="{r.get("serial","")}"}} {m["value"]}'
            )
    return "\n".join(lines) + "\n"


def poll_loop() -> None:
    while True:
        start = time.time()
        try:
            with ThreadPoolExecutor(max_workers=max(4, len(BMC_HOSTS))) as ex:
                results = list(ex.map(poll_bmc, BMC_HOSTS))
            with _LATEST_LOCK:
                for r in results:
                    _LATEST[r["ip"]] = r
            reachable = sum(1 for r in results if r["reachable"])
            n_metrics = sum(len(r["metrics"]) for r in results)
            log(f"poll: {reachable}/{len(BMC_HOSTS)} reachable, "
                f"{n_metrics} MetricValues, took {time.time()-start:.2f}s")
        except Exception as e:
            log(f"poll loop error: {e}")
        elapsed = time.time() - start
        time.sleep(max(1.0, SCRAPE_INTERVAL - elapsed))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args, **kwargs):
        return

    def do_GET(self):
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
    if not BMC_HOSTS:
        log("ERROR: BMC_HOSTS env var is empty")
        return 1
    if not BMC_PASS:
        log("ERROR: BMC_PASS env var is empty")
        return 1
    log(f"NVIS Platform Redfish NM Exporter starting (port={PORT}, "
        f"scrape={SCRAPE_INTERVAL}s, hosts={len(BMC_HOSTS)})")
    for h in BMC_HOSTS:
        log(f"  BMC: {h}")
    t = threading.Thread(target=poll_loop, daemon=True)
    t.start()
    server = ThreadingServer(("0.0.0.0", PORT), Handler)
    log(f"Metrics available at http://0.0.0.0:{PORT}/metrics")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
