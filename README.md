# terraform-aca — Azure Container Apps platform

Terraform + GitHub Actions platform for running containerised workloads on **Azure
Container Apps**. One Terraform core serves every environment; environments are defined
purely by variables files.

- **Developers** stand up and tear down their own sandbox from the Actions tab.
- **Staging and production** run the same code with different inputs, behind approval gates.
- **Disaster recovery** is one more variables file with a different region.
- **No secrets** — GitHub authenticates to Azure with OIDC workload identity federation.

> **Status:** specification phase. The documents in this repo are complete and under
> review; the Terraform and workflows they describe are not yet written. See
> [`docs/functional-spec.md`](docs/functional-spec.md) for the full design and
> [`CLAUDE.md`](CLAUDE.md) for contributor/agent working rules and the build order.

---

## Contents

- [How it works](#how-it-works)
- [Repository layout](#repository-layout)
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
envs/dev/dev-ryan.tfvars ─┐
envs/staging/staging.tfvars┤
envs/prod/prod.tfvars     ─┼──▶  terraform/  (one core, unchanged)  ──▶  Azure
envs/prod/prod-dr.tfvars  ─┘            │
                                        └─ state key = <env_name>.tfstate
```

Every environment gets its own resource group, its own Container Apps environment, its own
Log Analytics workspace, and its own Terraform state file. Nothing is shared except the
state storage account, which is created once during bootstrap and never managed by the
core Terraform.

Deploying and destroying are both GitHub Actions workflows that take an environment name:

```
Actions ▸ Deploy   ▸ environment: dev-ryan  ▸ Run   →  public HTTPS URL
Actions ▸ Destroy  ▸ environment: dev-ryan  ▸ confirm: dev-ryan  ▸ Run
```

Sandboxes need no approval. Staging and production apply/destroy pause on a GitHub
Environment gate until a reviewer approves.

## Repository layout

```
terraform/              the core — identical for every environment
envs/{dev,staging,prod} the only place environments differ
scripts/                bootstrap, local wrapper, TTL reaper
.github/workflows/      plan / deploy / destroy / reap
docs/functional-spec.md architecture, rationale, decisions, acceptance criteria
CLAUDE.md               how to work in this repo (rules, conventions, gotchas)
```

---

## Part 1 — Azure bootstrap from zero

Everything below assumes you are starting with **nothing**: no Azure account, no
subscription, no storage, no identities. Run it once. It is safe to re-run — every step is
idempotent.

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

# Terraform (if not already present)
terraform version   # need >= 1.9
```

Verify:

```bash
az version && gh --version && terraform version
```

### 1.1 Create the Azure account and subscription

Done in a browser — there is no CLI path to creating a tenant.

1. Go to <https://azure.microsoft.com/free> (or <https://portal.azure.com> if your
   organisation already has a tenant) and sign up. A credit card is required even for the
   free tier.
2. This creates a **Microsoft Entra tenant** and one **subscription** (usually
   "Azure subscription 1" or "Free Trial").
3. Note your organisation's billing arrangement. For a client PoC, ask whether you should
   use an existing Enterprise Agreement subscription instead of a new pay-as-you-go one.

**Permissions you need on the subscription and tenant.** You must be able to (a) create
resources, (b) assign RBAC roles, and (c) create Entra application registrations. If you
signed up yourself you already have all three. Inside an existing corporate tenant, ask for:

| Need | Role |
|---|---|
| Create resources | `Contributor` on the subscription |
| Assign roles to the CI identities | `User Access Administrator` or `Owner` on the subscription |
| Create app registrations | Entra `Application Developer` (or the tenant default allowing app creation) |

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
minutes and only ever has to be done once per subscription.

```bash
for ns in Microsoft.App \
          Microsoft.OperationalInsights \
          Microsoft.ContainerRegistry \
          Microsoft.ManagedIdentity \
          Microsoft.Storage \
          Microsoft.Insights \
          Microsoft.Network \
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

### 1.4 Create the Terraform state backend

One resource group, one storage account, one blob container. Shared-key access is
**disabled**, so there is no storage key anywhere — all access is via Entra ID.

```bash
export LOCATION="eastus2"
export TFSTATE_RESOURCE_GROUP="rg-acaplat-tfstate-eus2-001"
export TFSTATE_STORAGE_ACCOUNT="stacaplattf$(openssl rand -hex 4)"   # must be globally unique
export TFSTATE_CONTAINER="tfstate"

az group create \
  --name "$TFSTATE_RESOURCE_GROUP" \
  --location "$LOCATION" \
  --tags workload=acaplat purpose=tfstate managed_by=bootstrap

az storage account create \
  --name "$TFSTATE_STORAGE_ACCOUNT" \
  --resource-group "$TFSTATE_RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku Standard_ZRS \
  --kind StorageV2 \
  --https-only true \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --allow-shared-key-access false \
  --public-network-access Enabled \
  --tags workload=acaplat purpose=tfstate managed_by=bootstrap
```

Turn on versioning and soft delete so a corrupted or truncated state file is recoverable:

```bash
az storage account blob-service-properties update \
  --account-name "$TFSTATE_STORAGE_ACCOUNT" \
  --resource-group "$TFSTATE_RESOURCE_GROUP" \
  --enable-versioning true \
  --enable-delete-retention true --delete-retention-days 30 \
  --enable-container-delete-retention true --container-delete-retention-days 30
```

Because shared-key access is off, you must grant **yourself** data-plane access before you
can create the container:

```bash
export SA_ID="$(az storage account show \
  --name "$TFSTATE_STORAGE_ACCOUNT" \
  --resource-group "$TFSTATE_RESOURCE_GROUP" --query id -o tsv)"

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
echo "$TFSTATE_CONTAINER_ID"
```

Verify:

```bash
az storage container list --account-name "$TFSTATE_STORAGE_ACCOUNT" --auth-mode login -o table
```

### 1.5 Create the CI identities

Six app registrations: a **plan** (read-only) and an **apply** (read-write) identity for
each environment class. Each is federated to a specific GitHub Environment, so a workflow
job can only obtain the identity matching the environment it declares.

Set your repository coordinates first:

```bash
export GH_ORG="<your-github-org-or-username>"
export GH_REPO="terraform-aca"
export APP_PREFIX="gh-acaplat"
```

Now run the loop. It creates the app, the service principal, the federated credentials,
and the role assignments.

```bash
create_identity() {
  local class="$1" mode="$2"          # mode = plan | apply
  local name="${APP_PREFIX}-${class}-${mode}"
  local ghenv="${class}-${mode}"

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

  # --- federated credential: this GitHub Environment only ---
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

  # --- plan identities also run on pull_request events ---
  if [ "$mode" = "plan" ]; then
    az ad app federated-credential create --id "$app_id" --parameters "$(cat <<JSON
{
  "name": "gh-pull-request",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:${GH_ORG}/${GH_REPO}:pull_request",
  "description": "GitHub Actions PR plans",
  "audiences": ["api://AzureADTokenExchange"]
}
JSON
)" >/dev/null 2>&1 || echo "  (federated credential gh-pull-request already exists)" >&2
  fi

  # --- Azure RBAC ---
  if [ "$mode" = "plan" ]; then
    az role assignment create --assignee-object-id "$sp_oid" --assignee-principal-type ServicePrincipal \
      --role "Reader" --scope "/subscriptions/${SUBSCRIPTION_ID}" >/dev/null
  else
    az role assignment create --assignee-object-id "$sp_oid" --assignee-principal-type ServicePrincipal \
      --role "Contributor" --scope "/subscriptions/${SUBSCRIPTION_ID}" >/dev/null
    # needed only because Terraform creates the AcrPull assignment for the workload identity
    az role assignment create --assignee-object-id "$sp_oid" --assignee-principal-type ServicePrincipal \
      --role "User Access Administrator" --scope "/subscriptions/${SUBSCRIPTION_ID}" >/dev/null
  fi

  # state access: plan needs write too (terraform plan takes a state lock)
  az role assignment create --assignee-object-id "$sp_oid" --assignee-principal-type ServicePrincipal \
    --role "Storage Blob Data Contributor" --scope "$TFSTATE_CONTAINER_ID" >/dev/null

  # the ONLY thing this function writes to stdout — consumed by tee below
  echo "${ghenv} ${app_id}"
}

: > /tmp/acaplat-identities.txt
for class in dev staging prod; do
  for mode in plan apply; do
    create_identity "$class" "$mode" | tee -a /tmp/acaplat-identities.txt
  done
done

cat /tmp/acaplat-identities.txt
```

You should see six lines of `<github-environment> <client-id>`:

```
dev-plan       11111111-....
dev-apply      22222222-....
staging-plan   33333333-....
staging-apply  44444444-....
prod-plan      55555555-....
prod-apply     66666666-....
```

### 1.5b Add the destroy-gate federated credentials

The destroy workflow reuses the `*-apply` identities, but runs under separate GitHub
Environments (`dev-destroy`, `staging-destroy`, `prod-destroy`) so that permission to
*destroy* an environment can be approved independently of permission to *deploy* to it.
Each apply identity therefore needs one more federated subject:

```bash
while read -r ghenv app_id; do
  case "$ghenv" in
    *-apply)
      class="${ghenv%-apply}"
      az ad app federated-credential create --id "$app_id" --parameters "$(cat <<JSON
{
  "name": "gh-${class}-destroy",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:${GH_ORG}/${GH_REPO}:environment:${class}-destroy",
  "description": "GitHub Actions ${class}-destroy",
  "audiences": ["api://AzureADTokenExchange"]
}
JSON
)" >/dev/null 2>&1 || echo "  (already exists: ${class}-destroy)"
      ;;
  esac
done < /tmp/acaplat-identities.txt
```

Verify that each apply identity now has two subjects, and each plan identity two:

```bash
while read -r ghenv app_id; do
  echo "== $ghenv"
  az ad app federated-credential list --id "$app_id" --query "[].subject" -o tsv
done < /tmp/acaplat-identities.txt
```

### 1.6 Bootstrap complete — record these values

```bash
cat <<SUMMARY
AZURE_TENANT_ID          = $TENANT_ID
AZURE_SUBSCRIPTION_ID    = $SUBSCRIPTION_ID
TFSTATE_RESOURCE_GROUP   = $TFSTATE_RESOURCE_GROUP
TFSTATE_STORAGE_ACCOUNT  = $TFSTATE_STORAGE_ACCOUNT
TFSTATE_CONTAINER        = $TFSTATE_CONTAINER
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

Nine environments: plan / apply / destroy for each of the three classes.

```bash
for e in dev-plan dev-apply dev-destroy \
         staging-plan staging-apply staging-destroy \
         prod-plan prod-apply prod-destroy; do
  gh api -X PUT "repos/$GH_ORG/$GH_REPO/environments/$e" >/dev/null
  echo "created environment: $e"
done
```

### 2.3 Set the repository-level variables

```bash
gh variable set AZURE_TENANT_ID         --body "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID   --body "$SUBSCRIPTION_ID"
gh variable set TFSTATE_RESOURCE_GROUP  --body "$TFSTATE_RESOURCE_GROUP"
gh variable set TFSTATE_STORAGE_ACCOUNT --body "$TFSTATE_STORAGE_ACCOUNT"
gh variable set TFSTATE_CONTAINER       --body "$TFSTATE_CONTAINER"
```

### 2.4 Set the per-environment client IDs

```bash
while read -r ghenv app_id; do
  gh variable set AZURE_CLIENT_ID --env "$ghenv" --body "$app_id"
  echo "$ghenv -> $app_id"
done < /tmp/acaplat-identities.txt

# destroy environments reuse the apply identities
for class in dev staging prod; do
  app_id="$(grep "^${class}-apply " /tmp/acaplat-identities.txt | awk '{print $2}')"
  gh variable set AZURE_CLIENT_ID --env "${class}-destroy" --body "$app_id"
done
```

Verify:

```bash
gh variable list
gh variable list --env prod-apply
```

### 2.5 Add the approval gates

Replace `<REVIEWER_USER_ID>` with a user or team ID. Get a user ID with
`gh api users/<login> --jq .id`; get a team ID with
`gh api orgs/$GH_ORG/teams/<team-slug> --jq .id`.

```bash
# Production apply and destroy: require a reviewer, and forbid self-approval.
for e in prod-apply prod-destroy staging-destroy; do
  gh api -X PUT "repos/$GH_ORG/$GH_REPO/environments/$e" \
    --input - <<JSON
{
  "wait_timer": 0,
  "prevent_self_review": true,
  "reviewers": [{"type": "User", "id": <REVIEWER_USER_ID>}],
  "deployment_branch_policy": {"protected_branches": true, "custom_branch_policies": false}
}
JSON
done

# Staging apply: no reviewer, but only from protected branches.
gh api -X PUT "repos/$GH_ORG/$GH_REPO/environments/staging-apply" --input - <<'JSON'
{
  "deployment_branch_policy": {"protected_branches": true, "custom_branch_policies": false}
}
JSON
```

`dev-apply` and `dev-destroy` are deliberately left ungated — self-service is the point.

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

Also add `.github/CODEOWNERS` so sandbox changes stay self-service while shared
environments require platform review:

```
/terraform/           @<ORG>/platform-team
/.github/             @<ORG>/platform-team
/envs/staging/        @<ORG>/platform-team
/envs/prod/           @<ORG>/platform-team
# /envs/dev/ intentionally unowned — developers self-serve
```

---

## Part 3 — First deployment

### 3.1 Verify OIDC before touching Terraform

Cheapest possible smoke test of the whole identity chain. Push this as
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

(`azure/login@v2` is unpinned here only because this file is deleted immediately after
the check. Every workflow that stays in the repo pins actions to a full commit SHA — see
`CLAUDE.md`.)

If this passes, the federated credential subject, the GitHub Environment name, and the
variables all line up. If it fails with `AADSTS70021: No matching federated identity
record found`, the subject string and the environment name disagree — see
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

Check it:

```bash
curl -sSf https://ca-hello-dev-ryan.<suffix>.eastus2.azurecontainerapps.io
# -> "Welcome to Azure Container Apps!"
```

The `_terraform.yml` apply job already runs this assertion for you — a deploy that returns
anything other than HTTP 200 fails the run.

### 3.4 Deploy staging and production

```bash
gh workflow run deploy.yml -f environment=staging
gh workflow run deploy.yml -f environment=prod       # pauses for approval before apply
```

For `prod`, the run stops after the plan and waits. Review the plan artifact, then approve
the `prod-apply` environment in the Actions UI. The apply consumes the **exact** plan file
that was reviewed.

### 3.5 Prove the DR story

```bash
gh workflow run deploy.yml -f environment=prod-dr
```

`envs/prod/prod-dr.tfvars` differs from `prod.tfvars` only in `env_name` and `location`.
A complete second-region stack comes up with no code changes. That is the whole DR design.

---

## Day-2 operations

| Task | Command |
|---|---|
| Deploy any environment | `gh workflow run deploy.yml -f environment=<env>` |
| Destroy any environment | `gh workflow run destroy.yml -f environment=<env> -f confirm=<env>` |
| Watch a run | `gh run watch` |
| List environments that exist in Azure | `az group list --tag managed_by=terraform -o table` |
| See who owns a sandbox | `az group show -n rg-acaplat-<env>-eus2-001 --query tags` |
| List state files | `az storage blob list --account-name $TFSTATE_STORAGE_ACCOUNT -c tfstate --auth-mode login -o table` |
| Tail app logs | `az containerapp logs show -n ca-hello-<env> -g rg-acaplat-<env>-eus2-001 --follow` |
| Force-run the reaper (dry run) | `gh workflow run reaper.yml -f dry_run=true` |

### Creating a new environment

Add one file. That is the entire procedure.

| Environment kind | File | Reviewer needed |
|---|---|---|
| Developer sandbox | `envs/dev/dev-<name>.tfvars` | no |
| Staging | `envs/staging/<name>.tfvars` | yes |
| Production / DR | `envs/prod/<name>.tfvars` | yes |

### Destroying an environment

```bash
gh workflow run destroy.yml -f environment=dev-ryan -f confirm=dev-ryan
```

`confirm` must exactly match `environment` or the run fails immediately. Staging and
production destroys additionally wait on a reviewer. Sandboxes past their `ttl_hours` are
destroyed automatically by `reaper.yml`.

---

## Local development

Local runs are for **sandboxes only**. Staging and production are pipeline-only; the plan
identities are the only ones a human should ever borrow.

```bash
az login
az account set --subscription "$SUBSCRIPTION_ID"

export TFSTATE_RESOURCE_GROUP="rg-acaplat-tfstate-eus2-001"
export TFSTATE_STORAGE_ACCOUNT="<from the bootstrap summary>"
export TFSTATE_CONTAINER="tfstate"
export ARM_SUBSCRIPTION_ID="$SUBSCRIPTION_ID"

./scripts/tf.sh plan  dev-ryan
./scripts/tf.sh apply dev-ryan
```

You need `Storage Blob Data Contributor` on the state container (granted to yourself in
step 1.4) and `Contributor` on the subscription.

Always let `tf.sh` run `init` — it passes `-reconfigure` with the right backend key.
Running `terraform` directly after switching environments will silently reuse the previous
environment's state.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `AADSTS70021: No matching federated identity record found` | The OIDC `sub` claim does not match any federated credential | The job's `environment:` must exactly equal the credential subject's environment segment. Check with `az ad app federated-credential list --id <APP_ID> -o table` |
| `Error: building AzureRM Client: obtain subscription … ARM_SUBSCRIPTION_ID` | azurerm 4.x requires an explicit subscription | Export `ARM_SUBSCRIPTION_ID` or set `subscription_id` in the provider block |
| `403` / `AuthorizationPermissionMismatch` at `terraform init` | Identity lacks data-plane access to the state container | Grant `Storage Blob Data Contributor` on the **container**, not just `Contributor` on the account. Wait ~60s for propagation |
| `KeyBasedAuthenticationNotPermitted` from `az storage` | Shared-key access is disabled by design | Add `--auth-mode login` to the command |
| `MissingSubscriptionRegistration` for `Microsoft.App` | Provider not registered | Re-run step 1.3; registration takes several minutes |
| `Error: creating Container App … name is invalid` | Name exceeded 32 characters | Shorten `env_name`; the validation rule should have caught this |
| Plan succeeds, apply fails on `cpu`/`memory` | Illegal ACA CPU/memory pair | Use a supported combination: `0.25`/`0.5Gi`, `0.5`/`1Gi`, `0.75`/`1.5Gi`, `1.0`/`2Gi` |
| State lock held after a cancelled run | Blob lease still active | `terraform force-unlock <LOCK_ID>` — only after confirming no run is in flight |
| PR plan fails with no credentials on a fork PR | Forks never receive OIDC tokens | Use branches in this repository; keep the repo internal and forks disabled |
| `az ad app create` → `Insufficient privileges` | Tenant restricts app registration | Ask for the Entra `Application Developer` role |

---

## Cost

| Item | Approximate monthly cost |
|---|---|
| Developer sandbox (scale-to-zero, 1 GB/day log cap) | $0–5 |
| Staging (1 replica, 0.25 vCPU) | $30–50 |
| Production (2 replicas, 0.5 vCPU) | $100–160 |
| Production DR (cold — defined, not deployed) | $0 |
| Terraform state storage | < $1 |

Sandboxes scale to zero when idle and are destroyed automatically after `ttl_hours`
(72 by default). The largest cost *risk* is Log Analytics ingestion, which is capped
per environment by `log_daily_quota_gb`.

### Tearing down the bootstrap

To remove everything, including the shared state backend:

```bash
# 1. Destroy every environment first — otherwise you orphan Azure resources.
for env in dev-ryan staging prod prod-dr; do
  gh workflow run destroy.yml -f environment="$env" -f confirm="$env"
done

# 2. Then remove the shared backend and the CI identities.
az group delete --name "$TFSTATE_RESOURCE_GROUP" --yes
while read -r ghenv app_id; do az ad app delete --id "$app_id"; done < /tmp/acaplat-identities.txt
```

---

## Further reading

- [`docs/functional-spec.md`](docs/functional-spec.md) — architecture, environment
  contract, identity model, CI/CD design, DR, acceptance criteria, decisions log.
- [`CLAUDE.md`](CLAUDE.md) — working rules, conventions, build order, known pitfalls.
