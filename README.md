# terraform-aca — Azure Container Apps platform

Terraform + GitHub Actions for running containers on **Azure Container Apps**. One
Terraform core serves every environment; environments are defined purely by variables
files.

- Developers stand up and tear down their own sandbox from the Actions tab.
- Staging and production run the same code with different inputs, behind an approval gate.
- DR is simply another variables file with a different region.
- No secrets — GitHub authenticates to Azure with OIDC.

> **Status:** specification phase. These documents are complete and under review; the
> Terraform and workflows they describe are not yet written. See
> [`docs/functional-spec.md`](docs/functional-spec.md) for the design and
> [`CLAUDE.md`](CLAUDE.md) for working rules and the build order.

---

## How it works

```
envs/dev/dev-ryan.tfvars  ─┐
envs/staging/staging.tfvars┤
envs/prod/prod.tfvars     ─┼──▶  terraform/*.tf ──▶  Azure
envs/prod/prod-dr.tfvars  ─┘            │
                                        └─ state key = <env_name>.tfstate
```

```
Actions ▸ Deploy   ▸ environment: dev-ryan  ▸ Run   →  public HTTPS URL
Actions ▸ Destroy  ▸ environment: dev-ryan  ▸ confirm: dev-ryan  ▸ Run
```

Sandboxes need no approval. Production apply and destroy pause for a reviewer.

### Two layers

| Layer | Created by | Lifetime | Contents |
|---|---|---|---|
| **Shared platform** | `scripts/bootstrap-azure.sh`, once | Outlives every environment | State storage, container registry, managed identity, CI app registrations |
| **Environment** | The core Terraform, per environment | Created and destroyed freely | Resource group, Log Analytics workspace, ACA environment, container app |

The core *reads* shared resources with data sources and never creates them — which is why
it creates no role assignments, and why CI needs nothing beyond `Contributor`.

```
terraform/                 the core — identical for every environment
envs/{dev,staging,prod}/   the only place environments differ
scripts/tf.sh              all Terraform execution (CI calls it too)
scripts/bootstrap-azure.sh
.github/workflows/         plan · deploy · destroy
```

---

## Part 1 — Azure bootstrap from zero

Assumes **nothing** exists: no account, no subscription, no identities. Run once; every
step is idempotent.

### 1.0 Tooling

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

az version && gh --version && terraform version   # Terraform must be >= 1.9
```

### 1.1 Azure account

Browser only — there is no CLI path to creating a tenant. Sign up at
<https://azure.microsoft.com/free>, or use <https://portal.azure.com> if your organisation
already has a tenant. For a client PoC, check whether an existing Enterprise Agreement
subscription should be used instead.

You need three permissions: `Contributor` on the subscription (create resources),
`User Access Administrator` or `Owner` (assign roles to the CI identities), and Entra
`Application Developer` (create app registrations). If you signed up yourself you have all
three.

### 1.2 Sign in

```bash
az login
az account list --output table
```

```bash
# Set once — every later command uses these.
export SUBSCRIPTION_ID="<paste the SubscriptionId you want to use>"
az account set --subscription "$SUBSCRIPTION_ID"

export TENANT_ID="$(az account show --query tenantId -o tsv)"
export MY_OBJECT_ID="$(az ad signed-in-user show --query id -o tsv)"
```

### 1.3 Register resource providers

New subscriptions do not have the Container Apps providers enabled. Takes a few minutes,
once per subscription.

```bash
for ns in Microsoft.App Microsoft.OperationalInsights Microsoft.ContainerRegistry \
          Microsoft.ManagedIdentity Microsoft.Storage Microsoft.Insights Microsoft.Resources; do
  echo "Registering $ns ..."
  az provider register --namespace "$ns" --wait
done
```

### 1.4 Platform resource group and Terraform state

One resource group holds everything shared. Shared-key access is **disabled**, so no
storage key exists anywhere — all access is via Entra ID.

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

az storage account blob-service-properties update \
  --account-name "$TFSTATE_STORAGE_ACCOUNT" \
  --resource-group "$PLATFORM_RESOURCE_GROUP" \
  --enable-versioning true \
  --enable-delete-retention true --delete-retention-days 30 \
  --enable-container-delete-retention true --container-delete-retention-days 30
```

Shared-key access is off, so grant yourself data-plane access before creating the
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

# RBAC propagation is not instant; wait ~30s.
az storage container create \
  --name "$TFSTATE_CONTAINER" \
  --account-name "$TFSTATE_STORAGE_ACCOUNT" \
  --auth-mode login

export TFSTATE_CONTAINER_ID="${SA_ID}/blobServices/default/containers/${TFSTATE_CONTAINER}"
```

### 1.5 Shared registry and workload identity

The registry is shared so staging and production pull the identical digest a sandbox was
tested with. The identity is shared so the core Terraform never creates a role assignment —
which keeps CI at plain `Contributor`.

```bash
export ACR_NAME="cracaplat$(openssl rand -hex 4)"   # globally unique, alphanumeric
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

The only role assignment involving the workload identity, made here once — never by
Terraform:

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

### 1.6 CI identities

Three app registrations, one per class. Each gets two federated credentials — the ungated
`<class>-plan` environment and the gated `<class>` environment — plus `Contributor` and
write access to the state container.

Derive these from the git remote rather than typing them — a placeholder left
unsubstituted here produces federated credentials that look fine and never match
a real token.

Do **not** name these `GH_REPO` or `GH_ORG`: `GH_REPO` is reserved by the `gh`
CLI as a target-repository override in `OWNER/REPO` form, and setting it breaks
every `gh` command in Part 2.

```bash
remote="$(git remote get-url origin)"
export REPO_OWNER="$(basename "$(dirname "$remote")" | sed 's/.*://')"
export REPO_NAME="$(basename "$remote" .git)"
echo "REPO_OWNER=$REPO_OWNER  REPO_NAME=$REPO_NAME"
```

```bash
create_identity() {
  local class="$1"
  local name="gh-acaplat-${class}"

  local app_id
  app_id="$(az ad app list --display-name "$name" --query "[0].appId" -o tsv)"
  if [ -z "$app_id" ]; then
    app_id="$(az ad app create --display-name "$name" --sign-in-audience AzureADMyOrg --query appId -o tsv)"
    az ad sp create --id "$app_id" >/dev/null
    sleep 10
  fi
  local sp_oid
  sp_oid="$(az ad sp show --id "$app_id" --query id -o tsv)"

  # one federated credential per GitHub Environment this identity may run in
  local ghenv
  for ghenv in "${class}-plan" "${class}"; do
    az ad app federated-credential create --id "$app_id" --parameters "$(cat <<JSON
{
  "name": "gh-${ghenv}",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:${REPO_OWNER}/${REPO_NAME}:environment:${ghenv}",
  "description": "GitHub Actions ${ghenv}",
  "audiences": ["api://AzureADTokenExchange"]
}
JSON
)" >/dev/null 2>&1 || echo "  (federated credential gh-${ghenv} already exists)" >&2
  done

  az role assignment create --assignee-object-id "$sp_oid" --assignee-principal-type ServicePrincipal \
    --role "Contributor" --scope "/subscriptions/${SUBSCRIPTION_ID}" >/dev/null

  # terraform plan takes a state lock, so planning needs blob WRITE, scoped to the container
  az role assignment create --assignee-object-id "$sp_oid" --assignee-principal-type ServicePrincipal \
    --role "Storage Blob Data Contributor" --scope "$TFSTATE_CONTAINER_ID" >/dev/null

  echo "${class} ${app_id}"    # the only stdout — consumed by tee
}

: > /tmp/acaplat-identities.txt
for class in dev staging prod; do
  create_identity "$class" | tee -a /tmp/acaplat-identities.txt
done
```

GitHub presents one of two OIDC subject formats, depending on the repository's
settings:

```
classic    repo:OWNER/REPO:environment:NAME
ID-based   repo:OWNER@<ownerId>/REPO@<repoId>:environment:NAME     (rename-proof)
```

The script registers **both**, because which one arrives is not something you
control from Azure, and a mismatch surfaces only as an opaque `AADSTS700213` at
the first deploy. Registering both costs nothing.

Verify each identity has four subjects (two formats × two environments):

```bash
while read -r class app_id; do
  echo "== $class"
  az ad app federated-credential list --id "$app_id" --query "[].subject" -o tsv
done < /tmp/acaplat-identities.txt
```

### 1.7 Record these values

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

These are identifiers, not secrets — they go into GitHub Actions **variables**. There is no
client secret to record, because there is none.

---

## Part 2 — GitHub configuration

`GH_REPO` and `GH_HOST` are reserved by the `gh` CLI: `GH_REPO` overrides the
target repository for every command and must be `OWNER/REPO`. If one is set to
anything else — including a bare repository name left over from an earlier
shell — every `gh` command in this Part fails with
`expected the "[HOST/]OWNER/REPO" format`. Clear them first.

```bash
unset GH_REPO GH_HOST

: "${REPO_OWNER:?set REPO_OWNER first — see step 1.6}"
: "${REPO_NAME:?set REPO_NAME first — see step 1.6}"

gh auth login
gh repo set-default "$REPO_OWNER/$REPO_NAME"

# Should print ryanrca/terraform-aca, resolved from the git remote.
gh repo view --json nameWithOwner --jq .nameWithOwner
```

### 2.1 Environments

Six: an ungated `<class>-plan` so a plan is always produced for review, and `<class>` which
carries the gate for apply and destroy.

```bash
: "${REPO_OWNER:?set REPO_OWNER first — see step 1.6}"
: "${REPO_NAME:?set REPO_NAME first — see step 1.6}"
case "$REPO_OWNER$REPO_NAME" in *'<'*|*'>'*) echo "REPO_OWNER/REPO_NAME still hold a placeholder" >&2; return 1 2>/dev/null || exit 1 ;; esac

for e in dev-plan dev staging-plan staging prod-plan prod; do
  if gh api -X PUT "repos/$REPO_OWNER/$REPO_NAME/environments/$e" --silent; then
    echo "created environment: $e"
  else
    echo "FAILED to create environment: $e" >&2
  fi
done
```

A 404 here means one of three things: `REPO_OWNER`/`REPO_NAME` are unset in the current
shell, the repository has not been pushed to GitHub yet, or the repository is
**private on a Free plan** — GitHub Environments require a public repository, or
GitHub Pro/Team/Enterprise for a private one. Check with:

```bash
gh api "repos/$REPO_OWNER/$REPO_NAME" --jq '{full_name, visibility, plan: (.owner.plan.name // "not visible")}'
```

### 2.2 Variables

```bash
gh variable set AZURE_TENANT_ID         --body "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID   --body "$SUBSCRIPTION_ID"
gh variable set PLATFORM_RESOURCE_GROUP --body "$PLATFORM_RESOURCE_GROUP"
gh variable set TFSTATE_STORAGE_ACCOUNT --body "$TFSTATE_STORAGE_ACCOUNT"
gh variable set TFSTATE_CONTAINER       --body "$TFSTATE_CONTAINER"
gh variable set ACR_NAME                --body "$ACR_NAME"

# each class's identity is used by both of its environments
while read -r class app_id; do
  gh variable set AZURE_CLIENT_ID --env "${class}-plan" --body "$app_id"
  gh variable set AZURE_CLIENT_ID --env "${class}"      --body "$app_id"
done < /tmp/acaplat-identities.txt
```

### 2.3 Gates

Only production is gated. The reviewer must be a real numeric ID, so derive it
rather than typing one in. Note the **unquoted** heredoc delimiter on the first
command — `<<JSON`, not `<<'JSON'`. A quoted delimiter stops the shell expanding
the variable and GitHub answers `400 Problems parsing JSON`.

```bash
# Yourself. For a team: gh api orgs/$REPO_OWNER/teams/<slug> --jq .id, then "type": "Team".
REVIEWER_ID="$(gh api user --jq .id)"
echo "reviewer id: $REVIEWER_ID"

gh api -X PUT "repos/$REPO_OWNER/$REPO_NAME/environments/prod" --input - <<JSON
{
  "wait_timer": 0,
  "prevent_self_review": false,
  "reviewers": [{"type": "User", "id": ${REVIEWER_ID}}],
  "deployment_branch_policy": {"protected_branches": true, "custom_branch_policies": false}
}
JSON

gh api -X PUT "repos/$REPO_OWNER/$REPO_NAME/environments/staging" --input - <<'JSON'
{
  "deployment_branch_policy": {"protected_branches": true, "custom_branch_policies": false}
}
JSON
```

`prevent_self_review` is **false** on purpose. On a one-person PoC you are both
the deployer and the only reviewer, and `true` would make every production run
wait forever on an approval you are not permitted to give. Set it to `true` once
a second reviewer exists.

`dev` and all three `*-plan` environments are deliberately ungated.

Verify the gate took effect:

```bash
gh api "repos/$REPO_OWNER/$REPO_NAME/environments/prod" \
  --jq '{name, reviewers: [.protection_rules[] | select(.type=="required_reviewers") | .reviewers[].reviewer.login]}'
```

### 2.4 Branch protection and CODEOWNERS

```bash
gh api -X PUT "repos/$REPO_OWNER/$REPO_NAME/branches/main/protection" --input - <<'JSON'
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

`.github/CODEOWNERS` keeps sandboxes self-service while shared environments need
review. **The file already exists in this repository** — it is not something to
create, and the block below is file content, not shell commands. Pasting it into
a shell makes zsh treat `<ORG>` as an input redirect.

Owners must match the account type. A team reference (`@org/team-slug`) is valid
only on an organisation-owned repository; on a personal account, use the user:

```bash
# Personal account (the default here)
sed -i 's|@[^ ]*/platform-team|@'"$REPO_OWNER"'|' .github/CODEOWNERS

# Organisation: point at a team instead
# sed -i 's|@'"$REPO_OWNER"'$|@'"$REPO_OWNER"'/platform-team|' .github/CODEOWNERS

cat .github/CODEOWNERS
```

---

## Part 3 — First deployment

### 3.1 Verify OIDC first

The cheapest test of the whole identity chain: no Terraform, no Azure resources,
no state. It proves that the federated credential subject, the GitHub Environment
name, and the repository variables all agree. Do this before anything else.

**1. Create the file.**

```bash
cat > .github/workflows/oidc-check.yml <<'YAML'
name: OIDC check

# push, not just workflow_dispatch: a workflow_dispatch workflow does not appear
# in the Actions UI until it exists on the DEFAULT branch, so on a feature branch
# there would be nothing to click.
on: [push, workflow_dispatch]

permissions:
  id-token: write
  contents: read

jobs:
  check:
    runs-on: ubuntu-latest
    environment: dev-plan
    steps:
      - uses: azure/login@7ddb5af1ef8758cf1353cf3b42f940aee27ba21c # v3.0.2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
      - run: az account show --output table
YAML
```

**2. Commit and push it.** The push is what triggers the run.

```bash
git add .github/workflows/oidc-check.yml
git commit -m "chore: temporary OIDC pre-flight check"
git push
```

**3. Watch the run.** It takes about 20 seconds to appear.

```bash
gh run list --workflow=oidc-check.yml
gh run watch
```

**4. What success looks like.** The `az account show` step prints your
subscription, which means Azure accepted a token minted by GitHub:

```
Name              CloudName    SubscriptionId                        State    IsDefault
----------------  -----------  ------------------------------------  -------  -----------
Your Subscription AzureCloud   00000000-0000-0000-0000-000000000000  Enabled  True
```

Confirm the job actually ran green:

```bash
gh run list --workflow=oidc-check.yml --json conclusion,headBranch --jq '.[0]'
# expect: {"conclusion":"success","headBranch":"<your branch>"}
```

**5. If it fails**, read the error before changing anything:

| Symptom | Cause | Fix |
|---|---|---|
| No run appears at all | The workflow file has a YAML error, or it was never pushed | `gh run list --workflow=oidc-check.yml`; check the Actions tab, which shows parse errors against the file |
| `AADSTS70021: No matching federated identity record found` | The credential subject does not match `repo:OWNER/REPO:environment:dev-plan` | `az ad app federated-credential list --id <dev app id> --query "[].subject" -o tsv` and compare character for character |
| `Az CLI Login failed` with an empty client id | `AZURE_CLIENT_ID` is missing on the `dev-plan` environment | `gh variable get AZURE_CLIENT_ID --env dev-plan`; re-run step 2.2 if empty |
| `Error: Value cannot be null. (Parameter 'tenantId')` | Repository variables were never set | `gh variable list`; re-run step 2.2 |
| Job waits on approval | A protection rule was applied to `dev-plan` | `dev-plan` must be ungated — see step 2.3 |

**6. Delete it once green.** It has served its purpose and grants `id-token:
write` on every push.

```bash
git rm .github/workflows/oidc-check.yml
git commit -m "chore: remove temporary OIDC pre-flight check"
git push
```

### 3.2 Create a sandbox and deploy

```hcl
# envs/dev/dev-ryan.tfvars
env_name  = "dev-ryan"
env_class = "dev"
location  = "eastus2"
owner     = "ryan@example.com"
ttl_hours = 72
```

Open a PR (`pr-plan.yml` posts the plan as a comment), merge, then:

```bash
gh workflow run deploy.yml -f environment=dev-ryan
gh run watch
```

The job summary ends with the public URL. The apply job already curls it and fails the run
on anything but HTTP 200, so a green run means a working endpoint.

### 3.3 Staging, production, DR

```bash
gh workflow run deploy.yml -f environment=staging
gh workflow run deploy.yml -f environment=prod      # pauses for approval before apply
gh workflow run deploy.yml -f environment=prod-dr   # second region, no code changes
```

For `prod` the run stops after the plan. Review the plan artifact, approve the `prod`
environment in the Actions UI, and the apply consumes that exact plan.

---

## Day-2 operations

| Task | Command |
|---|---|
| Deploy | `gh workflow run deploy.yml -f environment=<env>` |
| Destroy | `gh workflow run destroy.yml -f environment=<env> -f confirm=<env>` |
| List deployed environments | `az group list --tag managed_by=terraform -o table` |
| Find abandoned sandboxes | `az group list --tag env_class=dev --query "[].{name:name, expires:tags.expires_at, owner:tags.owner}" -o table` |
| List state files | `az storage blob list --account-name $TFSTATE_STORAGE_ACCOUNT -c tfstate --auth-mode login -o table` |
| Tail app logs | `az containerapp logs show -n ca-hello-<env> -g rg-acaplat-<env>-eus2 --follow` |

**A new environment is one new file:** `envs/dev/dev-<name>.tfvars` (no review),
`envs/staging/` or `envs/prod/` (platform review via CODEOWNERS).

`confirm` must exactly match `environment` or the destroy fails immediately. **Production
destroys wait on the same reviewer that production deploys do.**

---

## Local development

Sandboxes only — staging and production are pipeline-only.

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

`tf.sh` is the same script the workflows call, so a plan that works locally works in the
pipeline. Use it rather than running `terraform` directly — it passes `-reconfigure` with
the correct backend key, and skipping that silently reuses the previous environment's state.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `AADSTS700213 / AADSTS70021: No matching federated identity record found` | Compare the `subject claim` printed in the failing job's log against `az ad app federated-credential list --id <APP_ID> --query "[].subject" -o tsv`. If the claim contains numeric IDs (`repo:owner@123/repo@456:...`), your repository issues ID-based subjects — re-run `scripts/bootstrap-azure.sh` with `gh` authenticated to register that form |
| `Error: building AzureRM Client: … ARM_SUBSCRIPTION_ID` | azurerm 4.x needs an explicit subscription — export `ARM_SUBSCRIPTION_ID` |
| `403` / `AuthorizationPermissionMismatch` at `terraform init` | Grant `Storage Blob Data Contributor` on the **container**, not just `Contributor` on the account. Allow ~60s propagation |
| `KeyBasedAuthenticationNotPermitted` from `az storage` | Shared-key access is disabled by design — add `--auth-mode login` |
| `MissingSubscriptionRegistration` for `Microsoft.App` | Re-run step 1.3; registration takes several minutes |
| `LinkedAuthorizationFailed` attaching the identity | Does not occur at subscription `Contributor`. If you scope CI down later, grant `Managed Identity Operator` on the shared identity |
| `creating Container App … name is invalid` | Name exceeded 32 chars — shorten `env_name` |
| Apply fails on `cpu`/`memory` | Use a legal ACA pair: `0.25`/`0.5Gi`, `0.5`/`1Gi`, `0.75`/`1.5Gi`, `1.0`/`2Gi` |
| State lock held after a cancelled run | `terraform force-unlock <LOCK_ID>` — only after confirming no run is in flight |
| PR plan has no credentials | Fork PRs never receive OIDC tokens; use branches in this repo |
| `az ad app create` → `Insufficient privileges` | Ask for the Entra `Application Developer` role |

---

## Cost

Sandbox $0–5/mo (scale-to-zero) · staging $30–50 · production $100–160 · cold DR $0 ·
shared platform ~$6. The dominant risk is **Log Analytics** ingestion, billed per GB and
capped per environment by `log_daily_quota_gb`.

### Tearing down everything

```bash
# Destroy every environment first — otherwise you orphan Azure resources.
for env in dev-ryan staging prod prod-dr; do
  gh workflow run destroy.yml -f environment="$env" -f confirm="$env"
done

az group delete --name "$PLATFORM_RESOURCE_GROUP" --yes
while read -r class app_id; do az ad app delete --id "$app_id"; done < /tmp/acaplat-identities.txt
```
