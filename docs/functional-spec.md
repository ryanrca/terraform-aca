# Functional Specification — ACA Platform (Terraform + GitHub Actions)

| | |
|---|---|
| **Document** | Functional Specification |
| **Version** | 0.2 (draft, for review) |
| **Status** | Proposed — not yet implemented |
| **Owner** | Platform Architecture / IT |
| **Last updated** | 2026-08-31 |

---

## 1. Purpose

Define the infrastructure platform on which application teams will build and run
containerised workloads on **Azure Container Apps (ACA)**. This specification covers the
Terraform code structure, the environment model, the identity/access model, and the
GitHub Actions delivery pipeline.

The immediate deliverable is a **proof of concept**: a publicly reachable "hello world"
container running on ACA, deployed entirely through the pipeline described here. The
application itself is deliberately trivial — the PoC exists to prove the *deployment
platform*, not the app.

This document describes a demonstrator. Mapping it onto a real production estate is a
later exercise and will require revisiting most of Section 12 and Section 17.

## 2. Scope

### 2.1 In scope

- One Terraform root module ("the core") that describes an entire environment.
- A variables-file-driven environment model: developer sandboxes, staging, production,
  and disaster recovery are all the *same code* with *different inputs*.
- Remote Terraform state in Azure Blob Storage, one state file per environment.
- GitHub Actions workflows to **plan**, **deploy**, and **destroy** any environment on
  demand, including self-service for developers.
- Keyless authentication from GitHub to Azure via OIDC / workload identity federation.
- Bootstrap procedure taking a brand-new Azure tenant to a working pipeline.

### 2.2 Out of scope (this phase)

- Application source code, Dockerfiles, and the application build pipeline.
- Private networking / VNet-integrated ACA environments, private endpoints, WAF.
- Custom domains, TLS certificates, Azure Front Door / Traffic Manager.
- Databases, caches, queues, or any stateful backing service.
- Secret management beyond what ACA and Key Vault provide natively.
- Multi-subscription or multi-tenant landing zones.

### 2.3 Non-goals

- **Not** a general-purpose landing zone. This is an application platform.
- **Not** Kubernetes. If a workload genuinely needs AKS, it does not belong here.
- **Not** a per-environment code fork. Environment-specific *code* is a design failure;
  see Section 7.5.

## 3. Goals and success criteria

| # | Goal | Success criterion |
|---|---|---|
| G1 | Single Terraform core for all environments | `git diff` between any two environments touches only files under `envs/` |
| G2 | Environments defined by variable files | A new environment requires exactly one new `.tfvars` file and zero code changes |
| G3 | DR is a solved problem | `envs/prod/prod-dr.tfvars` differs from `prod.tfvars` by region and name only |
| G4 | Developer self-service | A developer can create and destroy their own sandbox from the GitHub Actions UI without platform-team involvement |
| G5 | Safe production changes | Production apply requires a reviewed plan and a human approval gate |
| G6 | Keyless CI | No Azure client secrets, storage keys, or PATs stored in GitHub |
| G7 | Working PoC | A public HTTPS URL returns the hello-world page, produced only by pipeline runs |

## 4. Personas and primary use cases

| Persona | Needs |
|---|---|
| **Application developer** | Stand up a personal environment on demand, deploy to it repeatedly, tear it down when finished. No Azure portal access required. |
| **Platform engineer** | Own the Terraform core and the environment contract; review changes to staging/production inputs. |
| **Release manager** | Promote a known-good configuration to staging then production, with an audit trail. |
| **IT / FinOps** | See what exists, who owns it, and be confident nothing is left running by accident. |

### Primary use cases

1. **UC-1 Create sandbox** — developer adds `envs/dev/dev-<name>.tfvars`, merges, runs the
   Deploy workflow, receives a public URL.
2. **UC-2 Iterate** — developer re-runs Deploy after changing image tag or replica counts.
3. **UC-3 Destroy sandbox** — developer runs the Destroy workflow; all Azure resources for
   that environment are removed.
4. **UC-4 Promote to staging** — merge to `main` deploys staging.
5. **UC-5 Promote to production** — plan is produced, a reviewer approves the GitHub
   Environment gate, the *exact reviewed plan* is applied.
6. **UC-6 Invoke DR** — deploy `prod-dr` into the secondary region; it is an independent,
   fully functional stack.

## 5. Architecture overview

The platform is split into two layers. The distinction matters more than any other in this
document: it is what keeps an environment cheap to create and safe to destroy.

- **Shared platform layer** — created **once**, during bootstrap, and never touched by the
  core Terraform. Holds the things that must outlive any single environment: Terraform
  state, the container registry, and the workload identity.
- **Environment layer** — created and destroyed freely by the pipeline, once per
  environment, entirely from the core Terraform.

### 5.1 Shared platform layer (bootstrap once, never managed by core Terraform)

```
┌───────────────────────────────────────────────────────────────────┐
│ Resource Group   rg-acaplat-platform-eus2                          │
│                                                                    │
│  Storage Account  stacaplattf<suffix>                              │
│    Container  tfstate/                                             │
│      dev-ryan.tfstate    staging.tfstate                           │
│      dev-alice.tfstate   prod.tfstate    prod-dr.tfstate           │
│    (versioning on, soft-delete 30d, shared-key access DISABLED)     │
│                                                                    │
│  Container Registry        cracaplat<suffix>                       │
│    Application images, shared by every environment                 │
│                                                                    │
│  User-Assigned Identity    id-acaplat-platform                     │
│    Holds AcrPull on the registry above                             │
│    Attached to every container app in every environment            │
└───────────────────────────────────────────────────────────────────┘
```

Why these three are shared rather than per-environment:

| Resource | Reason it is shared |
|---|---|
| **Terraform state storage** | Must exist before any Terraform runs, and must survive the destruction of every environment. Chicken-and-egg: the core cannot manage its own backend. |
| **Container registry** | Images are promoted *across* environments — staging and production must be able to pull the identical digest a sandbox was tested with. A per-environment registry would force a re-push per environment and make "the same image" unprovable. It is also the single largest per-environment cost we can avoid duplicating. |
| **User-assigned identity** | Creating it per environment would mean the core Terraform also creates its `AcrPull` role assignment, which requires granting the CI identity `User Access Administrator` over the subscription. Bootstrapping it once removes that privilege entirely — the CI identities never need role-assignment rights. |

The last row is the reason this design is materially simpler and safer than one where the
identity is created per environment. Core Terraform creates **zero** role assignments.

### 5.2 Environment layer (created and destroyed per environment)

```
   Internet
      │  HTTPS (managed cert on *.<region>.azurecontainerapps.io)
      ▼
┌─────────────────────────────────────────────────────────────────┐
│ Resource Group   rg-acaplat-<env>-<region>                        │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │ Container App Environment  cae-acaplat-<env>-<region>       │ │
│  │   Consumption workload profile, scale-to-zero capable        │ │
│  │                                                              │ │
│  │   ┌──────────────────────────────────────────────────────┐  │ │
│  │   │ Container App  ca-<app>-<env>                         │  │ │
│  │   │   image: <app_image>   ingress: external, port 80     │  │ │
│  │   │   replicas: min..max   revision mode: Single          │  │ │
│  │   │   identity: the SHARED id-acaplat-platform ───────────┼──┼─┼──▶ ACR
│  │   └──────────────────────────────────────────────────────┘  │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  Log Analytics Workspace   log-acaplat-<env>-<region>            │
│  Management Lock           CanNotDelete    (staging/prod only)   │
└─────────────────────────────────────────────────────────────────┘
```

### 5.3 Resource inventory

**Bootstrap** (`scripts/bootstrap-azure.sh`, Azure CLI, run once):

| Resource | Notes |
|---|---|
| Resource group | `rg-acaplat-platform-<region>` |
| Storage account + blob container | Terraform state; Entra-ID auth only, no access keys |
| Container registry | Shared by all environments |
| User-assigned managed identity | Granted `AcrPull` on the registry |
| 3 Entra app registrations + federated credentials + RBAC | One per environment class — see Section 8 |

**Core Terraform** (`terraform/`, run per environment):

| Resource | Terraform type | Notes |
|---|---|---|
| Resource group | `azurerm_resource_group` | The unit of destruction |
| Log Analytics workspace | `azurerm_log_analytics_workspace` | ACA console/system log sink; per-environment retention and daily cap |
| Container App Environment | `azurerm_container_app_environment` | Consumption profile; the ACA "cluster" |
| Container App | `azurerm_container_app` | The workload; external ingress; attached to the shared identity |
| Management lock | `azurerm_management_lock` | `CanNotDelete` on the resource group when `enable_resource_lock = true` |
| Expiry timestamp | `time_offset` | Computes the `expires_at` tag from `ttl_hours` |
| Registry lookup | `data.azurerm_container_registry` | Reads the shared registry |
| Identity lookup | `data.azurerm_user_assigned_identity` | Reads the shared identity |

Five managed resources and two data sources. Small enough that the root module is honest
rather than a simplification — see Section 7.4.

### 5.4 Why ACA

ACA gives us serverless containers with scale-to-zero, built-in ingress and managed TLS,
revisions and traffic splitting, and Dapr/KEDA if we want them — without operating a
control plane. For a platform whose first workload is a stateless HTTP service, this is
materially cheaper and lower-toil than AKS.

## 6. Environment model

### 6.1 Environment classes

Every environment belongs to exactly one **class**, which determines its guardrails and
which approval gates apply.

| Class | Examples | Approval to apply | Approval to destroy | TTL tag | Resource lock | Cost posture |
|---|---|---|---|---|---|---|
| `dev` | `dev-ryan`, `dev-alice` | none | none | 72 h | no | min replicas 0, log cap 1 GB/day |
| `staging` | `staging` | none (auto on merge to `main`) | none | none | yes | min replicas 1 |
| `prod` | `prod`, `prod-dr` | **required** | **required + typed confirmation** | none | yes | min replicas 2 |

Class is derived from the directory the variables file lives in — `envs/dev/`,
`envs/staging/`, `envs/prod/` — and is *also* asserted inside the file as `env_class`. The
pipeline fails if the two disagree. This makes CODEOWNERS enforcement trivial:
`envs/prod/` and `envs/staging/` require platform-team review, `envs/dev/` does not.

### 6.2 The environment contract

An environment is fully described by one variables file:

- **Name** (`env_name`) is unique across the platform, lowercase, `a-z0-9-`, 3–22
  characters. It is the state-file key, the workflow input, and part of every resource name.
- **Class** (`env_class`) is one of `dev`, `staging`, `prod`.
- **Region** (`location`) is any Azure region where ACA is available.
- **Owner** (`owner`) is an email or team alias, used for tagging.
- Everything else has a defaulted value in `variables.tf`. A minimal sandbox file is five
  lines.

### 6.3 Naming convention

`<abbrev>-acaplat-<env_name>-<region_short>`

| Resource | Pattern | Example |
|---|---|---|
| Resource group | `rg-acaplat-<env>-<loc>` | `rg-acaplat-dev-ryan-eus2` |
| Container App Environment | `cae-acaplat-<env>-<loc>` | `cae-acaplat-staging-eus2` |
| Container App | `ca-<app>-<env>` | `ca-hello-dev-ryan` |
| Log Analytics workspace | `log-acaplat-<env>-<loc>` | `log-acaplat-prod-eus2` |

Shared platform resources use `platform` in place of the environment name:
`rg-acaplat-platform-eus2`, `id-acaplat-platform`.

Names are computed in `terraform/locals.tf` so the convention lives in exactly one place.
Container App names are capped at 32 characters; `env_name` validation rejects values that
would exceed it.

### 6.4 Mandatory tags

Applied to every resource:

`environment`, `env_class`, `workload=acaplat`, `owner`, `managed_by=terraform`,
`expires_at` (empty when `ttl_hours = 0`), `deployed_by`, `commit_sha`.

`expires_at`, `owner`, and `env_class` are what cleanup and cost reporting query on.

## 7. Terraform design

### 7.1 Repository layout

```
.
├── CLAUDE.md
├── README.md
├── docs/
│   └── functional-spec.md            ← this document
├── terraform/                        ← THE CORE. Identical for every environment.
│   ├── versions.tf                   terraform + provider version constraints
│   ├── providers.tf                  azurerm/time provider config
│   ├── backend.tf                    partial backend — no values committed
│   ├── variables.tf                  the environment contract, with validation
│   ├── locals.tf                     naming and tag computation
│   ├── main.tf                       the five resources and two data sources
│   └── outputs.tf                    app_url, app_fqdn, resource_group_name
├── envs/                             ← THE ONLY PLACE ENVIRONMENTS DIFFER
│   ├── dev/
│   │   ├── dev-template.tfvars
│   │   └── dev-ryan.tfvars
│   ├── staging/
│   │   └── staging.tfvars
│   └── prod/
│       ├── prod.tfvars
│       └── prod-dr.tfvars
├── scripts/
│   ├── bootstrap-azure.sh            one-time Azure setup (idempotent)
│   └── tf.sh                         ← ALL TERRAFORM EXECUTION LIVES HERE
└── .github/
    ├── CODEOWNERS
    └── workflows/
        ├── _terraform.yml            reusable: OIDC + gates + artifacts, calls tf.sh
        ├── pr-plan.yml               PR: fmt, validate, plan
        ├── deploy.yml                dispatch any env; push to main → staging
        └── destroy.yml               dispatch, guarded
```

### 7.2 Entry points

There are exactly two, and only one of them is the supported path:

| Entry point | Who uses it | Scope | Notes |
|---|---|---|---|
| **GitHub Actions workflows** | Everyone | Every environment | **The supported path.** The only way staging and production are ever changed. Produces the audit trail. |
| **`scripts/tf.sh`** | Developers | Sandboxes only | Local convenience for fast iteration. Not a deployment mechanism for shared environments. |

`scripts/tf.sh` is **not** a wrapper around a separate CI implementation — it *is* the
implementation. It owns the whole sequence: resolving the tfvars path from an environment
name, deriving the class, running `terraform init` with the correct backend key,
`fmt`/`validate`, and then `plan` / `apply` / `destroy`.

```bash
./scripts/tf.sh plan    dev-ryan
./scripts/tf.sh apply   dev-ryan
./scripts/tf.sh destroy dev-ryan
```

### 7.3 Why the reusable workflow lives in `.github/workflows/`

Two answers, and the second is the important one.

1. **GitHub requires it.** A workflow callable via `workflow_call` must be located in
   `.github/workflows/` in the repository. There is no alternative location; this is a
   platform constraint, not a design choice.

2. **It contains almost nothing worth relocating.** The concern behind the question — that
   deployment logic ends up trapped in YAML, untestable and unrunnable locally — is real,
   and the fix is not to move the file but to keep the logic out of it. All Terraform
   execution lives in `scripts/tf.sh`. `_terraform.yml` is responsible only for things that
   are genuinely GitHub's job:

   - acquiring an Azure token via OIDC,
   - declaring the GitHub Environment that triggers the approval gate,
   - uploading the plan as an artifact and downloading it in the apply job,
   - setting the concurrency group,
   - writing the run summary.

   Its Terraform-related content is one line per job: `./scripts/tf.sh plan "$ENV"`.

The practical benefit is that CI and a developer's laptop run **the same code path**. A
plan that works locally works in the pipeline, and debugging does not mean pushing commits
to read Actions logs.

### 7.4 No submodules

The core is a single flat root module. Five managed resources with no repetition do not
justify a module layer; wrapping each in its own module would add directories, variable
plumbing, and indirection while removing nothing.

Introduce modules when there is an actual second caller — the first two candidates are a
second container app per environment (`for_each` over an app map) and a networking layer
for VNet integration. Until then, a module boundary is cost without benefit.

### 7.5 Explicit design rules

These are the rules that keep G1/G2 true. They are restated in `CLAUDE.md`.

1. **No environment names in the core.** `terraform/**` must never branch on an environment
   name. No `count = var.env_name == "prod" ? 1 : 0`. If production needs something a
   sandbox does not, that is a **variable with a dev-safe default**, e.g.
   `enable_resource_lock`.
2. **No Terraform workspaces.** Workspaces hide the environment in CLI state rather than in
   a reviewable file, and they encourage `terraform.workspace` conditionals — exactly the
   anti-pattern rule 1 forbids. State keys give the same isolation, visibly.
3. **Every input is validated at the boundary.** `variables.tf` carries `validation` blocks;
   cross-variable invariants (e.g. "dev must have a TTL", "prod must be locked") are
   enforced with cross-object validation so a bad tfvars fails in seconds, before touching
   Azure.
4. **Defaults are safe-for-dev.** An omitted value must never silently produce an expensive
   or production-grade resource. Staging and production state their posture explicitly.
5. **The core never creates shared resources.** Anything that must outlive an environment,
   or be shared between environments, belongs in bootstrap. The core reads it with a data
   source.

### 7.6 State management

- Backend: `azurerm`, using **Entra ID auth** (`use_azuread_auth = true`). Storage account
  shared-key access is disabled, so there is no key to leak.
- **One state file per environment**, key = `<env_name>.tfstate`. The blast radius of any
  single apply is one environment.
- `backend.tf` contains an empty `backend "azurerm" {}` block; all values are supplied at
  `terraform init` time with `-backend-config`. This is what allows one core to serve N
  environments, and it is why `tf.sh` always passes `-reconfigure`.
- Locking uses native blob leases — no extra infrastructure.
- Blob versioning and 30-day soft delete give us state recovery.

### 7.7 Variable contract

Full reference lives in `terraform/variables.tf`; this is the shape.

| Variable | Type | Default | Purpose |
|---|---|---|---|
| `env_name` | string | — | Unique environment identifier; state key; name component |
| `env_class` | string | — | `dev` \| `staging` \| `prod` |
| `location` | string | `"eastus2"` | Azure region |
| `owner` | string | — | Email or team alias; tag |
| `extra_tags` | map(string) | `{}` | Additional tags |
| `ttl_hours` | number | `72` | `0` disables expiry; must be `> 0` for `dev` |
| `enable_resource_lock` | bool | `false` | `CanNotDelete` lock; must be `true` for `prod` |
| `log_retention_days` | number | `30` | Log Analytics workspace retention |
| `log_daily_quota_gb` | number | `1` | Log Analytics daily ingestion cap; `-1` for unlimited |
| `platform_resource_group_name` | string | `"rg-acaplat-platform-eus2"` | Where the shared registry and identity live |
| `acr_name` | string | — | Shared registry to look up (set once as a GitHub variable) |
| `uami_name` | string | `"id-acaplat-platform"` | Shared workload identity to look up |
| `app_name` | string | `"hello"` | Container app short name |
| `app_image` | string | `mcr.microsoft.com/azuredocs/containerapps-helloworld:latest` | The PoC image |
| `app_target_port` | number | `80` | Container listen port |
| `app_cpu` | number | `0.25` | vCPU per replica |
| `app_memory` | string | `"0.5Gi"` | Must pair legally with `app_cpu` |
| `app_min_replicas` | number | `0` | `0` = scale to zero |
| `app_max_replicas` | number | `1` | |
| `app_env_vars` | map(string) | `{}` | Non-secret environment variables |

Ingress is always external on port `app_target_port` — that is the platform's design, not
an environment-level choice, so it is not a variable.

**Example — developer sandbox** (`envs/dev/dev-ryan.tfvars`):

```hcl
env_name  = "dev-ryan"
env_class = "dev"
location  = "eastus2"
owner     = "ryan@example.com"
ttl_hours = 72
```

**Example — production** (`envs/prod/prod.tfvars`):

```hcl
env_name             = "prod"
env_class            = "prod"
location             = "eastus2"
owner                = "platform-team@example.com"
ttl_hours            = 0
enable_resource_lock = true
log_retention_days   = 90
log_daily_quota_gb   = -1
app_min_replicas     = 2
app_max_replicas     = 10
app_cpu              = 0.5
app_memory           = "1Gi"
```

**Example — disaster recovery** (`envs/prod/prod-dr.tfvars`) — G3 in practice:

```hcl
env_name             = "prod-dr"
env_class            = "prod"
location             = "westus3" # <-- the only meaningful difference
owner                = "platform-team@example.com"
ttl_hours            = 0
enable_resource_lock = true
log_retention_days   = 90
log_daily_quota_gb   = -1
app_min_replicas     = 2
app_max_replicas     = 10
app_cpu              = 0.5
app_memory           = "1Gi"
```

## 8. Identity and access model

### 8.1 GitHub → Azure authentication

No secrets. GitHub Actions requests an OIDC token; Microsoft Entra ID exchanges it for an
Azure access token via a **federated identity credential** whose subject is pinned to a
specific repository *and* GitHub Environment.

```
GitHub Actions job  (environment: prod)
   │  id-token: write  →  OIDC JWT
   │      sub = repo:<ORG>/<REPO>:environment:prod
   ▼
Entra ID app registration  gh-acaplat-prod
   federated credential matching that exact subject
   ▼
Service principal  →  Contributor on the subscription
```

### 8.2 Three identities, six credentials

One identity per environment class. Each has two federated credentials, because plan and
apply run under different GitHub Environments — the plan environment is ungated so that a
plan is always produced for review, and the apply environment carries the gate.

| Identity | GitHub Environments | Azure roles |
|---|---|---|
| `gh-acaplat-dev` | `dev-plan`, `dev` | `Contributor` (subscription), `Storage Blob Data Contributor` (state container) |
| `gh-acaplat-staging` | `staging-plan`, `staging` | same |
| `gh-acaplat-prod` | `prod-plan`, `prod` | same |

Two properties worth noting:

- **No role-assignment rights.** Because the shared identity and its `AcrPull` grant are
  bootstrapped (Section 5.1), the core Terraform creates no role assignments, so no CI
  identity needs `User Access Administrator`. `Contributor` is sufficient and is the
  ceiling.
- **Plan needs blob *write*.** `terraform plan` acquires a state lock and may write
  refreshed state, so `Storage Blob Data Contributor` on the state container is required
  even for planning. This is scoped to the container, not the storage account.

When a job declares `environment:`, GitHub puts that environment in the OIDC subject claim
regardless of the triggering event — so pull-request plans authenticate through the same
`<class>-plan` credential, and no separate `pull_request` subject is needed.

### 8.3 Approval gates

Implemented as GitHub Environment protection rules, not as logic in the workflow:

| GitHub Environment | Protection |
|---|---|
| `dev-plan`, `staging-plan`, `prod-plan` | None — a plan must always be viewable |
| `dev` | None. Self-service is the point |
| `staging` | Deployments restricted to protected branches |
| `prod` | **Required reviewers** (platform team), self-review disabled, protected branches only |

Destroy runs under the same environment as apply, so production destruction inherits the
production approval gate automatically, plus a typed-confirmation input in the workflow.

### 8.4 Human access

Developers do not need Azure portal write access for the normal workflow. `Reader` on the
subscription plus `Log Analytics Reader` is recommended so they can see logs and metrics
for their sandbox.

## 9. CI/CD design

### 9.1 Workflow inventory

| Workflow | Trigger | What it does |
|---|---|---|
| `_terraform.yml` | `workflow_call` | Reusable. Inputs: `env_name`, `action` (`plan`/`apply`/`destroy`). Handles OIDC login, the environment gate, plan artifacts, concurrency, and the run summary. Calls `scripts/tf.sh`. |
| `pr-plan.yml` | `pull_request` | Detects changed `envs/**` files and any change under `terraform/**`; plans each affected environment; posts the plan as a PR comment. |
| `deploy.yml` | `workflow_dispatch`, `push` to `main` | Dispatch: choose any environment, plan → gate → apply. Push to `main`: plan and apply `staging`. |
| `destroy.yml` | `workflow_dispatch` | Choose an environment, type the confirmation, plan a destroy, gate, apply the destroy. |

### 9.2 Deploy sequence

```
workflow_dispatch(environment=prod)
   │
   ├─ resolve ─────────────────────────────────────────────────
   │    find envs/*/<env>.tfvars  (exactly one, else fail)
   │    derive env_class from the path, cross-check env_class in the file
   │    emit: tfvars_path, env_class
   │
   ├─ plan ─────────────────────── environment: prod-plan ─────
   │    OIDC login
   │    ./scripts/tf.sh plan prod
   │    upload tfplan + human-readable plan as artifacts
   │    write the plan summary to the job summary
   │
   ├─ apply ────────────────────── environment: prod ──────────
   │    ⏸ waits for required reviewer approval
   │    OIDC login
   │    download the tfplan artifact
   │    ./scripts/tf.sh apply prod     ← the exact reviewed plan, no re-plan
   │    smoke test: curl the app URL, assert HTTP 200
   │    publish app_url to the job summary
   │
   └─ concurrency: group=terraform-prod, cancel-in-progress=false
```

Key properties:

- **Apply applies a saved plan.** No drift between what was reviewed and what runs.
- **Concurrency group per environment.** Two applies against the same environment queue
  rather than fighting over the state lock; applies against *different* environments run in
  parallel freely.
- **Everything is an artifact.** Plan output, apply log, and outputs are retained on the run.

### 9.3 Destroy sequence

`destroy.yml` inputs:

| Input | Required | Notes |
|---|---|---|
| `environment` | yes | Environment name, e.g. `dev-ryan` |
| `confirm` | yes | Must exactly equal `environment`; the job fails fast otherwise |

Flow: resolve → `terraform plan -destroy` under `<class>-plan` → gate on the `<class>`
environment → apply the destroy plan → verify the resource group is gone.

Guardrails:

- `dev`: no approval. A developer destroying their own sandbox is routine.
- `staging` / `prod`: inherits the deployment gate on the `<class>` environment, so
  production destruction needs the same reviewer that production deployment does.
- The management lock is a Terraform-managed resource, so `terraform destroy` removes it
  first and then the resource group. Out-of-band portal deletion remains blocked.

### 9.4 Pull-request experience

For a PR that adds `envs/dev/dev-alice.tfvars`, the PR check posts:

```
Terraform plan — dev-alice (dev)
  Plan: 4 to add, 0 to change, 0 to destroy.
  + azurerm_resource_group.this                rg-acaplat-dev-alice-eus2
  + azurerm_log_analytics_workspace.this       log-acaplat-dev-alice-eus2
  + azurerm_container_app_environment.this     cae-acaplat-dev-alice-eus2
  + azurerm_container_app.this                 ca-hello-dev-alice
```

A change under `terraform/**` fans out a plan for *every* existing environment, so core
changes are reviewed against real production state before merge.

## 10. Environment lifecycle

### 10.1 Creating a developer sandbox

1. Copy `envs/dev/dev-template.tfvars` to `envs/dev/dev-<name>.tfvars`; set `env_name` and
   `owner`.
2. Open a PR. The PR plan runs; a platform reviewer is *not* required for `envs/dev/`.
3. Merge.
4. Actions → **Deploy** → environment `dev-<name>` → Run.
5. The job summary prints the public URL.

Time to first URL is roughly five minutes, most of it ACA environment provisioning.

### 10.2 Expiry

At apply time Terraform computes `expires_at = now + ttl_hours` and tags the resource
group. For the PoC this is **advisory** — it makes abandoned sandboxes visible to a simple
query:

```bash
az group list --tag env_class=dev --query "[].{name:name, expires:tags.expires_at, owner:tags.owner}" -o table
```

Automatic reaping of expired sandboxes is a scheduled workflow that dispatches
`destroy.yml`; it is straightforward to add and is listed in Section 17, but it is not
needed to prove the platform.

## 11. Disaster recovery

### 11.1 Design

Because the platform is stateless and every environment is a complete, independent stack,
DR is not a special mechanism — it is a second environment in a second region.

- `prod-dr` is defined by one variables file differing from `prod` in `env_name` and
  `location`.
- It has its own state file, its own resource group, its own ACA environment.
- It pulls from the same shared registry, so it runs the identical image digest.
- It can be run **warm** (deployed continuously, minimal replicas) or **cold** (deployed on
  demand from the pipeline).

### 11.2 Objectives (PoC posture)

| Mode | RTO | RPO | Cost |
|---|---|---|---|
| Cold — deploy on demand | ~10 min (one pipeline run) | N/A (stateless) | ~0 |
| Warm — always deployed, `app_min_replicas = 1` | < 5 min (traffic switch) | N/A (stateless) | one small ACA environment |

For the PoC, `prod-dr` is defined but not continuously deployed; the DR drill *is* running
the Deploy workflow against it.

### 11.3 What DR does not yet cover

Traffic steering is manual — each environment has its own
`*.<region>.azurecontainerapps.io` hostname. Azure Front Door with both environments as
origins is the next step (Section 17). The shared registry is currently single-region; a
geo-replicated registry, or a second registry in the DR region, is required before this is
a real DR posture. Once state exists (databases, storage), DR stops being free and needs a
replication design.

## 12. Security

| Control | Implementation |
|---|---|
| No long-lived cloud credentials | OIDC workload identity federation; zero secrets in GitHub |
| No storage account keys | `allow-shared-key-access false`; Entra ID auth to the state backend |
| No role-assignment rights in CI | Shared identity and its `AcrPull` grant are bootstrapped; `Contributor` is the CI ceiling |
| Federated subject pinning | Credentials bound to `repo:<ORG>/<REPO>:environment:<name>` — another repo cannot assume them |
| Fork safety | Fork PRs never receive OIDC tokens; the repository is internal and forks are disabled |
| State protection | Blob versioning, 30-day soft delete, no public blob access |
| Accidental deletion | `CanNotDelete` management lock on staging/prod resource groups |
| Supply chain | Actions pinned to full commit SHAs; provider versions pinned; `.terraform.lock.hcl` committed |
| Secrets in app config | Non-secret values via `app_env_vars`; real secrets via ACA secrets backed by Key Vault (next phase) |
| Auditability | Every change is a merged commit plus a retained plan artifact and an Actions run record |
| Static analysis | `terraform fmt`, `validate`, and `tflint` in the PR check |

Accepted risks for the PoC, to be revisited when this is mapped onto production:

- Deployment identities are scoped at **subscription** level with `Contributor`. Production
  should move to a subscription per class; the design supports this by changing one GitHub
  variable per environment.
- ACA ingress is public with no WAF. Acceptable for a hello-world PoC; not for real data.
- The shared registry is a single point of failure across all environments.

## 13. Cost

Indicative monthly cost, US East 2 list pricing:

| Item | Rough cost |
|---|---|
| Developer sandbox — min replicas 0, 0.25 vCPU / 0.5 Gi, logs capped at 1 GB/day | **≈ $0–5** idle; charged only while requests flow |
| Staging — min 1, 0.25 vCPU / 0.5 Gi, 30-day log retention | **≈ $30–50** |
| Production — min 2, 0.5 vCPU / 1 Gi, 90-day log retention | **≈ $100–160** |
| Production DR — cold, not deployed | **$0** |
| Shared platform — state storage + Basic registry | **≈ $6** |

The dominant *risk* is not the container runtime but **Log Analytics** ingestion, which is
billed per GB ingested. Each environment therefore sets `log_daily_quota_gb`, a hard daily
ingestion cap on its own workspace, defaulting to 1 GB for sandboxes. Sandboxes also scale
to zero when idle, so the realistic worst case for a forgotten sandbox is a few dollars.

## 14. Observability

- Container `stdout`/`stderr` and ACA system logs flow to the environment's **Log Analytics**
  workspace (`ContainerAppConsoleLogs_CL`, `ContainerAppSystemLogs_CL`).
- Each environment has its **own** workspace: sandbox log volume can never affect production
  retention or cost, and workspace deletion is part of environment destruction.
- Application Insights and distributed tracing are deferred until there is an application
  worth tracing.
- Deployment observability is the GitHub Actions run: plan artifact, apply log, outputs.

## 15. Testing and validation

| Layer | Check | Where |
|---|---|---|
| Formatting | `terraform fmt -check -recursive` | `tf.sh`, therefore PR check and local |
| Syntax/schema | `terraform validate` | `tf.sh`, therefore PR check and local |
| Lint | `tflint` with the azurerm ruleset | PR check |
| Contract | `variable validation` blocks | Every plan |
| Integration | Plan against every existing environment when `terraform/**` changes | PR check |
| Smoke | After apply, `curl -sf <app_url>` asserts HTTP 200 | `_terraform.yml` apply job |
| Teardown | Destroy workflow asserts the resource group no longer exists | `destroy.yml` |

## 16. Acceptance criteria for the PoC

The PoC is accepted when all of the following are demonstrated:

1. A brand-new Azure subscription is bootstrapped using only the documented README steps.
2. `staging` deploys from a GitHub Actions run and returns HTTP 200 from a public URL.
3. `prod` deploys only after a human approves the GitHub Environment gate, and the applied
   plan is the reviewed plan.
4. A developer creates `dev-<name>` via PR + Deploy without platform-team involvement, and
   destroys it via the Destroy workflow.
5. `prod-dr` deploys into a second region from a variables file that differs from `prod`
   only in name and region.
6. Attempting to destroy `prod` without approval fails; attempting with a mismatched
   `confirm` input fails fast.
7. No Azure client secret or storage key exists in the repository or in GitHub secrets.
8. `grep -rniE '"(dev|staging|prod)"' terraform/` returns only validation allow-lists.

## 17. Roadmap (post-PoC)

| Phase | Item |
|---|---|
| 2 | Application build pipeline pushing to the shared registry; `app_image` becomes a promoted digest |
| 2 | Key Vault + ACA secret references |
| 2 | Scheduled reaper workflow destroying sandboxes past `expires_at` |
| 3 | VNet-integrated ACA environments, private endpoints, no public ingress on production |
| 3 | Azure Front Door in front of `prod` + `prod-dr`, health-probe failover, custom domain |
| 3 | Geo-replicated registry for a genuine DR posture |
| 3 | Subscription-per-class isolation; management groups; Azure Policy guardrails |
| 4 | Multiple container apps per environment (`app` becomes a map, first real module boundary) |
| 4 | Cost reporting by tag; budget alerts per environment |
| 4 | Drift detection: scheduled plan against staging/prod, alert on a non-empty diff |

## 18. Decisions log

| # | Decision | Rationale | Alternatives rejected |
|---|---|---|---|
| D1 | One root module, variables files per environment | Satisfies G1/G2; a new environment is a file, not a fork | Terragrunt (extra tool, extra concept); per-environment root modules (drift) |
| D2 | No Terraform workspaces | The environment must be visible in the repo and in review, not in CLI state | Workspaces |
| D3 | State key per environment in one container | Isolation with trivial bootstrap; blob-lease locking is free | Single shared state (blast radius); per-environment storage accounts (toil) |
| D4 | Class derived from `envs/<class>/` directory | Makes CODEOWNERS and gate selection mechanical | Class parsed from the name prefix (fragile) |
| D5 | Registry and workload identity are bootstrapped, not per-environment | Removes the need for `User Access Administrator` in CI, keeps image promotion provable, avoids duplicating cost | Per-environment registry and identity |
| D6 | One CI identity per class, not a plan/apply pair | With no role-assignment rights to protect, a second identity per class added ceremony without meaningfully reducing risk | Separate read-only plan identities |
| D7 | Apply a saved plan artifact | Reviewed plan == applied plan | Re-plan inside the apply job |
| D8 | GitHub Environments as the gate | Native approvals, audit, and OIDC subject scoping in one mechanism | Bespoke approval logic in the workflow |
| D9 | All Terraform execution in `scripts/tf.sh` | CI and laptop run the same code path; the workflow stays thin | Terraform commands inline in YAML |
| D10 | No submodules in the core | Five resources with no repetition; a module layer would be indirection without a second caller | A module per resource group of concerns |
| D11 | DR = another variables file | Zero new machinery; provable by running it | Paired-region blueprints, Azure Site Recovery |
| D12 | Log Analytics workspace per environment | Cost and retention isolation; clean teardown | One shared workspace |
| D13 | Public `mcr.microsoft.com` hello-world image for the PoC | Removes the image build from the critical path of proving the pipeline | Building an image first |
