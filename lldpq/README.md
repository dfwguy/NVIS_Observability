# LLDPq Integration

LLDPq polls network switches via SSH/LLDP to build a live topology map and expose Prometheus metrics for link state, neighbor discovery, and port adjacency.

**Version**: 3.7.4  
**Upstream**: https://github.com/mna/lldpq

## Prerequisites

- SSH access to switch management IPs from the ObsVM
- Switches running LLDP (Cumulus Linux or NVIDIA NVOS/SPX)
- Docker or Docker Compose on the ObsVM

## Setup

1. **Copy example configs**:
   ```bash
   cp lldpq-config/devices.yaml.example lldpq-config/devices.yaml
   cp lldpq-config/topology_config.yaml.example lldpq-config/topology_config.yaml
   ```

2. **Edit `devices.yaml`** — fill in your switch management IPs, hostnames, and roles. Set `defaults.username` to match your switch OS:
   - Cumulus Linux: `cumulus`
   - NVIDIA NVOS (SPX): `admin`

3. **Edit `topology_config.yaml`** — adjust hostname patterns to match your naming convention (spine, leaf, compute node patterns).

4. **Add SSH key**:
   ```bash
   mkdir -p lldpq-ssh-keys
   cp ~/.ssh/id_rsa lldpq-ssh-keys/
   chmod 600 lldpq-ssh-keys/id_rsa
   ```
   Ensure the public key is authorized on all switches in `devices.yaml`.

5. **Start the service**:
   ```bash
   docker compose up -d
   ```
   LLDPq UI: http://ObsVM-IP:8080  
   Metrics: http://ObsVM-IP:8080/metrics

## Prometheus Scrape Config

Add to your Alloy/Prometheus scrape config:

```yaml
- job_name: lldpq
  static_configs:
    - targets: ['localhost:8080']
  relabel_configs:
    - target_label: cluster
      replacement: YOUR_CLUSTER_NAME
```

## SPX Fabric Topology

For a 2-plane SPX fabric with spine/leaf/compute hierarchy, see the example configs — they match SPXSPINE, SPXLEAF, and dgx* hostname patterns from standard NVIDIA SPX naming conventions.

## Grafana Integration

LLDPq metrics feed the **SPX Fabric** dashboards in NVIS:
- `spx-topology.json` — live link adjacency topology
- `spx-topology-live.json` — real-time canvas view
- `spx-traffic-health.json` — interface utilization and error rates
