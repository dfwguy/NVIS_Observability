resource "grafana_data_source" "victoriametrics" {
  name       = "VictoriaMetrics"
  type       = "prometheus"
  uid        = "nvis-victoriametrics"
  url        = var.victoriametrics_url
  is_default = true

  json_data_encoded = jsonencode({
    httpMethod     = "POST"
    prometheusType = "Prometheus"
    timeInterval   = "15s"
  })
}

resource "grafana_data_source" "loki" {
  name = "Loki"
  type = "loki"
  uid  = "nvis-loki"
  url  = var.loki_url

  json_data_encoded = jsonencode({
    maxLines = 1000
  })
}
