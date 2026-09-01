# Disaster recovery. Identical to prod.tfvars except for env_name and location.
# That is the entire DR design.

env_name  = "prod-dr"
env_class = "prod"
location  = "westus3"
owner     = "platform-team@example.com"

ttl_hours = 0

log_retention_days = 90
log_daily_quota_gb = -1

app_min_replicas = 2
app_max_replicas = 10
app_cpu          = 0.5
app_memory       = "1Gi"
