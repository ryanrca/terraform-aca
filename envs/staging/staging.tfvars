env_name  = "staging"
env_class = "staging"
location  = "eastus2"
owner     = "platform-team@example.com"

ttl_hours            = 0
enable_resource_lock = true

log_retention_days = 30
log_daily_quota_gb = 5

app_min_replicas = 1
app_max_replicas = 3
app_cpu          = 0.25
app_memory       = "0.5Gi"
