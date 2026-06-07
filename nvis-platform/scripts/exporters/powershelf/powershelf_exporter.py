#!/usr/bin/env python3
"""
NVIS PowerShelf Redfish Prometheus Exporter — v1.2
====================================================
Scrapes LiteOn PF-1333-13RD PowerShelves over Redfish and exposes Prometheus
metrics on :9103. Each shelf reports 6 PSUs and ~72 sensors.

Each PowerShelf reports a single Chassis (/Chassis/powershelf) with:
  - 1 PowerSubsystem
  - 6 PowerSupply members (PSU 1..6, indexed 0..5 under PowerSupplies/{n})
  - 72 Sensors under /Chassis/powershelf/Sensors (per-PSU + chassis aggregates)

The shelf BMC (OpenBMC-derived) does NOT support $expand, FilterQuery, or
SelectQuery. TelemetryService exists but exposes 0 MetricReports/Definitions.
We therefore lean on the LEGACY /Power and /Thermal endpoints which return
all sub-resources INLINE in a single GET:
  - /Power   → 6 PowerSupplies (incl. PowerInputWatts) + 14 Voltages + PowerLimit
  - /Thermal → 6 Fans (RPM) + 21 Temperatures
That bulk pair covers 41 of the 72 sensor readings in 2 GETs. The remaining
25 readings (per-PSU iin/iout/pout/freqin + ishare) are still fetched via the
modern /Sensors/{id} resources in parallel. Chassis-level aggregates
(input_power, output_power, efficiency_pct, load_pct, input/output_current) are
DERIVED from per-PSU values rather than fetched separately. ServiceRoot and
Chassis bodies (static metadata) are cached for POWERSHELF_META_REFRESH cycles.
Net per-cycle GETs: ~27 vs. ~51 in v1.0 (47% reduction). The BMC PMC caps
concurrent clients at ~8, which still bounds per-shelf concurrency.

Environment variables:
  POWERSHELF_HOSTS         CSV of shelf IPs or @/path/to/hosts.txt (one per line).
                           IPs of 0.0.0.0 / blank are skipped (BCM stubs).
  POWERSHELF_USER          Redfish username (default: root)
  POWERSHELF_PASS          Redfish password (LiteOn default: 0penBmc)
  CLUSTER_NAME             Cluster label stamped on every metric
  PORT                     Listen port (default: 9103)
  SCRAPE_INTERVAL          Seconds between scrape cycles (default: 30)
  VERIFY_SSL               true/false (default: false — shelves use self-signed)
  POWERSHELF_TIMEOUT       Per-HTTP-call timeout in seconds (default: 10)
  POWERSHELF_MAX_WORKERS   Concurrent shelves per cycle (default: 16)
  POWERSHELF_SENSOR_WORKERS Concurrent sensor fetches per shelf (default: 8)
  POWERSHELF_PSU_FW_EXPECTED   Expected PSU FW string (default: "0xf1 / 0xf1")
  POWERSHELF_META_REFRESH  Cycles between ServiceRoot+Chassis re-fetches (default: 60)

Safety rules (no in-field PSU patching available):
  - HTTP 401/403 from a shelf is recorded once per scrape cycle and that shelf
    is then SKIPPED for the rest of that cycle (account lockout: 4 fails =
    10 min lockout).
  - Bad / unreachable hosts never crash the loop.
  - If POWERSHELF_HOSTS is empty, the exporter runs idle (serves /metrics with
    nvis_powershelf_up 1 only). install.sh launches us even when no shelves
    are configured for the deployment.
"""

import os
import re
import sys
import ssl
import json
import time
import base64
import logging
import threading
import urllib.request
import urllib.error
import ipaddress
from concurrent.futures import ThreadPoolExecutor, as_completed
from http.server import HTTPServer, BaseHTTPRequestHandler

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("powershelf-exporter")

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
HOSTS_RAW          = os.environ.get("POWERSHELF_HOSTS", "")
USER               = os.environ.get("POWERSHELF_USER", "root")
PASS               = os.environ.get("POWERSHELF_PASS", "")
CLUSTER_NAME       = os.environ.get("CLUSTER_NAME", "")
PORT               = int(os.environ.get("PORT", "9103"))
SCRAPE_INTERVAL    = int(os.environ.get("SCRAPE_INTERVAL", "30"))
VERIFY_SSL         = os.environ.get("VERIFY_SSL", "false").lower() == "true"
TIMEOUT            = int(os.environ.get("POWERSHELF_TIMEOUT", "10"))
MAX_WORKERS        = int(os.environ.get("POWERSHELF_MAX_WORKERS", "16"))
SENSOR_WORKERS     = int(os.environ.get("POWERSHELF_SENSOR_WORKERS", "8"))
PSU_FW_EXPECTED    = os.environ.get("POWERSHELF_PSU_FW_EXPECTED", "0xf1 / 0xf1")
METADATA_REFRESH_CYCLES = int(os.environ.get("POWERSHELF_META_REFRESH", "60"))


def _expand_file(token: str) -> list[str]:
    path = token[1:]
    if not os.path.isfile(path):
        log.warning("POWERSHELF_HOSTS file not found: %s", path)
        return []
    out = []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                out.append(line)
    except OSError as e:
        log.warning("Cannot read POWERSHELF_HOSTS file %s: %s", path, e)
    return out


def expand_hosts(raw: str) -> list[str]:
    """Expand CSV / @file / CIDR into a deduplicated flat list of IP strings.

    Skips empty strings and the literal 0.0.0.0 (BCM stubs without an IP yet).
    """
    hosts: list[str] = []
    seen: set[str] = set()
    tokens: list[str] = []
    for tok in raw.split(","):
        tok = tok.strip()
        if not tok:
            continue
        if tok.startswith("@"):
            tokens.extend(_expand_file(tok))
        else:
            tokens.append(tok)
    for tok in tokens:
        try:
            net = ipaddress.ip_network(tok, strict=False)
            if net.num_addresses == 1:
                cand = [str(net.network_address)]
            else:
                cand = [str(h) for h in net.hosts()]
        except ValueError:
            cand = [tok]
        for ip in cand:
            if not ip or ip == "0.0.0.0":
                continue
            if ip in seen:
                continue
            seen.add(ip)
            hosts.append(ip)
    return hosts


HOSTS = expand_hosts(HOSTS_RAW)


# ---------------------------------------------------------------------------
# HTTP helper
# ---------------------------------------------------------------------------
# Set of (cycle_id, ip) tuples for which auth has failed this cycle. Any
# further GETs to that shelf in the same cycle are short-circuited. Resets each
# new cycle. Key includes cycle_id so a stale entry never leaks to a new cycle.
_AUTH_FAIL: set[tuple[int, str]] = set()


def redfish_get(ip: str, path: str, cycle_id: int,
                errors: dict[str, int]) -> tuple[dict | None, str | None]:
    """Authenticated GET against a shelf. Returns (body, error_type).

    error_type values: None on success, otherwise one of:
      "auth_failure", "timeout", "http_4xx", "http_5xx",
      "parse_error", "unreachable", "skipped_after_auth_fail"
    """
    if (cycle_id, ip) in _AUTH_FAIL:
        errors["skipped_after_auth_fail"] = errors.get("skipped_after_auth_fail", 0) + 1
        return None, "skipped_after_auth_fail"

    url = f"https://{ip}{path}"
    ctx = ssl.create_default_context()
    if not VERIFY_SSL:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE

    token = base64.b64encode(f"{USER}:{PASS}".encode()).decode()
    req = urllib.request.Request(url, headers={
        "Authorization": f"Basic {token}",
        "Accept":        "application/json",
        "OData-Version": "4.0",
    })
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=TIMEOUT) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            _AUTH_FAIL.add((cycle_id, ip))
            errors["auth_failure"] = errors.get("auth_failure", 0) + 1
            log.warning("%s %s HTTP %d (auth) — skipping shelf for rest of cycle",
                        ip, path, e.code)
            return None, "auth_failure"
        if 500 <= e.code < 600:
            errors["http_5xx"] = errors.get("http_5xx", 0) + 1
            return None, "http_5xx"
        if e.code in (404, 501):
            # Optional resource — not really an error
            return None, None
        errors["http_4xx"] = errors.get("http_4xx", 0) + 1
        return None, "http_4xx"
    except urllib.error.URLError as e:
        reason = str(getattr(e, "reason", e))
        if "timed out" in reason.lower() or "timeout" in reason.lower():
            errors["timeout"] = errors.get("timeout", 0) + 1
            return None, "timeout"
        errors["unreachable"] = errors.get("unreachable", 0) + 1
        return None, "unreachable"
    except (TimeoutError, OSError):
        errors["timeout"] = errors.get("timeout", 0) + 1
        return None, "timeout"
    except Exception as e:
        log.debug("%s %s unexpected: %s", ip, path, e)
        errors["unreachable"] = errors.get("unreachable", 0) + 1
        return None, "unreachable"

    try:
        return json.loads(raw), None
    except (ValueError, TypeError):
        errors["parse_error"] = errors.get("parse_error", 0) + 1
        return None, "parse_error"


# ---------------------------------------------------------------------------
# Sensor name parsing
# ---------------------------------------------------------------------------
_SENSOR_RE = re.compile(
    r"^(?P<type>voltage|current|power|temperature|fantach|utilization|frequency)"
    r"_(?P<scope>chassis|p[0-9]+|DC|ishare)"
    r"(?:_(?P<metric>.+))?$"
)

# Per-PSU mapping (regex scope matches p\d+):  type+metric -> prom suffix
PER_PSU_MAP = {
    ("voltage",     "vin"):       "psu_input_voltage_volts",
    ("voltage",     "vout"):      "psu_output_voltage_volts",
    ("current",     "iin"):       "psu_input_current_amps",
    ("current",     "iout"):      "psu_output_current_amps",
    ("power",       "pin"):       "psu_input_power_watts",
    ("power",       "pout"):      "psu_output_power_watts",
    ("temperature", "ambient"):   "psu_temp_ambient_celsius",
    ("temperature", "exhaust"):   "psu_temp_exhaust_celsius",
    ("temperature", "hotspot"):   "psu_temp_hotspot_celsius",
    ("fantach",     "fan1"):      "psu_fan_rpm",
    ("frequency",   "freqin"):    "psu_input_frequency_hz",
}

# Shelf-aggregate map: scope is "chassis" or "DC". key = (type, metric)
SHELF_MAP = {
    ("voltage",     "input_voltage"):    "input_voltage_volts",
    ("voltage",     "output_voltage"):   "output_voltage_volts",
    ("current",     "input_current"):    "input_current_amps",
    ("current",     "output_current"):   "output_current_amps",
    ("power",       "input_power"):      "input_power_watts",
    ("power",       "output_power"):     "output_power_watts",
    ("temperature", "temperature"):      "temp_chassis_celsius",
    ("temperature", "temp_plus"):        "temp_dc_plus_celsius",
    ("temperature", "temp_minus"):       "temp_dc_minus_celsius",
    ("utilization", "efficiency"):       "efficiency_pct",
    ("utilization", "load"):             "load_pct",
}

# Single-token sensors: current_ishare
ISHARE_METRIC = "ishare_amps"


def _coerce(value) -> float | None:
    if value is None:
        return None
    if isinstance(value, bool):
        return float(int(value))
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        s = value.strip()
        if not s:
            return None
        try:
            return float(s)
        except ValueError:
            return None
    return None


# ---------------------------------------------------------------------------
# Bulk-endpoint parsers (v1.2)
# ---------------------------------------------------------------------------
# Cache for ServiceRoot + Chassis bodies — static metadata, refresh every
# METADATA_REFRESH_CYCLES cycles. Per-ip tuple of (cycle_id_set, body).
_META_CACHE: dict[str, tuple[int, dict]] = {}
_ROOT_CACHE: dict[str, tuple[int, dict]] = {}

_PWR_PSU_DEV_RE   = re.compile(r"^powerdevice(\d+)$")
_PWR_VOLT_PSU_RE  = re.compile(r"^p(\d+)_(vin|vout)$")
_THERM_FAN_RE     = re.compile(r"^p(\d+)_fan\d+$")
_THERM_TEMP_PSU_RE = re.compile(r"^p(\d+)_(ambient|exhaust|hotspot)$")


def _missing_sensor_paths(sensors_link: str) -> list[str]:
    """The 25 sensor IDs whose readings are NOT in /Power or /Thermal."""
    base = sensors_link.rstrip("/")
    out: list[str] = []
    for n in range(6):
        out.append(f"{base}/current_p{n}_iin")
        out.append(f"{base}/current_p{n}_iout")
        out.append(f"{base}/power_p{n}_pout")
        out.append(f"{base}/frequency_p{n}_freqin")
    out.append(f"{base}/current_ishare")
    return out


def _parse_bulk_power(body: dict, data: dict) -> None:
    """Pull PSU identity + PowerInputWatts + Voltages + PowerLimit from /Power."""
    if not body:
        return
    for ps in body.get("PowerSupplies", []) or []:
        mid = ps.get("MemberId", "")
        m = _PWR_PSU_DEV_RE.match(mid)
        if not m:
            continue
        psu_idx = int(m.group(1))
        loc = ps.get("Location") or {}
        partloc = loc.get("PartLocation") or {}
        service_label = partloc.get("ServiceLabel", "") or loc.get("ServiceLabel", "")
        data["psus"].append({
            "id":             str(psu_idx),
            "psu":            str(psu_idx + 1),
            "model":          ps.get("Model", ""),
            "serial":         ps.get("SerialNumber", ""),
            "manufacturer":   ps.get("Manufacturer", ""),
            "hwversion":      ps.get("HardwareVersion", ""),
            "fwversion":      ps.get("FirmwareVersion", ""),
            "capacity_watts": None,
            "hot_pluggable":  1,
            "powered":        1 if ps.get("PowerState") else 0,
            "status_health":  (ps.get("Status") or {}).get("Health", ""),
            "status_state":   (ps.get("Status") or {}).get("State", ""),
            "service_label":  service_label,
        })
        piw = _coerce(ps.get("PowerInputWatts"))
        if piw is not None:
            data["psu_metrics"][(str(psu_idx), "psu_input_power_watts")] = piw

    data["psus"].sort(key=lambda p: int(p["id"]))

    mpw = _coerce(data.get("max_power_watts"))
    if mpw and data["psus"]:
        cap = mpw / len(data["psus"])
        for psu in data["psus"]:
            psu["capacity_watts"] = cap

    for v in body.get("Voltages", []) or []:
        mid = v.get("MemberId", "")
        reading = _coerce(v.get("ReadingVolts"))
        if reading is None:
            continue
        if mid == "chassis_input_voltage":
            data["shelf_metrics"]["input_voltage_volts"] = reading
        elif mid == "chassis_output_voltage":
            data["shelf_metrics"]["output_voltage_volts"] = reading
        else:
            vm = _PWR_VOLT_PSU_RE.match(mid)
            if vm:
                suffix = ("psu_input_voltage_volts" if vm.group(2) == "vin"
                          else "psu_output_voltage_volts")
                data["psu_metrics"][(vm.group(1), suffix)] = reading

    for pc in body.get("PowerControl", []) or []:
        pl = _coerce((pc.get("PowerLimit") or {}).get("LimitInWatts"))
        if pl is not None:
            data["shelf_metrics"]["power_limit_watts"] = pl
            break


def _parse_bulk_thermal(body: dict, data: dict) -> None:
    """Pull fan RPMs + all temperatures from /Thermal."""
    if not body:
        return
    for fan in body.get("Fans", []) or []:
        reading = _coerce(fan.get("Reading"))
        if reading is None:
            continue
        fm = _THERM_FAN_RE.match(fan.get("MemberId", ""))
        if fm:
            data["psu_metrics"][(fm.group(1), "psu_fan_rpm")] = reading

    for t in body.get("Temperatures", []) or []:
        mid = t.get("MemberId", "")
        reading = _coerce(t.get("ReadingCelsius"))
        if reading is None:
            continue
        if mid == "chassis_temperature":
            data["shelf_metrics"]["temp_chassis_celsius"] = reading
        elif mid == "DC_temp_plus":
            data["shelf_metrics"]["temp_dc_plus_celsius"] = reading
        elif mid == "DC_temp_minus":
            data["shelf_metrics"]["temp_dc_minus_celsius"] = reading
        else:
            tm = _THERM_TEMP_PSU_RE.match(mid)
            if tm:
                data["psu_metrics"][(tm.group(1),
                                     f"psu_temp_{tm.group(2)}_celsius")] = reading


def _derive_chassis_metrics(data: dict) -> None:
    """Sum per-PSU values into chassis aggregates the firmware doesn't bulk-expose."""
    pin_sum = pout_sum = iin_sum = iout_sum = 0.0
    pin_n = pout_n = iin_n = iout_n = 0
    for (_idx, suffix), val in data["psu_metrics"].items():
        if   suffix == "psu_input_power_watts":     pin_sum  += val; pin_n  += 1
        elif suffix == "psu_output_power_watts":    pout_sum += val; pout_n += 1
        elif suffix == "psu_input_current_amps":    iin_sum  += val; iin_n  += 1
        elif suffix == "psu_output_current_amps":   iout_sum += val; iout_n += 1

    sm = data["shelf_metrics"]
    if pin_n:  sm["input_power_watts"]   = pin_sum
    if pout_n: sm["output_power_watts"]  = pout_sum
    if iin_n:  sm["input_current_amps"]  = iin_sum
    if iout_n: sm["output_current_amps"] = iout_sum
    if pin_n and pout_n and pin_sum > 0:
        sm["efficiency_pct"] = max(0.0, min(100.0, (pout_sum / pin_sum) * 100.0))
    mpw = _coerce(data.get("max_power_watts"))
    if mpw and mpw > 0 and pout_n:
        sm["load_pct"] = max(0.0, (pout_sum / mpw) * 100.0)


# ---------------------------------------------------------------------------
# Per-shelf collector
# ---------------------------------------------------------------------------
def collect_shelf(ip: str, cycle_id: int) -> dict:
    t0 = time.time()
    errors: dict[str, int] = {}
    data: dict = {
        "ip":            ip,
        "reachable":     False,
        "scrape_success": False,
        "errors":        errors,
        "duration":      0.0,
        # Chassis-level
        "model":         "",
        "manufacturer":  "",
        "serial":        "",
        "partnumber":    "",
        "hwversion":     "",
        "max_power_watts": None,
        "status_health": "",
        "redfish_version": "",
        "uuid":          "",
        "psus":          [],   # list of dicts per PSU
        "shelf_metrics": {},   # name -> float
        "psu_metrics":   {},   # (psu_id, name) -> float
    }

    # --- 1. Static metadata: ServiceRoot + Chassis, cached for N cycles. ---
    chassis = None
    root: dict | None = None
    cached_root_cycle, cached_root = _ROOT_CACHE.get(ip, (-10**9, None))
    cached_meta_cycle, cached_meta = _META_CACHE.get(ip, (-10**9, None))
    if cached_meta and (cycle_id - cached_meta_cycle) < METADATA_REFRESH_CYCLES:
        chassis = cached_meta
        root    = cached_root
    else:
        root, _ = redfish_get(ip, "/redfish/v1/", cycle_id, errors)
        chassis, _ = redfish_get(ip, "/redfish/v1/Chassis/powershelf",
                                 cycle_id, errors)
        if not chassis:
            coll, _ = redfish_get(ip, "/redfish/v1/Chassis", cycle_id, errors)
            if coll:
                members = coll.get("Members", []) or []
                if members:
                    first = members[0].get("@odata.id", "")
                    if first:
                        chassis, _ = redfish_get(ip, first, cycle_id, errors)
        if chassis:
            _META_CACHE[ip] = (cycle_id, chassis)
            _ROOT_CACHE[ip] = (cycle_id, root or {})

    if not chassis:
        data["duration"] = round(time.time() - t0, 3)
        return data

    data["redfish_version"] = (root or {}).get("RedfishVersion", "")
    data["uuid"]            = (root or {}).get("UUID", "")
    data["model"]           = chassis.get("Model", "")
    data["manufacturer"]    = chassis.get("Manufacturer", "")
    data["serial"]          = chassis.get("SerialNumber", "")
    data["partnumber"]      = chassis.get("PartNumber", "")
    data["hwversion"]       = chassis.get("HardwareVersion", "")
    data["max_power_watts"] = chassis.get("MaxPowerWatts")
    data["status_health"]   = (chassis.get("Status") or {}).get("Health", "")

    chassis_id   = chassis.get("@odata.id", "/redfish/v1/Chassis/powershelf").rstrip("/")
    sensors_link = (chassis.get("Sensors") or {}).get("@odata.id",
                                                      f"{chassis_id}/Sensors")
    power_link   = f"{chassis_id}/Power"
    thermal_link = f"{chassis_id}/Thermal"

    # --- 2. Bulk fetch of /Power + /Thermal in parallel.
    # Two GETs return 41 sensor readings + 6 PSU identities + PowerLimit.
    with ThreadPoolExecutor(max_workers=2) as ex:
        f_power   = ex.submit(redfish_get, ip, power_link,   cycle_id, errors)
        f_thermal = ex.submit(redfish_get, ip, thermal_link, cycle_id, errors)
        power_body,   _ = f_power.result()
        thermal_body, _ = f_thermal.result()

    _parse_bulk_power(power_body, data)
    _parse_bulk_thermal(thermal_body, data)

    # --- 3. Per-sensor fan-out.
    # Happy path: only the 25 readings missing from /Power+/Thermal.
    # Degraded path (either bulk failed): walk the full /Sensors collection
    # the same way v1.0 did, so we never lose visibility.
    used_fallback = (power_body is None) or (thermal_body is None)
    if used_fallback:
        sensor_coll, _ = redfish_get(ip, sensors_link, cycle_id, errors)
        sensor_paths: list[str] = []
        if sensor_coll:
            for m in sensor_coll.get("Members", []) or []:
                p = m.get("@odata.id", "")
                if p:
                    sensor_paths.append(p)
    else:
        sensor_paths = _missing_sensor_paths(sensors_link)

    def _fetch_sensor(p: str):
        body, _e = redfish_get(ip, p, cycle_id, errors)
        return p, body

    if sensor_paths:
        with ThreadPoolExecutor(max_workers=min(SENSOR_WORKERS, len(sensor_paths))) as ex:
            sensor_results = list(ex.map(_fetch_sensor, sensor_paths))
    else:
        sensor_results = []

    for path, body in sensor_results:
        if not body:
            continue
        # The LiteOn firmware strips the leading "{type}_" from Sensor.Id
        # (URL "/Sensors/current_p0_iin" returns Id "p0_iin"), so we MUST
        # parse the URL tail to keep the type prefix _SENSOR_RE expects.
        sid     = path.rstrip("/").rsplit("/", 1)[-1]
        reading = _coerce(body.get("Reading"))
        if reading is None:
            continue
        m = _SENSOR_RE.match(sid)
        if not m:
            continue
        typ    = m.group("type")
        scope  = m.group("scope")
        metric = m.group("metric") or ""

        if scope.startswith("p") and len(scope) > 1 and scope[1:].isdigit():
            suffix = PER_PSU_MAP.get((typ, metric))
            if suffix:
                data["psu_metrics"][(scope[1:], suffix)] = reading
            continue

        if scope == "chassis":
            suffix = SHELF_MAP.get((typ, metric))
            if suffix:
                data["shelf_metrics"][suffix] = reading
            continue

        if scope == "DC":
            suffix = SHELF_MAP.get(("temperature", metric))
            if suffix:
                data["shelf_metrics"][suffix] = reading
            continue

        if scope == "ishare" and typ == "current":
            data["shelf_metrics"][ISHARE_METRIC] = reading

    # --- 4. Derive chassis aggregates when bulk path succeeded.
    if not used_fallback:
        _derive_chassis_metrics(data)

    # --- 5. Reachability + scrape success.
    if data["shelf_metrics"] or data["psus"] or data["psu_metrics"]:
        data["reachable"] = True
        data["scrape_success"] = True

    data["duration"] = round(time.time() - t0, 3)
    return data


# ---------------------------------------------------------------------------
# Metric rendering
# ---------------------------------------------------------------------------
# Counter-style state — survives across cycles per (shelf, error_type).
_ERR_TOTALS: dict[tuple[str, str], int] = {}
_LAST_HOST_HEALTH: dict[str, dict] = {}


def _esc(s) -> str:
    return str(s).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def render(results: list[dict]) -> str:
    cluster = CLUSTER_NAME
    out: list[str] = []

    def add(name, labels: dict, value):
        if not labels:
            out.append(f"{name} {value}")
            return
        lstr = ",".join(f'{k}="{_esc(v)}"' for k, v in labels.items())
        out.append(f"{name}{{{lstr}}} {value}")

    # ── exporter liveness ────────────────────────────────────────────────────
    out.append("# HELP nvis_powershelf_up 1 if the exporter process is alive")
    out.append("# TYPE nvis_powershelf_up gauge")
    add("nvis_powershelf_up", {"cluster": cluster}, 1)

    # ── per-shelf scrape health ──────────────────────────────────────────────
    out.append("\n# HELP nvis_powershelf_scrape_success 1 if last scrape succeeded")
    out.append("# TYPE nvis_powershelf_scrape_success gauge")
    out.append("# HELP nvis_powershelf_scrape_duration_seconds Last scrape duration")
    out.append("# TYPE nvis_powershelf_scrape_duration_seconds gauge")
    out.append("# HELP nvis_powershelf_scrape_errors_total Cumulative scrape errors")
    out.append("# TYPE nvis_powershelf_scrape_errors_total counter")
    for r in results:
        base = {"cluster": cluster, "shelf": r["ip"]}
        add("nvis_powershelf_scrape_success", base, 1 if r["scrape_success"] else 0)
        add("nvis_powershelf_scrape_duration_seconds", base, r["duration"])
        for et, count in r["errors"].items():
            tot_key = (r["ip"], et)
            _ERR_TOTALS[tot_key] = _ERR_TOTALS.get(tot_key, 0) + count
    for (shelf, et), total in _ERR_TOTALS.items():
        add("nvis_powershelf_scrape_errors_total",
            {"cluster": cluster, "shelf": shelf, "error_type": et}, total)

    # ── chassis info + health ────────────────────────────────────────────────
    out.append("\n# HELP nvis_powershelf_info Shelf identity (value always 1)")
    out.append("# TYPE nvis_powershelf_info gauge")
    out.append("# HELP nvis_powershelf_status_ok 1 if shelf Status.Health == OK")
    out.append("# TYPE nvis_powershelf_status_ok gauge")
    out.append("# HELP nvis_powershelf_max_power_watts Shelf MaxPowerWatts (constant 33000)")
    out.append("# TYPE nvis_powershelf_max_power_watts gauge")
    for r in results:
        if not r["reachable"]:
            continue
        add("nvis_powershelf_info", {
            "cluster":         cluster,
            "shelf":           r["ip"],
            "model":           r["model"],
            "partnumber":      r["partnumber"],
            "serial":          r["serial"],
            "hwversion":       r["hwversion"],
            "manufacturer":    r["manufacturer"],
            "ip":              r["ip"],
            "redfish_version": r["redfish_version"],
        }, 1)
        add("nvis_powershelf_status_ok",
            {"cluster": cluster, "shelf": r["ip"], "status": r["status_health"]},
            1 if str(r["status_health"]).upper() == "OK" else 0)
        if r["max_power_watts"] is not None:
            add("nvis_powershelf_max_power_watts",
                {"cluster": cluster, "shelf": r["ip"]},
                _coerce(r["max_power_watts"]))

    # ── shelf-level aggregate metrics ────────────────────────────────────────
    SHELF_NAMES = sorted({v for v in SHELF_MAP.values()}
                         | {ISHARE_METRIC}
                         | {"power_limit_watts"})
    SHELF_HELP = {
        "input_voltage_volts":   "Shelf AC input voltage (V)",
        "output_voltage_volts":  "Shelf DC output voltage (V)",
        "input_current_amps":    "Shelf AC input current (A, sum of PSU iin in v1.2)",
        "output_current_amps":   "Shelf DC output current (A, sum of PSU iout in v1.2)",
        "input_power_watts":     "Shelf AC input power (W, sum of PSU PowerInputWatts in v1.2)",
        "output_power_watts":    "Shelf DC output power (W, sum of PSU pout in v1.2)",
        "temp_chassis_celsius":  "Shelf ambient/chassis temperature (degC)",
        "temp_dc_plus_celsius":  "DC bus + temperature (degC)",
        "temp_dc_minus_celsius": "DC bus - temperature (degC)",
        "efficiency_pct":        "Shelf utilization efficiency (percent, derived in v1.2)",
        "load_pct":              "Shelf utilization load (percent, derived in v1.2)",
        "ishare_amps":           "Current-share balance (A)",
        "power_limit_watts":     "Shelf PowerControl.PowerLimit.LimitInWatts (W)",
    }
    for name in SHELF_NAMES:
        mname = f"nvis_powershelf_{name}"
        out.append(f"\n# HELP {mname} {SHELF_HELP.get(name, name)}")
        out.append(f"# TYPE {mname} gauge")
        for r in results:
            if not r["reachable"]:
                continue
            v = r["shelf_metrics"].get(name)
            if v is None:
                continue
            add(mname, {"cluster": cluster, "shelf": r["ip"]}, v)

    # ── PSU info + status ────────────────────────────────────────────────────
    out.append("\n# HELP nvis_powershelf_psu_info PSU identity (value always 1)")
    out.append("# TYPE nvis_powershelf_psu_info gauge")
    out.append("# HELP nvis_powershelf_psu_status_ok 1 if PSU Status.Health == OK")
    out.append("# TYPE nvis_powershelf_psu_status_ok gauge")
    out.append("# HELP nvis_powershelf_psu_powered 1 if PSU PowerState truthy")
    out.append("# TYPE nvis_powershelf_psu_powered gauge")
    out.append("# HELP nvis_powershelf_psu_capacity_watts PSU CapacityWatts (constant 5500)")
    out.append("# TYPE nvis_powershelf_psu_capacity_watts gauge")
    out.append("# HELP nvis_powershelf_psu_fw_compliant 1 if PSU FW matches expected baseline")
    out.append("# TYPE nvis_powershelf_psu_fw_compliant gauge")
    for r in results:
        if not r["reachable"]:
            continue
        for psu in r["psus"]:
            base = {"cluster": cluster, "shelf": r["ip"], "psu": psu["psu"]}
            add("nvis_powershelf_psu_info", {
                **base,
                "model":         psu["model"],
                "serial":        psu["serial"],
                "fwversion":     psu["fwversion"],
                "hwversion":     psu["hwversion"],
                "manufacturer":  psu["manufacturer"],
                "service_label": psu["service_label"],
            }, 1)
            add("nvis_powershelf_psu_status_ok",
                {**base, "status": psu["status_health"], "state": psu["status_state"]},
                1 if str(psu["status_health"]).upper() == "OK" else 0)
            add("nvis_powershelf_psu_powered", base, psu["powered"])
            if psu["capacity_watts"] is not None:
                add("nvis_powershelf_psu_capacity_watts", base, psu["capacity_watts"])
            actual_fw = psu["fwversion"]
            compliant = 1 if actual_fw and actual_fw == PSU_FW_EXPECTED else 0
            add("nvis_powershelf_psu_fw_compliant", {
                **base,
                "expected": PSU_FW_EXPECTED,
                "actual":   actual_fw,
            }, compliant)

    # ── PSU live telemetry metrics ───────────────────────────────────────────
    PSU_NAMES = sorted(set(PER_PSU_MAP.values()))
    PSU_HELP = {
        "psu_input_voltage_volts":   "PSU AC input voltage (V)",
        "psu_output_voltage_volts":  "PSU DC output voltage (V)",
        "psu_input_current_amps":    "PSU AC input current (A)",
        "psu_output_current_amps":   "PSU DC output current (A)",
        "psu_input_power_watts":     "PSU AC input power (W)",
        "psu_output_power_watts":    "PSU DC output power (W)",
        "psu_temp_ambient_celsius":  "PSU intake/ambient temperature (degC)",
        "psu_temp_exhaust_celsius":  "PSU exhaust temperature (degC)",
        "psu_temp_hotspot_celsius":  "PSU hotspot temperature (degC)",
        "psu_fan_rpm":               "PSU fan speed (RPM)",
        "psu_input_frequency_hz":    "PSU AC input frequency (Hz)",
    }
    for name in PSU_NAMES:
        mname = f"nvis_powershelf_{name}"
        out.append(f"\n# HELP {mname} {PSU_HELP.get(name, name)}")
        out.append(f"# TYPE {mname} gauge")
        for r in results:
            if not r["reachable"]:
                continue
            for (psu_n, suffix), val in r["psu_metrics"].items():
                if suffix != name:
                    continue
                add(mname, {"cluster": cluster, "shelf": r["ip"], "psu": psu_n}, val)

    return "\n".join(out) + "\n"


# ---------------------------------------------------------------------------
# Scrape loop
# ---------------------------------------------------------------------------
_lock          = threading.Lock()
_latest        = ""
_ready         = threading.Event()
_force_refresh = threading.Event()
_cycle_counter = 0


def scrape_all(cycle_id: int) -> list[dict]:
    if not HOSTS:
        return []
    workers = max(1, min(MAX_WORKERS, len(HOSTS)))
    results: list[dict] = []
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futures = {ex.submit(_safe_collect, ip, cycle_id): ip for ip in HOSTS}
        for fut in as_completed(futures):
            ip = futures[fut]
            try:
                results.append(fut.result())
            except Exception as e:
                log.warning("collect_shelf(%s) raised %s", ip, e)
                results.append({
                    "ip":            ip,
                    "reachable":     False,
                    "scrape_success": False,
                    "errors":        {"unreachable": 1},
                    "duration":      0.0,
                    "model":         "", "manufacturer": "", "serial": "",
                    "partnumber":    "", "hwversion": "", "max_power_watts": None,
                    "status_health": "", "redfish_version": "", "uuid": "",
                    "psus":          [], "shelf_metrics": {}, "psu_metrics": {},
                })
    # preserve original input order so dashboards have stable axes
    by_ip = {r["ip"]: r for r in results}
    return [by_ip[ip] for ip in HOSTS if ip in by_ip]


def _safe_collect(ip: str, cycle_id: int) -> dict:
    try:
        return collect_shelf(ip, cycle_id)
    except Exception as e:
        log.warning("collect_shelf(%s) raised: %s", ip, e)
        return {
            "ip":            ip,
            "reachable":     False,
            "scrape_success": False,
            "errors":        {"unreachable": 1},
            "duration":      0.0,
            "model":         "", "manufacturer": "", "serial": "",
            "partnumber":    "", "hwversion": "", "max_power_watts": None,
            "status_health": "", "redfish_version": "", "uuid": "",
            "psus":          [], "shelf_metrics": {}, "psu_metrics": {},
        }


def scrape_loop():
    global _latest, _cycle_counter
    while True:
        _cycle_counter += 1
        cycle_id = _cycle_counter
        # purge auth-fail entries from prior cycles
        stale = {k for k in _AUTH_FAIL if k[0] != cycle_id}
        for k in stale:
            _AUTH_FAIL.discard(k)

        if not HOSTS:
            log.info("idle — no POWERSHELF_HOSTS configured")
            metrics = render([])
            with _lock:
                _latest = metrics
            _ready.set()
            triggered = _force_refresh.wait(timeout=SCRAPE_INTERVAL)
            if triggered:
                _force_refresh.clear()
            continue

        t0 = time.time()
        log.info("scrape cycle %d — %d shelf host(s)", cycle_id, len(HOSTS))
        results = scrape_all(cycle_id)
        dur = time.time() - t0
        up = sum(1 for r in results if r["scrape_success"])
        log.info("scrape cycle %d — %d/%d shelves succeeded in %.1fs",
                 cycle_id, up, len(results), dur)

        metrics = render(results)
        with _lock:
            _latest = metrics
        _ready.set()

        triggered = _force_refresh.wait(timeout=SCRAPE_INTERVAL)
        if triggered:
            _force_refresh.clear()


# ---------------------------------------------------------------------------
# HTTP server
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # silence access log
        pass

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/metrics", "/"):
            _ready.wait(timeout=60)
            with _lock:
                body = _latest.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif path == "/-/healthy":
            self.send_response(200); self.end_headers()
            self.wfile.write(b"OK\n")
        elif path == "/refresh":
            _force_refresh.set()
            body = b'{"status":"refresh triggered"}\n'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()

    def do_POST(self):
        if self.path.split("?", 1)[0] == "/refresh":
            _force_refresh.set()
            body = b'{"status":"refresh triggered"}\n'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    log.info("NVIS PowerShelf Exporter starting")
    log.info("  POWERSHELF_HOSTS : %d shelf(es)%s", len(HOSTS),
             ("" if not HOSTS else " — " + ", ".join(HOSTS[:5]) +
              ("..." if len(HOSTS) > 5 else "")))
    log.info("  POWERSHELF_USER  : %s", USER)
    log.info("  CLUSTER_NAME     : %s", CLUSTER_NAME)
    log.info("  PORT             : %d", PORT)
    log.info("  SCRAPE_INTERVAL  : %ds", SCRAPE_INTERVAL)
    log.info("  TIMEOUT          : %ds", TIMEOUT)
    log.info("  MAX_WORKERS      : %d shelves × %d sensors", MAX_WORKERS, SENSOR_WORKERS)
    log.info("  VERIFY_SSL       : %s", VERIFY_SSL)
    log.info("  PSU FW expected  : %s", PSU_FW_EXPECTED)
    if not HOSTS:
        log.warning("POWERSHELF_HOSTS is empty — running idle. /metrics will "
                    "expose only nvis_powershelf_up. This is intentional for "
                    "sites without LiteOn shelves.")

    t = threading.Thread(target=scrape_loop, daemon=True)
    t.start()

    server = HTTPServer(("", PORT), Handler)
    log.info("Metrics available at http://0.0.0.0:%d/metrics", PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down.")
