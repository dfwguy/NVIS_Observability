#!/usr/bin/env python3
"""Redfish /Sensors temperature-only exporter.

Walks /redfish/v1/Chassis/*/Sensors with $expand and emits ONE temperature
gauge per sensor. Slower cadence (60-80s) -- the granular Sensors collection
can crash some BMCs under tighter sweeps. Per-BMC sequential to bound
concurrent load; intra-BMC parallelism across chassis.

Env vars:
  BMC_HOSTS, BMC_USER, BMC_PASS, CLUSTER_NAME
  PORT             default 9108
  SCRAPE_INTERVAL  default 80
  BMC_TIMEOUT      default 15
  VERIFY_SSL       default "false"
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
PORT            = int(os.environ.get("PORT",        "9108"))
SCRAPE_INTERVAL = int(os.environ.get("SCRAPE_INTERVAL", "80"))
TIMEOUT         = int(os.environ.get("BMC_TIMEOUT", "15"))
VERIFY_SSL      = os.environ.get("VERIFY_SSL",      "false").lower() == "true"


# Substrings of /Chassis member ids to skip (attestation and root-of-trust
# nodes commonly expose no meaningful sensors). Override with a comma-separated
# list via the CHASSIS_BLACKLIST env var.
_default_blacklist = "IRoT,ERoT,EROT_BIOS_0,EROT_BMC_0"
CHASSIS_BLACKLIST_SUBSTRINGS = tuple(
    s.strip() for s in os.environ.get("CHASSIS_BLACKLIST", _default_blacklist).split(",")
    if s.strip()
)


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


_SERIAL_CACHE: dict[str, str] = {}


def discover_serial(bmc_ip: str) -> str:
    if bmc_ip in _SERIAL_CACHE:
        return _SERIAL_CACHE[bmc_ip]
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
    serial = system.get("SerialNumber", "")
    if serial:
        _SERIAL_CACHE[bmc_ip] = serial
    return serial


def _esc(s: str) -> str:
    return (s or "").replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def _chassis_blacklisted(path: str) -> bool:
    for bad in CHASSIS_BLACKLIST_SUBSTRINGS:
        if bad in path:
            return True
    return False


def _chassis_name(path: str) -> str:
    return path.rstrip("/").rsplit("/", 1)[-1]


def _is_expanded(sensor_obj: dict) -> bool:
    if not isinstance(sensor_obj, dict):
        return False
    return any(k in sensor_obj for k in ("Reading", "ReadingType", "ReadingUnits"))


def _parse_sensor(s: dict) -> dict | None:
    if not isinstance(s, dict):
        return None
    if s.get("ReadingType") != "Temperature":
        return None
    name = s.get("Id") or s.get("Name") or ""
    if not name:
        return None
    status_blk = s.get("Status") or {}
    state      = status_blk.get("State", "")
    health     = status_blk.get("Health", "")
    raw        = s.get("Reading", None)
    if raw is None or (state and state != "Enabled"):
        reading = float("nan")
    else:
        try:
            reading = float(raw)
        except (TypeError, ValueError):
            reading = float("nan")
    out = {
        "name":   name,
        "reading": reading,
        "status": health,
        "physical_context": s.get("PhysicalContext", "") or "",
        "thresholds": {},
    }
    th = s.get("Thresholds") or {}
    if isinstance(th, dict):
        for kind in ("LowerCaution", "UpperCaution", "UpperCritical", "UpperFatal"):
            blk = th.get(kind) or {}
            if isinstance(blk, dict) and "Reading" in blk and blk["Reading"] is not None:
                try:
                    out["thresholds"][kind] = float(blk["Reading"])
                except (TypeError, ValueError):
                    pass
    return out


def _fetch_chassis_sensors(bmc_ip: str, chassis_path: str) -> list[dict]:
    coll = redfish_get(bmc_ip, f"{chassis_path}/Sensors?$expand=*($levels=1)")
    if not coll:
        return []
    members = coll.get("Members", []) or []
    if not members:
        return []

    if _is_expanded(members[0]):
        results: list[dict] = []
        for m in members:
            p = _parse_sensor(m)
            if p is not None:
                results.append(p)
        return results

    sensor_paths = [m.get("@odata.id", "") for m in members if isinstance(m, dict)]
    sensor_paths = [p for p in sensor_paths if p]

    def _one(p: str) -> dict | None:
        body = redfish_get(bmc_ip, p)
        if not body:
            return None
        return _parse_sensor(body)

    out: list[dict] = []
    with ThreadPoolExecutor(max_workers=16) as ex:
        for r in ex.map(_one, sensor_paths):
            if r is not None:
                out.append(r)
    return out


def poll_bmc(bmc_ip: str) -> dict:
    started = time.time()
    out = {
        "ip": bmc_ip,
        "serial": discover_serial(bmc_ip),
        "reachable": False,
        "sensors": [],
        "duration": 0.0,
        "n_chassis": 0,
    }

    chassis_root = redfish_get(bmc_ip, "/redfish/v1/Chassis")
    if not chassis_root:
        out["duration"] = time.time() - started
        return out
    out["reachable"] = True

    chassis_paths = []
    for m in chassis_root.get("Members", []) or []:
        p = m.get("@odata.id", "") if isinstance(m, dict) else ""
        if p and not _chassis_blacklisted(p):
            chassis_paths.append(p)
    out["n_chassis"] = len(chassis_paths)

    def _one_chassis(path: str):
        cname = _chassis_name(path)
        return cname, _fetch_chassis_sensors(bmc_ip, path)

    with ThreadPoolExecutor(max_workers=8) as ex:
        for cname, sensors in ex.map(_one_chassis, chassis_paths):
            for s in sensors:
                s["chassis"] = cname
                out["sensors"].append(s)

    out["duration"] = time.time() - started
    return out


_LATEST: dict[str, dict] = {}
_LATEST_LOCK = threading.Lock()
_FIRST_CYCLE_DONE = threading.Event()


def _fmt(v: float) -> str:
    if v != v:
        return "NaN"
    return repr(v) if isinstance(v, float) else str(v)


def render_metrics() -> str:
    with _LATEST_LOCK:
        snapshot = list(_LATEST.values())

    lines: list[str] = []

    lines.append("# HELP redfish_sensors_up 1 if the /Sensors walk succeeded this cycle")
    lines.append("# TYPE redfish_sensors_up gauge")
    for r in snapshot:
        lines.append(
            f'redfish_sensors_up{{bmc="{r["ip"]}",cluster="{CLUSTER_NAME}",'
            f'serial="{r["serial"]}"}} {1 if r["reachable"] else 0}'
        )

    lines.append("\n# HELP redfish_sensors_scrape_duration_seconds Wall-clock cost of last cycle")
    lines.append("# TYPE redfish_sensors_scrape_duration_seconds gauge")
    for r in snapshot:
        lines.append(
            f'redfish_sensors_scrape_duration_seconds{{bmc="{r["ip"]}"}} '
            f'{r.get("duration", 0.0):.3f}'
        )

    lines.append("\n# HELP redfish_sensor_celsius Temperature reading from Redfish /Sensors (Celsius)")
    lines.append("# TYPE redfish_sensor_celsius gauge")
    for r in snapshot:
        if not r["reachable"]:
            continue
        for s in r["sensors"]:
            lbls = (
                f'bmc="{r["ip"]}",cluster="{CLUSTER_NAME}",serial="{r["serial"]}",'
                f'sensor="{_esc(s["name"])}",chassis="{_esc(s["chassis"])}",'
                f'physical_context="{_esc(s.get("physical_context",""))}",'
                f'status="{_esc(s.get("status",""))}"'
            )
            lines.append(f'redfish_sensor_celsius{{{lbls}}} {_fmt(s["reading"])}')

    lines.append("\n# HELP redfish_sensor_thresholds_celsius Static Redfish threshold values (Celsius)")
    lines.append("# TYPE redfish_sensor_thresholds_celsius gauge")
    for r in snapshot:
        if not r["reachable"]:
            continue
        for s in r["sensors"]:
            for kind, val in s.get("thresholds", {}).items():
                lbls = (
                    f'bmc="{r["ip"]}",cluster="{CLUSTER_NAME}",serial="{r["serial"]}",'
                    f'sensor="{_esc(s["name"])}",chassis="{_esc(s["chassis"])}",'
                    f'kind="{kind}"'
                )
                lines.append(f'redfish_sensor_thresholds_celsius{{{lbls}}} {_fmt(val)}')

    return "\n".join(lines) + "\n"


def poll_loop() -> None:
    while True:
        cycle_start = time.time()
        try:
            for ip in BMC_HOSTS:
                r = poll_bmc(ip)
                with _LATEST_LOCK:
                    _LATEST[ip] = r
                n_temps = len(r["sensors"])
                log(f"{ip}: {r['n_chassis']} chassis, {n_temps} temp sensors, "
                    f"{r['duration']:.1f}s")
            _FIRST_CYCLE_DONE.set()
        except Exception as e:
            log(f"poll loop error: {e}")
        elapsed = time.time() - cycle_start
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
    log(f"NVIS Platform Redfish Sensors Exporter starting "
        f"(port={PORT}, scrape={SCRAPE_INTERVAL}s, hosts={len(BMC_HOSTS)})")
    for h in BMC_HOSTS:
        log(f"  BMC: {h}")
    with _LATEST_LOCK:
        for ip in BMC_HOSTS:
            _LATEST.setdefault(ip, {
                "ip": ip, "serial": "", "reachable": False,
                "sensors": [], "duration": 0.0, "n_chassis": 0,
            })
    threading.Thread(target=poll_loop, daemon=True).start()
    server = ThreadingServer(("0.0.0.0", PORT), Handler)
    log(f"Metrics available at http://0.0.0.0:{PORT}/metrics")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
