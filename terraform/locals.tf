locals {
  # Region abbreviations used in resource names. Unknown regions fall through to
  # the full region name, which is ugly but never wrong.
  region_abbreviations = {
    australiaeast      = "aue"
    canadacentral      = "cac"
    centralindia       = "cin"
    centralus          = "cus"
    eastasia           = "eas"
    eastus             = "eus"
    eastus2            = "eus2"
    francecentral      = "frc"
    germanywestcentral = "gwc"
    japaneast          = "jpe"
    northeurope        = "neu"
    norwayeast         = "nwe"
    southcentralus     = "scus"
    southeastasia      = "sea"
    swedencentral      = "sdc"
    switzerlandnorth   = "szn"
    uksouth            = "uks"
    ukwest             = "ukw"
    westeurope         = "weu"
    westus2            = "wus2"
    westus3            = "wus3"
  }

  location_short = lookup(local.region_abbreviations, var.location, var.location)

  # Naming convention lives here and nowhere else.
  name_prefix            = "acaplat-${var.env_name}-${local.location_short}"
  resource_group_name    = "rg-${local.name_prefix}"
  log_analytics_name     = "log-${local.name_prefix}"
  container_app_env_name = "cae-${local.name_prefix}"
  container_app_name     = "ca-${var.app_name}-${var.env_name}"
  management_lock_name   = "lock-${local.name_prefix}"

  # Empty when TTL is disabled, so the tag is always present and always queryable.
  expires_at = var.ttl_hours > 0 ? time_offset.expiry[0].rfc3339 : ""

  tags = merge(var.extra_tags, {
    environment = var.env_name
    env_class   = var.env_class
    workload    = "acaplat"
    owner       = var.owner
    managed_by  = "terraform"
    expires_at  = local.expires_at
    deployed_by = var.deployed_by
    commit_sha  = var.commit_sha
  })
}
