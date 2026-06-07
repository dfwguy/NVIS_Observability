#!/bin/bash
# Run as root: sudo bash /home/hlakshminara/nvis-observability/scripts/k3s-fix-service.sh

# Remove symlinks that intercept k3s subcommands
rm -f /usr/local/bin/kubectl /usr/local/bin/crictl /usr/local/bin/ctr

# Write clean service file — no leading spaces, no unsupported flags
# CNI fix: add /opt/cni/bin to PATH so k3s agent can find host-local, flannel etc.
cat > /etc/systemd/system/k3s.service << 'EOF'
[Unit]
Description=Lightweight Kubernetes
Documentation=https://k3s.io
Wants=network-online.target
After=network-online.target

[Install]
WantedBy=multi-user.target

[Service]
Type=notify
Environment="PATH=/opt/cni/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EnvironmentFile=-/etc/default/k3s
KillMode=process
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=always
RestartSec=5s
ExecStartPre=-/sbin/modprobe br_netfilter
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/k3s server --disable traefik --disable servicelb --write-kubeconfig-mode 644 --tls-san 10.131.132.232 --node-taint node-role.kubernetes.io/control-plane=:NoSchedule
EOF

systemctl daemon-reload
systemctl restart k3s

echo "Waiting 45s for k3s to start..."
for i in $(seq 1 15); do
  sleep 3
  /usr/local/bin/k3s kubectl get nodes --no-headers 2>/dev/null | grep -q "Ready" && {
    echo "k3s is Ready!"
    /usr/local/bin/k3s kubectl get nodes
    exit 0
  }
  echo "  [${i}/15] waiting..."
done

echo "Still starting — latest journal:"
journalctl -u k3s -n 5 --no-pager
