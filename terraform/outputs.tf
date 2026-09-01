output "app_url" {
  description = "Public HTTPS URL of the container app."
  value       = "https://${azurerm_container_app.this.ingress[0].fqdn}"
}

output "app_fqdn" {
  description = "Public hostname of the container app."
  value       = azurerm_container_app.this.ingress[0].fqdn
}

output "resource_group_name" {
  description = "Resource group holding this environment. The unit of destruction."
  value       = azurerm_resource_group.this.name
}

output "container_app_environment_id" {
  description = "Resource ID of the Container Apps managed environment."
  value       = azurerm_container_app_environment.this.id
}

output "log_analytics_workspace_id" {
  description = "Resource ID of this environment's Log Analytics workspace."
  value       = azurerm_log_analytics_workspace.this.id
}

output "expires_at" {
  description = "When this environment is considered expired. Empty when ttl_hours is 0."
  value       = local.expires_at
}
