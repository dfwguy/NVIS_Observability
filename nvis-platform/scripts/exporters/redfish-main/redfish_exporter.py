#!/usr/bin/env python3
"""
NVIS Platform Redfish BMC Prometheus Exporter
=============================================
Polls each node's BMC via Redfish to collect BIOS / firmware / boot order /
fans / temperatures / power draw / SEL entries / leak detectors. Exposes a
Prometheus text-format /metrics endpoint.

Environment variables:
  BMC_HOSTS          Comma-separated IPs or CIDRs (required)
  BMC_USER           BMC username (default: root)
  BMC_PASS           BMC password (required)
  CLUSTER_NAME       Label added to all metrics (required, default: "")
  PORT               Listen port (default: 9102)
  SCRAPE_INTERVAL    Seconds between full polls (default: 60)
  VERIFY_SSL         "true"/"false" — verify BMC TLS cert (default: false)
  BMC_TIMEOUT        Per-HTTP-call timeout, seconds (default: 10)
  LOKI_URL           Optional Loki push URL for SEL JSON entries (default: "")
  FAST_CHASSIS_ID    Optional chassis Id name for legacy /Thermal+/Power
                     fast path (default: "" — disabled; only enable on
                     platforms that expose this legacy node, e.g. "DGX")
  LOG_DIR            Where to write the SEL JSON log file
                     (default: /var/log/nvis-platform)
  CHASSIS_TTL        Chassis topology cache TTL, seconds (default: 1800)
  SENSOR_NAME_REGEX  Regex applied to Sensors Ids before fetching bodies
  FW_DISABLED        "true" → skip firmware inventory walk (default: false)
  SEL_DISABLED       "true" → skip SEL/EventLog walk (default: false)
"""

import os
import re
import sys
import time
import json
import calendar
import ipaddress
import threading
import logging
import urllib.request
import urllib.error
import ssl
import base64
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("redfish-exporter")

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
BMC_HOSTS_RAW   = os.environ.get("BMC_HOSTS",       "")
BMC_USER        = os.environ.get("BMC_USER",         "root")
BMC_PASS        = os.environ.get("BMC_PASS",         "")
CLUSTER_NAME    = os.environ.get("CLUSTER_NAME",     "")
PORT            = int(os.environ.get("PORT",         "9102"))
SCRAPE_INTERVAL = int(os.environ.get("SCRAPE_INTERVAL", "60"))
VERIFY_SSL      = os.environ.get("VERIFY_SSL",       "false").lower() == "true"
TIMEOUT         = int(os.environ.get("BMC_TIMEOUT",  "10"))
LOKI_URL        = os.environ.get("LOKI_URL",         "")
LOG_DIR         = os.environ.get("LOG_DIR",          "/var/log/nvis-platform")
FAST_CHASSIS_ID = os.environ.get("FAST_CHASSIS_ID",  "")

# Sensor filter: collect every temperature, fan, and power-related sensor.
SENSOR_NAME_REGEX = os.environ.get(
    "SENSOR_NAME_REGEX",
    r"(?i)("
    r"^TEMP_.*|"
    r".*_Temp_[0-9]+$|"
    r".*_TEMP_[0-9]+$|"
    r"^SPD_FAN_.*|"
    r".*_Power_[0-9]+$|"
    r"^Total_Power$|^PWR_.*|^AMP_.*_HSC$|"
    r".*Temperature.*"
    r")",
)
_sensor_re = re.compile(SENSOR_NAME_REGEX) if SENSOR_NAME_REGEX else None


def expand_hosts(raw: str) -> list[str]:
    """Expand comma-separated IPs and CIDRs into a flat list of IP strings."""
    hosts = []
    for token in raw.split(","):
        token = token.strip()
        if not token:
            continue
        try:
            net = ipaddress.ip_network(token, strict=False)
            if net.num_addresses == 1:
                hosts.append(str(net.network_address))
            else:
                hosts.extend(str(h) for h in net.hosts())
        except ValueError:
            hosts.append(token)
    return hosts


BMC_HOSTS = expand_hosts(BMC_HOSTS_RAW)


# ---------------------------------------------------------------------------
# Redfish HTTP helper
# ---------------------------------------------------------------------------
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
        "OData-Version": "4.0",
    })
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=TIMEOUT) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        if e.code not in (404, 501):
            log.debug("%s %s -> HTTP %d", bmc_ip, path, e.code)
        return None
    except Exception as e:
        log.debug("%s %s -> %s", bmc_ip, path, e)
        return None


# Module-level caches & state (declared early so collect_bmc can read them)
_CHASSIS_CACHE: dict[str, tuple[float, list[str]]] = {}
_CHASSIS_TTL = int(os.environ.get("CHASSIS_TTL", "1800"))
_SEL_COUNT_HW: dict[tuple[str, str], int] = {}
_SEL_STATE: dict[str, dict] = {}


# ---------------------------------------------------------------------------
# Per-BMC collector
# ---------------------------------------------------------------------------
def collect_bmc(bmc_ip: str) -> dict:
    data = {
        "ip":            bmc_ip,
        "reachable":     False,
        "model":         "",
        "manufacturer":  "",
        "serial":        "",
        "uuid":          "",
        "bios_version":  "",
        "boot_order":    [],
        "power_state":   "",
        "power_watts":   None,
        "fans":          [],
        "temps":         [],
        "firmware":      [],
        "leak_sensors":  [],
        "power_sensors": [],
        "sel_entries":   [],
        "sel_severity_counts": dict(_SEL_STATE.get(bmc_ip, {}).get(
            "severity_counts", {"OK": 0, "Warning": 0, "Critical": 0})),
        "sel_latest_ts": _SEL_STATE.get(bmc_ip, {}).get("latest_ts"),
    }

    sys_root = redfish_get(bmc_ip, "/redfish/v1/Systems")
    if not sys_root:
        return data
    members = sys_root.get("Members", [])
    if not members:
        return data
    sys_path = members[0].get("@odata.id", "/redfish/v1/Systems/1")

    system = redfish_get(bmc_ip, sys_path)
    if not system:
        return data

    data["reachable"]    = True
    data["model"]        = system.get("Model", "")
    data["manufacturer"] = system.get("Manufacturer", "")
    data["serial"]       = system.get("SerialNumber", "")
    data["uuid"]         = system.get("UUID", "")
    data["power_state"]  = system.get("PowerState", "")
    bios_ver = system.get("BiosVersion", "")
    data["bios_version"] = bios_ver

    boot = system.get("Boot", {})
    boot_order = boot.get("BootOrder", [])
    if not boot_order:
        override = boot.get("BootSourceOverrideTarget", "")
        if override:
            boot_order = [override]
    data["boot_order"] = boot_order

    bios_link = system.get("Bios", {}).get("@odata.id", "")
    if bios_link and not bios_ver:
        bios_data = redfish_get(bmc_ip, bios_link)
        if bios_data:
            data["bios_version"] = bios_data.get("Attributes", {}).get(
                "SystemBiosVersion", bios_data.get("Version", "")
            )

    # ── FAST PATH: legacy /Thermal + /Power at a known chassis Id ───────────
    # Only attempted when FAST_CHASSIS_ID is set (platform-dependent).
    fast_path_ok = False
    if FAST_CHASSIS_ID:
        fast_thermal = redfish_get(
            bmc_ip, f"/redfish/v1/Chassis/{FAST_CHASSIS_ID}/Thermal")
        if fast_thermal:
            for fan in fast_thermal.get("Fans", []):
                name    = fan.get("Name", fan.get("FanName", ""))
                rpm     = fan.get("Reading", fan.get("CurrentReading"))
                status  = fan.get("Status", {}).get("Health", "")
                if name and rpm is not None:
                    data["fans"].append({"name": name, "rpm": rpm, "status": status})
            for sensor in fast_thermal.get("Temperatures", []):
                name     = sensor.get("Name", "")
                celsius  = sensor.get("ReadingCelsius")
                status   = sensor.get("Status", {}).get("Health", "")
                if name and celsius is not None:
                    data["temps"].append({"name": name, "celsius": celsius, "status": status})
            fast_path_ok = bool(data["temps"]) or bool(data["fans"])

        fast_power = redfish_get(
            bmc_ip, f"/redfish/v1/Chassis/{FAST_CHASSIS_ID}/Power")
        if fast_power:
            for ctrl in fast_power.get("PowerControl", []):
                consumed = (ctrl.get("PowerConsumedWatts")
                            or ctrl.get("PowerMetrics", {}).get("AverageConsumedWatts"))
                if consumed is not None and data["power_watts"] is None:
                    data["power_watts"] = consumed
                    pm = ctrl.get("PowerMetrics", {}) or {}
                    if pm.get("MaxConsumedWatts") is not None:
                        data["power_max_watts"] = pm["MaxConsumedWatts"]
                    if pm.get("MinConsumedWatts") is not None:
                        data["power_min_watts"] = pm["MinConsumedWatts"]
                    break

    # Per-component power via TelemetryService MetricReport
    tel = redfish_get(bmc_ip,
        "/redfish/v1/TelemetryService/MetricReports/HGX_PlatformEnvironmentMetrics_0")
    if tel:
        for mv in tel.get("MetricValues", []):
            mp = mv.get("MetricProperty", "")
            val = mv.get("MetricValue", "")
            if not mp or not val:
                continue
            comp = mp.rstrip("/").rsplit("/", 1)[-1]
            try:
                num = float(val)
            except (TypeError, ValueError):
                continue
            mp_lower = mp.lower()
            if "power" in mp_lower:
                data["power_sensors"].append({"name": comp, "watts": num})
            elif "temp" in mp_lower:
                if not any(t["name"] == comp for t in data["temps"]):
                    data["temps"].append({"name": comp, "celsius": num, "status": "OK"})

    # ── Chassis discovery (skipped if fast path satisfied) ─────────────────
    chassis_paths: list[str] = []
    cached = _CHASSIS_CACHE.get(bmc_ip)
    now = time.time()
    if fast_path_ok:
        chassis_paths = []
    elif cached and now - cached[0] < _CHASSIS_TTL:
        chassis_paths = cached[1]
    else:
        next_path = "/redfish/v1/Chassis"
        for _hop in range(10):
            page = redfish_get(bmc_ip, next_path)
            if not page:
                break
            for m in page.get("Members", []):
                p = m.get("@odata.id", "")
                if p:
                    chassis_paths.append(p)
            nl = page.get("Members@odata.nextLink", "")
            if not nl:
                break
            next_path = nl
        skip_re = re.compile(r"(?i)(erot|irot|bridge|slot|connector|attestation)")
        chassis_paths = [c for c in chassis_paths if not skip_re.search(c)]
        _CHASSIS_CACHE[bmc_ip] = (now, chassis_paths)

    chassis_path = chassis_paths[0] if chassis_paths else ""

    # ── Sensors collection walk ─────────────────────────────────────────────
    sensor_paths: list[str] = []

    def _fetch_sensor_collection(ch_path: str) -> list[str]:
        coll = redfish_get(bmc_ip, f"{ch_path.rstrip('/')}/Sensors")
        if not coll:
            return []
        return [sm.get("@odata.id", "")
                for sm in coll.get("Members", []) if sm.get("@odata.id")]

    with ThreadPoolExecutor(max_workers=8) as ex:
        for paths in ex.map(_fetch_sensor_collection, chassis_paths):
            sensor_paths.extend(paths)

    if _sensor_re:
        sensor_paths = [p for p in sensor_paths
                        if _sensor_re.match(p.rstrip("/").rsplit("/", 1)[-1])]

    if sensor_paths:
        seen_names: set[str] = set()
        def _fetch(p):
            return p, redfish_get(bmc_ip, p)
        with ThreadPoolExecutor(max_workers=8) as ex:
            for _sp, body in ex.map(_fetch, sensor_paths):
                if not body:
                    continue
                rt      = body.get("ReadingType", "")
                name    = body.get("Name") or body.get("Id") or ""
                reading = body.get("Reading")
                status  = body.get("Status", {}).get("Health", "")
                if reading is None or not name:
                    continue
                if name in seen_names:
                    continue
                seen_names.add(name)
                if rt == "Temperature":
                    data["temps"].append({"name": name, "celsius": reading, "status": status})
                elif rt == "Rotational":
                    data["fans"].append({"name": name, "rpm": reading, "status": status})
                elif rt == "Power":
                    if data["power_watts"] is None and "total" in name.lower():
                        data["power_watts"] = reading

    # ── Legacy /Thermal + /Power on the discovered primary chassis ──────────
    if chassis_path:
        thermal = redfish_get(bmc_ip, f"{chassis_path}/Thermal")
        if thermal:
            for fan in thermal.get("Fans", []):
                name    = fan.get("Name", fan.get("FanName", ""))
                rpm     = fan.get("Reading", fan.get("CurrentReading"))
                status  = fan.get("Status", {}).get("Health", "")
                if name and not any(f["name"] == name for f in data["fans"]):
                    data["fans"].append({"name": name, "rpm": rpm, "status": status})
            for sensor in thermal.get("Temperatures", []):
                name     = sensor.get("Name", "")
                celsius  = sensor.get("ReadingCelsius")
                status   = sensor.get("Status", {}).get("Health", "")
                if name and celsius is not None and not any(t["name"] == name for t in data["temps"]):
                    data["temps"].append({"name": name, "celsius": celsius, "status": status})

        power_data = redfish_get(bmc_ip, f"{chassis_path}/Power")
        if power_data:
            for ctrl in power_data.get("PowerControl", []):
                consumed = ctrl.get("PowerConsumedWatts")
                if consumed is not None and data["power_watts"] is None:
                    data["power_watts"] = consumed
                    break

    # ── Firmware inventory ──────────────────────────────────────────────────
    fw_inv = None if os.environ.get("FW_DISABLED", "false").lower() == "true" \
        else redfish_get(bmc_ip, "/redfish/v1/UpdateService/FirmwareInventory")
    if fw_inv:
        for member in fw_inv.get("Members", []):
            fw_path = member.get("@odata.id", "")
            if not fw_path:
                continue
            fw_item = redfish_get(bmc_ip, fw_path)
            if not fw_item:
                continue
            name    = fw_item.get("Name", fw_item.get("Id", ""))
            version = fw_item.get("Version", "")
            ftype   = fw_item.get("SoftwareId", fw_item.get("Description", ""))
            if name and version:
                data["firmware"].append({
                    "name":    name,
                    "version": version,
                    "type":    ftype,
                })

    # ── Leak detection (Redfish 2023.3+) ───────────────────────────────────
    if chassis_path:
        leak = redfish_get(bmc_ip, f"{chassis_path}/LeakDetection")
        if leak:
            detectors = leak.get("Detectors", [])
            for grp in leak.get("DetectorGroups", []):
                detectors.extend(grp.get("Detectors", []))
            for d in detectors:
                sensor_name = d.get("Name", d.get("PhysicalContext", "unknown"))
                state       = d.get("DetectorState", d.get("Status", {}).get("State", "Unknown"))
                data["leak_sensors"].append({
                    "name":  sensor_name,
                    "state": state,
                    "value": 1 if str(state).lower() == "leak" else 0,
                })

    # ── System Event Log (SEL) / EventLog / AuditLog ────────────────────────
    sel_re = re.compile(r"^(sel|eventlog|auditlog|logs)$", re.IGNORECASE)
    log_roots: list[str] = []
    if os.environ.get("SEL_DISABLED", "false").lower() != "true":
        log_roots.append(sys_path)
        mgr_root = redfish_get(bmc_ip, "/redfish/v1/Managers")
        if mgr_root:
            for mm in mgr_root.get("Members", []):
                mp = mm.get("@odata.id", "")
                if mp:
                    log_roots.append(mp)
        # Optional fast-path chassis often has its own LogServices.
        if FAST_CHASSIS_ID:
            log_roots.append(f"/redfish/v1/Chassis/{FAST_CHASSIS_ID}")

    for root_path in log_roots:
        log_svcs = redfish_get(bmc_ip, f"{root_path.rstrip('/')}/LogServices")
        if not log_svcs:
            continue
        for svc_member in log_svcs.get("Members", []):
            svc_path = svc_member.get("@odata.id", "")
            if not svc_path:
                continue
            svc_id = svc_path.rstrip("/").rsplit("/", 1)[-1]
            if not sel_re.match(svc_id):
                continue
            base_entries = f"{svc_path.rstrip('/')}/Entries"
            peek = redfish_get(bmc_ip, f"{base_entries}?$top=0") or \
                   redfish_get(bmc_ip, f"{base_entries}?$top=1")
            cur_count = (peek or {}).get("Members@odata.count", 0) if peek else 0
            hw_key = (bmc_ip, svc_path)
            prev_count = _SEL_COUNT_HW.get(hw_key, 0)
            if cur_count and cur_count == prev_count:
                continue
            skip = prev_count if cur_count > prev_count else 0
            top_param = "$top=6000"
            if skip:
                entries_path = f"{base_entries}?$skip={skip}&{top_param}"
            else:
                entries_path = f"{base_entries}?{top_param}"
            collected = 0
            for _hop in range(5):
                page = redfish_get(bmc_ip, entries_path)
                if not page:
                    break
                for entry in page.get("Members", []):
                    if collected >= 500:
                        break
                    eid       = entry.get("Id", "")
                    created   = entry.get("EventTimestamp") or entry.get("Created", "")
                    severity  = entry.get("Severity", "")
                    message   = entry.get("Message", "")
                    msg_id    = entry.get("MessageId", "")
                    sensor_t  = entry.get("SensorType", "")
                    ent_type  = entry.get("EntryType", "")
                    ts_unix   = None
                    if created:
                        try:
                            iso = created.replace("Z", "+00:00")
                            ts_unix = calendar.timegm(
                                datetime.fromisoformat(iso).utctimetuple()
                            )
                        except (ValueError, TypeError):
                            ts_unix = None
                    data["sel_entries"].append({
                        "id":          f"{svc_id}/{eid}",
                        "source":      svc_id,
                        "ts":          created,
                        "ts_unix":     ts_unix,
                        "severity":    severity,
                        "message":     message,
                        "message_id":  msg_id,
                        "sensor_type": sensor_t,
                        "entry_type":  ent_type,
                    })
                    sev_key = severity if severity in ("OK", "Warning", "Critical") else "OK"
                    data["sel_severity_counts"][sev_key] = (
                        data["sel_severity_counts"].get(sev_key, 0) + 1
                    )
                    if ts_unix is not None and (
                        data["sel_latest_ts"] is None or ts_unix > data["sel_latest_ts"]
                    ):
                        data["sel_latest_ts"] = ts_unix
                    collected += 1
                if collected >= 500:
                    break
                next_link = page.get("Members@odata.nextLink", "")
                if not next_link:
                    break
                entries_path = next_link
            if cur_count:
                _SEL_COUNT_HW[hw_key] = cur_count

    _SEL_STATE[bmc_ip] = {
        "severity_counts": dict(data["sel_severity_counts"]),
        "latest_ts": data["sel_latest_ts"],
    }
    return data


# ---------------------------------------------------------------------------
# Metrics renderer
# ---------------------------------------------------------------------------
def esc(s: str) -> str:
    return str(s).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def render_metrics(results: list[dict]) -> str:
    cluster = CLUSTER_NAME
    lines = []

    def add(metric, labels_dict, value):
        lstr = ",".join(f'{k}="{esc(v)}"' for k, v in labels_dict.items())
        lines.append(f"{metric}{{{lstr}}} {value}")

    lines.append("# HELP redfish_up 1 if BMC Redfish API is reachable")
    lines.append("# TYPE redfish_up gauge")
    for r in results:
        add("redfish_up", {"bmc": r["ip"], "cluster": cluster,
                           "node": r.get("serial", r["ip"])}, 1 if r["reachable"] else 0)

    lines.append("\n# HELP redfish_system_info System identity (info gauge)")
    lines.append("# TYPE redfish_system_info gauge")
    for r in results:
        if not r["reachable"]:
            continue
        add("redfish_system_info", {
            "bmc":          r["ip"],
            "cluster":      cluster,
            "model":        r["model"],
            "manufacturer": r["manufacturer"],
            "serial":       r["serial"],
            "uuid":         r["uuid"],
            "bios_version": r["bios_version"],
            "power_state":  r["power_state"],
        }, 1)

    lines.append("\n# HELP redfish_boot_order_entry Boot order position (0=first)")
    lines.append("# TYPE redfish_boot_order_entry gauge")
    for r in results:
        if not r["reachable"]:
            continue
        for pos, entry in enumerate(r["boot_order"]):
            add("redfish_boot_order_entry", {
                "bmc":     r["ip"],
                "cluster": cluster,
                "serial":  r["serial"],
                "entry":   str(entry),
            }, pos)

    lines.append("\n# HELP redfish_firmware_info Firmware version per component")
    lines.append("# TYPE redfish_firmware_info gauge")
    for r in results:
        if not r["reachable"]:
            continue
        for fw in r["firmware"]:
            add("redfish_firmware_info", {
                "bmc":       r["ip"],
                "cluster":   cluster,
                "serial":    r["serial"],
                "component": fw["name"],
                "version":   fw["version"],
                "type":      fw["type"],
            }, 1)

    lines.append("\n# HELP redfish_fan_rpm Fan speed in RPM")
    lines.append("# TYPE redfish_fan_rpm gauge")
    lines.append("# HELP redfish_fan_health 1 if fan health is OK")
    lines.append("# TYPE redfish_fan_health gauge")
    for r in results:
        if not r["reachable"]:
            continue
        for fan in r["fans"]:
            if fan["rpm"] is not None:
                add("redfish_fan_rpm", {
                    "bmc": r["ip"], "cluster": cluster,
                    "serial": r["serial"], "fan": fan["name"],
                }, fan["rpm"])
            add("redfish_fan_health", {
                "bmc": r["ip"], "cluster": cluster,
                "serial": r["serial"], "fan": fan["name"],
                "status": fan["status"],
            }, 1 if fan["status"].upper() == "OK" else 0)

    lines.append("\n# HELP redfish_temperature_celsius Temperature sensor reading (C)")
    lines.append("# TYPE redfish_temperature_celsius gauge")
    for r in results:
        if not r["reachable"]:
            continue
        for temp in r["temps"]:
            add("redfish_temperature_celsius", {
                "bmc": r["ip"], "cluster": cluster,
                "serial": r["serial"], "sensor": temp["name"],
                "status": temp["status"],
            }, temp["celsius"])

    lines.append("\n# HELP redfish_power_watts Current power consumption (watts)")
    lines.append("# TYPE redfish_power_watts gauge")
    for r in results:
        if not r["reachable"] or r["power_watts"] is None:
            continue
        add("redfish_power_watts", {
            "bmc": r["ip"], "cluster": cluster, "serial": r["serial"],
        }, r["power_watts"])

    lines.append("\n# HELP redfish_component_power_watts Per-component power (W)")
    lines.append("# TYPE redfish_component_power_watts gauge")
    for r in results:
        if not r["reachable"]:
            continue
        for ps in r.get("power_sensors", []):
            add("redfish_component_power_watts", {
                "bmc": r["ip"], "cluster": cluster, "serial": r["serial"],
                "component": ps["name"],
            }, ps["watts"])

    lines.append("\n# HELP rf_leakdetector_state Tray-level leak sensor (0=OK 1=Leak)")
    lines.append("# TYPE rf_leakdetector_state gauge")
    for r in results:
        if not r["reachable"]:
            continue
        for sensor in r.get("leak_sensors", []):
            sname = sensor["name"].lower().replace(" ", "_").replace("-", "_")
            add("rf_leakdetector_state", {
                "bmc":    r["ip"],
                "cluster": cluster,
                "serial": r["serial"],
                "sensor": sname,
                "state":  sensor["state"],
            }, sensor["value"])

    lines.append("\n# HELP redfish_sel_severity_count SEL entries per severity")
    lines.append("# TYPE redfish_sel_severity_count gauge")
    lines.append("# HELP redfish_sel_latest_timestamp Unix ts of most recent SEL entry")
    lines.append("# TYPE redfish_sel_latest_timestamp gauge")
    for r in results:
        if not r["reachable"]:
            continue
        base = {"bmc": r["ip"], "cluster": cluster, "serial": r["serial"]}
        for sev in ("OK", "Warning", "Critical"):
            add("redfish_sel_severity_count",
                {**base, "severity": sev},
                r.get("sel_severity_counts", {}).get(sev, 0))
        if r.get("sel_latest_ts") is not None:
            add("redfish_sel_latest_timestamp", base, r["sel_latest_ts"])

    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# SEL -> Loki JSON log file
# ---------------------------------------------------------------------------
_SEL_LOG_PATH = os.environ.get(
    "SEL_LOG_PATH", os.path.join(LOG_DIR, "redfish-sel.json"))
_SEL_SEEN: set[tuple[str, str]] = set()
_SEL_SEEN_CAP = 50000


def write_sel_logfile(results: list[dict]) -> None:
    new_lines = []
    loki_streams_by_key: dict[tuple, list[tuple[int, str]]] = {}
    for r in results:
        if not r.get("reachable"):
            continue
        bmc_ip = r["ip"]
        serial = r.get("serial", "")
        for entry in r.get("sel_entries", []):
            key = (bmc_ip, str(entry.get("id", "")))
            if key in _SEL_SEEN:
                continue
            _SEL_SEEN.add(key)
            payload = {
                "ts":          entry.get("ts", ""),
                "ts_unix":     entry.get("ts_unix"),
                "bmc":         bmc_ip,
                "serial":      serial,
                "cluster":     CLUSTER_NAME,
                "id":          entry.get("id", ""),
                "source":      entry.get("source", ""),
                "severity":    entry.get("severity", ""),
                "message":     entry.get("message", ""),
                "message_id":  entry.get("message_id", ""),
                "sensor_type": entry.get("sensor_type", ""),
                "entry_type":  entry.get("entry_type", ""),
            }
            line = json.dumps(payload, separators=(",", ":"))
            new_lines.append(line)
            sev = entry.get("severity", "OK") or "OK"
            src = entry.get("source", "") or "SEL"
            ts_ns = str(int(time.time() * 1_000_000_000))
            loki_streams_by_key.setdefault((bmc_ip, sev, src), []).append((ts_ns, line))

    if not new_lines:
        return

    try:
        os.makedirs(os.path.dirname(_SEL_LOG_PATH), exist_ok=True)
        with open(_SEL_LOG_PATH, "a", encoding="utf-8") as fh:
            fh.write("\n".join(new_lines) + "\n")
    except OSError as e:
        log.warning("Failed writing SEL log %s: %s", _SEL_LOG_PATH, e)

    if LOKI_URL and loki_streams_by_key:
        try:
            streams = []
            for (bmc_ip, sev, src), entries in loki_streams_by_key.items():
                entries.sort(key=lambda x: int(x[0]))
                streams.append({
                    "stream": {
                        "job":      "redfish-sel",
                        "cluster":  CLUSTER_NAME,
                        "bmc":      bmc_ip,
                        "severity": sev,
                        "source":   src,
                    },
                    "values": [[ts, msg] for ts, msg in entries],
                })
            body = json.dumps({"streams": streams}).encode("utf-8")
            req = urllib.request.Request(
                LOKI_URL,
                data=body,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                if resp.status not in (200, 204):
                    log.warning("Loki push %s: HTTP %s", LOKI_URL, resp.status)
        except Exception as e:
            log.warning("Loki push failed (%s): %s", LOKI_URL, e)

    if len(_SEL_SEEN) > _SEL_SEEN_CAP:
        keep = list(_SEL_SEEN)[-_SEL_SEEN_CAP // 2:]
        _SEL_SEEN.clear()
        _SEL_SEEN.update(keep)


# ---------------------------------------------------------------------------
# Background scrape loop
# ---------------------------------------------------------------------------
_lock          = threading.Lock()
_latest        = ""
_ready         = threading.Event()
_force_refresh = threading.Event()
_refresh_targets: list[str] = []


def scrape_all(hosts=None) -> list[dict]:
    hosts = list(BMC_HOSTS) if hosts is None else list(hosts)
    results = [None] * len(hosts)
    threads = []

    def worker(idx, ip):
        results[idx] = collect_bmc(ip)

    for i, ip in enumerate(hosts):
        t = threading.Thread(target=worker, args=(i, ip), daemon=True)
        t.start()
        threads.append(t)
    join_budget = max(600, TIMEOUT * 40)
    for t in threads:
        t.join(timeout=join_budget)

    return [r for r in results if r is not None]


def scrape_loop():
    global _latest
    last_results: list[dict] = []
    while True:
        with _lock:
            targets = list(_refresh_targets)
            _refresh_targets.clear()
        if targets and last_results:
            log.info("Polling %d BMC host(s) (targeted: %s)...", len(targets), ",".join(targets))
            t0 = time.time()
            partial = scrape_all(targets)
            dur = time.time() - t0
            by_ip = {r["ip"]: r for r in last_results}
            for r in partial:
                by_ip[r["ip"]] = r
            results = [by_ip[ip] for ip in BMC_HOSTS if ip in by_ip]
            up = sum(1 for r in partial if r["reachable"])
            log.info("Done -- %d/%d reachable in %.1fs (targeted)", up, len(partial), dur)
        else:
            log.info("Polling %d BMC host(s)...", len(BMC_HOSTS))
            t0 = time.time()
            results = scrape_all()
            up   = sum(1 for r in results if r["reachable"])
            dur  = time.time() - t0
            log.info("Done -- %d/%d reachable in %.1fs", up, len(results), dur)
        last_results = results
        metrics = render_metrics(results)
        with _lock:
            _latest = metrics
        _ready.set()
        write_sel_logfile(results)
        triggered = _force_refresh.wait(timeout=SCRAPE_INTERVAL)
        if triggered:
            _force_refresh.clear()


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _handle_refresh(self):
        path, _, query = self.path.partition("?")
        if path != "/refresh":
            self.send_response(404)
            self.end_headers()
            return
        bmc_param = None
        for part in query.split("&"):
            if not part:
                continue
            k, _, v = part.partition("=")
            if k == "bmc":
                bmc_param = v
                break
        if bmc_param:
            if bmc_param not in BMC_HOSTS:
                err = (b'{"status": "error", "error": "bmc not in BMC_HOSTS", '
                       b'"bmc": "' + bmc_param.encode() + b'"}\n')
                self.send_response(404)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(err)))
                self.end_headers()
                self.wfile.write(err)
                return
            with _lock:
                if bmc_param not in _refresh_targets:
                    _refresh_targets.append(bmc_param)
            ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            log.info("Manual refresh triggered at %s (bmc=%s)", ts, bmc_param)
            _force_refresh.set()
            body = (b'{"status": "refresh triggered", "bmc": "'
                    + bmc_param.encode() + b'"}\n')
        else:
            with _lock:
                _refresh_targets.clear()
            ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            log.info("Manual refresh triggered at %s", ts)
            _force_refresh.set()
            body = b'{"status": "refresh triggered", "bmc": "all"}\n'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/metrics", "/"):
            _ready.wait(timeout=120)
            with _lock:
                body = _latest.encode()
            self.send_response(200)
            self.send_header("Content-Type",
                             "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif path == "/-/healthy":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"OK\n")
        elif path == "/refresh":
            self._handle_refresh()
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path == "/refresh":
            self._handle_refresh()
        else:
            self.send_response(404)
            self.end_headers()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    if not BMC_HOSTS:
        log.error("BMC_HOSTS is empty -- set the env var")
        sys.exit(1)
    if not BMC_PASS:
        log.error("BMC_PASS is empty -- set the env var")
        sys.exit(1)

    log.info("NVIS Platform Redfish Exporter starting")
    log.info("  BMC hosts      : %d host(s) -- %s", len(BMC_HOSTS),
             ", ".join(BMC_HOSTS[:5]) + ("..." if len(BMC_HOSTS) > 5 else ""))
    log.info("  BMC user       : %s", BMC_USER)
    log.info("  Cluster        : %s", CLUSTER_NAME)
    log.info("  Scrape interval: %ds", SCRAPE_INTERVAL)
    log.info("  SSL verify     : %s", VERIFY_SSL)
    log.info("  Listen port    : %d", PORT)

    t = threading.Thread(target=scrape_loop, daemon=True)
    t.start()

    server = HTTPServer(("", PORT), Handler)
    log.info("Metrics available at http://0.0.0.0:%d/metrics", PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down.")
