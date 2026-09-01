# Functional Specification — ACA Platform

**Version 0.3 (draft, for review) · Proposed, not yet implemented · 2026-08-31**

---

## 1. Purpose and scope

A platform for running containerised workloads on **Azure Container Apps (ACA)**, defined
in Terraform and delivered by GitHub Actions. One Terraform core serves every environment;
environments differ only by a variables file.

The deliverable is a **proof of concept**: a publicly reachable hello-world container,
deployed entirely through the pipeline. The PoC proves the deployment platform, not the 
app.

**In scope:** the Terraform core; the variables-file environment model; remote state;
plan/deploy/destroy workflows with developer self-service using GitHub Actions; keyless OIDC auth; 
a bootstrap procedure from a brand-new Azure tenant.

**Out of scope:** application code and build pipeline; VNet integration, private endpoints,
WAF; custom domains and Front Door; databases or any stateful service; multi-subscription
landing zones.

## 2. Goals

| # | Goal | Success criterion |
|---|---|---|
| G1 | Single Terraform core for all environments | `git diff` between any two environments touches only `envs/` |
| G2 | Environments defined by variable files | A new environment is one new `.tfvars` file and zero code changes |
| G3 | DR is a solved problem | `prod-dr.tfvars` differs from `prod.tfvars` by region and name only |
| G4 | Developer self-service | A developer creates and destroys their own sandbox without platform-team involvement |
| G5 | Safe production changes | Production apply requires a reviewed plan and a human approval gate |
| G6 | Keyless CI | No Azure client secrets, storage keys, or PATs in GitHub |
| G7 | Working PoC | A public HTTPS URL returns the hello-world page, produced only by pipeline runs |

## 3. Architecture

The platform has two layers. This keeps environments cheap to create and safe to destroy.

### 3.1 Shared platform layer — bootstrapped once, never managed by the core

```
┌──────────────────────────────────────────────────────────────┐
│ Resource Group   rg-acaplat-platform-eus2                    │
│                                                              │
│  Storage Account  stacaplattf<suffix>                        │
│    Container  tfstate/                                       │
│      dev-ryan.tfstate   staging.tfstate                      │
│      dev-alice.tfstate  prod.tfstate   prod-dr.tfstate       │
│    versioning on · soft-delete 30d · shared-key access OFF   │
│                                                              │
│  Container Registry     cracaplat<suffix>                    │
│  User-Assigned Identity id-acaplat-platform  (holds AcrPull) │
└──────────────────────────────────────────────────────────────┘
```

| Resource | Why it is shared, not per-environment |
|---|---|
| State storage | Must exist before Terraform runs and survives after environment's destruction. |
| Container registry | Staging and production must pull identical containers the sandbox was tested with. |
| Managed identity | Creating it per environment would mean the core also creates its `AcrPull` role assignment, requiring `User Access Administrator` in CI. Bootstrapping it removes that privilege — **the core creates zero role assignments.** |

### 3.2 Environment layer — created and destroyed per environment

```
   Internet
      │  HTTPS (managed cert on *.<region>.azurecontainerapps.io)
      ▼
┌────────────────────────────────────────────────────────────────┐
│ Resource Group   rg-acaplat-<env>-<region>                     │
│                                                                │
│  ┌───────────────────────────────────────────────────────────┐ │
│  │ Container App Environment  cae-acaplat-<env>-<region>     │ │
│  │   Consumption profile, scale-to-zero capable              │ │
│  │   ┌─────────────────────────────────────────────────────┐ │ │
│  │   │ Container App  ca-<app>-<env>                       │ │ │
│  │   │   external ingress · replicas min..max              │ │ │
│  │   │   identity: SHARED id-acaplat-platform ─────────────┼─┼─┼─▶ ACR
│  │   └─────────────────────────────────────────────────────┘ │ │
│  └───────────────────────────────────────────────────────────┘ │
│  Log Analytics Workspace  log-acaplat-<env>-<region>           │
└────────────────────────────────────────────────────────────────┘
```

Core Terraform: `azurerm_resource_group`, `azurerm_log_analytics_workspace`,
`azurerm_container_app_environment`, `azurerm_container_app`, `time_offset` — plus data
sources reading the shared registry and identity. Four Azure resources plus a
`time_offset` helper; no submodules until there is a second caller.

## 4. Environment model

### 4.1 Classes

| Class | Examples | Approve apply | Approve destroy | TTL tag | Cost posture |
|---|---|---|---|---|---|
| `dev` | `dev-ryan`, `dev-alice` | none | none | 72 h | min replicas 0, log cap 1 GB/day |
| `staging` | `staging` | none (auto on merge to `main`) | none | none | min replicas 1 |
| `prod` | `prod`, `prod-dr` | **required** | **required + typed confirmation** | none | min replicas 2 |

Class is derived from the directory (`envs/dev/`, `envs/staging/`, `envs/prod/`) and 
asserted in the file as `env_class`; the pipeline fails if they disagree.

### 4.2 The contract

An environment is described by one variables file. `env_name` (unique, lowercase,
`a-z0-9-`, 3–22 chars), `env_class`, `location`, and `owner` are required; everything else
defaults. A minimal sandbox file is five lines.

### 4.3 Naming and tags

`<abbrev>-acaplat-<env_name>-<region_short>` — `rg-acaplat-dev-ryan-eus2`,
`cae-acaplat-staging-eus2`, `log-acaplat-prod-eus2`, `ca-hello-dev-ryan`. Shared resources
use `platform` in place of the environment name. Computed in `locals.tf`. Container App
names cap at 32 characters, which `env_name` validation enforces.

Every resource is tagged `environment`, `env_class`, `workload`, `owner`,
`managed_by=terraform`, `expires_at`, `deployed_by`, `commit_sha`.

## 5. Terraform design

### 5.1 Layout

```
terraform/         versions · providers · backend · variables · locals · main · outputs
envs/{dev,staging,prod}/*.tfvars       the only place environments differ
scripts/tf.sh                          ALL terraform execution
scripts/bootstrap-azure.sh             one-time Azure setup
.github/workflows/                     _terraform · pr-plan · deploy · destroy
```

### 5.2 Entry points

| Entry point | Scope | Use |
|---|---|---|
| GitHub Actions workflows | Every environment | The supported path. The only way staging and production change. |
| `scripts/tf.sh` | Sandboxes only | Local iteration. Not a deployment mechanism for shared environments. |

`tf.sh` is the implementation. It resolves the tfvars path from
an environment name, cross-checks the class, runs `terraform init -reconfigure` with the
right backend key, then `fmt`, `validate`, and `plan`/`apply`/`destroy`.

`_terraform.yml` lives in `.github/workflows/` because GitHub requires `workflow_call`
workflows to be there. That is acceptable because it holds no logic: it does OIDC
login, the environment gate, plan artifacts, concurrency, the run summary, and calls
`tf.sh` in one line per job. CI and a Devs can therefore run the same code path.

### 5.3 Design rules

1. **No environment names in `terraform/`.** No `count = var.env_name == "prod" ? 1 : 0`.
   Differences are variables with dev-safe defaults, set in the tfvars.
2. **No Terraform workspaces.** State isolation is the backend `key`, passed at init.
3. **No shared resources in the core.** Anything that outlives an environment is
   handled at the platform layer, and read with a data source.
4. **Validate at the boundary.** `variables.tf` carries `validation` blocks, including
   cross-variable invariants (dev must have a TTL; prod must not), so a bad tfvars
   fails in seconds without touching Azure.
5. **Defaults are safe-for-dev.** An omitted value never silently produces something
   expensive or production-grade.

### 5.4 State

Backend is `azurerm` with Entra ID auth (`use_azuread_auth = true`); shared-key access on
the storage account is disabled, so there is no key to leak. **One state file per
environment**, key `<env_name>.tfstate` — the blast radius of any apply is one environment.
`backend.tf` holds an empty `backend "azurerm" {}`; values arrive via `-backend-config`,
which is what lets one core serve N environments and why `tf.sh` always passes
`-reconfigure`. Locking uses native blob leases.

### 5.5 Variables

| Variable | Type | Default | Purpose |
|---|---|---|---|
| `env_name` | string | — | Unique identifier; state key; name component |
| `env_class` | string | — | `dev` \| `staging` \| `prod` |
| `location` | string | `"eastus2"` | Azure region |
| `owner` | string | — | Email or team alias |
| `extra_tags` | map(string) | `{}` | Additional tags |
| `ttl_hours` | number | `72` | `0` disables expiry; must be `> 0` for `dev` |
| `log_retention_days` | number | `30` | Log Analytics retention |
| `log_daily_quota_gb` | number | `1` | Log Analytics daily ingestion cap; `-1` unlimited |
| `platform_resource_group_name` | string | `"rg-acaplat-platform-eus2"` | Where the shared registry and identity live |
| `acr_name` | string | — | Shared registry to look up |
| `uami_name` | string | `"id-acaplat-platform"` | Shared identity to look up |
| `app_name` | string | `"hello"` | Container app short name |
| `app_image` | string | `mcr.microsoft.com/azuredocs/containerapps-helloworld:latest` | PoC image |
| `app_target_port` | number | `80` | Container listen port |
| `app_cpu` / `app_memory` | number / string | `0.25` / `"0.5Gi"` | Must be a legal ACA pair |
| `app_min_replicas` / `app_max_replicas` | number | `0` / `1` | `0` = scale to zero |
| `app_env_vars` | map(string) | `{}` | Non-secret environment variables |

Ingress is external — an ACA platform property.

**Sandbox** (`envs/dev/dev-ryan.tfvars`):

```hcl
env_name  = "dev-ryan"
env_class = "dev"
location  = "eastus2"
owner     = "ryan@example.com"
ttl_hours = 72
```

**Disaster recovery** (`envs/prod/prod-dr.tfvars`) — G3 in practice. `prod.tfvars` is this
file with `env_name = "prod"` and `location = "eastus2"`:

```hcl
env_name  = "prod-dr"
env_class = "prod"
location  = "westus3" # <-- the only meaningful difference
owner     = "platform-team@example.com"

ttl_hours = 0

log_retention_days = 90
log_daily_quota_gb = -1

app_min_replicas = 2
app_max_replicas = 10
app_cpu          = 0.5
app_memory       = "1Gi"
```

## 6. Identity and access

No secrets. GitHub Actions requests an OIDC token; Entra ID exchanges it via a federated
credential pinned to a specific repository *and* GitHub Environment.

```
GitHub Actions job (environment: prod)
   │  sub = repo:<ORG>/<REPO>:environment:prod
   ▼
Entra app registration  gh-acaplat-prod  →  SP  →  Contributor on the subscription
```

One identity per class, two federated credentials each — plan runs under an ungated
`<class>-plan` environment so a plan is always produced; apply and destroy run under the
gated `<class>` environment.

| Identity | GitHub Environments | Azure roles |
|---|---|---|
| `gh-acaplat-dev` | `dev-plan`, `dev` | `Contributor` (subscription), `Storage Blob Data Contributor` (state container) |
| `gh-acaplat-staging` | `staging-plan`, `staging` | same |
| `gh-acaplat-prod` | `prod-plan`, `prod` | same |

Two things that are not obvious:

- **`Contributor` is the ceiling.** Because the shared identity and its `AcrPull` grant are
  bootstrapped, the core creates no role assignments, so no CI identity needs
  `User Access Administrator`.
- **Planning needs blob *write*.** `terraform plan` takes a state lock, so
  `Storage Blob Data Contributor` on the container is required even to plan.
- **No `pull_request` federated subject is needed.** A job declaring `environment:` puts
  that environment in the OIDC subject regardless of trigger.

**Gates** are GitHub Environment protection rules, not workflow logic: `prod` requires
reviewers with self-review disabled; `staging` is restricted to protected branches; `dev`
and all `*-plan` environments are ungated. Destroy runs under the same environment as
apply, so production destruction inherits the production gate.

Developers need no Azure write access — `Reader` plus `Log Analytics Reader` is enough to
see their sandbox.

## 7. CI/CD

| Workflow | Trigger | Purpose |
|---|---|---|
| `_terraform.yml` | `workflow_call` | Reusable. OIDC login, gate, plan artifacts, concurrency, summary. Calls `tf.sh`. |
| `pr-plan.yml` | `pull_request` | Plans every affected environment; posts the plan as a PR comment. A change under `terraform/**` fans out a plan for *all* environments. |
| `deploy.yml` | `workflow_dispatch`, push to `main` | Dispatch any environment; push to `main` deploys `staging`. |
| `destroy.yml` | `workflow_dispatch` | Inputs `environment` and `confirm` (must match exactly). |

```
workflow_dispatch(environment=prod)
   │
   ├─ resolve ───────────────────────────────────────────
   │    find envs/*/prod.tfvars (exactly one, else fail)
   │    derive class from path, cross-check env_class
   │
   ├─ plan ────────────────── environment: prod-plan ────
   │    OIDC login · ./scripts/tf.sh plan prod
   │    upload tfplan artifact · write job summary
   │
   ├─ apply ───────────────── environment: prod ─────────
   │    ⏸ waits for reviewer approval
   │    download tfplan · ./scripts/tf.sh apply prod
   │    smoke test: curl app URL, assert HTTP 200
   │
   └─ concurrency: group=terraform-prod, cancel-in-progress=false
```

Apply consumes the saved plan, so the reviewed plan is the applied plan. The concurrency
group is per environment, so applies to different environments run in parallel while
applies to the same one queue.

Destroy follows the same shape with `terraform plan -destroy`.

## 8. Environment lifecycle

1. Copy `envs/dev/dev-template.tfvars` to `envs/dev/dev-<name>.tfvars`; set `env_name` and
   `owner`.
2. Open a PR — the plan runs, and `envs/dev/` needs no platform reviewer. Merge.
3. **Actions ▸ Deploy ▸ `dev-<name>`**. The job summary prints the public URL.

Roughly five minutes to first URL, most of it ACA environment provisioning.

`expires_at` is tagged at apply time from `ttl_hours`. For the PoC it is advisory — it
makes abandoned sandboxes visible to `az group list --tag env_class=dev`. Automatic reaping
is a scheduled workflow dispatching `destroy.yml`; straightforward to add, not built in 
V1 of this POC.

## 9. Disaster recovery

DR is a second environment in a second region, defined by one
variables file differing in `env_name` and `location`. It has its own state, its own
resource group, and pulls the identical image from the shared registry. It can run warm
(deployed, minimal replicas) or cold (deployed on demand).

This POC makes no attempt to migrate application state or DB into the new DR env.

| Mode | RTO | RPO | Cost |
|---|---|---|---|
| Cold — deploy on demand | ~10 min (one pipeline run) | N/A (stateless) | ~0 |
| Warm — always deployed | < 5 min (traffic switch) | N/A (stateless) | one small ACA environment |

For this PoC `prod-dr` is defined but not continuously deployed; the DR drill *is* running
the Deploy workflow against it.

**Not yet covered:** traffic steering is manual — each environment has its own
`*.azurecontainerapps.io` hostname, and Front Door is out of scope for this POC. 
The shared registry is single-region, so geo-replication is required before this 
is a real DR solution.

## 10. Security

| Control | Implementation |
|---|---|
| No long-lived credentials | OIDC workload identity federation; zero secrets in GitHub |
| No storage keys | `allow-shared-key-access false`; Entra ID auth to the backend |
| No role-assignment rights in CI | Shared identity and `AcrPull` are bootstrapped; `Contributor` is the ceiling |
| Subject pinning | Credentials bound to `repo:<ORG>/<REPO>:environment:<name>` |
| Fork safety | Fork PRs never receive OIDC tokens; repo is internal, forks disabled |
| State protection | Blob versioning, 30-day soft delete, no public blob access |
| Supply chain | Actions pinned to commit SHAs; providers pinned; `.terraform.lock.hcl` committed |
| Auditability | Every change is a merged commit plus a retained plan artifact and run record |
| Static analysis | `terraform fmt`, `validate`, `tflint` in the PR check |

**Accepted for the PoC, to revisit for production:** CI identities are `Contributor` at
subscription scope (production wants a subscription per class); ACA ingress is public with
no WAF; the shared registry is a single point of failure.

## 11. Cost

| Item | Approximate monthly cost |
|---|---|
| Developer sandbox — scale-to-zero, logs capped at 1 GB/day | $0–5 |
| Staging — 1 replica, 0.25 vCPU | $30–50 |
| Production — 2 replicas, 0.5 vCPU | $100–160 |
| Production DR — cold | $0 |
| Shared platform — state storage + Basic registry | ~$6 |

The dominant cost *risk* is **Log Analytics** ingestion, billed per GB. Each environment
caps its own workspace via `log_daily_quota_gb`.

## 12. Observability

Container `stdout`/`stderr` and ACA system logs go to the environment's own **Log
Analytics** workspace (`ContainerAppConsoleLogs_CL`, `ContainerAppSystemLogs_CL`). One
workspace per environment means sandbox log volume cannot affect production cost or
retention, and the workspace dies with the environment.

## 13. Testing

| Check | Where |
|---|---|
| `terraform fmt -check` and `validate` | `tf.sh` — therefore both PR check and local |
| `tflint` (azurerm ruleset) | PR check |
| `variable validation` blocks | Every plan |
| Plan against every environment when `terraform/**` changes | PR check |
| `curl -sf <app_url>` asserts HTTP 200 after apply | `_terraform.yml` |
| Resource group absent after destroy | `destroy.yml` |

## 14. Acceptance criteria

1. A brand-new Azure subscription is bootstrapped using only the README steps.
2. `staging` deploys from an Actions run and returns HTTP 200 from a public URL.
3. `prod` deploys only after a reviewer approves the gate, and the applied plan is the
   reviewed plan.
4. A developer creates and destroys `dev-<name>` without platform-team involvement.
5. `prod-dr` deploys to a second region from a file differing only in name and region.
6. Destroying `prod` without approval fails; a mismatched `confirm` fails fast.
7. No client secret or storage key exists in the repo or in GitHub secrets.
8. `grep -rniE '"(dev|staging|prod)"' terraform/` returns only validation allow-lists.

## 15. Roadmap

| Phase | Item |
|---|---|
| 2 | Build pipeline pushing to the shared registry; `app_image` becomes a promoted digest |
| 2 | Key Vault + ACA secret references |
| 2 | Scheduled reaper destroying sandboxes past `expires_at` |
| 3 | VNet integration, private endpoints, no public ingress on production |
| 3 | Front Door across `prod` + `prod-dr`, health-probe failover, custom domain |
| 3 | Geo-replicated registry |
| 3 | Subscription per class; management groups; Azure Policy |
| 4 | Multiple container apps per environment (first justified module boundary) |
| 4 | Cost reporting by tag; per-environment budget alerts |
| 4 | Drift detection: scheduled plan against staging/prod |
