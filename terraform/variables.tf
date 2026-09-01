# ---------------------------------------------------------------------------
# Environment identity
# ---------------------------------------------------------------------------

variable "env_name" {
  type        = string
  description = "Unique environment identifier. Becomes the state file key and a component of every resource name."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{1,20})[a-z0-9]$", var.env_name))
    error_message = "env_name must be 3-22 characters of lowercase letters, digits and hyphens, and must start and end with a letter or digit."
  }
}

variable "env_class" {
  type        = string
  description = "Guardrail class for this environment. Must match the envs/<class>/ directory the tfvars file lives in."

  validation {
    condition     = contains(["dev", "staging", "prod"], var.env_class)
    error_message = "env_class must be one of: dev, staging, prod."
  }
}

variable "location" {
  type        = string
  description = "Azure region. Must be a region where Container Apps is available."
  default     = "eastus2"
}

variable "owner" {
  type        = string
  description = "Email address or team alias responsible for this environment. Applied as a tag."

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner must not be empty."
  }
}

variable "extra_tags" {
  type        = map(string)
  description = "Additional tags merged over the platform's mandatory tags."
  default     = {}
}

# ---------------------------------------------------------------------------
# Lifecycle guardrails
# ---------------------------------------------------------------------------

variable "ttl_hours" {
  type        = number
  description = "Hours until this environment is considered expired. 0 disables expiry. Required to be greater than 0 for the dev class."
  default     = 72

  validation {
    condition     = var.ttl_hours >= 0
    error_message = "ttl_hours must be 0 or greater."
  }

  validation {
    condition     = var.env_class != "dev" || var.ttl_hours > 0
    error_message = "A dev environment must set ttl_hours greater than 0 so abandoned sandboxes are visible."
  }

  validation {
    condition     = var.env_class != "prod" || var.ttl_hours == 0
    error_message = "A prod environment must set ttl_hours = 0."
  }
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

variable "log_retention_days" {
  type        = number
  description = "Log Analytics workspace retention in days."
  default     = 30

  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "log_retention_days must be between 30 and 730."
  }
}

variable "log_daily_quota_gb" {
  type        = number
  description = "Hard daily ingestion cap for this environment's Log Analytics workspace, in GB. -1 means unlimited."
  default     = 1

  validation {
    condition     = var.log_daily_quota_gb == -1 || var.log_daily_quota_gb > 0
    error_message = "log_daily_quota_gb must be -1 (unlimited) or greater than 0."
  }
}

# ---------------------------------------------------------------------------
# Shared platform layer (bootstrapped once, read here with data sources)
# ---------------------------------------------------------------------------

variable "platform_resource_group_name" {
  type        = string
  description = "Resource group holding the shared registry and workload identity. Supplied by the pipeline as TF_VAR_platform_resource_group_name."
  default     = "rg-acaplat-platform-eus2"
}

variable "acr_name" {
  type        = string
  description = "Name of the shared container registry. Supplied by the pipeline as TF_VAR_acr_name; not committed to any tfvars file."
}

variable "uami_name" {
  type        = string
  description = "Name of the shared user-assigned managed identity that holds AcrPull."
  default     = "id-acaplat-platform"
}

# ---------------------------------------------------------------------------
# The application
# ---------------------------------------------------------------------------

variable "app_name" {
  type        = string
  description = "Short name for the container app."
  default     = "hello"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,18})[a-z0-9]$", var.app_name))
    error_message = "app_name must be 2-20 characters of lowercase letters, digits and hyphens, and must start and end with a letter or digit."
  }

  validation {
    condition     = length("ca-${var.app_name}-${var.env_name}") <= 32
    error_message = "The generated container app name 'ca-<app_name>-<env_name>' must be 32 characters or fewer. Shorten env_name or app_name."
  }
}

variable "app_image" {
  type        = string
  description = "Fully qualified container image reference."
  default     = "mcr.microsoft.com/azuredocs/containerapps-helloworld:latest"
}

variable "app_target_port" {
  type        = number
  description = "Port the container listens on. Ingress is published to it."
  default     = 80

  validation {
    condition     = var.app_target_port > 0 && var.app_target_port <= 65535
    error_message = "app_target_port must be between 1 and 65535."
  }
}

variable "app_cpu" {
  type        = number
  description = "vCPU per replica. Must form a legal pair with app_memory."
  default     = 0.25
}

variable "app_memory" {
  type        = string
  description = "Memory per replica. Azure Container Apps only accepts specific cpu/memory pairs."
  default     = "0.5Gi"

  validation {
    condition = contains([
      "0.25:0.5Gi",
      "0.5:1Gi",
      "0.75:1.5Gi",
      "1:2Gi",
      "1.25:2.5Gi",
      "1.5:3Gi",
      "1.75:3.5Gi",
      "2:4Gi",
    ], "${var.app_cpu}:${var.app_memory}")
    error_message = "app_cpu and app_memory must be a legal Container Apps pair: 0.25/0.5Gi, 0.5/1Gi, 0.75/1.5Gi, 1/2Gi, 1.25/2.5Gi, 1.5/3Gi, 1.75/3.5Gi or 2/4Gi."
  }
}

variable "app_min_replicas" {
  type        = number
  description = "Minimum replica count. 0 allows scale to zero, which is why an idle sandbox costs almost nothing."
  default     = 0

  validation {
    condition     = var.app_min_replicas >= 0 && var.app_min_replicas <= 300
    error_message = "app_min_replicas must be between 0 and 300."
  }

  validation {
    condition     = var.env_class == "dev" || var.app_min_replicas >= 1
    error_message = "Only a dev environment may scale to zero; staging and prod must set app_min_replicas of at least 1."
  }
}

variable "app_max_replicas" {
  type        = number
  description = "Maximum replica count."
  default     = 1

  validation {
    condition     = var.app_max_replicas >= 1 && var.app_max_replicas <= 300
    error_message = "app_max_replicas must be between 1 and 300."
  }

  validation {
    condition     = var.app_max_replicas >= var.app_min_replicas
    error_message = "app_max_replicas must be greater than or equal to app_min_replicas."
  }
}

variable "app_env_vars" {
  type        = map(string)
  description = "Non-secret environment variables passed to the container. Secrets belong in Key Vault, not here."
  default     = {}
}

# ---------------------------------------------------------------------------
# Provenance (set by the pipeline, defaulted for local runs)
# ---------------------------------------------------------------------------

variable "deployed_by" {
  type        = string
  description = "Who or what applied this environment. Set by the pipeline as TF_VAR_deployed_by."
  default     = "local"
}

variable "commit_sha" {
  type        = string
  description = "Commit the deployment was produced from. Set by the pipeline as TF_VAR_commit_sha."
  default     = "local"
}
