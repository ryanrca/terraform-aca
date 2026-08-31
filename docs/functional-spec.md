# Functional Specification — ACA Platform (Terraform + GitHub Actions)

| | |
|---|---|
| **Document** | Functional Specification |
| **Version** | 0.1 (draft, for review) |
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

## 2. Scope

### 2.1 In scope

- One Terraform root module ("the core") that describes the entire platform.
- A variables-file-driven environment model: developer sandboxes, staging, production,
  and disaster recovery are all the *same code* with *different inputs*.
- Remote Terraform state in Azure Blob Storage, one state file per environment.
- GitHub Actions workflows to **plan**, **deploy**, and **destroy** any environment on
  demand, including self-service for developers.
- Keyless authentication from GitHub to Azure via OIDC / workload identity federation.
- Bootstrap procedure taking a brand-new Azure tenant to a working pipeline.
- Cost and lifecycle guardrails (scale-to-zero, TTL on sandboxes, automated reaping).

### 2.2 Out of scope (this phase)

- Application source code, Dockerfiles, and the application build pipeline.
- Private networking / VNet-integrated ACA environments, private endpoints, WAF.
- Custom domains, TLS certificates, Azure Front Door / Traffic Manager.
- Databases, caches, queues, or any stateful backing service.
- Secret management beyond what ACA and Key Vault provide natively.
- Multi-subscription or multi-tenant landing zones.

These are explicitly deferred, and Section 17 records how the design keeps the door open
for each of them.

### 2.3 Non-goals

- **Not** a general-purpose landing zone. This is an application platform.
- **Not** Kubernetes. If a workload genuinely needs AKS, it does not belong here.
- **Not** a per-environment code fork. Environment-specific *code* is a design failure;
  see Section 7.3.

## 3. Goals and success criteria

| # | Goal | Success criterion |
|---|---|---|
| G1 | Single Terraform core for all environments | `git diff` between any two environments touches only files under `envs/` |
| G2 | Environments defined by variable files | A new environment requires exactly one new `.tfvars` file and zero code changes |
| G3 | DR is a solved problem | `envs/prod/prod-dr.tfvars` differs from `prod.tfvars` by region and name only |
| G4 | Developer self-service | A developer can create and destroy their own sandbox from the GitHub Actions UI without platform-team involvement |
| G5 | Safe production changes | Production apply requires a reviewed plan and a human approval gate |
| G6 | Keyless CI | No Azure client secrets, storage keys, or PATs stored in GitHub |
| G7 | Cost containment | Idle sandboxes cost approximately nothing and are destroyed automatically |
| G8 | Working PoC | A public HTTPS URL returns the hello-world page, produced only by pipeline runs |

## 4. Personas and primary use cases

| Persona | Needs |
|---|---|
| **Application developer** | Stand up a personal environment on demand, deploy to it repeatedly, tear it down when finished. No Azure portal access required. |
| **Platform engineer** | Own the Terraform core and the environment contract; review changes to staging/production inputs. |
| **Release manager** | Promote a known-good configuration to staging then production, with an audit trail. |
| **IT / FinOps** | See what exists, who owns it, what it costs, and be confident nothing is left running by accident. |

### Primary use cases

1. **UC-1 Create sandbox** — developer adds `envs/dev/dev-<name>.tfvars`, merges, runs the
   Deploy workflow, receives a public URL.
2. **UC-2 Iterate** — developer re-runs Deploy after changing image tag or replica counts.
3. **UC-3 Destroy sandbox** — developer runs the Destroy workflow; all Azure resources for
   that environment are removed and the state file is emptied.
4. **UC-4 Promote to staging** — merge to `main` triggers (or a maintainer dispatches) a
   staging deploy.
5. **UC-5 Promote to production** — plan is produced, a reviewer approves the GitHub
   Environment gate, the *exact reviewed plan* is applied.
6. **UC-6 Invoke DR** — deploy `prod-dr` into the secondary region; it is an independent,
   fully functional stack.
7. **UC-7 Reap expired sandboxes** — a scheduled workflow destroys sandboxes past their TTL.

## 5. Architecture overview

### 5.1 What gets deployed per environment

Every environment is a self-contained, independently destroyable stack:

```
   Internet
      │  HTTPS (managed cert on *.<region>.azurecontainerapps.io)
      ▼
┌─────────────────────────────────────────────────────────────────┐
│ Resource Group   rg-acaplat-<env>-<region>-<instance>            │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │ Container App Environment  cae-acaplat-<env>-…              │ │
│  │   Consumption workload profile, scale-to-zero capable        │ │
│  │                                                              │ │
│  │   ┌──────────────────────────────────────────────────────┐  │ │
│  │   │ Container App  ca-hello-<env>-…                       │  │ │
│  │   │   image: <app_image>   ingress: external, port 80     │  │ │
│  │   │   replicas: min..max   revision mode: Single          │  │ │
│  │   │   identity: user-assigned                             │  │ │
│  │   └──────────────────────────────────────────────────────┘  │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  Log Analytics Workspace    log-acaplat-<env>-…                  │
│  User-Assigned Identity     id-acaplat-<env>-…                   │
│  Container Registry         cracaplat<env>…      (optional)      │
│  Management Lock            CanNotDelete         (staging/prod)  │
└─────────────────────────────────────────────────────────────────┘
```

Shared, bootstrapped **once** and never managed by the core Terraform:

```
┌────────────────────────────────────────────────────────────────┐
│ rg-acaplat-tfstate-<region>-001                                 │
│   Storage Account  stacaplattfstate<suffix>                     │
│     Container  tfstate/                                          │
│       dev-ryan.tfstate   staging.tfstate                         │
│       dev-alice.tfstate  prod.tfstate   prod-dr.tfstate          │
│   (versioning on, soft-delete 30d, shared-key access disabled)   │
└────────────────────────────────────────────────────────────────┘
```

### 5.2 Resource inventory

| Resource | Terraform type | Notes |
|---|---|---|
| Resource group | `azurerm_resource_group` | One per environment; the unit of destruction |
| Log Analytics workspace | `azurerm_log_analytics_workspace` | ACA console/system logs sink; per-env retention and daily cap |
| Container App Environment | `azurerm_container_app_environment` | Consumption profile; the ACA "cluster" |
| Container App | `azurerm_container_app` | The hello-world workload; external ingress |
| User-assigned identity | `azurerm_user_assigned_identity` | Future ACR pull / Key Vault access; created now to fix the pattern |
| Container registry | `azurerm_container_registry` | Optional (`enable_acr`); off for the PoC, on later |
| Role assignment `AcrPull` | `azurerm_role_assignment` | Only when ACR is enabled |
| Management lock | `azurerm_management_lock` | `CanNotDelete` on staging/prod RG; guards against portal deletion |
| Expiry timestamp | `time_offset` | Computes the `expires_at` tag from `ttl_hours` |

### 5.3 Why ACA (recorded for the review)

ACA gives us serverless containers with scale-to-zero, built-in ingress and managed TLS,
revisions and traffic splitting, and Dapr/KEDA if we want them — without operating a
control plane. For a platform whose first workload is a stateless HTTP service, this is
materially cheaper and lower-toil than AKS. The Terraform surface is small enough that a
single root module is honest rather than a simplification.

## 6. Environment model

### 6.1 Environment classes

Every environment belongs to exactly one **class**, which determines its guardrails,
which identity deploys it, and which approval gates apply.

| Class | Examples | Approval to apply | Approval to destroy | TTL | Resource lock | Cost posture |
|---|---|---|---|---|---|---|
| `dev` | `dev-ryan`, `dev-alice`, `dev-feature-x` | none | none | 72 h default | no | min replicas 0, LA cap 1 GB/day |
| `staging` | `staging` | none (auto on merge to `main`) | required | none | yes | min replicas 1 |
| `prod` | `prod`, `prod-dr` | **required** | **required + typed confirmation** | none | yes | min replicas 2 |

Class is derived from the directory the variables file lives in — `envs/dev/`,
`envs/staging/`, `envs/prod/` — and is *also* asserted inside the file as `env_class`.
The pipeline fails if the two disagree. This makes CODEOWNERS enforcement trivial:
`envs/prod/` and `envs/staging/` require platform-team review, `envs/dev/` does not.

### 6.2 The environment contract

An environment is fully described by one variables file. The contract is:

- **Name** (`env_name`) is globally unique across the platform, lowercase, `a-z0-9-`,
  3–22 characters. It is the state-file key, the workflow input, and part of every
  resource name.
- **Class** (`env_class`) is one of `dev`, `staging`, `prod`.
- **Region** (`location`) is any Azure region where ACA is available.
- Everything else has a defaulted value in `variables.tf`. A minimal sandbox file is
  under ten lines.

### 6.3 Naming convention

`<abbrev>-<workload>-<env_name>-<region_short>-<instance>`

| Resource | Pattern | Example |
|---|---|---|
| Resource group | `rg-acaplat-<env>-<loc>-<inst>` | `rg-acaplat-dev-ryan-eus2-001` |
| Container App Env | `cae-acaplat-<env>-<loc>-<inst>` | `cae-acaplat-staging-eus2-001` |
| Container App | `ca-<app>-<env>` | `ca-hello-dev-ryan` |
| Log Analytics | `log-acaplat-<env>-<loc>-<inst>` | `log-acaplat-prod-eus2-001` |
| Managed identity | `id-acaplat-<env>-<loc>-<inst>` | `id-acaplat-prod-dr-wus3-001` |
| Container registry | `cracaplat<env><inst>` (alphanumeric, ≤50) | `cracaplatstaging001` |

Names are produced by a single `naming` module so the convention lives in one place.
Container App names are capped at 32 characters — the module truncates deterministically
and validation rejects `env_name` values that would collide after truncation.

### 6.4 Mandatory tags

Applied to every resource via the provider's default tags plus the RG:

`environment`, `env_class`, `workload=acaplat`, `owner`, `cost_center`, `managed_by=terraform`,
`repo`, `expires_at` (empty when TTL is disabled), `deployed_by`, `commit_sha`.

`expires_at`, `owner`, and `env_class` are what the reaper and FinOps reporting query on.

## 7. Terraform design

### 7.1 Repository layout

```
.
├── CLAUDE.md
├── README.md
├── docs/
│   └── functional-spec.md            ← this document
├── terraform/                        ← THE CORE. Identical for every environment.
│   ├── versions.tf                   provider + terraform version constraints
│   ├── providers.tf                  azurerm/time provider config, default tags
│   ├── backend.tf                    partial backend — no values committed
│   ├── variables.tf                  the environment contract, with validation
│   ├── locals.tf                     derived values, tag merge
│   ├── main.tf                       module composition
│   ├── outputs.tf                    app_url, fqdn, rg name, …
│   └── modules/
│       ├── naming/                   name generation, the only place conventions live
│       ├── observability/            Log Analytics workspace
│       ├── container_app_env/        ACA environment + workload profiles
│       └── container_app/            a single container app + ingress + identity
├── envs/                             ← THE ONLY PLACE ENVIRONMENTS DIFFER
│   ├── dev/
│   │   ├── dev-ryan.tfvars
│   │   └── dev-alice.tfvars
│   ├── staging/
│   │   └── staging.tfvars
│   └── prod/
│       ├── prod.tfvars
│       └── prod-dr.tfvars
├── scripts/
│   ├── bootstrap-azure.sh            one-time tenant/subscription setup
│   ├── tf.sh                         local wrapper: ./scripts/tf.sh plan dev-ryan
│   └── reap.sh                       find expired sandboxes, dispatch destroys
└── .github/
    ├── CODEOWNERS
    └── workflows/
        ├── _terraform.yml            reusable workflow — all TF execution lives here
        ├── pr-plan.yml               PR: fmt, validate, lint, plan every changed env
        ├── deploy.yml                workflow_dispatch + push to main → staging
        ├── destroy.yml               workflow_dispatch, guarded
        └── reaper.yml                schedule: destroy expired sandboxes
```

### 7.2 State management

- Backend: `azurerm`, using **AzureAD auth** (`use_azuread_auth = true`). Storage account
  shared-key access is disabled, so there is no key to leak.
- **One state file per environment**, key = `<env_name>.tfstate`. Blast radius of any
  single apply is one environment.
- `backend.tf` contains an empty `backend "azurerm" {}` block; all values are supplied at
  `terraform init` time with `-backend-config`. This is what allows one core to serve N
  environments.
- Locking uses native blob leases — no extra infrastructure.
- Blob versioning and 30-day soft delete are enabled, giving us state recovery.

### 7.3 Explicit design rules

These are the rules that keep G1/G2 true. They are restated in `CLAUDE.md` as
non-negotiable for contributors and for AI assistants working in this repo.

1. **No environment names in the core.** `terraform/**` must never contain the strings
   `dev`, `staging`, or `prod` in a conditional. No `count = var.env_name == "prod" ? 1 : 0`.
   If production needs something staging does not, that is a **variable with a default**,
   e.g. `enable_resource_lock`.
2. **No Terraform workspaces.** Workspaces hide the environment in CLI state rather than
   in a reviewable file, and they encourage `terraform.workspace` conditionals — exactly
   the anti-pattern rule 1 forbids. State keys give the same isolation, visibly.
3. **Every input is validated at the boundary.** `variables.tf` carries `validation`
   blocks; cross-variable invariants (e.g. "dev must have a TTL", "prod must be locked")
   are enforced with cross-object validation / `precondition` checks so a bad tfvars fails
   in seconds, before touching Azure.
4. **Defaults are safe-for-dev.** An omitted value must never silently produce an
   expensive or production-grade resource. Staging and production state their posture
   explicitly.
5. **Modules are thin and local.** `terraform/modules/*` are composition helpers, not a
   published module library. No remote module sources in this phase.
6. **Providers are pinned** with `~>` on minor and a committed `.terraform.lock.hcl`.

### 7.4 Variable contract (summary)

Full reference lives in `terraform/variables.tf`; this is the shape.

| Variable | Type | Default | Purpose |
|---|---|---|---|
| `env_name` | string | — | Unique environment identifier; state key; name component |
| `env_class` | string | — | `dev` \| `staging` \| `prod` |
| `location` | string | `eastus2` | Azure region |
| `instance` | string | `"001"` | Disambiguator for parallel stacks in one region |
| `owner` | string | — | Email or team alias; tag + reaper contact |
| `cost_center` | string | `"IT-PLATFORM"` | Chargeback tag |
| `extra_tags` | map(string) | `{}` | Free-form additional tags |
| `ttl_hours` | number | `72` | `0` disables expiry; must be `> 0` for `dev` |
| `enable_resource_lock` | bool | `false` | `CanNotDelete` lock; must be `true` for `prod` |
| `log_retention_days` | number | `30` | Log Analytics retention |
| `log_daily_quota_gb` | number | `1` | `-1` for unlimited; caps sandbox spend |
| `enable_acr` | bool | `false` | Create a registry + grant `AcrPull` to the app identity |
| `acr_sku` | string | `"Basic"` | |
| `app_name` | string | `"hello"` | Container app short name |
| `app_image` | string | `mcr.microsoft.com/azuredocs/containerapps-helloworld:latest` | The PoC image |
| `app_target_port` | number | `80` | Container listen port |
| `app_cpu` | number | `0.25` | vCPU per replica |
| `app_memory` | string | `"0.5Gi"` | Must pair legally with `app_cpu` |
| `app_min_replicas` | number | `0` | `0` = scale to zero |
| `app_max_replicas` | number | `1` | |
| `app_env_vars` | map(string) | `{}` | Non-secret environment variables |
| `ingress_external` | bool | `true` | Public ingress; required for the PoC |
| `ingress_allowed_ip_ranges` | list(string) | `[]` | Empty = allow all; ACA ingress IP restrictions |

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
cost_center          = "IT-PROD"
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
cost_center          = "IT-PROD"
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
GitHub Actions job (environment: prod-apply)
   │  id-token: write  →  OIDC JWT
   │      sub = repo:<ORG>/<REPO>:environment:prod-apply
   ▼
Entra ID app registration  gh-acaplat-prod-apply
   federated credential matching that exact subject
   ▼
Service principal with Azure RBAC → subscription
```

### 8.2 Plan/apply split

Each class has **two** identities. Plan runs with read-only Azure rights and cannot be
used to change anything even if the workflow is compromised; apply runs behind the
approval gate.

| Identity | GitHub Environment | Azure roles | Federated subjects |
|---|---|---|---|
| `gh-acaplat-dev-plan` | `dev-plan` | `Reader` (sub), `Storage Blob Data Contributor` (state container) | `environment:dev-plan`, `pull_request` |
| `gh-acaplat-dev-apply` | `dev-apply` | `Contributor` (sub), `Storage Blob Data Contributor` | `environment:dev-apply` |
| `gh-acaplat-staging-plan` | `staging-plan` | as above | `environment:staging-plan`, `pull_request` |
| `gh-acaplat-staging-apply` | `staging-apply` | `Contributor`, `User Access Administrator`, `Storage Blob Data Contributor` | `environment:staging-apply` |
| `gh-acaplat-prod-plan` | `prod-plan` | `Reader`, `Storage Blob Data Contributor` | `environment:prod-plan`, `pull_request` |
| `gh-acaplat-prod-apply` | `prod-apply` | `Contributor`, `User Access Administrator`, `Storage Blob Data Contributor` | `environment:prod-apply` |

`User Access Administrator` is required only because Terraform creates the `AcrPull` role
assignment for the workload identity. It is granted to apply identities only, and should
be scoped down (or replaced with a pre-created assignment) when ACR is enabled for real.

Plan identities need **write** access to the state container because `terraform plan`
acquires a state lock and may write a refreshed state. `Reader` on the subscription plus
blob-data write on the state container is the correct, minimal combination.

### 8.3 Approval gates

Implemented as GitHub Environment protection rules, not as logic in the workflow:

- `prod-apply` — required reviewers: platform team. Optional wait timer.
- `staging-apply` — no reviewers; branch policy restricts it to `main`.
- `*-destroy` for staging/prod — required reviewers, plus a typed-confirmation input in
  the workflow that must exactly equal the environment name.
- `dev-apply` / `dev-destroy` — no reviewers. Self-service is the point.

### 8.4 Human access

Developers do not need Azure portal write access for the normal workflow. Read access
(`Reader` on the subscription, plus `Log Analytics Reader`) is recommended so they can see
logs and metrics for their sandbox. Break-glass Owner access is a separate, audited PIM
role and is out of scope for this document.

## 9. CI/CD design

### 9.1 Workflow inventory

| Workflow | Trigger | What it does |
|---|---|---|
| `_terraform.yml` | `workflow_call` | The only place `terraform` runs. Inputs: `env_name`, `action` (`plan`/`apply`/`destroy`), `gh_environment`. Handles init with per-env backend config, fmt/validate, plan, artifact upload, apply. |
| `pr-plan.yml` | `pull_request` | Detects changed `envs/**` files and any change under `terraform/**`; runs fmt+validate+tflint once and a plan per affected environment; posts a collapsed plan summary as a PR comment. |
| `deploy.yml` | `workflow_dispatch`, `push` to `main` | Dispatch: choose any environment, plan → gate → apply. Push to `main`: auto-plan+apply `staging` only. |
| `destroy.yml` | `workflow_dispatch` | Choose an environment, type the confirmation, plan a destroy, gate, apply the destroy. |
| `reaper.yml` | `schedule` (daily 06:00 UTC), `workflow_dispatch` | Queries Azure for resource groups tagged `env_class=dev` with `expires_at` in the past and dispatches `destroy.yml` for each. Dry-run by default on manual dispatch. |

### 9.2 Deploy sequence

```
workflow_dispatch(environment=prod)
   │
   ├─ resolve ─────────────────────────────────────────────────
   │    find envs/*/<env>.tfvars  (exactly one, else fail)
   │    derive env_class from the path, cross-check env_class in the file
   │    emit: tfvars_path, env_class, plan/apply GitHub Environment names
   │
   ├─ plan ────────────────────── environment: prod-plan ──────
   │    OIDC login (read-only identity)
   │    terraform init -backend-config=key=prod.tfstate
   │    terraform fmt -check && validate
   │    terraform plan -var-file=envs/prod/prod.tfvars -out=tfplan
   │    upload tfplan + human-readable plan as artifacts
   │    write plan summary to the job summary
   │
   ├─ apply ───────────────────── environment: prod-apply ─────
   │    ⏸ waits for required reviewer approval
   │    OIDC login (apply identity)
   │    terraform init (same backend config)
   │    download tfplan artifact
   │    terraform apply tfplan      ← the exact reviewed plan, no re-plan
   │    publish outputs (app_url) to the job summary
   │
   └─ concurrency: group=terraform-prod, cancel-in-progress=false
```

Key properties:

- **Apply applies a saved plan.** No drift between what was reviewed and what runs.
- **Concurrency group per environment.** Two applies against the same environment queue
  rather than fighting over the state lock; applies against *different* environments run
  in parallel freely.
- **Everything is an artifact.** Plan output, apply log, and outputs are retained on the
  run for audit.

### 9.3 Destroy sequence

`destroy.yml` inputs:

| Input | Required | Notes |
|---|---|---|
| `environment` | yes | Environment name, e.g. `dev-ryan` |
| `confirm` | yes | Must exactly equal `environment`; the job fails fast otherwise |

Flow: resolve → `terraform plan -destroy` (plan identity, always shown) → gate on
`<class>-destroy` GitHub Environment → `terraform apply` the destroy plan → verify the
resource group is gone → report.

Guardrails:

- `dev`: no approval. A developer destroying their own sandbox is routine.
- `staging`/`prod`: required reviewers on the destroy environment. Additionally, the
  workflow refuses to run against `prod`/`prod-dr` unless the actor is in the platform
  team (checked via the environment's reviewer list, not bespoke logic).
- The management lock is a Terraform-managed resource, so `terraform destroy` removes it
  first and then the resource group. Out-of-band portal deletion remains blocked.

### 9.4 Pull-request experience

For a PR that adds `envs/dev/dev-alice.tfvars`, the PR check posts:

```
Terraform plan — dev-alice (dev)
  Plan: 6 to add, 0 to change, 0 to destroy.
  + azurerm_resource_group.this                rg-acaplat-dev-alice-eus2-001
  + azurerm_log_analytics_workspace.this       log-acaplat-dev-alice-eus2-001
  + azurerm_container_app_environment.this     cae-acaplat-dev-alice-eus2-001
  + azurerm_container_app.this                 ca-hello-dev-alice
  + azurerm_user_assigned_identity.this        id-acaplat-dev-alice-eus2-001
  + time_offset.expiry
```

A change under `terraform/**` fans out a plan for *every* existing environment, so core
changes are reviewed against real production state before merge.

## 10. Environment lifecycle

### 10.1 Creating a developer sandbox

1. Copy `envs/dev/dev-template.tfvars` to `envs/dev/dev-<name>.tfvars`, set `env_name`,
   `owner`, and any overrides.
2. Open a PR. The PR plan runs; a platform reviewer is *not* required for `envs/dev/`.
3. Merge.
4. Actions → **Deploy** → environment `dev-<name>` → Run.
5. The job summary prints the public URL.

Time to first URL: roughly 5 minutes, most of it ACA environment provisioning.

### 10.2 TTL and reaping

At apply time Terraform computes `expires_at = now + ttl_hours` (via `time_offset`) and
tags the resource group. The value is stable across applies unless `ttl_hours` changes —
re-deploying does **not** silently extend the lease; a developer extends it by raising
`ttl_hours` (or setting `0`, which requires a platform reviewer via CODEOWNERS on a
`ttl_hours = 0` in `envs/dev/` — enforced by a policy check in `pr-plan.yml`).

The reaper runs daily, finds expired dev resource groups, and dispatches `destroy.yml`.
It posts a summary listing what it destroyed and notifies owners.

### 10.3 Promotion path

There is no artifact promotion in this phase because there is no build. The promotion
unit is a **git commit**: the same `terraform/**` code, applied to `staging` on merge to
`main`, then dispatched to `prod` after verification. Once the application pipeline
exists, `app_image` becomes the promoted artifact and moves from tfvars to a workflow
input.

## 11. Disaster recovery

### 11.1 Design

Because the platform is stateless and every environment is a complete, independent stack,
DR is not a special mechanism — it is a second environment in a second region.

- `prod-dr` is defined by one variables file differing from `prod` in `env_name` and
  `location`.
- It has its own state file, its own resource group, its own ACA environment.
- It can be run **warm** (deployed continuously, minimal replicas) or **cold** (deployed
  on demand from the pipeline).

### 11.2 Objectives (PoC posture)

| Mode | RTO | RPO | Cost |
|---|---|---|---|
| Cold — deploy on demand | ~10 min (pipeline run) | N/A (stateless) | ~0 |
| Warm — `app_min_replicas = 1`, always deployed | < 5 min (DNS/traffic switch) | N/A (stateless) | one small ACA env |

For the PoC, `prod-dr` is defined but not continuously deployed; the DR drill *is* running
the Deploy workflow against it.

### 11.3 What DR does not yet cover

Traffic steering is manual — each environment has its own
`*.<region>.azurecontainerapps.io` hostname. Azure Front Door with both environments as
origins, or Traffic Manager with health probes, is the next step and is listed in
Section 17. Once state exists (databases, storage), DR stops being free and requires a
replication design; this specification will need revision at that point.

## 12. Security

| Control | Implementation |
|---|---|
| No long-lived cloud credentials | OIDC workload identity federation; zero secrets in GitHub |
| No storage account keys | `allow-shared-key-access false`; Entra ID auth to the state backend |
| Least privilege in CI | Plan identities are `Reader`; write rights only behind approval gates |
| Federated subject pinning | Credentials bound to `repo:<ORG>/<REPO>:environment:<name>` — another repo cannot assume them |
| Fork safety | `pull_request` plans do not receive OIDC tokens from forks; repository is internal, forks disabled |
| State protection | Blob versioning, 30-day soft delete, private endpoint-ready, no public blob access |
| Accidental deletion | `CanNotDelete` management lock on staging/prod resource groups |
| Supply chain | Actions pinned to full commit SHAs; provider versions pinned; `.terraform.lock.hcl` committed |
| Secrets in app config | Non-secret values via `app_env_vars`; real secrets via ACA secrets backed by Key Vault (next phase) |
| Auditability | Every change is a merged commit plus a retained plan artifact and an Actions run record |
| Static analysis | `terraform fmt`, `validate`, `tflint`, and `checkov`/`trivy config` in the PR check |

Known accepted risks for the PoC, to be revisited:

- Deployment identities are scoped at **subscription** level. Production should move to a
  subscription per class (dev / staging / prod) — the design supports this by changing one
  GitHub variable per environment.
- ACA ingress is public with no WAF. Acceptable for a hello-world PoC; not for real data.
- `User Access Administrator` on apply identities is broader than ideal.

## 13. Cost model

Indicative monthly cost, US East 2 list pricing, per environment:

| Environment | Shape | Rough cost |
|---|---|---|
| Developer sandbox | min replicas 0, 0.25 vCPU / 0.5 Gi, LA capped 1 GB/day | **≈ $0–5** idle; charged only while requests flow |
| Staging | min 1, 0.25 vCPU / 0.5 Gi, 30-day logs | **≈ $30–50** |
| Production | min 2, 0.5 vCPU / 1 Gi, 90-day logs | **≈ $100–160** |
| Production DR (cold) | not deployed | **$0** |
| Shared state storage | one ZRS account, a few MB | **< $1** |

The dominant *risk* is not the container runtime but Log Analytics ingestion, hence the
per-environment daily quota that defaults to 1 GB. Sandboxes scale to zero and are reaped
after 72 hours; the realistic worst case for a forgotten sandbox is a few dollars.

## 14. Observability

- Container `stdout`/`stderr` and ACA system logs flow to the environment's Log Analytics
  workspace (`ContainerAppConsoleLogs_CL`, `ContainerAppSystemLogs_CL`).
- Each environment has its **own** workspace: sandbox log volume can never affect
  production retention or cost, and workspace deletion is part of environment destruction.
- Application Insights and distributed tracing are deferred until there is an application
  worth tracing.
- Deployment observability is the GitHub Actions run: plan artifact, apply log, outputs.

## 15. Testing and validation

| Layer | Check | Where |
|---|---|---|
| Formatting | `terraform fmt -check -recursive` | PR check |
| Syntax/schema | `terraform validate` | PR check |
| Lint | `tflint` with the azurerm ruleset | PR check |
| Security | `checkov` (or `trivy config`) on `terraform/` | PR check |
| Contract | `variable validation` + `precondition` blocks | Every plan |
| Integration | Plan against every existing environment when `terraform/**` changes | PR check |
| Smoke | After apply, `curl -sf <app_url>` asserts HTTP 200 and expected body | `_terraform.yml` apply job |
| Teardown | Destroy workflow asserts the resource group no longer exists | `destroy.yml` |

## 16. Acceptance criteria for the PoC

The PoC is accepted when all of the following are demonstrated:

1. A brand-new Azure subscription is bootstrapped using only the documented README steps.
2. `staging` deploys from a GitHub Actions run and returns HTTP 200 from a public URL.
3. `prod` deploys only after a human approves the GitHub Environment gate, and the applied
   plan is byte-identical to the reviewed plan.
4. A developer creates `dev-<name>` via PR + Deploy without platform-team involvement, and
   destroys it via the Destroy workflow.
5. `prod-dr` deploys into a second region from a variables file that differs from `prod`
   only in name and region.
6. Attempting to destroy `prod` without approval fails; attempting with a mismatched
   `confirm` input fails fast.
7. No Azure client secret or storage key exists anywhere in the repository or in GitHub
   secrets.
8. `grep -rniE '\b(dev|staging|prod)\b' terraform/` returns no conditional logic.

## 17. Roadmap (post-PoC)

| Phase | Item |
|---|---|
| 2 | Application build pipeline; ACR enabled; `app_image` becomes a promoted artifact |
| 2 | Key Vault + ACA secret references; managed identity for data-plane access |
| 3 | VNet-integrated ACA environments, private endpoints, no public ingress on prod |
| 3 | Azure Front Door in front of `prod` + `prod-dr`, health-probe failover, custom domain + TLS |
| 3 | Subscription-per-class isolation; management groups; Azure Policy guardrails |
| 4 | Multiple container apps per environment (`app` variable becomes a map), Dapr, KEDA scalers |
| 4 | Cost reporting by `cost_center` tag; budget alerts per environment |
| 4 | Drift detection: scheduled plan against staging/prod, alert on non-empty diff |

## 18. Decisions log

| # | Decision | Rationale | Alternatives rejected |
|---|---|---|---|
| D1 | One root module, variables files per environment | Satisfies G1/G2; a new environment is a file, not a fork | Terragrunt (extra tool, extra concept); per-env root modules (drift) |
| D2 | No Terraform workspaces | Environment must be visible in the repo and in review, not in CLI state | Workspaces |
| D3 | State key per environment in one container | Isolation with trivial bootstrap; blob-lease locking is free | Single state (blast radius); per-env storage accounts (toil) |
| D4 | Class derived from `envs/<class>/` directory | Makes CODEOWNERS and gate selection mechanical | Class parsed from name prefix (fragile) |
| D5 | Separate plan and apply identities | A compromised plan job cannot mutate Azure | Single identity per class |
| D6 | Apply a saved plan artifact | Reviewed plan == applied plan | Re-plan inside apply |
| D7 | GitHub Environments as the gate | Native approvals, audit, and OIDC subject scoping in one mechanism | Bespoke approval logic in the workflow |
| D8 | DR = another variables file | Zero new machinery; provable by running it | Paired-region blueprints, ASR |
| D9 | Log Analytics per environment | Cost/retention isolation; clean teardown | One shared workspace |
| D10 | Public `mcr.microsoft.com` hello-world image for the PoC | Removes ACR/build from the critical path of proving the pipeline | Building an image first |

## 19. Open questions for review

1. **Subscription strategy** — one subscription for the PoC, or dev/staging/prod
   subscriptions from day one? The design supports either; the answer changes only
   bootstrap and GitHub variables.
2. **Sandbox naming** — per-developer (`dev-ryan`) or per-feature (`dev-feature-x`)? The
   contract allows both; do we want a policy?
3. **Default TTL** — is 72 hours right, or should it be one working week?
4. **Region pair** — `eastus2` / `westus3` assumed. Confirm against data-residency and
   ACA availability requirements.
5. **Who approves production?** Named reviewer group for the `prod-apply` and
   `prod-destroy` environments.
6. **Staging auto-deploy** — should merges to `main` deploy staging automatically, or
   should staging also be dispatch-only?
