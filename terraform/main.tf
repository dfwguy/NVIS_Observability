provider "grafana" {
  url  = var.grafana_url
  auth = var.grafana_auth
}

resource "grafana_folder" "nvis" {
  title = var.grafana_folder_name
  uid   = var.grafana_folder_uid
}

locals {
  # Auto-discover all JSON files in terraform/dashboards/
  # Drop a new .json file here → it's deployed on next `terraform apply`. No code change needed.
  dashboard_files = fileset("${path.module}/dashboards", "*.json")
}

resource "grafana_dashboard" "nvis" {
  for_each    = local.dashboard_files
  folder      = grafana_folder.nvis.uid
  config_json = file("${path.module}/dashboards/${each.value}")
  overwrite   = true
}
