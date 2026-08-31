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
Build them in the order given in "Implementation order" below.

## Non-negotiable rules

These exist because the entire value of the design collapses without them.

1. **Never put an environment name in `terraform/`.**
   No `var.env_name == "prod"`, no `terraform.workspace`, no `count = var.env_class ==
   "dev" ? 0 : 1`. If production needs something a sandbox does not, add a **variable with
   a dev-safe default** (`enable_resource_lock`, `log_daily_quota_gb`, …) and set it in the
   production tfvars. Verify with:
   `grep -rniE '"(dev|staging|prod)"' terraform/` — should return nothing but validation
   allow-lists.

2. **Never use Terraform workspaces.** State isolation comes from the backend `key`
   (`<env_name>.tfstate`), passed at `init` time.

3. **Never commit backend values.** `terraform/backend.tf` holds an empty
   `backend "azurerm" {}`. All values arrive via `-backend-config`.

4. **Never commit secrets, subscription IDs, tenant IDs, or object IDs.** They live in
   GitHub Actions variables. Placeholders in docs are `<ORG>`, `<REPO>`, `<SUBSCRIPTION_ID>`.

5. **Never add a resource without a tag story.** Everything inherits default tags; the
   resource group additionally carries `expires_at`, `owner`, `env_class`.

6. **Never widen the blast radius.** One environment = one resource group = one state file.
   If something must be shared across environments, it belongs in bootstrap, not in the core.

7. **Apply only saved plans in CI.** The apply job downloads the plan artifact produced by
   the plan job. Never `terraform apply -auto-approve` against a fresh plan in a workflow.

## Repository layout

```
terraform/                 THE CORE — identical for every environment
  versions.tf              terraform + provider version constraints
  providers.tf             azurerm/time providers, default_tags
  backend.tf               empty partial backend block
  variables.tf             the environment contract + validation
  locals.tf                derived values, tag merging
  main.tf                  module composition only
  outputs.tf               app_url, app_fqdn, resource_group_name, …
  modules/
    naming/                the ONLY place naming conventions live
    observability/         Log Analytics workspace
    container_app_env/     ACA managed environment
    container_app/         one container app + ingress + identity
envs/                      THE ONLY PLACE ENVIRONMENTS DIFFER
  dev/       dev-*.tfvars  sandboxes (self-service, TTL enforced)
  staging/   staging.tfvars
  prod/      prod.tfvars, prod-dr.tfvars
scripts/
  bootstrap-azure.sh       one-time tenant setup (idempotent)
  tf.sh                    local wrapper: ./scripts/tf.sh <plan|apply|destroy> <env>
  reap.sh                  find expired sandboxes, dispatch destroys
.github/workflows/
  _terraform.yml           reusable — the ONLY place terraform runs in CI
  pr-plan.yml              PR: fmt/validate/lint/plan
  deploy.yml               dispatch (any env) + push to main → staging
  destroy.yml              dispatch, guarded by confirmation + approval
  reaper.yml               scheduled TTL cleanup
docs/functional-spec.md    architecture and rationale
```

Environment **class** is derived from the directory: `envs/dev/` → `dev`, `envs/staging/`
→ `staging`, `envs/prod/` → `prod`. The tfvars file also states `env_class`; the pipeline
fails if the two disagree. Do not add class directories beyond these three without
updating `_terraform.yml`, CODEOWNERS, and the spec.

## Conventions

### Terraform style

- Terraform `>= 1.9`. `azurerm` `~> 4.0`, `time` `~> 0.12`. Pin with `~>`, commit
  `.terraform.lock.hcl`.
- One resource per logical concept; no `for_each` over environments — ever.
- Every variable has a `description` and a `type`. Every variable that can be wrong has a
  `validation` block.
- Cross-variable invariants go in `validation` (Terraform 1.9+ can reference other
  variables) or a `lifecycle { precondition }` on the resource they protect. Required
  invariants:
  - `env_class == "dev"` ⇒ `ttl_hours > 0`
  - `env_class == "prod"` ⇒ `enable_resource_lock == true` and `ttl_hours == 0`
  - `env_class != "dev"` ⇒ `app_min_replicas >= 1`
  - `env_name` matches `^[a-z0-9]([a-z0-9-]{1,20})[a-z0-9]$`
- `locals.tf` computes tags once; resources reference `local.tags`.
- Outputs are stable contracts — renaming one is a breaking change to the workflows.

### Naming

Everything comes from `modules/naming`. Pattern:
`<abbrev>-acaplat-<env_name>-<region_short>-<instance>`, e.g.
`rg-acaplat-dev-ryan-eus2-001`. Container App names are capped at 32 characters and
storage/registry names must be alphanumeric — the module handles truncation
deterministically. If you need a new resource name, add it to the naming module; do not
interpolate a name inline.

### GitHub Actions

- Pin every third-party action to a full commit SHA with a `# vX.Y.Z` comment.
- Job-level `permissions:` always explicit; `id-token: write` only where OIDC is used.
- Never `echo` a token, plan file contents that could contain secrets, or `az` output that
  includes credentials.
- `concurrency: { group: terraform-${{ inputs.env_name }}, cancel-in-progress: false }` on
  every job that touches state.
- All Terraform execution goes through `_terraform.yml`. If you find yourself writing
  `terraform` in another workflow, stop and extend the reusable one.

### Commits and PRs

- Conventional-commit style subjects (`feat:`, `fix:`, `docs:`, `chore:`).
- A PR that changes `terraform/**` must show plans for every existing environment
  (`pr-plan.yml` does this automatically). Read them before approving.
- A PR that only adds `envs/dev/*.tfvars` needs no platform review — CODEOWNERS covers
  `envs/staging/`, `envs/prod/`, `terraform/`, and `.github/`.

## Common commands

```bash
# Local plan against a sandbox (requires: az login, Storage Blob Data Contributor on state)
./scripts/tf.sh plan dev-ryan
./scripts/tf.sh apply dev-ryan
./scripts/tf.sh destroy dev-ryan

# What tf.sh does, longhand:
cd terraform
terraform init -reconfigure \
  -backend-config="resource_group_name=$TFSTATE_RESOURCE_GROUP" \
  -backend-config="storage_account_name=$TFSTATE_STORAGE_ACCOUNT" \
  -backend-config="container_name=$TFSTATE_CONTAINER" \
  -backend-config="key=dev-ryan.tfstate" \
  -backend-config="use_azuread_auth=true"
terraform plan -var-file=../envs/dev/dev-ryan.tfvars -out=tfplan
terraform apply tfplan

# Quality gates (run before pushing)
terraform -chdir=terraform fmt -recursive
terraform -chdir=terraform validate
tflint --chdir=terraform
checkov -d terraform --quiet

# Pipeline operations
gh workflow run deploy.yml  -f environment=dev-ryan
gh workflow run destroy.yml -f environment=dev-ryan -f confirm=dev-ryan
gh run watch
```

`terraform init` **must** be re-run with `-reconfigure` when switching environments
locally, because the backend key changes. `tf.sh` does this for you; forgetting it is the
single most common way to plan against the wrong state.

## Implementation order

Build in this sequence — each step is independently verifiable:

1. `terraform/versions.tf`, `providers.tf`, `backend.tf`, `variables.tf`, `locals.tf`,
   `outputs.tf` — plus `modules/naming`. Verify: `terraform validate` passes.
2. `modules/observability` + `modules/container_app_env` + `modules/container_app`, wired
   in `main.tf`. Verify: local `plan` against a sandbox tfvars produces the expected
   6-resource plan.
3. `envs/dev/dev-template.tfvars`, `envs/staging/staging.tfvars`, `envs/prod/prod.tfvars`,
   `envs/prod/prod-dr.tfvars`.
4. `scripts/bootstrap-azure.sh` and `scripts/tf.sh`. Verify: a real sandbox applies locally
   and the URL returns 200.
5. `.github/workflows/_terraform.yml`, then `pr-plan.yml`, `deploy.yml`, `destroy.yml`.
   Verify against a sandbox before pointing them at staging.
6. `reaper.yml` and `scripts/reap.sh`.
7. `.github/CODEOWNERS`, `tflint`/`checkov` config, branch protection.

Do not start step N+1 until step N is verified. Do not build the workflows before the
Terraform plans cleanly locally — debugging Terraform through Actions logs is slow.

## Things that will bite you

- **ACA needs resource providers registered.** `Microsoft.App` and
  `Microsoft.OperationalInsights` registration is a one-time, per-subscription action that
  takes minutes. It is in the bootstrap script; if a first apply fails with
  `MissingSubscriptionRegistration`, that is why.
- **Container App name limit is 32 chars.** Long `env_name` values silently collide after
  truncation without the validation rule.
- **`cpu`/`memory` must be a legal ACA pair.** `0.25`/`0.5Gi`, `0.5`/`1Gi`, `0.75`/`1.5Gi`,
  `1.0`/`2Gi`, … A mismatched pair fails at apply, not at plan.
- **Shared-key access is disabled on the state storage account.** Any `az storage` command
  against it needs `--auth-mode login` and the caller needs `Storage Blob Data Contributor`
  on the container — `Contributor` on the account is not enough.
- **Plan identities need blob *write*.** `terraform plan` takes a state lock. `Reader` on
  the subscription plus `Storage Blob Data Contributor` on the state container is the
  correct pair; omitting the latter produces a confusing 403 at `init`.
- **`azurerm` 4.x requires an explicit `subscription_id`** in the provider block or
  `ARM_SUBSCRIPTION_ID` in the environment.
- **Fork PRs get no OIDC token.** PR plans only work for branches in this repo.
- **Destroying an environment with a management lock works** (Terraform removes the lock
  first) — but a *manual* portal deletion will not. That is the intent.

## When asked to add something

| Request | Correct move |
|---|---|
| "Production needs X but dev doesn't" | New variable, dev-safe default, set in `envs/prod/*.tfvars`. Never a conditional on env name. |
| "Add a new environment" | One new `.tfvars` under the right class directory. Nothing else. |
| "Add a second container app" | Change `app_*` scalars into a `map(object(...))` and `for_each` the `container_app` module. Update the spec's variable contract. |
| "Add a database / queue / cache" | New module under `terraform/modules/`, gated by an `enable_*` variable defaulting to `false`. Revisit the DR section of the spec — state changes the RPO story. |
| "Make it private / VNet-integrated" | Roadmap phase 3. Needs a networking module and a `enable_vnet_integration` variable; it changes the ingress and DR design, so update the spec first. |
| "Speed up CI" | Cache the provider plugin directory; do not skip `validate` or the plan artifact. |
| "Give devs more access" | Adjust the GitHub Environment reviewers or the Azure role assignment in bootstrap — not the workflow logic. |
