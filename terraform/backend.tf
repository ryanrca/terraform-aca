# Partial backend configuration. Every value is supplied at init time with
# -backend-config, which is what lets one core serve N environments:
#
#   terraform init -reconfigure \
#     -backend-config="resource_group_name=..."  \
#     -backend-config="storage_account_name=..." \
#     -backend-config="container_name=..."       \
#     -backend-config="key=<env_name>.tfstate"   \
#     -backend-config="use_azuread_auth=true"
#
# scripts/tf.sh does this for you. Never commit values here.
terraform {
  backend "azurerm" {}
}
