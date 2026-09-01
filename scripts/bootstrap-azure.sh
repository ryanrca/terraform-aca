#!/usr/bin/env bash
#
# One-time Azure bootstrap for the ACA platform. Creates the shared platform
# layer that the core Terraform reads but never manages:
#
#   - resource group for everything shared
#   - storage account + container for Terraform state (no access keys)
#   - container registry shared by every environment
#   - user-assigned managed identity holding AcrPull on that registry
#   - one Entra app registration per environment class, federated to GitHub
#
# Idempotent: re-running discovers what already exists and only fills gaps.
#
# Usage:
#   SUBSCRIPTION_ID=<id> GH_ORG=<org> GH_REPO=<repo> ./scripts/bootstrap-azure.sh
#
# Optional overrides:
#   LOCATION                  default eastus2
#   PLATFORM_RESOURCE_GROUP   default rg-acaplat-platform-<region-short>
#   UAMI_NAME                 default id-acaplat-platform
#   IDENTITIES_FILE           default /tmp/acaplat-identities.txt

set -euo pipefail

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }

command -v az >/dev/null || die "the Azure CLI (az) is required; see the README"
command -v openssl >/dev/null || die "openssl is required to generate unique names"

: "${SUBSCRIPTION_ID:?set SUBSCRIPTION_ID to the subscription to bootstrap}"
: "${GH_ORG:?set GH_ORG to your GitHub organisation or username}"
: "${GH_REPO:?set GH_REPO to the repository name, e.g. terraform-aca}"

LOCATION="${LOCATION:-eastus2}"
UAMI_NAME="${UAMI_NAME:-id-acaplat-platform}"
IDENTITIES_FILE="${IDENTITIES_FILE:-/tmp/acaplat-identities.txt}"
CLASSES=(dev staging prod)

# Region abbreviation, matching terraform/locals.tf.
case "${LOCATION}" in
  eastus2) LOC_SHORT="eus2" ;;  eastus) LOC_SHORT="eus" ;;
  westus2) LOC_SHORT="wus2" ;;  westus3) LOC_SHORT="wus3" ;;
  centralus) LOC_SHORT="cus" ;; northeurope) LOC_SHORT="neu" ;;
  westeurope) LOC_SHORT="weu" ;; uksouth) LOC_SHORT="uks" ;;
  *) LOC_SHORT="${LOCATION}" ;;
esac
PLATFORM_RESOURCE_GROUP="${PLATFORM_RESOURCE_GROUP:-rg-acaplat-platform-${LOC_SHORT}}"
TFSTATE_CONTAINER="tfstate"
COMMON_TAGS=(workload=acaplat layer=platform managed_by=bootstrap)

step "Selecting subscription"
az account set --subscription "${SUBSCRIPTION_ID}"
TENANT_ID="$(az account show --query tenantId -o tsv)"
MY_OBJECT_ID="$(az ad signed-in-user show --query id -o tsv)"
info "subscription ${SUBSCRIPTION_ID}"
info "tenant       ${TENANT_ID}"

# ---------------------------------------------------------------------------
step "Registering resource providers"
# ---------------------------------------------------------------------------
for ns in Microsoft.App Microsoft.OperationalInsights Microsoft.ContainerRegistry \
          Microsoft.ManagedIdentity Microsoft.Storage Microsoft.Insights Microsoft.Resources; do
  state="$(az provider show --namespace "${ns}" --query registrationState -o tsv 2>/dev/null || echo NotRegistered)"
  if [ "${state}" = "Registered" ]; then
    info "${ns} already registered"
  else
    info "${ns} registering (this can take several minutes) ..."
    az provider register --namespace "${ns}" --wait
  fi
done

# ---------------------------------------------------------------------------
step "Platform resource group"
# ---------------------------------------------------------------------------
az group create \
  --name "${PLATFORM_RESOURCE_GROUP}" \
  --location "${LOCATION}" \
  --tags "${COMMON_TAGS[@]}" \
  --output none
info "${PLATFORM_RESOURCE_GROUP}"

# ---------------------------------------------------------------------------
step "Terraform state storage"
# ---------------------------------------------------------------------------
# Reuse the existing state account if one is already tagged in this group.
TFSTATE_STORAGE_ACCOUNT="${TFSTATE_STORAGE_ACCOUNT:-$(az storage account list \
  --resource-group "${PLATFORM_RESOURCE_GROUP}" \
  --query "[?tags.purpose=='tfstate'] | [0].name" -o tsv 2>/dev/null || true)}"

if [ -z "${TFSTATE_STORAGE_ACCOUNT}" ] || [ "${TFSTATE_STORAGE_ACCOUNT}" = "None" ]; then
  TFSTATE_STORAGE_ACCOUNT="stacaplattf$(openssl rand -hex 4)"
  info "creating ${TFSTATE_STORAGE_ACCOUNT}"
  # Shared-key access off: there is no storage key to leak, and every caller
  # authenticates with Entra ID.
  az storage account create \
    --name "${TFSTATE_STORAGE_ACCOUNT}" \
    --resource-group "${PLATFORM_RESOURCE_GROUP}" \
    --location "${LOCATION}" \
    --sku Standard_ZRS \
    --kind StorageV2 \
    --https-only true \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    --allow-shared-key-access false \
    --tags "${COMMON_TAGS[@]}" purpose=tfstate \
    --output none
else
  info "reusing ${TFSTATE_STORAGE_ACCOUNT}"
fi

az storage account blob-service-properties update \
  --account-name "${TFSTATE_STORAGE_ACCOUNT}" \
  --resource-group "${PLATFORM_RESOURCE_GROUP}" \
  --enable-versioning true \
  --enable-delete-retention true --delete-retention-days 30 \
  --enable-container-delete-retention true --container-delete-retention-days 30 \
  --output none
info "versioning and 30-day soft delete enabled"

SA_ID="$(az storage account show \
  --name "${TFSTATE_STORAGE_ACCOUNT}" \
  --resource-group "${PLATFORM_RESOURCE_GROUP}" --query id -o tsv)"

# You need data-plane access yourself before you can create the container.
az role assignment create \
  --assignee-object-id "${MY_OBJECT_ID}" \
  --assignee-principal-type User \
  --role "Storage Blob Data Contributor" \
  --scope "${SA_ID}" \
  --output none 2>/dev/null || info "you already hold Storage Blob Data Contributor"

info "waiting 30s for RBAC propagation"
sleep 30

az storage container create \
  --name "${TFSTATE_CONTAINER}" \
  --account-name "${TFSTATE_STORAGE_ACCOUNT}" \
  --auth-mode login \
  --output none
info "container ${TFSTATE_CONTAINER} ready"

TFSTATE_CONTAINER_ID="${SA_ID}/blobServices/default/containers/${TFSTATE_CONTAINER}"

# ---------------------------------------------------------------------------
step "Shared container registry and workload identity"
# ---------------------------------------------------------------------------
ACR_NAME="${ACR_NAME:-$(az acr list \
  --resource-group "${PLATFORM_RESOURCE_GROUP}" --query "[0].name" -o tsv 2>/dev/null || true)}"

if [ -z "${ACR_NAME}" ] || [ "${ACR_NAME}" = "None" ]; then
  ACR_NAME="cracaplat$(openssl rand -hex 4)"
  info "creating registry ${ACR_NAME}"
  az acr create \
    --name "${ACR_NAME}" \
    --resource-group "${PLATFORM_RESOURCE_GROUP}" \
    --location "${LOCATION}" \
    --sku Basic \
    --admin-enabled false \
    --tags "${COMMON_TAGS[@]}" \
    --output none
else
  info "reusing registry ${ACR_NAME}"
fi

az identity create \
  --name "${UAMI_NAME}" \
  --resource-group "${PLATFORM_RESOURCE_GROUP}" \
  --location "${LOCATION}" \
  --tags "${COMMON_TAGS[@]}" \
  --output none
info "identity ${UAMI_NAME}"

ACR_ID="$(az acr show --name "${ACR_NAME}" --query id -o tsv)"
UAMI_PRINCIPAL_ID="$(az identity show \
  --name "${UAMI_NAME}" --resource-group "${PLATFORM_RESOURCE_GROUP}" \
  --query principalId -o tsv)"

# The only role assignment involving the workload identity. Making it here is
# what removes the need for the CI identities to hold role-assignment rights.
az role assignment create \
  --assignee-object-id "${UAMI_PRINCIPAL_ID}" \
  --assignee-principal-type ServicePrincipal \
  --role "AcrPull" \
  --scope "${ACR_ID}" \
  --output none 2>/dev/null || info "AcrPull already granted"
info "AcrPull granted to ${UAMI_NAME}"

# ---------------------------------------------------------------------------
step "CI identities"
# ---------------------------------------------------------------------------
: > "${IDENTITIES_FILE}"

for class in "${CLASSES[@]}"; do
  app_name="gh-acaplat-${class}"

  app_id="$(az ad app list --display-name "${app_name}" --query "[0].appId" -o tsv 2>/dev/null || true)"
  if [ -z "${app_id}" ] || [ "${app_id}" = "None" ]; then
    info "creating app registration ${app_name}"
    app_id="$(az ad app create --display-name "${app_name}" \
      --sign-in-audience AzureADMyOrg --query appId -o tsv)"
    az ad sp create --id "${app_id}" --output none
    sleep 10
  else
    info "reusing app registration ${app_name} (${app_id})"
  fi
  sp_oid="$(az ad sp show --id "${app_id}" --query id -o tsv)"

  # One federated credential per GitHub Environment this identity may run in:
  # the ungated <class>-plan, and the gated <class>.
  for ghenv in "${class}-plan" "${class}"; do
    if az ad app federated-credential create --id "${app_id}" --parameters "$(cat <<JSON
{
  "name": "gh-${ghenv}",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:${GH_ORG}/${GH_REPO}:environment:${ghenv}",
  "description": "GitHub Actions ${ghenv}",
  "audiences": ["api://AzureADTokenExchange"]
}
JSON
)" --output none 2>/dev/null; then
      info "  federated credential gh-${ghenv}"
    else
      info "  federated credential gh-${ghenv} already exists"
    fi
  done

  # Contributor is the ceiling: the core Terraform creates no role assignments,
  # so no CI identity ever needs User Access Administrator.
  az role assignment create --assignee-object-id "${sp_oid}" \
    --assignee-principal-type ServicePrincipal \
    --role "Contributor" --scope "/subscriptions/${SUBSCRIPTION_ID}" \
    --output none 2>/dev/null || true

  # terraform plan takes a state lock, so planning needs blob write.
  az role assignment create --assignee-object-id "${sp_oid}" \
    --assignee-principal-type ServicePrincipal \
    --role "Storage Blob Data Contributor" --scope "${TFSTATE_CONTAINER_ID}" \
    --output none 2>/dev/null || true

  printf '%s %s\n' "${class}" "${app_id}" >> "${IDENTITIES_FILE}"
done

# ---------------------------------------------------------------------------
step "Bootstrap complete"
# ---------------------------------------------------------------------------
cat <<SUMMARY

Identifiers for GitHub Actions variables (none of these are secrets):

  AZURE_TENANT_ID         = ${TENANT_ID}
  AZURE_SUBSCRIPTION_ID   = ${SUBSCRIPTION_ID}
  PLATFORM_RESOURCE_GROUP = ${PLATFORM_RESOURCE_GROUP}
  TFSTATE_STORAGE_ACCOUNT = ${TFSTATE_STORAGE_ACCOUNT}
  TFSTATE_CONTAINER       = ${TFSTATE_CONTAINER}
  ACR_NAME                = ${ACR_NAME}

Per-class client IDs written to ${IDENTITIES_FILE}:

$(sed 's/^/  /' "${IDENTITIES_FILE}")

Next: README Part 2 (GitHub configuration). Export the values above, then run
the commands in that section — they read ${IDENTITIES_FILE} directly.
SUMMARY
