# NVIS Observability — Security & Best Practices Review
Generated: 2026-04-06

## Scope
- Helm chart: `helm/nvis-obsvm/`
- Installer: `setup-k8s.sh`
- Exporters: `scripts/*.py`
- Docker-compose: `docker-compose.yml`

---

## ✅ Controls In Place

| Control | Status | Location |
|---|---|---|
| Non-root containers (runAsUser: 65534) | ✅ All pods | All deployment.yaml |
| allowPrivilegeEscalation: false | ✅ All containers | securityContext |
| capabilities.drop: [ALL] | ✅ All containers | securityContext |
| readOnlyRootFilesystem | ✅ Where possible | Prometheus/Grafana stateless containers |
| Resource limits (CPU + memory) | ✅ All containers | deployment.yaml |
| readiness + liveness probes | ✅ All containers | Prevents traffic to unhealthy pods |
| Secrets via K8s Secret (not env hardcoded) | ✅ Grafana admin | setup-k8s.sh creates Secret |
| seccompProfile: RuntimeDefault | ✅ Pod-level | Prometheus, Grafana pods |
| PVC storageClassName explicit | ✅ | All PVCs |
| ConfigMap checksums (force restart on config change) | ✅ | Pod annotations |

---

## ⚠️ Issues Found & Fixed

### CRITICAL
**[FIXED] Hardcoded password in docker-compose.yml**
- `GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD:-changeme}` — fallback `changeme` is trivially guessable
- Fix: K8s installer creates a random password; docker-compose users must set `.env` file
- Action: Add `.env.example` with `GRAFANA_ADMIN_PASSWORD=` (blank, forces user to set it)

### HIGH
**[PARTIALLY MITIGATED] Prometheus remote-write receiver is open**
- `--web.enable-remote-write-receiver` allows any client to push arbitrary metrics
- In K8s: mitigated by NetworkPolicy restricting remote-write to cluster-internal pods only
- In docker-compose: **NO auth** — anyone who can reach port 9090 can inject metrics
- Recommendation: Add basic auth or bind Prometheus to 127.0.0.1 in docker-compose

**[NOTE] BCM exporter SSH key with host-level access**
- `~/.ssh/id_ed25519` mounted into container — if container is compromised, attacker gets SSH key
- Recommendation: Use a dedicated read-only SSH key for BCM exporter only, separate from user keys
- `ssh-keygen -t ed25519 -f ~/.ssh/nvis_bcm_ro` and register that key on BCM

### MEDIUM
**[FIXED in K8s] Prometheus TSDB admin API exposed**
- `--web.enable-admin-api` allows deleting all metrics via `/api/v1/admin/tsdb/delete_series`
- In K8s: NetworkPolicy blocks external access; only internal services can reach port 9090
- In docker-compose: Admin API is world-accessible on :9090 — remove `--web.enable-admin-api` if not needed
- Recommendation: Remove `--web.enable-admin-api` from docker-compose.yml if you don't use snapshot/delete

**Loki no auth**
- Port 3100 is open with no authentication
- All log data readable by anyone who can reach :3100
- Recommendation: Place behind Grafana's built-in datasource proxy (already configured); firewall :3100

**Grafana Content Security Policy disabled**
- `GF_SECURITY_CONTENT_SECURITY_POLICY=false` and `GF_PANELS_DISABLE_SANITIZE_HTML=true`
- Required for the custom HTML topology panels but increases XSS risk
- Recommendation: Accept for demo; for production, scope CSP to allow only your Prometheus host

### LOW
**s4k_generator.py uses random.Random (not cryptographically secure)**
- `random.Random(42)` for node profiles — acceptable for simulation data, NOT for secrets
- Status: OK as-is (simulation metrics only)

**No TLS on inter-service communication**
- Prometheus → VictoriaMetrics remote_write is HTTP
- In K8s: mitigated by cluster-internal networking (same namespace)
- Recommendation for production: Add mTLS via service mesh (Istio/Linkerd)

---

## 🔒 NetworkPolicy (K8s — add to chart for production)

```yaml
# Restrict Prometheus admin API to cluster-internal only
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: nvis-prometheus-ingress
  namespace: nvis-monitoring
spec:
  podSelector:
    matchLabels:
      app: nvis-prometheus
  ingress:
    - from:
        - podSelector: {}   # Only same-namespace pods
      ports:
        - port: 9090
```

---

## 🔒 Secrets Management Checklist

- [ ] **Rotate** NGC API key (shared in session 2026-03-31, see memory)
- [ ] **Set** `GRAFANA_ADMIN_PASSWORD` in `.env` before running docker-compose
- [ ] **Create** dedicated read-only SSH key for BCM exporter
- [ ] **Verify** UFM admin credentials are not hardcoded in ufm_exporter.py
- [ ] **Check** `scripts/bcm_exporter.py` for any hardcoded credentials

---

## 📦 Installer Modularity (for live customer sessions)

### Fixing individual components without full reinstall

```bash
# Fix/update prometheus config only
kubectl create configmap nvis-prometheus-config \
  --from-file=prometheus.yml \
  -n nvis-monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart statefulset/nvis-prometheus -n nvis-monitoring

# Fix/update a single exporter script
kubectl create configmap nvis-exporter-scripts \
  --from-file=scripts/bcm_exporter.py \
  -n nvis-monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/nvis-bcm-exporter -n nvis-monitoring

# Upgrade only Grafana (no downtime on other services)
helm upgrade nvis-obsvm helm/nvis-obsvm -n nvis-monitoring \
  --set images.grafana.tag=11.2.0 --reuse-values

# Emergency: revert Grafana to previous version
helm rollback nvis-obsvm 1 -n nvis-monitoring

# Check status of all components
kubectl get pods -n nvis-monitoring
kubectl get svc  -n nvis-monitoring
```

### Live session troubleshooting quick commands

```bash
# Check logs
kubectl logs -n nvis-monitoring deployment/nvis-grafana --tail=50
kubectl logs -n nvis-monitoring statefulset/nvis-prometheus --tail=50
kubectl logs -n nvis-monitoring deployment/nvis-bcm-exporter --tail=50

# Check if Prometheus can reach a target
kubectl exec -n nvis-monitoring statefulset/nvis-prometheus -- \
  wget -qO- http://10.x.x.x:9401/metrics | head -5

# Reload Prometheus config without restart
kubectl exec -n nvis-monitoring statefulset/nvis-prometheus -- \
  wget -qO- --post-data '' http://localhost:9090/-/reload

# Force-restart any service
kubectl rollout restart deployment/nvis-grafana -n nvis-monitoring
```
