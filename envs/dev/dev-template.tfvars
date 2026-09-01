# Developer sandbox template.
#
#   cp envs/dev/dev-template.tfvars envs/dev/dev-<yourname>.tfvars
#
# Change env_name and owner. Everything else has a dev-safe default: the app
# scales to zero when idle, and Log Analytics ingestion is capped at 1 GB/day.

env_name  = "dev-CHANGEME"
env_class = "dev"
location  = "eastus2"
owner     = "you@example.com"
ttl_hours = 72
