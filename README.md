# terraform-aca — Azure Container Apps platform

Terraform + GitHub Actions platform for running containerised workloads on **Azure
Container Apps**. One Terraform core serves every environment; environments are defined
purely by variables files.

- **Developers** stand up and tear down their own sandbox from the Actions tab.
- **Staging and production** run the same code with different inputs, behind an approval gate.
- **Disaster recovery** is one more variables file with a different region.
- **No secrets** — GitHub authenticates to Azure with OIDC workload identity federation.

> **Status:** specification phase. The documents in this repo are complete and under
> review; the Terraform and workflows they describe are not yet written. See
> [`docs/functional-spec.md`](docs/functional-spec.md) for the full design and
> [`CLAUDE.md`](CLAUDE.md) for contributor working rules and the build order.

---

## Contents

- [How it works](#how-it-works)
- [The two layers](#the-two-layers)
- [Part 1 — Azure bootstrap from zero](#part-1--azure-bootstrap-from-zero)
- [Part 2 — GitHub configuration](#part-2--github-configuration)
- [Part 3 — First deployment](#part-3--first-deployment)
- [Day-2 operations](#day-2-operations)
- [Local development](#local-development)
- [Troubleshooting](#troubleshooting)
- [Cost](#cost)

---

## How it works

```
envs/dev/dev-ryan.tfvars  ─┐
envs/staging/staging.tfvars┤
envs/prod/prod.tfvars     ─┼──▶  terraform/  (one core, unchanged)  ──▶  Azure
envs/prod/prod-dr.tfvars  ─┘            │
                                        └─ state key = <env_name>.tfstate
```

Deploying and destroying are both GitHub Actions workflows that take an environment name:

```
Actions ▸ Deploy   ▸ environment: dev-ryan  ▸ Run   →  public HTTPS URL
Actions ▸ Destroy  ▸ environment: dev-ryan  ▸ confirm: dev-ryan  ▸ Run
```

Sandboxes need no approval. Production apply and destroy pause on a GitHub Environment gate
until a reviewer approves.

## The two layers

| Layer | Created by | Lifetime | Contents |
|---|---|---|---|
| **Shared platform** | `scripts/bootstrap-azure.sh`, once | Outlives every environment | Terraform state storage, container registry, user-assigned managed identity, CI app registrations |
| **Environment** | The core Terraform, per environment | Created and destroyed freely | Resource group, Log Analytics workspace, ACA environment, container app, management lock |

The core Terraform *reads* the shared resources with data sources and never creates them.
That is why it creates no role assignments, and why the CI identities need nothing beyond
`Contributor`.

```
terraform/              the core — identical for every environment
envs/{dev,staging,prod} the only place environments differ
scripts/tf.sh           all Terraform execution lives here (CI calls it too)
scripts/bootstrap-azure.sh
.github/workflows/      plan / deploy / destroy
docs/functional-spec.md architecture, rationale, decisions, acceptance criteria
CLAUDE.md               how to work in this repo (rules, conventions, gotchas)
```

---

## Part 1 — Azure bootstrap from zero

Everything below assumes you are starting with **nothing**: no Azure account, no
subscription, no storage, no identities. Run it once. Every step is idempotent, so it is
safe to re-run.

### 1.0 Install the tooling

```bash
# Azure CLI (Debian/Ubuntu)
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# GitHub CLI
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update && sudo apt install gh -y
```

Verify — Terraform must be 1.9 or newer:

```bash
az version && gh --version && terraform version
```

### 1.1 Create the Azure account and subscription

Done in a browser — there is no CLI path to creating a tenant.

1. Go to <https://azure.microsoft.com/free> (or <https://portal.azure.com> if your
   organisation already has a tenant) and sign up. A credit card is required even for the
   free tier.
2. This creates a **Microsoft Entra tenant** and one **subscription**.
3. For a client PoC, check whether you should use an existing Enterprise Agreement
   subscription rather than a new pay-as-you-go one.

**Permissions you need.** You must be able to create resources, assign RBAC roles, and
create Entra application registrations. If you signed up yourself you already have all
three. Inside an existing corporate tenant, ask for:

| Need | Role |
|---|---|
| Create resources | `Contributor` on the subscription |
| Assign roles to the CI identities | `User Access Administrator` or `Owner` on the subscription |
| Create app registrations | Entra `Application Developer` |

### 1.2 Sign in and select the subscription

```bash
az login
az account list --output table
```

```bash
# Set these once — every later command uses them.
export SUBSCRIPTION_ID="<paste the SubscriptionId you want to use>"
az account set --subscription "$SUBSCRIPTION_ID"

export TENANT_ID="$(az account show --query tenantId -o tsv)"
export MY_OBJECT_ID="$(az ad signed-in-user show --query id -o tsv)"

echo "Subscription: $SUBSCRIPTION_ID"
echo "Tenant:       $TENANT_ID"
```

### 1.3 Register the resource providers

New subscriptions do not have the Container Apps providers enabled. This takes a few
minutes and is only ever done once per subscription.

```bash
for ns in Microsoft.App \
          Microsoft.OperationalInsights \
          Microsoft.ContainerRegistry \
          Microsoft.ManagedIdentity \
          Microsoft.Storage \
          Microsoft.Insights \
          Microsoft.Resources; do
  echo "Registering $ns ..."
  az provider register --namespace "$ns" --wait
done
```

Verify — every row must say `Registered`:

```bash
az provider list \
  --query "[?namespace=='Microsoft.App' || namespace=='Microsoft.OperationalInsights' || namespace=='Microsoft.ContainerRegistry' || namespace=='Microsoft.ManagedIdentity'].{Namespace:namespace, State:registrationState}" \
  -o table
```

### 1.4 Create the shared platform resource group and Terraform state backend

One resource group holds everything shared. Shared-key access on the storage account is
**disabled**, so there is no storage key anywhere — all access is via Entra ID.

```bash
export LOCATION="eastus2"
export PLATFORM_RESOURCE_GROUP="rg-acaplat-platform-eus2"
export TFSTATE_STORAGE_ACCOUNT="stacaplattf$(openssl rand -hex 4)"   # globally unique
export TFSTATE_CONTAINER="tfstate"

az group create \
  --name "$PLATFORM_RESOURCE_GROUP" \
  --location "$LOCATION" \
  --tags workload=acaplat layer=platform managed_by=bootstrap

az storage account create \
  --name "$TFSTATE_STORAGE_ACCOUNT" \
  --resource-group "$PLATFORM_RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku Standard_ZRS \
  --kind StorageV2 \
  --https-only true \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --allow-shared-key-access false \
  --tags workload=acaplat layer=platform purpose=tfstate
```

Turn on versioning and soft delete so a corrupted or truncated state file is recoverable:

```bash
az storage account blob-service-properties update \
  --account-name "$TFSTATE_STORAGE_ACCOUNT" \
  --resource-group "$PLATFORM_RESOURCE_GROUP" \
  --enable-versioning true \
  --enable-delete-retention true --delete-retention-days 30 \
  --enable-container-delete-retention true --container-delete-retention-days 30
```

Because shared-key access is off, grant **yourself** data-plane access before creating the
container:

```bash
export SA_ID="$(az storage account show \
  --name "$TFSTATE_STORAGE_ACCOUNT" \
  --resource-group "$PLATFORM_RESOURCE_GROUP" --query id -o tsv)"

az role assignment create \
  --assignee-object-id "$MY_OBJECT_ID" \
  --assignee-principal-type User \
  --role "Storage Blob Data Contributor" \
  --scope "$SA_ID"

# RBAC propagation is not instant; wait ~30s before the next command.
az storage container create \
  --name "$TFSTATE_CONTAINER" \
  --account-name "$TFSTATE_STORAGE_ACCOUNT" \
  --auth-mode login
```

Record the container's resource ID — the CI identities get scoped access to exactly this:

```bash
export TFSTATE_CONTAINER_ID="${SA_ID}/blobServices/default/containers/${TFSTATE_CONTAINER}"
```

### 1.5 Create the shared registry and workload identity

The container registry is shared so that staging and production can pull the *identical*
image digest a sandbox was tested with. The managed identity is shared so that the core
Terraform never has to create a role assignment — which is what keeps the CI identities
down to plain `Contributor`.

```bash
export ACR_NAME="cracaplat$(openssl rand -hex 4)"   # globally unique, alphanumeric only
export UAMI_NAME="id-acaplat-platform"

az acr create \
  --name "$ACR_NAME" \
  --resource-group "$PLATFORM_RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku Basic \
  --admin-enabled false \
  --tags workload=acaplat layer=platform

az identity create \
  --name "$UAMI_NAME" \
  --resource-group "$PLATFORM_RESOURCE_GROUP" \
  --location "$LOCATION" \
  --tags workload=acaplat layer=platform
```

Grant the identity pull rights on the registry. This is the **only** role assignment
involving the workload identity, and it is made here, once — never by Terraform:

```bash
export ACR_ID="$(az acr show --name "$ACR_NAME" --query id -o tsv)"
export UAMI_PRINCIPAL_ID="$(az identity show \
  --name "$UAMI_NAME" --resource-group "$PLATFORM_RESOURCE_GROUP" \
  --query principalId -o tsv)"

az role assignment create \
  --assignee-object-id "$UAMI_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "AcrPull" \
  --scope "$ACR_ID"
```

Verify:

```bash
az resource list --resource-group "$PLATFORM_RESOURCE_GROUP" -o table
az role assignment list --scope "$ACR_ID" --query "[].{principal:principalName, role:roleDefinitionName}" -o table
```

### 1.6 Create the CI identities

Three app registrations, one per environment class. Each gets two federated credentials —
one for its ungated `<class>-plan` GitHub Environment and one for its gated `<class>`
environment — plus `Contributor` on the subscription and write access to the state
container.

Set your repository coordinates first:

```bash
export GH_ORG="<your-github-org-or-username>"
export GH_REPO="terraform-aca"
```

```bash
create_identity() {
  local class="$1"
  local name="gh-acaplat-${class}"

  # --- app registration + service principal (idempotent) ---
  local app_id
  app_id="$(az ad app list --display-name "$name" --query "[0].appId" -o tsv)"
  if [ -z "$app_id" ]; then
    app_id="$(az ad app create --display-name "$name" --sign-in-audience AzureADMyOrg --query appId -o tsv)"
    az ad sp create --id "$app_id" >/dev/null
    sleep 10
  fi
  local sp_oid
  sp_oid="$(az ad sp show --id "$app_id" --query id -o tsv)"

  # --- one federated credential per GitHub Environment this identity may run in ---
  local ghenv
  for ghenv in "${class}-plan" "${class}"; do
    az ad app federated-credential create --id "$app_id" --parameters "$(cat <<JSON
{
  "name": "gh-${ghenv}",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:${GH_ORG}/${GH_REPO}:environment:${ghenv}",
  "description": "GitHub Actions ${ghenv}",
  "audiences": ["api://AzureADTokenExchange"]
}
JSON
)" >/dev/null 2>&1 || echo "  (federated credential gh-${ghenv} already exists)" >&2
  done

  # --- Azure RBAC: Contributor is the ceiling. No role-assignment rights needed. ---
  az role assignment create --assignee-object-id "$sp_oid" --assignee-principal-type ServicePrincipal \
    --role "Contributor" --scope "/subscriptions/${SUBSCRIPTION_ID}" >/dev/null

  # terraform plan takes a state lock, so planning needs blob WRITE, scoped to the container
  az role assignment create --assignee-object-id "$sp_oid" --assignee-principal-type ServicePrincipal \
    --role "Storage Blob Data Contributor" --scope "$TFSTATE_CONTAINER_ID" >/dev/null

  # the only thing this function writes to stdout — consumed by tee below
  echo "${class} ${app_id}"
}

: > /tmp/acaplat-identities.txt
for class in dev staging prod; do
  create_identity "$class" | tee -a /tmp/acaplat-identities.txt
done
```

You should see three lines of `<class> <client-id>`:

```
dev      11111111-1111-1111-1111-111111111111
staging  22222222-2222-2222-2222-222222222222
prod     33333333-3333-3333-3333-333333333333
```

Verify each identity has exactly two subjects:

```bash
while read -r class app_id; do
  echo "== $class"
  az ad app federated-credential list --id "$app_id" --query "[].subject" -o tsv
done < /tmp/acaplat-identities.txt
```

### 1.7 Bootstrap complete — record these values

```bash
cat <<SUMMARY
AZURE_TENANT_ID         = $TENANT_ID
AZURE_SUBSCRIPTION_ID   = $SUBSCRIPTION_ID
PLATFORM_RESOURCE_GROUP = $PLATFORM_RESOURCE_GROUP
TFSTATE_STORAGE_ACCOUNT = $TFSTATE_STORAGE_ACCOUNT
TFSTATE_CONTAINER       = $TFSTATE_CONTAINER
ACR_NAME                = $ACR_NAME
SUMMARY
```

None of these are secrets — they are identifiers, and they go into GitHub Actions
**variables**, not secrets. There is no client secret to record, because there is none.

---

## Part 2 — GitHub configuration

### 2.1 Authenticate and select the repository

```bash
gh auth login
gh repo set-default "$GH_ORG/$GH_REPO"
```

### 2.2 Create the GitHub Environments

Six: an ungated `<class>-plan` so a plan is always produced for review, and a `<class>`
environment that carries the gate for apply and destroy.

```bash
for e in dev-plan dev staging-plan staging prod-plan prod; do
  gh api -X PUT "repos/$GH_ORG/$GH_REPO/environments/$e" >/dev/null
  echo "created environment: $e"
done
```

### 2.3 Set the repository-level variables

```bash
gh variable set AZURE_TENANT_ID         --body "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID   --body "$SUBSCRIPTION_ID"
gh variable set PLATFORM_RESOURCE_GROUP --body "$PLATFORM_RESOURCE_GROUP"
gh variable set TFSTATE_STORAGE_ACCOUNT --body "$TFSTATE_STORAGE_ACCOUNT"
gh variable set TFSTATE_CONTAINER       --body "$TFSTATE_CONTAINER"
gh variable set ACR_NAME                --body "$ACR_NAME"
```

### 2.4 Set the per-environment client IDs

Each class's identity is used by both of its environments.

```bash
while read -r class app_id; do
  gh variable set AZURE_CLIENT_ID --env "${class}-plan" --body "$app_id"
  gh variable set AZURE_CLIENT_ID --env "${class}"      --body "$app_id"
  echo "$class -> $app_id"
done < /tmp/acaplat-identities.txt
```

Verify:

```bash
gh variable list
gh variable list --env prod
```

### 2.5 Add the production approval gate

Only production is gated. Replace `<REVIEWER_USER_ID>` with a user ID from
`gh api users/<login> --jq .id`, or a team ID from
`gh api orgs/$GH_ORG/teams/<team-slug> --jq .id` (with `"type": "Team"`).

```bash
gh api -X PUT "repos/$GH_ORG/$GH_REPO/environments/prod" --input - <<'JSON'
{
  "wait_timer": 0,
  "prevent_self_review": true,
  "reviewers": [{"type": "User", "id": <REVIEWER_USER_ID>}],
  "deployment_branch_policy": {"protected_branches": true, "custom_branch_policies": false}
}
JSON
```

Restrict staging to protected branches, but do not require a reviewer:

```bash
gh api -X PUT "repos/$GH_ORG/$GH_REPO/environments/staging" --input - <<'JSON'
{
  "deployment_branch_policy": {"protected_branches": true, "custom_branch_policies": false}
}
JSON
```

`dev` and all three `*-plan` environments are deliberately left ungated — self-service and
always-visible plans are the point.

### 2.6 Protect the default branch

```bash
gh api -X PUT "repos/$GH_ORG/$GH_REPO/branches/main/protection" --input - <<'JSON'
{
  "required_status_checks": {"strict": true, "contexts": ["terraform-plan"]},
  "enforce_admins": false,
  "required_pull_request_reviews": {"required_approving_review_count": 1},
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
```

Add `.github/CODEOWNERS` so sandbox changes stay self-service while shared environments
require platform review:

```
/terraform/           @<ORG>/platform-team
/scripts/             @<ORG>/platform-team
/.github/             @<ORG>/platform-team
/envs/staging/        @<ORG>/platform-team
/envs/prod/           @<ORG>/platform-team
# /envs/dev/ intentionally unowned — developers self-serve
```

---

## Part 3 — First deployment

### 3.1 Verify OIDC before touching Terraform

The cheapest possible test of the whole identity chain. Push this as
`.github/workflows/oidc-check.yml`, run it against `dev-plan`, then delete it.

```yaml
name: OIDC check
on: { workflow_dispatch: }
permissions: { id-token: write, contents: read }
jobs:
  check:
    runs-on: ubuntu-latest
    environment: dev-plan
    steps:
      - uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
      - run: az account show -o table
```

(`azure/login@v2` is unpinned here only because this file is deleted immediately after the
check. Every workflow that stays in the repo pins actions to a full commit SHA.)

If this passes, the federated credential subject, the GitHub Environment name, and the
variables all line up. If it fails with `AADSTS70021: No matching federated identity record
found`, the subject and the environment name disagree — see
[Troubleshooting](#troubleshooting).

### 3.2 Create your sandbox environment file

```bash
cp envs/dev/dev-template.tfvars envs/dev/dev-ryan.tfvars
```

```hcl
# envs/dev/dev-ryan.tfvars
env_name  = "dev-ryan"
env_class = "dev"
location  = "eastus2"
owner     = "ryan@example.com"
ttl_hours = 72
```

Open a PR. `pr-plan.yml` posts the plan as a comment. Merge it.

### 3.3 Deploy

```bash
gh workflow run deploy.yml -f environment=dev-ryan
gh run watch
```

Or in the browser: **Actions ▸ Deploy ▸ Run workflow ▸ environment: `dev-ryan`**.

The job summary ends with the public URL:

```
app_url = https://ca-hello-dev-ryan.politemoss-1a2b3c4d.eastus2.azurecontainerapps.io
```

The apply job already curls that URL and fails the run on anything other than HTTP 200, so
a green run means a working endpoint.

### 3.4 Deploy staging and production

```bash
gh workflow run deploy.yml -f environment=staging
gh workflow run deploy.yml -f environment=prod       # pauses for approval before apply
```

For `prod`, the run stops after the plan and waits. Review the plan artifact, then approve
the `prod` environment in the Actions UI. The apply consumes the **exact** plan file that
was reviewed.

### 3.5 Prove the DR story

```bash
gh workflow run deploy.yml -f environment=prod-dr
```

`envs/prod/prod-dr.tfvars` differs from `prod.tfvars` only in `env_name` and `location`. A
complete second-region stack comes up with no code changes. That is the whole DR design.

---

## Day-2 operations

| Task | Command |
|---|---|
| Deploy any environment | `gh workflow run deploy.yml -f environment=<env>` |
| Destroy any environment | `gh workflow run destroy.yml -f environment=<env> -f confirm=<env>` |
| Watch a run | `gh run watch` |
| List deployed environments | `az group list --tag managed_by=terraform -o table` |
| Find abandoned sandboxes | `az group list --tag env_class=dev --query "[].{name:name, expires:tags.expires_at, owner:tags.owner}" -o table` |
| List state files | `az storage blob list --account-name $TFSTATE_STORAGE_ACCOUNT -c tfstate --auth-mode login -o table` |
| Tail app logs | `az containerapp logs show -n ca-hello-<env> -g rg-acaplat-<env>-eus2 --follow` |

### Creating a new environment

Add one file. That is the entire procedure.

| Environment kind | File | Platform review |
|---|---|---|
| Developer sandbox | `envs/dev/dev-<name>.tfvars` | no |
| Staging | `envs/staging/<name>.tfvars` | yes |
| Production / DR | `envs/prod/<name>.tfvars` | yes |

### Destroying an environment

```bash
gh workflow run destroy.yml -f environment=dev-ryan -f confirm=dev-ryan
```

`confirm` must exactly match `environment` or the run fails immediately. Production
destroys additionally wait on the same reviewer that production deploys do.

---

## Local development

Local runs are for **sandboxes only**. Staging and production are pipeline-only.

```bash
az login
az account set --subscription "$SUBSCRIPTION_ID"

export PLATFORM_RESOURCE_GROUP="rg-acaplat-platform-eus2"
export TFSTATE_STORAGE_ACCOUNT="<from the bootstrap summary>"
export TFSTATE_CONTAINER="tfstate"
export ACR_NAME="<from the bootstrap summary>"
export ARM_SUBSCRIPTION_ID="$SUBSCRIPTION_ID"

./scripts/tf.sh plan    dev-ryan
./scripts/tf.sh apply   dev-ryan
./scripts/tf.sh destroy dev-ryan
```

You need `Storage Blob Data Contributor` on the state container (granted to yourself in
step 1.4) and `Contributor` on the subscription.

`tf.sh` is the same script the workflows call, so a plan that works locally works in the
pipeline. Always use it rather than running `terraform` directly: it passes `-reconfigure`
with the correct backend key, and skipping that silently reuses the previous environment's
state.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `AADSTS70021: No matching federated identity record found` | The OIDC `sub` claim matches no federated credential | The job's `environment:` must exactly equal the credential subject's environment segment. Check with `az ad app federated-credential list --id <APP_ID> --query "[].subject" -o tsv` |
| `Error: building AzureRM Client: … ARM_SUBSCRIPTION_ID` | azurerm 4.x requires an explicit subscription | Export `ARM_SUBSCRIPTION_ID` |
| `403` / `AuthorizationPermissionMismatch` at `terraform init` | Identity lacks data-plane access to the state container | Grant `Storage Blob Data Contributor` on the **container**, not just `Contributor` on the account. Wait ~60s for propagation |
| `KeyBasedAuthenticationNotPermitted` from `az storage` | Shared-key access is disabled by design | Add `--auth-mode login` |
| `MissingSubscriptionRegistration` for `Microsoft.App` | Provider not registered | Re-run step 1.3; registration takes several minutes |
| `LinkedAuthorizationFailed` when attaching the identity | The deployment identity cannot assign the shared managed identity | With subscription `Contributor` this does not occur. If you later scope the CI identity down, grant it `Managed Identity Operator` on the shared identity |
| `Error: creating Container App … name is invalid` | Name exceeded 32 characters | Shorten `env_name`; the validation rule should have caught this |
| Plan succeeds, apply fails on `cpu`/`memory` | Illegal ACA CPU/memory pair | Use `0.25`/`0.5Gi`, `0.5`/`1Gi`, `0.75`/`1.5Gi`, or `1.0`/`2Gi` |
| State lock held after a cancelled run | Blob lease still active | `terraform force-unlock <LOCK_ID>` — only after confirming no run is in flight |
| PR plan fails with no credentials | Fork PRs never receive OIDC tokens | Use branches in this repository |
| `az ad app create` → `Insufficient privileges` | Tenant restricts app registration | Ask for the Entra `Application Developer` role |

---

## Cost

| Item | Approximate monthly cost |
|---|---|
| Developer sandbox (scale-to-zero, logs capped at 1 GB/day) | $0–5 |
| Staging (1 replica, 0.25 vCPU) | $30–50 |
| Production (2 replicas, 0.5 vCPU) | $100–160 |
| Production DR (cold — defined, not deployed) | $0 |
| Shared platform (state storage + Basic registry) | ~$6 |

Sandboxes scale to zero when idle. The largest cost *risk* is **Log Analytics** ingestion,
billed per GB; each environment caps its own workspace via `log_daily_quota_gb`, defaulting
to 1 GB/day for sandboxes.

### Tearing down everything

```bash
# 1. Destroy every environment first — otherwise you orphan Azure resources.
for env in dev-ryan staging prod prod-dr; do
  gh workflow run destroy.yml -f environment="$env" -f confirm="$env"
done

# 2. Then remove the shared platform layer and the CI identities.
az group delete --name "$PLATFORM_RESOURCE_GROUP" --yes
while read -r class app_id; do az ad app delete --id "$app_id"; done < /tmp/acaplat-identities.txt
```

---

## Further reading

- [`docs/functional-spec.md`](docs/functional-spec.md) — architecture, environment contract,
  identity model, CI/CD design, DR, acceptance criteria, decisions log.
- [`CLAUDE.md`](CLAUDE.md) — working rules, conventions, build order, known pitfalls.
