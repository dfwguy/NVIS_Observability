#!/usr/bin/env python3
"""IPMI SEL exporter -- runs `ipmitool sel elist` per BMC and pushes new
entries to Loki.

Captures everything the BMC's IPMI SEL contains, including:
  - Processor IERR events (Redfish LogService drops these on some BMCs)
  - Nvidia OEM SEL types (SEL_FAN_BEHAVIOR, SEL_BB_HEALTH, SEL_BMC_DIAG, ...)
  - Standard sensor assert/deassert lines with the same human-readable text
    that ipmitool prints in a terminal

Loki stream labels: {job="ipmi-sel", cluster, bmc, severity, sensor_type}
Severity is classified in-process from message keywords because ipmitool doesn't
emit it (IERR / Thermal Trip / S5/G2 / OVERT / Drive Fault -> Critical,
threshold crossings + Deasserted -> Warning, everything else -> OK).

Env:
  BMC_CREDS_JSON     JSON list of {"bmc":..,"user":..,"pass":..} (required)
  CLUSTER_NAME       label, default ""
  LOKI_URL           e.g. http://nvis-loki:3100/loki/api/v1/push (required)
  POLL_INTERVAL      seconds between cycles, default 300
  IPMITOOL_TIMEOUT   per-BMC timeout, default 240 (must be >=240 for B-class
                     systems with large SELs)
  STATE_DIR          base dir for watermark file
                     (default: /var/lib/nvis-platform)
  WATERMARK_PATH     override the full watermark file path
                     (default: $STATE_DIR/ipmi-sel-watermark.json)
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.request


CLUSTER_NAME     = os.environ.get("CLUSTER_NAME", "")
LOKI_URL         = os.environ.get("LOKI_URL", "")
POLL_INTERVAL    = int(os.environ.get("POLL_INTERVAL", "300"))
IPMITOOL_TIMEOUT = int(os.environ.get("IPMITOOL_TIMEOUT", "240"))
STATE_DIR        = os.environ.get("STATE_DIR", "/var/lib/nvis-platform")
WATERMARK_PATH   = os.environ.get(
    "WATERMARK_PATH", os.path.join(STATE_DIR, "ipmi-sel-watermark.json"))

if not LOKI_URL:
    print("LOKI_URL required", file=sys.stderr)
    sys.exit(1)
_creds_raw = os.environ.get("BMC_CREDS_JSON", "")
if not _creds_raw:
    print("BMC_CREDS_JSON required (JSON list of {bmc,user,pass})", file=sys.stderr)
    sys.exit(1)
BMC_CREDS = json.loads(_creds_raw)

_CRIT = re.compile(
    r"(?i)\b("
    r"IERR|Thermal Trip|Drive Fault|Predictive Failure|OVERT|"
    r"S5/G2|S5 G2|Soft Off|Non-recoverable|"
    r"Upper Critical going|Lower Critical going"
    r")\b"
)
_WARN = re.compile(
    r"(?i)\b("
    r"Upper Non-critical going|Lower Non-critical going|"
    r"HMC.*Absent|Deasserted"
    r")\b"
)

_SEL_LINE = re.compile(
    r"^\s*([0-9a-fA-F]+)\s*\|"
    r"\s*([^|]+)\s*\|"
    r"\s*([^|]+)\s*\|"
    r"\s*([^|]+)\s*\|"
    r"\s*([^|]*)\s*\|"
    r"\s*(.+)$"
)


def log(msg: str) -> None:
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)


def load_watermark() -> dict:
    try:
        with open(WATERMARK_PATH) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_watermark(wm: dict) -> None:
    os.makedirs(os.path.dirname(WATERMARK_PATH), exist_ok=True)
    tmp = WATERMARK_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(wm, f)
    os.replace(tmp, WATERMARK_PATH)


def classify(line: str) -> str:
    if _CRIT.search(line):
        return "Critical"
    if _WARN.search(line):
        return "Warning"
    return "OK"


def run_ipmitool(bmc: str, user: str, password: str) -> str | None:
    cmd = ["ipmitool", "-I", "lanplus", "-H", bmc, "-U", user, "-P", password,
           "sel", "elist"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=IPMITOOL_TIMEOUT)
    except subprocess.TimeoutExpired:
        log(f"  {bmc}: ipmitool timed out after {IPMITOOL_TIMEOUT}s")
        return None
    except FileNotFoundError:
        log("ipmitool binary not found in PATH")
        return None
    if r.returncode != 0:
        log(f"  {bmc}: ipmitool rc={r.returncode} stderr={r.stderr.strip()[:200]}")
        return None
    return r.stdout


def parse(output: str) -> list[dict]:
    out = []
    for raw in output.splitlines():
        m = _SEL_LINE.match(raw)
        if not m:
            continue
        rid_hex = m.group(1).strip()
        try:
            rid = int(rid_hex, 16)
        except ValueError:
            continue
        out.append({
            "record_id":     rid,
            "record_id_hex": rid_hex,
            "bmc_date":      m.group(2).strip(),
            "bmc_time":      m.group(3).strip(),
            "sensor":        m.group(4).strip(),
            "event_type":    m.group(5).strip(),
            "action":        m.group(6).strip(),
            "raw":           raw.strip(),
        })
    return out


def push_loki(new_by_bmc: dict[str, list[dict]]) -> None:
    if not new_by_bmc:
        return
    streams = []
    for bmc, entries in new_by_bmc.items():
        groups: dict[tuple[str, str], list[dict]] = {}
        for e in entries:
            sev = classify(e["raw"])
            stype = (e["sensor"].split() or ["unknown"])[0]
            groups.setdefault((sev, stype), []).append(e)
        for (sev, stype), ents in groups.items():
            now_ns = int(time.time() * 1e9)
            values = []
            for e in ents:
                body = json.dumps({
                    "bmc":            bmc,
                    "cluster":        CLUSTER_NAME,
                    "record_id":      e["record_id"],
                    "record_id_hex":  e["record_id_hex"],
                    "bmc_date":       e["bmc_date"],
                    "bmc_time":       e["bmc_time"],
                    "sensor":         e["sensor"],
                    "event_type":     e["event_type"],
                    "action":         e["action"],
                    "message":        e["raw"],
                })
                values.append([str(now_ns), body])
                now_ns += 1
            streams.append({
                "stream": {
                    "job":         "ipmi-sel",
                    "cluster":     CLUSTER_NAME,
                    "bmc":         bmc,
                    "severity":    sev,
                    "sensor_type": stype,
                },
                "values": values,
            })
    payload = json.dumps({"streams": streams}).encode("utf-8")
    req = urllib.request.Request(
        LOKI_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            if r.status >= 300:
                log(f"loki push HTTP {r.status}: {r.read()[:300]!r}")
    except Exception as e:
        log(f"loki push failed: {e}")


def main() -> None:
    wm = load_watermark()
    log(f"start bmcs={len(BMC_CREDS)} loki={LOKI_URL} interval={POLL_INTERVAL}s "
        f"ipmitool_timeout={IPMITOOL_TIMEOUT}s watermark={WATERMARK_PATH}")
    while True:
        cycle_start = time.time()
        new_by_bmc: dict[str, list[dict]] = {}
        for bc in BMC_CREDS:
            bmc, user, password = bc["bmc"], bc["user"], bc["pass"]
            out = run_ipmitool(bmc, user, password)
            if out is None:
                continue
            entries = parse(out)
            last_rid = wm.get(bmc, -1)
            new = [e for e in entries if e["record_id"] > last_rid]
            if new:
                log(f"  {bmc}: total={len(entries)} new={len(new)} "
                    f"(since RID {last_rid+1})")
                new_by_bmc[bmc] = new
                wm[bmc] = max(e["record_id"] for e in entries)
            else:
                log(f"  {bmc}: total={len(entries)} new=0")
        if new_by_bmc:
            push_loki(new_by_bmc)
            save_watermark(wm)
        elapsed = time.time() - cycle_start
        sleep_for = max(0, POLL_INTERVAL - elapsed)
        log(f"cycle {elapsed:.1f}s, sleep {sleep_for:.0f}s")
        time.sleep(sleep_for)


if __name__ == "__main__":
    main()
