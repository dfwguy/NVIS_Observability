FROM python:3.11-slim

WORKDIR /app

# iputils-ping ships /bin/ping. Modern Debian configures it with the
# `net_raw` file capability (cap_net_raw=ep), NOT setuid, so the binary
# can open an ICMP socket as any UID without root.
#
# When this image runs as the unprivileged "nobody" user (UID 65534) the
# container runtime must still propagate CAP_NET_RAW to the process.
# This is the default for Docker and for Kubernetes Pods that do NOT set
# securityContext.capabilities.drop=["ALL"]. If you drop ALL, you must
# explicitly add NET_RAW back, e.g.:
#
#   securityContext:
#     capabilities:
#       add: ["NET_RAW"]
#
# On systemd hosts the bundled unit file uses AmbientCapabilities=CAP_NET_RAW.
RUN apt-get update \
 && apt-get install -y --no-install-recommends iputils-ping ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY dgx_ping_exporter.py /app/dgx_ping_exporter.py

EXPOSE 9116

# Run as the unprivileged "nobody" user. CAP_NET_RAW on /bin/ping (set by
# the iputils-ping package via file capabilities) lets this user ping
# without root.
USER 65534:65534

ENTRYPOINT ["python3", "-u", "/app/dgx_ping_exporter.py"]
