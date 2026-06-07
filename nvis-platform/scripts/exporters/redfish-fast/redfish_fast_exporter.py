#!/usr/bin/env python3
"""Fast-path Redfish exporter -- fans, temps, power only.

Designed to run alongside the slow main `redfish_exporter.py` (firmware
inventory + SEL + leak + sensor walk) so thermal/power can update on a
30s cadence without hammering the BMC with the heavy paths.

Endpoints (per BMC, per cycle):
  - /redfish/v1/Systems                                          (serial cache)
  - /redfish/v1/Chassis/{FAST_CHASSIS_ID}/Thermal                (fans + temps)
  - /redfish/v1/Chassis/{FAST_CHASSIS_ID}/Power                  (chassis watts)
  - /redfish/v1/TelemetryService/MetricReports/HGX_PlatformEnvironmentMetrics_0

Emits the same metric names AND label keys as the main exporter so existing
dashboards work unchanged.

Env vars:
  BMC_HOSTS, BMC_USER, BMC_PASS, CLUSTER_NAME (required-ish)
  PORT             default 9107
  SCRAPE_INTERVAL  default 30
  BMC_TIMEOUT      default 10
  VERIFY_SSL       default "false"
  FAST_CHASSIS_ID  Chassis Id for legacy /Thermal+/Power calls (required;
                   platform-specific, e.g. some Redfish stacks expose a
                   single legacy chassis node that returns all telemetry in
                   one shot)
  FAN_RPM_FLOOR    Drop fan readings below this RPM as phantom/absent slots
                   (default: 0 — no filtering)
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
PORT            = int(os.environ.get("PORT",        "9107"))
SCRAPE_INTERVAL = int(os.environ.get("SCRAPE_INTERVAL", "30"))
TIMEOUT         = int(os.environ.get("BMC_TIMEOUT", "10"))
VERIFY_SSL      = os.environ.get("VERIFY_SSL",      "false").lower() == "true"
FAST_CHASSIS_ID = os.environ.get("FAST_CHASSIS_ID", "")
FAN_RPM_FLOOR   = int(os.environ.get("FAN_RPM_FLOOR", "0"))


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
    out = {
        "ip": bmc_ip,
        "serial": discover_serial(bmc_ip),
        "reachable": False,
        "fans": [],
        "temps": [],
        "power_watts": None,
        "power_sensors": [],
    }

    if not FAST_CHASSIS_ID:
        log(f"  {bmc_ip}: FAST_CHASSIS_ID is unset -- skipping legacy thermal/power calls")
    else:
        thermal_path = f"/redfish/v1/Chassis/{FAST_CHASSIS_ID}/Thermal"
        thermal = redfish_get(bmc_ip, thermal_path)
        if thermal:
            out["reachable"] = True
            for fan in thermal.get("Fans", []):
                name   = fan.get("Name", fan.get("FanName", ""))
                rpm    = fan.get("Reading", fan.get("CurrentReading"))
                status = fan.get("Status", {}).get("Health", "")
                state  = fan.get("Status", {}).get("State", "")
                # Drop phantom slots when FAN_RPM_FLOOR is set: BMC firmware on
                # certain SKUs reports absent fan positions with a hardcoded
                # low RPM. Default floor is 0 (no filtering).
                if (name and rpm is not None and state == "Enabled"
                        and (FAN_RPM_FLOOR == 0 or rpm >= FAN_RPM_FLOOR)):
                    out["fans"].append({"name": name, "rpm": rpm, "status": status})
            for s in thermal.get("Temperatures", []):
                name    = s.get("Name", "")
                celsius = s.get("ReadingCelsius")
                status  = s.get("Status", {}).get("Health", "")
                if name and celsius is not None:
                    out["temps"].append({"name": name, "celsius": celsius, "status": status})

        power_path = f"/redfish/v1/Chassis/{FAST_CHASSIS_ID}/Power"
        power = redfish_get(bmc_ip, power_path)
        if power:
            out["reachable"] = True
            for ctrl in power.get("PowerControl", []):
                w = (ctrl.get("PowerConsumedWatts")
                     or ctrl.get("PowerMetrics", {}).get("AverageConsumedWatts"))
                if w is not None:
                    out["power_watts"] = w
                    break

    tel = redfish_get(bmc_ip,
        "/redfish/v1/TelemetryService/MetricReports/HGX_PlatformEnvironmentMetrics_0")
    if tel:
        out["reachable"] = True
        seen_temp_names = {t["name"] for t in out["temps"]}
        for mv in tel.get("MetricValues", []):
            mp = mv.get("MetricProperty", "")
            if not mp:
                continue
            comp = mp.rstrip("/").rsplit("/", 1)[-1]
            if _mv_stale(mv):
                num = float("nan")
            else:
                val = mv.get("MetricValue", "")
                if val in ("", None):
                    continue
                try:
                    num = float(val)
                except (TypeError, ValueError):
                    continue
            mp_lower = mp.lower()
            if "power" in mp_lower:
                out["power_sensors"].append({"name": comp, "watts": num})
            elif "temp" in mp_lower and comp not in seen_temp_names:
                out["temps"].append({"name": comp, "celsius": num, "status": "OK"})

    return out


_LATEST: dict[str, dict] = {}
_LATEST_LOCK = threading.Lock()


def _esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def render_metrics() -> str:
    with _LATEST_LOCK:
        snapshot = list(_LATEST.values())

    lines: list[str] = []

    lines.append("# HELP redfish_fast_up 1 if fast-path Redfish endpoints responded")
    lines.append("# TYPE redfish_fast_up gauge")
    for r in snapshot:
        lines.append(
            f'redfish_fast_up{{bmc="{r["ip"]}",cluster="{CLUSTER_NAME}",'
            f'serial="{r["serial"]}"}} {1 if r["reachable"] else 0}'
        )

    lines.append("\n# HELP redfish_fan_rpm Fan speed in RPM")
    lines.append("# TYPE redfish_fan_rpm gauge")
    lines.append("# HELP redfish_fan_health 1 if fan health is OK")
    lines.append("# TYPE redfish_fan_health gauge")
    for r in snapshot:
        if not r["reachable"]:
            continue
        for f in r["fans"]:
            base = (f'bmc="{r["ip"]}",cluster="{CLUSTER_NAME}",'
                    f'serial="{r["serial"]}",fan="{_esc(f["name"])}"')
            if f["rpm"] is not None:
                lines.append(f'redfish_fan_rpm{{{base}}} {f["rpm"]}')
            ok = 1 if (f.get("status") or "").lower() == "ok" else 0
            lines.append(f'redfish_fan_health{{{base},status="{_esc(f.get("status",""))}"}} {ok}')

    lines.append("\n# HELP redfish_temperature_celsius Temperature sensor reading in Celsius")
    lines.append("# TYPE redfish_temperature_celsius gauge")
    for r in snapshot:
        if not r["reachable"]:
            continue
        for t in r["temps"]:
            lbls = (f'bmc="{r["ip"]}",cluster="{CLUSTER_NAME}",'
                    f'serial="{r["serial"]}",sensor="{_esc(t["name"])}",'
                    f'status="{_esc(t.get("status",""))}"')
            lines.append(f'redfish_temperature_celsius{{{lbls}}} {t["celsius"]}')

    lines.append("\n# HELP redfish_power_watts Current chassis power consumption (watts)")
    lines.append("# TYPE redfish_power_watts gauge")
    for r in snapshot:
        if r["reachable"] and r["power_watts"] is not None:
            lines.append(
                f'redfish_power_watts{{bmc="{r["ip"]}",cluster="{CLUSTER_NAME}",'
                f'serial="{r["serial"]}"}} {r["power_watts"]}'
            )

    lines.append("\n# HELP redfish_component_power_watts Per-component power (watts)")
    lines.append("# TYPE redfish_component_power_watts gauge")
    for r in snapshot:
        if not r["reachable"]:
            continue
        for ps in r["power_sensors"]:
            lbls = (f'bmc="{r["ip"]}",cluster="{CLUSTER_NAME}",'
                    f'serial="{r["serial"]}",component="{_esc(ps["name"])}"')
            lines.append(f'redfish_component_power_watts{{{lbls}}} {ps["watts"]}')

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
            up = sum(1 for r in results if r["reachable"])
            n_temps = sum(len(r["temps"]) for r in results)
            n_fans = sum(len(r["fans"]) for r in results)
            n_comp = sum(len(r["power_sensors"]) for r in results)
            log(f"poll: {up}/{len(BMC_HOSTS)} reachable, "
                f"temps={n_temps} fans={n_fans} components={n_comp}, "
                f"took {time.time()-start:.2f}s")
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
    log(f"NVIS Platform Redfish Fast Exporter starting (port={PORT}, "
        f"scrape={SCRAPE_INTERVAL}s, hosts={len(BMC_HOSTS)}, "
        f"fast_chassis_id={FAST_CHASSIS_ID or '(unset)'})")
    for h in BMC_HOSTS:
        log(f"  BMC: {h}")
    threading.Thread(target=poll_loop, daemon=True).start()
    server = ThreadingServer(("0.0.0.0", PORT), Handler)
    log(f"Metrics available at http://0.0.0.0:{PORT}/metrics")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
