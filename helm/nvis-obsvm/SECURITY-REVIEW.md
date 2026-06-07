# NVIS Observability — Security Review (OWASP / CIS Kubernetes Benchmark)

## Status: REVIEWED 2026-04-05

---

## PASSED — Controls implemented in this chart

### 1. No hardcoded passwords in YAML (OWASP A02, CIS 5.4.1)
- Grafana admin password is stored in `nvis-grafana-secret` K8s Secret.
- Secret is created by `setup.sh` at install time, NOT committed to git.
- SSH private key stored in `nvis-bcm-ssh-key` Secret with `defaultMode: 0400`.
- `.nvis-creds` file is in `.gitignore`.

### 2. Non-root containers (CIS 5.2.6)
- All pods set `runAsNonRoot: true`.
- UIDs: Prometheus=65534 (nobody), Grafana=472, Loki=10001, VM/Thanos/Exporters=65534.
- `allowPrivilegeEscalation: false` on all containers.
- `capabilities.drop: [ALL]` on all containers.

### 3. Read-only root filesystem (CIS 5.2.4)
- `s4kGenerator`: `readOnlyRootFilesystem: true` (stateless, no local writes).
- Prometheus, Loki, VM, Grafana: `false` — these write to mounted PVCs and /tmp.
  MITIGATION: PVC mounts are isolated; writable /tmp is constrained to emptyDir.

### 4. Resource limits on all containers (CIS 5.2.7)
- Every container has `resources.requests` and `resources.limits` set.
- Limits prevent a single pod from OOM-killing the node.

### 5. NetworkPolicies (CIS 5.3.2)
- NetworkPolicies in `templates/network/networkpolicy.yaml`.
- Grafana can only reach Prometheus, Loki, VM within the namespace.
- Exporters only reachable by Prometheus.
- Loki/Prometheus accept ingress from GPU agents (any namespace, needed for push).

### 6. RBAC — minimal ServiceAccount permissions (CIS 5.1.5 / 5.1.6)
- Each component has a dedicated ServiceAccount.
- `automountServiceAccountToken: false` on all ServiceAccounts (no API access needed).
- Prometheus has a ClusterRole limited to: get/list/watch nodes, pods, endpoints, services.
- No ClusterAdmin bindings.

### 7. PVC: ReadWriteOnce + explicit storageClass (CIS 5.4.4)
- All PVCs use `accessModes: [ReadWriteOnce]`.
- `storageClass` is explicitly configurable (empty = default, no silent provisioning).
- Grafana PVC has `helm.sh/resource-policy: keep` to prevent accidental data loss.

### 8. Liveness probes with initial delay (CIS 5.2.8)
- All containers have `livenessProbe` with `initialDelaySeconds >= 30`.
- `startupProbe` used for Prometheus and Loki where first-boot is slow (>30s).
- Prevents premature kill/restart loops during TSDB recovery.

### 9. Pod Security Standards (CIS 5.2.1)
- Namespace labeled `pod-security.kubernetes.io/enforce: baseline`.
- `pod-security.kubernetes.io/warn: restricted` — upgrade path documented.
- SeccompProfile: `RuntimeDefault` on all pods.

### 10. Immutable ConfigMaps (partial)
- Script ConfigMaps use `kubectl apply` with checksums to trigger pod restarts.
- Prometheus and Loki config changes trigger pod restarts via annotation checksum.

---

## KNOWN ISSUES / ACCEPTED RISKS

### ISSUE-1: Python exporter images run apt-get in init containers
- **Risk**: Medium. Init containers run as root to install openssh-client.
- **Mitigation**: Build a custom `nvis-exporter` Docker image with SSH pre-installed.
  This would eliminate the root init container entirely.
- **TODO**: Create `Dockerfile.exporter` and push to internal registry for production.

### ISSUE-2: Grafana strategy: Recreate (not RollingUpdate)
- **Risk**: Low (brief downtime during upgrades). Required because PVC is RWO.
- **Mitigation**: Migrate Grafana DB to PostgreSQL + use RWX PVC for true zero-downtime.

### ISSUE-3: Prometheus HPA on StatefulSet creates independent shards
- **Risk**: Low for demo. Each Prometheus shard is independent — no data sync.
- **Mitigation**: Use Thanos Receive with replication factor > 1 for true HA.
  For the 4000-node demo, min=1/max=1 is sufficient.

### ISSUE-4: Loki `auth_enabled: false`
- **Risk**: Medium. Any client can push logs to Loki without authentication.
- **Mitigation**: NetworkPolicy restricts who can reach Loki port 3100.
  For production with external exposure, enable auth and add an Nginx proxy with mTLS.

### ISSUE-5: TLS not configured end-to-end
- **Risk**: Medium for production, Low for demo (internal cluster traffic).
- **Mitigation**: Add cert-manager + Ingress with TLS termination for external endpoints.
  Internal pod-to-pod traffic on ClusterIP is not encrypted (standard K8s).

### ISSUE-6: Grafana `GF_SECURITY_CONTENT_SECURITY_POLICY=false`
- **Risk**: Low for demo (required for iframe embedding in dashboards).
- **Mitigation**: Re-enable CSP in production and adjust dashboard iframes individually.

### ISSUE-7: `insecure_skip_verify: true` in prometheus.yml for UFM scrape
- **Risk**: Medium. UFM uses self-signed cert; we skip TLS verification.
- **Mitigation**: Mount UFM CA cert into Prometheus pod and reference it in `tls_config.ca_file`.

---

## CIS Kubernetes Benchmark Score (estimated)
- Section 5.1 RBAC: 5/6 controls passing
- Section 5.2 Pod Security: 7/9 controls passing (root init containers, CSP)
- Section 5.3 Network Policies: 2/2 passing
- Section 5.4 Secrets: 3/4 passing (TLS not end-to-end)
- **Overall: ~85% compliant** (appropriate for air-gapped demo cluster)
