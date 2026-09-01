# CLAUDE.md

Guidance for Claude Code (and any contributor) working in this repository.

## What this repo is

A Terraform + GitHub Actions platform for deploying **Azure Container Apps** environments.
One Terraform root module ("the core") serves every environment — developer sandboxes,
staging, production, and DR. Environments differ **only** by a variables file under
`envs/`.

Read `docs/functional-spec.md` before making design decisions. It is the source of truth
for architecture, the environment contract, and the identity model. This file is the
source of truth for *how to work in the repo*.

Current state: **specification and docs only.** No Terraform or workflows exist yet.
Build them in the order given under "Implementation order".

## The two layers

The single most important distinction in this repo:

| Layer | Created by | Lifetime | Contents |
|---|---|---|---|
| **Shared platform** | `scripts/bootstrap-azure.sh`, once | Outlives every environment | State storage account, container registry, user-assigned managed identity (holding `AcrPull`), CI app registrations |
| **Environment** | The core Terraform, per environment | Created and destroyed freely | Resource group, Log Analytics workspace, ACA environment, container app, management lock |

The core reads shared resources with **data sources**. It never creates them, and it never
creates a role assignment — which is why the CI identities need only `Contributor`.

## Non-negotiable rules

1. **Never put an environment name in `terraform/`.**
   No `var.env_name == "prod"`, no `terraform.workspace`, no
   `count = var.env_class == "dev" ? 0 : 1`. If production needs something a sandbox does
   not, add a **variable with a dev-safe default** (`enable_resource_lock`,
   `log_daily_quota_gb`, …) and set it in the production tfvars. Verify with
   `grep -rniE '"(dev|staging|prod)"' terraform/` — should return only validation
   allow-lists.

2. **Never use Terraform workspaces.** State isolation comes from the backend `key`
   (`<env_name>.tfstate`), passed at `init` time.

3. **Never create a shared resource in the core.** If it must outlive an environment or be
   shared between environments, it goes in bootstrap and the core reads it with a data
   source. A `terraform destroy` of any environment must never break another one.

4. **Never commit backend values.** `terraform/backend.tf` holds an empty
   `backend "azurerm" {}`. All values arrive via `-backend-config`.

5. **Never commit secrets, subscription IDs, tenant IDs, or object IDs.** They live in
   GitHub Actions variables. Placeholders in docs are `<ORG>`, `<REPO>`,
   `<SUBSCRIPTION_ID>`.

6. **Never put Terraform commands in a workflow.** All Terraform execution lives in
   `scripts/tf.sh`. Workflows call it. This is what keeps CI and local runs on the same
   code path.

7. **Apply only saved plans in CI.** The apply job downloads the plan artifact produced by
   the plan job. Never `terraform apply -auto-approve` against a fresh plan in a workflow.

## Repository layout

```
terraform/                 THE CORE — identical for every environment
  versions.tf              terraform + provider version constraints
  providers.tf             azurerm/time providers
  backend.tf               empty partial backend block
  variables.tf             the environment contract + validation
  locals.tf                naming and tag computation
  main.tf                  5 Azure resources + time_offset + 2 data sources
  outputs.tf               app_url, app_fqdn, resource_group_name
envs/                      THE ONLY PLACE ENVIRONMENTS DIFFER
  dev/       dev-*.tfvars  sandboxes (self-service)
  staging/   staging.tfvars
  prod/      prod.tfvars, prod-dr.tfvars
scripts/
  bootstrap-azure.sh       one-time Azure setup (idempotent)
  tf.sh                    ALL TERRAFORM EXECUTION LIVES HERE
.github/workflows/
  _terraform.yml           reusable: OIDC + gate + artifacts, calls tf.sh
  pr-plan.yml              PR: fmt/validate/plan
  deploy.yml               dispatch (any env) + push to main -> staging
  destroy.yml              dispatch, guarded by confirmation + gate
docs/functional-spec.md    architecture and rationale
```

Environment **class** is derived from the directory: `envs/dev/` → `dev`, `envs/staging/`
→ `staging`, `envs/prod/` → `prod`. The tfvars file also states `env_class`; `tf.sh` fails
if the two disagree. Do not add class directories beyond these three without updating
`tf.sh`, `_terraform.yml`, CODEOWNERS, and the spec.

## Entry points

There are two, and only one is the supported deployment path.

| Entry point | Scope | Use |
|---|---|---|
| **GitHub Actions workflows** | Every environment | The supported path. The only way staging and production ever change. |
| **`scripts/tf.sh`** | Sandboxes only | Local iteration. Not a deployment mechanism for shared environments. |

`tf.sh` is the implementation, not a wrapper around one. It owns: resolving the tfvars path
from an environment name, cross-checking `env_class` against the directory, `terraform init
-reconfigure` with the right backend key, `fmt`, `validate`, then `plan`/`apply`/`destroy`.
`_terraform.yml` adds only what is genuinely GitHub's job — OIDC login, the environment
gate, plan artifacts, concurrency, run summary — and its Terraform content is one line per
job.

The reusable workflow lives in `.github/workflows/` because GitHub requires `workflow_call`
workflows to be there. That is acceptable precisely because it contains no logic worth
relocating.

## Conventions

### Terraform style

- Terraform `>= 1.9`. `azurerm` `~> 4.0`, `time` `~> 0.12`. Pin with `~>` and commit
  `.terraform.lock.hcl`.
- No submodules. Six resources with no repetition do not justify a module layer. Introduce
  one when there is a second caller — the first candidate is multiple container apps per
  environment.
- No `for_each` over environments — ever.
- Every variable has a `description` and a `type`. Every variable that can be wrong has a
  `validation` block. Required invariants:
  - `env_class == "dev"` ⇒ `ttl_hours > 0`
  - `env_class == "prod"` ⇒ `enable_resource_lock == true` and `ttl_hours == 0`
  - `env_class != "dev"` ⇒ `app_min_replicas >= 1`
  - `env_name` matches `^[a-z0-9]([a-z0-9-]{1,20})[a-z0-9]$`
- `locals.tf` computes names and tags once; resources reference `local.*`. Never
  interpolate a resource name inline.
- Outputs are stable contracts — renaming one is a breaking change to the workflows.

### Naming

`<abbrev>-acaplat-<env_name>-<region_short>`, e.g. `rg-acaplat-dev-ryan-eus2`. Shared
platform resources use `platform` in place of the environment name. Container App names are
capped at 32 characters; the `env_name` validation rule is what keeps this safe.

### GitHub Actions

- Pin every third-party action to a full commit SHA with a `# vX.Y.Z` comment.
- Job-level `permissions:` always explicit; `id-token: write` only where OIDC is used.
- `concurrency: { group: terraform-${{ inputs.env_name }}, cancel-in-progress: false }` on
  every job that touches state.
- Never echo a token, or `az` output that includes credentials.

### Commits and PRs

- Conventional-commit style subjects (`feat:`, `fix:`, `docs:`, `chore:`).
- A PR that changes `terraform/**` must show plans for every existing environment
  (`pr-plan.yml` does this automatically). Read them before approving.
- A PR that only adds `envs/dev/*.tfvars` needs no platform review — CODEOWNERS covers
  `envs/staging/`, `envs/prod/`, `terraform/`, and `.github/`.

## Common commands

```bash
# Local, sandboxes only. Requires: az login + Storage Blob Data Contributor on the state container.
./scripts/tf.sh plan    dev-ryan
./scripts/tf.sh apply   dev-ryan
./scripts/tf.sh destroy dev-ryan

# What tf.sh does, longhand — note -reconfigure, which is why you should use tf.sh:
cd terraform
terraform init -reconfigure \
  -backend-config="resource_group_name=$PLATFORM_RESOURCE_GROUP" \
  -backend-config="storage_account_name=$TFSTATE_STORAGE_ACCOUNT" \
  -backend-config="container_name=$TFSTATE_CONTAINER" \
  -backend-config="key=dev-ryan.tfstate" \
  -backend-config="use_azuread_auth=true"
terraform plan -var-file=../envs/dev/dev-ryan.tfvars -out=tfplan
terraform apply tfplan

# Quality gates
terraform -chdir=terraform fmt -recursive
terraform -chdir=terraform validate
tflint --chdir=terraform

# Pipeline operations
gh workflow run deploy.yml  -f environment=dev-ryan
gh workflow run destroy.yml -f environment=dev-ryan -f confirm=dev-ryan
gh run watch
```

## Implementation order

Each step is independently verifiable. Do not start step N+1 until step N is verified, and
do not build the workflows before Terraform plans cleanly locally — debugging Terraform
through Actions logs is slow.

1. `scripts/bootstrap-azure.sh`. Verify: the platform resource group contains a storage
   account, a registry, and an identity holding `AcrPull`; three app registrations exist.
2. `terraform/versions.tf`, `providers.tf`, `backend.tf`, `variables.tf`, `locals.tf`,
   `outputs.tf`. Verify: `terraform validate` passes.
3. `terraform/main.tf` — the five resources and two data sources.
4. `envs/dev/dev-template.tfvars`, `envs/staging/staging.tfvars`, `envs/prod/prod.tfvars`,
   `envs/prod/prod-dr.tfvars`.
5. `scripts/tf.sh`. Verify: a real sandbox applies locally and the URL returns 200.
6. `.github/workflows/_terraform.yml`, then `pr-plan.yml`, `deploy.yml`, `destroy.yml`.
   Verify against a sandbox before pointing them at staging.
7. `.github/CODEOWNERS`, `tflint` config, branch protection.

## Things that will bite you

- **ACA needs resource providers registered.** `Microsoft.App` and
  `Microsoft.OperationalInsights` registration is a one-time, per-subscription action that
  takes minutes. It is in the bootstrap script; a first apply failing with
  `MissingSubscriptionRegistration` is why.
- **Container App name limit is 32 chars.** Long `env_name` values collide after truncation
  without the validation rule.
- **`cpu`/`memory` must be a legal ACA pair.** `0.25`/`0.5Gi`, `0.5`/`1Gi`, `0.75`/`1.5Gi`,
  `1.0`/`2Gi`. A mismatched pair fails at apply, not at plan.
- **Shared-key access is disabled on the state storage account.** Any `az storage` command
  against it needs `--auth-mode login`, and the caller needs `Storage Blob Data Contributor`
  on the container — `Contributor` on the account is not enough.
- **Planning needs blob *write*.** `terraform plan` takes a state lock. Read-only access to
  the state container produces a confusing 403 at `init`.
- **`azurerm` 4.x requires an explicit `subscription_id`** in the provider block or
  `ARM_SUBSCRIPTION_ID` in the environment.
- **Forgetting `-reconfigure` plans against the previous environment's state.** This is the
  single most likely way to cause real damage locally. Use `tf.sh`.
- **Fork PRs get no OIDC token.** PR plans only work for branches in this repo.
- **Destroying an environment with a management lock works** (Terraform removes the lock
  first) — but a *manual* portal deletion will not. That is the intent.

## When asked to add something

| Request | Correct move |
|---|---|
| "Production needs X but dev doesn't" | New variable, dev-safe default, set in `envs/prod/*.tfvars`. Never a conditional on env name. |
| "Add a new environment" | One new `.tfvars` under the right class directory. Nothing else. |
| "Add a second container app" | Turn the `app_*` scalars into a `map(object(...))` and `for_each` it. This is the first justified module boundary — extract one then, not before. |
| "Add a database / queue / cache" | New resource in the core gated by an `enable_*` variable defaulting to `false`, unless it must be shared — then it is bootstrap. Revisit the DR section of the spec: state changes the RPO story. |
| "Make it private / VNet-integrated" | Roadmap phase 3. Needs a networking layer and an `enable_vnet_integration` variable; it changes the ingress and DR design, so update the spec first. |
| "Add automatic cleanup of old sandboxes" | Roadmap phase 2. A scheduled workflow that queries `expires_at` tags and dispatches `destroy.yml`. The tag already exists. |
| "Speed up CI" | Cache the provider plugin directory. Do not skip `validate` or the plan artifact. |
| "Give devs more access" | Adjust the GitHub Environment reviewers or the Azure role assignment in bootstrap — not the workflow logic. |
