#!/usr/bin/env python3
"""
NVIS Platform SOL (Serial-over-LAN) Capture Daemon
==================================================
For each configured BMC, spawns one long-running `ipmitool sol activate`
subprocess and tees its output to a per-BMC log file (under $LOG_DIR/sol)
with ISO-8601 timestamps. May also push every line to Loki under
{job="ipmi-sol", cluster, bmc}.

Design rules:
  - One ipmitool subprocess per BMC, never more.
  - Yield to manual admin sessions (only one SOL session per BMC at a time --
    exit cleanly and back off on contention, do NOT fight).
  - `sol deactivate` is issued first to flush stale sessions left over from
    previous runs / crashed daemons, then `sol activate`.
  - Exponential backoff on consecutive failures, reset after stable
    uptime > 5 minutes.
  - SIGTERM/SIGINT -> tear down every child with `sol deactivate`.

Environment variables:
  BMC_CREDS_JSON     JSON list of {"bmc":..,"user":..,"pass":..} (required;
                     if absent, falls back to BMC_HOSTS+BMC_USER+BMC_PASS)
  BMC_HOSTS          Comma-separated IPs / CIDRs (fallback to creds JSON)
  BMC_USER           default "root"
  BMC_PASS           (only used in fallback mode)
  CLUSTER_NAME       label string used in Loki stream + log
  LOG_DIR            base log dir; SOL logs go to $LOG_DIR/sol/<bmc>.log
                     (default: /var/log/nvis-platform)
  SOL_LOG_DIR        override the SOL log dir entirely (takes precedence)
  DEACTIVATE_FIRST   "true" to send `sol deactivate` first (default: true)
  RETRY_BACKOFF      Initial backoff after subprocess exit, seconds (default: 30)
  MAX_RETRY_BACKOFF  Maximum backoff, seconds (default: 300)
  LOKI_URL           e.g. http://nvis-loki:3100/loki/api/v1/push (optional)
  LOKI_FLUSH_SECS    flush batch every N seconds (default: 2)
  LOKI_FLUSH_LINES   flush batch every N lines (default: 50)
"""

import os
import pty
import sys
import time
import json
import signal
import logging
import threading
import ipaddress
import subprocess
import urllib.request
from datetime import datetime, timezone

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    stream=sys.stderr,
)
log = logging.getLogger("sol-capture")

BMC_HOSTS_RAW     = os.environ.get("BMC_HOSTS",         "")
BMC_USER          = os.environ.get("BMC_USER",          "root")
BMC_PASS          = os.environ.get("BMC_PASS",          "")
BMC_CREDS_JSON    = os.environ.get("BMC_CREDS_JSON",    "")
CLUSTER_NAME      = os.environ.get("CLUSTER_NAME",      "")
LOG_DIR           = os.environ.get("LOG_DIR",           "/var/log/nvis-platform")
SOL_LOG_DIR       = os.environ.get("SOL_LOG_DIR",       os.path.join(LOG_DIR, "sol"))
DEACTIVATE_FIRST  = os.environ.get("DEACTIVATE_FIRST",  "true").lower() == "true"
RETRY_BACKOFF     = int(os.environ.get("RETRY_BACKOFF",      "30"))
MAX_RETRY_BACKOFF = int(os.environ.get("MAX_RETRY_BACKOFF",  "300"))
STABLE_RESET_SECS = 300
LOKI_URL          = os.environ.get("LOKI_URL",           "")
LOKI_FLUSH_SECS   = float(os.environ.get("LOKI_FLUSH_SECS", "2"))
LOKI_FLUSH_LINES  = int(os.environ.get("LOKI_FLUSH_LINES", "50"))

_shutdown = threading.Event()
_children: dict[str, subprocess.Popen] = {}
_children_lock = threading.Lock()


def expand_hosts(raw: str) -> list[str]:
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


def _ipmi_base(bmc: str, user: str, password: str) -> list[str]:
    return ["ipmitool", "-I", "lanplus", "-H", bmc, "-U", user, "-P", password]


def _iso_now() -> str:
    return datetime.now(timezone.utc).strftime("[%Y-%m-%dT%H:%M:%SZ] ")


def _deactivate(bmc: str, user: str, password: str) -> None:
    """Best-effort `sol deactivate`. Stale-session error is expected and ignored."""
    try:
        subprocess.run(
            _ipmi_base(bmc, user, password) + ["sol", "deactivate"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=15,
        )
    except Exception as e:
        log.debug("%s: deactivate failed (ok if no session): %s", bmc, e)


def _loki_push(bmc: str, batch: list) -> None:
    """POST a batch of (ts_ns, line) tuples to Loki under stream
    {job=ipmi-sol, cluster=<>, bmc=<ip>}. No-op if LOKI_URL unset."""
    if not LOKI_URL or not batch:
        return
    body = json.dumps({"streams": [{
        "stream": {"job": "ipmi-sol", "cluster": CLUSTER_NAME, "bmc": bmc},
        "values": [[ts, line] for ts, line in batch],
    }]}).encode("utf-8")
    try:
        req = urllib.request.Request(
            LOKI_URL, data=body,
            headers={"Content-Type": "application/json"}, method="POST",
        )
        urllib.request.urlopen(req, timeout=5)
    except Exception as e:
        log.warning("%s: Loki push failed: %s", bmc, e)


def capture_loop(bmc: str, user: str, password: str) -> None:
    log_path = os.path.join(SOL_LOG_DIR, f"{bmc}.log")
    backoff = RETRY_BACKOFF
    log.info("%s: starting capture (user=%s) -> %s", bmc, user, log_path)

    while not _shutdown.is_set():
        if DEACTIVATE_FIRST:
            _deactivate(bmc, user, password)

        master_fd, slave_fd = pty.openpty()
        try:
            proc = subprocess.Popen(
                _ipmi_base(bmc, user, password) + ["sol", "activate"],
                stdin=slave_fd,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                bufsize=1, text=True, errors="replace",
                close_fds=True,
            )
        except FileNotFoundError:
            os.close(master_fd)
            os.close(slave_fd)
            log.error("ipmitool not found in PATH -- install ipmitool package")
            return
        except Exception as e:
            os.close(master_fd)
            os.close(slave_fd)
            log.error("%s: failed to spawn ipmitool: %s", bmc, e)
            if _shutdown.wait(backoff):
                return
            backoff = min(backoff * 2, MAX_RETRY_BACKOFF)
            continue

        os.close(slave_fd)

        with _children_lock:
            _children[bmc] = proc
        log.info("%s: SOL session active (pid=%d)", bmc, proc.pid)
        started = time.monotonic()

        loki_batch: list = []
        last_flush = time.monotonic()

        try:
            with open(log_path, "a", encoding="utf-8") as fh:
                assert proc.stdout is not None
                for line in proc.stdout:
                    line = line.rstrip("\n")
                    if not line:
                        continue
                    fh.write(_iso_now() + line + "\n")
                    fh.flush()
                    if LOKI_URL:
                        ts_ns = str(time.time_ns())
                        loki_batch.append((ts_ns, line))
                        now = time.monotonic()
                        if (len(loki_batch) >= LOKI_FLUSH_LINES
                                or now - last_flush >= LOKI_FLUSH_SECS):
                            _loki_push(bmc, loki_batch)
                            loki_batch = []
                            last_flush = now
                if loki_batch:
                    _loki_push(bmc, loki_batch)
        except Exception as e:
            log.warning("%s: tee error: %s", bmc, e)
            if loki_batch:
                _loki_push(bmc, loki_batch)

        rc = proc.wait()
        try:
            os.close(master_fd)
        except OSError:
            pass
        with _children_lock:
            _children.pop(bmc, None)
        uptime = time.monotonic() - started
        log.info("%s: SOL session ended (rc=%d, uptime=%.0fs)", bmc, rc, uptime)

        if _shutdown.is_set():
            return

        if uptime >= STABLE_RESET_SECS:
            backoff = RETRY_BACKOFF
        log.info("%s: reconnecting in %ds", bmc, backoff)
        if _shutdown.wait(backoff):
            return
        backoff = min(backoff * 2, MAX_RETRY_BACKOFF)


def _shutdown_handler(signum, _frame) -> None:
    log.info("Signal %d received -- tearing down all SOL sessions", signum)
    _shutdown.set()
    with _children_lock:
        children = list(_children.items())
    for bmc, proc in children:
        try:
            proc.terminate()
        except Exception:
            pass
    for bmc, _proc in children:
        creds = _CREDS_BY_BMC.get(bmc)
        if creds:
            _deactivate(bmc, creds["user"], creds["pass"])


_CREDS_BY_BMC: dict[str, dict[str, str]] = {}


def _resolve_targets() -> list[dict]:
    """Return list of {bmc, user, pass} dicts.
    Prefer BMC_CREDS_JSON; otherwise expand singleton BMC_HOSTS/USER/PASS."""
    if BMC_CREDS_JSON:
        try:
            raw = json.loads(BMC_CREDS_JSON)
        except Exception as e:
            log.error("BMC_CREDS_JSON parse error: %s", e)
            return []
        out = []
        for item in raw:
            bmc = item.get("bmc") or item.get("host")
            user = item.get("user", BMC_USER)
            password = item.get("pass") or item.get("password", BMC_PASS)
            if not bmc or not password:
                log.warning("Skipping incomplete BMC_CREDS_JSON entry: %s", item)
                continue
            out.append({"bmc": bmc, "user": user, "pass": password})
        return out
    return [{"bmc": h, "user": BMC_USER, "pass": BMC_PASS}
            for h in expand_hosts(BMC_HOSTS_RAW)]


if __name__ == "__main__":
    targets = _resolve_targets()
    if not targets:
        log.error("No BMC targets -- set BMC_CREDS_JSON or BMC_HOSTS+BMC_PASS")
        sys.exit(1)

    os.makedirs(SOL_LOG_DIR, exist_ok=True)

    log.info("NVIS Platform SOL Capture starting")
    log.info("  Targets          : %d BMC(s) -- %s", len(targets),
             ", ".join(t["bmc"] for t in targets[:5])
             + ("..." if len(targets) > 5 else ""))
    log.info("  Cluster          : %s", CLUSTER_NAME)
    log.info("  Log dir          : %s", SOL_LOG_DIR)
    log.info("  Loki URL         : %s", LOKI_URL or "(disabled)")
    log.info("  Deactivate first : %s", DEACTIVATE_FIRST)
    log.info("  Backoff          : %ds (max %ds)", RETRY_BACKOFF, MAX_RETRY_BACKOFF)

    signal.signal(signal.SIGTERM, _shutdown_handler)
    signal.signal(signal.SIGINT,  _shutdown_handler)

    threads = []
    for t in targets:
        _CREDS_BY_BMC[t["bmc"]] = {"user": t["user"], "pass": t["pass"]}
        th = threading.Thread(target=capture_loop,
                              args=(t["bmc"], t["user"], t["pass"]),
                              name=f"sol-{t['bmc']}", daemon=True)
        th.start()
        threads.append(th)

    while not _shutdown.is_set():
        _shutdown.wait(1.0)
    for th in threads:
        th.join(timeout=5)
    log.info("Shutdown complete.")
