#!/usr/bin/env python3
"""
NVIS CMDaemon Prometheus Exporter — v1.0
=========================================
Runs on ObsVM. SSHes to BCM head node and executes a pythoncm data-collection
script there, then exposes the results as Prometheus metrics on port 9101.

Environment variables:
  BCM_HOST          BCM head node IP (default: 10.141.255.254)
  BCM_USER          SSH user        (default: root)
  JUMP_HOST         SSH jump host   (default: "", e.g. user@krusty5.nvidia.com)
  SSH_KEY           SSH key path    (default: /root/.ssh/id_ed25519)
  CLUSTER_NAME      Cluster label   (default: "")
  PORT              Listen port     (default: 9101)
  SCRAPE_INTERVAL   Seconds between BCM polls (default: 30)
  PYTHONCM_PATH     pythoncm site-packages on BCM
                    (default: /cm/local/apps/cmd/pythoncm/lib/python3.9/site-packages)

Systemd service: /etc/systemd/system/cmdaemon-exporter.service
"""

import os
import sys
import time
import json
import subprocess
import threading
import logging
from http.server import HTTPServer, BaseHTTPRequestHandler

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("cmdaemon-exporter")

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
BCM_HOST        = os.environ.get("BCM_HOST",        "10.141.255.254")
BCM_USER        = os.environ.get("BCM_USER",        "root")
JUMP_HOST       = os.environ.get("JUMP_HOST",       "")
SSH_KEY         = os.environ.get("SSH_KEY",         "/root/.ssh/id_ed25519")
CLUSTER_NAME    = os.environ.get("CLUSTER_NAME",    "")
PORT            = int(os.environ.get("PORT",        "9101"))
SCRAPE_INTERVAL = int(os.environ.get("SCRAPE_INTERVAL", "30"))
PYTHONCM_PATH   = os.environ.get(
    "PYTHONCM_PATH",
    "/cm/local/apps/cmd/pythoncm/lib/python3.9/site-packages",
)

# ---------------------------------------------------------------------------
# The Python snippet executed on BCM via SSH
# ---------------------------------------------------------------------------
BCM_COLLECTOR_SCRIPT = r"""
import sys, json, time
sys.path.insert(0, "{pythoncm_path}")
try:
    from pythoncm.cluster import Cluster
except ImportError as e:
    print(json.dumps({{"error": "import_failed", "detail": str(e)}}))
    sys.exit(1)

BCM_HOST = "{bcm_host}"
try:
    c = Cluster(host=BCM_HOST)
except Exception as e:
    print(json.dumps({{"error": "connect_failed", "detail": str(e)}}))
    sys.exit(1)

results = {{
    "nodes": [],
    "scrape_duration": 0.0,
}}
t0 = time.time()

def safe(fn, default=None):
    try:
        return fn()
    except Exception:
        return default

# Discover all nodes
try:
    node_names = [n.tostring() for n in c.listObjects("node")]
except Exception as e:
    print(json.dumps({{"error": "list_nodes_failed", "detail": str(e)}}))
    sys.exit(1)

for name in node_names:
    try:
        node = c.getObject("node", name)
    except Exception:
        continue

    nd = {{"name": name}}

    # Status
    nd["status"] = safe(lambda: str(node.status), "UNKNOWN")

    # Boot loader
    try:
        bl = node.bootLoader
        nd["bootloader"] = {{"type": str(bl.name), "protocol": safe(lambda: str(bl.protocol), "")}}
    except Exception:
        nd["bootloader"] = {{"type": "", "protocol": ""}}

    # Kernel
    nd["kernel_version"] = safe(lambda: str(node.kernelVersion), "")
    nd["kernel_parameters"] = safe(lambda: str(node.kernelParameters), "")

    # Category / install mode
    nd["category"] = safe(lambda: str(node.category), "")
    nd["install_mode"] = safe(lambda: str(node.installMode), "")

    # Provision transport
    nd["provision_transport"] = safe(lambda: str(node.provisioningTransport), "")

    # FIPS
    nd["fips"] = safe(lambda: str(node.fipsEnabled), "")

    # Power control
    try:
        pc = node.powerControl
        nd["power_control"] = {{
            "type":   safe(lambda: str(pc.type), ""),
            "script": safe(lambda: str(pc.script), ""),
        }}
    except Exception:
        nd["power_control"] = {{"type": "", "script": ""}}

    # Services
    nd["services"] = []
    try:
        for svc in node.roles:
            nd["services"].append({{
                "name":      safe(lambda: str(svc.name), ""),
                "running":   safe(lambda: 1 if svc.running else 0, 0),
                "autostart": safe(lambda: str(svc.autoStart), ""),
                "monitored": safe(lambda: str(svc.monitored), ""),
            }})
    except Exception:
        pass

    # Firmware info
    nd["firmware"] = []
    try:
        fwinfo = node.firmware_info()
        for comp, ver in (fwinfo or {{}}).items():
            nd["firmware"].append({{"component": str(comp), "version": str(ver)}})
    except Exception:
        pass

    # Health checks
    nd["health_checks"] = []
    try:
        checks = node.get_all_healthchecks() or []
        for hc in checks:
            nd["health_checks"].append({{
                "check":  safe(lambda: str(hc.name), ""),
                "status": safe(lambda: str(hc.status), ""),
            }})
    except Exception:
        pass

    results["nodes"].append(nd)

results["scrape_duration"] = time.time() - t0
print(json.dumps(results))
""".format(pythoncm_path="{pythoncm_path}", bcm_host="{bcm_host}")


# ---------------------------------------------------------------------------
# SSH executor
# ---------------------------------------------------------------------------
def run_on_bcm(script: str) -> dict:
    """SSH to BCM and execute the python3 collector script. Returns parsed JSON."""
    cmd = ["ssh",
           "-o", "StrictHostKeyChecking=no",
           "-o", "BatchMode=yes",
           "-o", "ConnectTimeout=15",
           "-o", "ServerAliveInterval=10"]

    if SSH_KEY and os.path.exists(SSH_KEY):
        cmd += ["-i", SSH_KEY]

    if JUMP_HOST:
        cmd += ["-J", JUMP_HOST]

    cmd += [f"{BCM_USER}@{BCM_HOST}"]
    cmd += ["python3", "-c", script]

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=60,
        )
        if result.returncode != 0:
            log.warning("SSH exited %d: %s", result.returncode, result.stderr[:200])
            return {"error": "ssh_failed", "detail": result.stderr[:200]}
        return json.loads(result.stdout.strip())
    except subprocess.TimeoutExpired:
        return {"error": "timeout"}
    except json.JSONDecodeError as e:
        return {"error": "json_parse", "detail": str(e)}
    except Exception as e:
        return {"error": "exception", "detail": str(e)}


# ---------------------------------------------------------------------------
# Metrics renderer
# ---------------------------------------------------------------------------
def render_metrics(data: dict) -> str:
    cluster = CLUSTER_NAME
    lines = []

    if "error" in data:
        lines.append("# HELP cmdaemon_up 1 if CMDaemon scrape succeeded")
        lines.append("# TYPE cmdaemon_up gauge")
        lines.append(f'cmdaemon_up{{cluster="{cluster}"}} 0')
        return "\n".join(lines) + "\n"

    lines.append("# HELP cmdaemon_up 1 if CMDaemon scrape succeeded")
    lines.append("# TYPE cmdaemon_up gauge")
    lines.append(f'cmdaemon_up{{cluster="{cluster}"}} 1')

    lines.append("")
    lines.append("# HELP bcm_node_up 1 if node is UP")
    lines.append("# TYPE bcm_node_up gauge")

    lines.append("")
    lines.append("# HELP bcm_node_boot_loader Node boot loader info")
    lines.append("# TYPE bcm_node_boot_loader gauge")

    lines.append("")
    lines.append("# HELP bcm_node_kernel_version Node kernel version info")
    lines.append("# TYPE bcm_node_kernel_version gauge")

    lines.append("")
    lines.append("# HELP bcm_node_kernel_parameters Node kernel parameters info")
    lines.append("# TYPE bcm_node_kernel_parameters gauge")

    lines.append("")
    lines.append("# HELP bcm_node_service_status 1 if service is running")
    lines.append("# TYPE bcm_node_service_status gauge")

    lines.append("")
    lines.append("# HELP bcm_node_power_control Node power control info")
    lines.append("# TYPE bcm_node_power_control gauge")

    lines.append("")
    lines.append("# HELP bcm_node_provision_transport Node provision transport info")
    lines.append("# TYPE bcm_node_provision_transport gauge")

    lines.append("")
    lines.append("# HELP bcm_node_category Node category info")
    lines.append("# TYPE bcm_node_category gauge")

    lines.append("")
    lines.append("# HELP bcm_node_install_mode Node install mode info")
    lines.append("# TYPE bcm_node_install_mode gauge")

    lines.append("")
    lines.append("# HELP bcm_node_fips Node FIPS status info")
    lines.append("# TYPE bcm_node_fips gauge")

    lines.append("")
    lines.append("# HELP bcm_node_firmware_info Node firmware version info")
    lines.append("# TYPE bcm_node_firmware_info gauge")

    lines.append("")
    lines.append("# HELP bcm_node_health_check Node health check status")
    lines.append("# TYPE bcm_node_health_check gauge")

    def esc(s):
        """Escape label values for Prometheus text format."""
        return str(s).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

    for nd in data.get("nodes", []):
        h = esc(nd.get("name", ""))
        status = nd.get("status", "UNKNOWN").upper()
        up = 1 if status == "UP" else 0
        lines.append(f'bcm_node_up{{hostname="{h}",cluster="{cluster}"}} {up}')

        bl = nd.get("bootloader", {})
        lines.append(
            f'bcm_node_boot_loader{{hostname="{h}",cluster="{cluster}",'
            f'bootloader="{esc(bl.get("type",""))}",protocol="{esc(bl.get("protocol",""))}"}} 1'
        )

        lines.append(
            f'bcm_node_kernel_version{{hostname="{h}",cluster="{cluster}",'
            f'version="{esc(nd.get("kernel_version",""))}"}} 1'
        )

        lines.append(
            f'bcm_node_kernel_parameters{{hostname="{h}",cluster="{cluster}",'
            f'params="{esc(nd.get("kernel_parameters",""))}"}} 1'
        )

        pc = nd.get("power_control", {})
        lines.append(
            f'bcm_node_power_control{{hostname="{h}",cluster="{cluster}",'
            f'type="{esc(pc.get("type",""))}",script="{esc(pc.get("script",""))}"}} 1'
        )

        lines.append(
            f'bcm_node_provision_transport{{hostname="{h}",cluster="{cluster}",'
            f'transport="{esc(nd.get("provision_transport",""))}"}} 1'
        )

        lines.append(
            f'bcm_node_category{{hostname="{h}",cluster="{cluster}",'
            f'category="{esc(nd.get("category",""))}"}} 1'
        )

        lines.append(
            f'bcm_node_install_mode{{hostname="{h}",cluster="{cluster}",'
            f'mode="{esc(nd.get("install_mode",""))}"}} 1'
        )

        lines.append(
            f'bcm_node_fips{{hostname="{h}",cluster="{cluster}",'
            f'fips="{esc(nd.get("fips",""))}"}} 1'
        )

        for svc in nd.get("services", []):
            lines.append(
                f'bcm_node_service_status{{hostname="{h}",cluster="{cluster}",'
                f'service="{esc(svc.get("name",""))}",autostart="{esc(svc.get("autostart",""))}",'
                f'monitored="{esc(svc.get("monitored",""))}"}} {svc.get("running", 0)}'
            )

        for fw in nd.get("firmware", []):
            lines.append(
                f'bcm_node_firmware_info{{hostname="{h}",cluster="{cluster}",'
                f'component="{esc(fw.get("component",""))}",version="{esc(fw.get("version",""))}"}} 1'
            )

        for hc in nd.get("health_checks", []):
            lines.append(
                f'bcm_node_health_check{{hostname="{h}",cluster="{cluster}",'
                f'check="{esc(hc.get("check",""))}",status="{esc(hc.get("status",""))}"}} 1'
            )

    dur = data.get("scrape_duration", 0.0)
    lines.append("")
    lines.append("# HELP bcm_scrape_duration_seconds Time taken to scrape BCM CMDaemon")
    lines.append("# TYPE bcm_scrape_duration_seconds gauge")
    lines.append(f'bcm_scrape_duration_seconds{{cluster="{cluster}"}} {dur:.4f}')

    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Background scrape loop
# ---------------------------------------------------------------------------
_lock   = threading.Lock()
_latest = ""
_ready  = threading.Event()


def _build_collector_script() -> str:
    return BCM_COLLECTOR_SCRIPT.format(
        pythoncm_path=PYTHONCM_PATH,
        bcm_host=BCM_HOST,
    )


def scrape_loop():
    global _latest
    script = _build_collector_script()
    while True:
        log.info("Scraping BCM CMDaemon at %s ...", BCM_HOST)
        data = run_on_bcm(script)
        if "error" in data:
            log.warning("Scrape error: %s — %s", data["error"], data.get("detail", ""))
        else:
            log.info("Collected %d node(s) in %.2fs",
                     len(data.get("nodes", [])),
                     data.get("scrape_duration", 0))
        metrics = render_metrics(data)
        with _lock:
            _latest = metrics
        _ready.set()
        time.sleep(SCRAPE_INTERVAL)


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress default access log

    def do_GET(self):
        if self.path in ("/metrics", "/"):
            _ready.wait(timeout=90)
            with _lock:
                body = _latest.encode()
            self.send_response(200)
            self.send_header("Content-Type",
                             "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/-/healthy":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"OK\n")
        else:
            self.send_response(404)
            self.end_headers()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    log.info("NVIS CMDaemon Exporter starting")
    log.info("  BCM host       : %s", BCM_HOST)
    log.info("  BCM user       : %s", BCM_USER)
    log.info("  Jump host      : %s", JUMP_HOST or "(none)")
    log.info("  SSH key        : %s", SSH_KEY)
    log.info("  Cluster        : %s", CLUSTER_NAME)
    log.info("  pythoncm path  : %s", PYTHONCM_PATH)
    log.info("  Scrape interval: %ds", SCRAPE_INTERVAL)
    log.info("  Listen port    : %d", PORT)

    t = threading.Thread(target=scrape_loop, daemon=True)
    t.start()

    server = HTTPServer(("", PORT), Handler)
    log.info("Metrics available at http://0.0.0.0:%d/metrics", PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down.")
