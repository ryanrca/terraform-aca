# ---------------------------------------------------------------------------
# Shared platform layer. Bootstrapped once by scripts/bootstrap-azure.sh and
# only ever read here. The core creates no shared resources and no role
# assignments, which is why the deployment identities need only Contributor.
# ---------------------------------------------------------------------------

data "azurerm_container_registry" "platform" {
  name                = var.acr_name
  resource_group_name = var.platform_resource_group_name
}

data "azurerm_user_assigned_identity" "platform" {
  name                = var.uami_name
  resource_group_name = var.platform_resource_group_name
}

# ---------------------------------------------------------------------------
# Expiry stamp. Keyed on ttl_hours so re-deploying an environment does not
# silently extend its lease; changing ttl_hours does.
# ---------------------------------------------------------------------------

resource "time_offset" "expiry" {
  count = var.ttl_hours > 0 ? 1 : 0

  offset_hours = var.ttl_hours

  triggers = {
    ttl_hours = tostring(var.ttl_hours)
  }
}

# ---------------------------------------------------------------------------
# Environment layer
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "this" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.tags
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = local.log_analytics_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days

  # The main cost control: ingestion is billed per GB.
  daily_quota_gb = var.log_daily_quota_gb

  tags = local.tags
}

resource "azurerm_container_app_environment" "this" {
  name                       = local.container_app_env_name
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  tags = local.tags
}

resource "azurerm_container_app" "this" {
  name                         = local.container_app_name
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"

  tags = local.tags

  # The shared identity, which already holds AcrPull on the shared registry.
  identity {
    type         = "UserAssigned"
    identity_ids = [data.azurerm_user_assigned_identity.platform.id]
  }

  registry {
    server   = data.azurerm_container_registry.platform.login_server
    identity = data.azurerm_user_assigned_identity.platform.id
  }

  ingress {
    external_enabled = true
    target_port      = var.app_target_port
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.app_min_replicas
    max_replicas = var.app_max_replicas

    container {
      name   = var.app_name
      image  = var.app_image
      cpu    = var.app_cpu
      memory = var.app_memory

      dynamic "env" {
        for_each = var.app_env_vars

        content {
          name  = env.key
          value = env.value
        }
      }
    }
  }
}
