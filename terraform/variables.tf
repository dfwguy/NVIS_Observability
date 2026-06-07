variable "grafana_url" {
  description = "Base URL of the Grafana instance (e.g. http://10.0.0.10:3000)"
  type        = string
  default     = "http://localhost:3000"
}

variable "grafana_auth" {
  description = "Grafana authentication: 'admin:<password>' for basic auth, or a service-account token"
  type        = string
  sensitive   = true
}

variable "cluster_name" {
  description = "Cluster identifier — must match the 'cluster' label your exporters emit (DCGM, Slurm, SPX, node-exporter)"
  type        = string
  default     = "my-cluster"
}

variable "grafana_folder_name" {
  description = "Display name of the Grafana folder containing all NVIS dashboards"
  type        = string
  default     = "NVIS"
}

variable "grafana_folder_uid" {
  description = "Stable UID for the Grafana folder (used in bookmark URLs)"
  type        = string
  default     = "nvis-observability"
}

variable "victoriametrics_url" {
  description = "HTTP URL of the VictoriaMetrics (Prometheus-compatible) endpoint"
  type        = string
  default     = "http://nvis-victoriametrics:8428"
}

variable "loki_url" {
  description = "HTTP URL of the Loki log-aggregation endpoint"
  type        = string
  default     = "http://nvis-loki:3100"
}
