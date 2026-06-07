output "grafana_url" {
  description = "Grafana base URL as configured"
  value       = var.grafana_url
}

output "grafana_folder_uid" {
  description = "UID of the provisioned Grafana folder"
  value       = grafana_folder.nvis.uid
}

output "grafana_folder_url" {
  description = "Direct URL to the NVIS dashboards folder"
  value       = "${var.grafana_url}/dashboards/f/${grafana_folder.nvis.uid}/${lower(replace(var.grafana_folder_name, " ", "-"))}"
}

output "cluster_name" {
  description = "Cluster name injected into all dashboard template variables"
  value       = var.cluster_name
}

output "dashboard_count" {
  description = "Number of dashboards provisioned by Terraform"
  value       = length(local.dashboard_files)
}
