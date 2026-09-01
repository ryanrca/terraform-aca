#!/usr/bin/env bash
#
# The single implementation of every Terraform action for this platform.
# Both developers and GitHub Actions run this script, so a plan that works
# locally works in the pipeline.
#
#   ./scripts/tf.sh plan          dev-ryan
#   ./scripts/tf.sh apply         dev-ryan
#   ./scripts/tf.sh destroy       dev-ryan
#   ./scripts/tf.sh resolve       dev-ryan     # env_class / tfvars path / state key
#   ./scripts/tf.sh plan-destroy  dev-ryan     # used by the destroy workflow
#   ./scripts/tf.sh output        dev-ryan
#   ./scripts/tf.sh lint                       # no environment; needs no Azure access
#
# Required environment (identifiers, not secrets):
#   ARM_SUBSCRIPTION_ID      Azure subscription to deploy into
#   PLATFORM_RESOURCE_GROUP  resource group holding shared state / registry / identity
#   TFSTATE_STORAGE_ACCOUNT  storage account holding Terraform state
#   TFSTATE_CONTAINER        blob container holding Terraform state
#   ACR_NAME                 shared container registry
#
# Optional:
#   UAMI_NAME       shared managed identity name (default: id-acaplat-platform)
#   TF_PLAN_FILE    plan file path (default: <repo>/terraform/tfplan)
#   DEPLOYED_BY     provenance tag (default: local)
#   COMMIT_SHA      provenance tag (default: current git SHA, else "local")

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT}/terraform"
PLAN_FILE="${TF_PLAN_FILE:-${TF_DIR}/tfplan}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*" >&2; }

usage() {
  sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^#\s\?//' >&2
  exit 64
}

# ---------------------------------------------------------------------------
# Resolve an environment name to its variables file and class.
#
# The class is the directory the file lives in. The file also declares
# env_class; disagreement is a hard failure, because the directory drives
# CODEOWNERS review and the approval gate while the declaration drives the
# Terraform guardrails. They must never diverge.
# ---------------------------------------------------------------------------
resolve_env() {
  local env="$1"

  [[ "${env}" =~ ^[a-z0-9]([a-z0-9-]{1,20})[a-z0-9]$ ]] \
    || die "invalid environment name '${env}': expected 3-22 lowercase letters, digits and hyphens"

  shopt -s nullglob
  local matches=( "${ROOT}"/envs/*/"${env}.tfvars" )
  shopt -u nullglob

  case "${#matches[@]}" in
    0) die "no variables file found for '${env}' (looked for envs/*/${env}.tfvars)" ;;
    1) : ;;
    *) die "'${env}' matches ${#matches[@]} variables files; environment names must be unique across classes" ;;
  esac

  TFVARS_PATH="${matches[0]}"
  ENV_CLASS="$(basename "$(dirname "${TFVARS_PATH}")")"
  STATE_KEY="${env}.tfstate"

  local declared
  declared="$(sed -nE 's/^[[:space:]]*env_class[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "${TFVARS_PATH}" | head -1)"

  [[ -n "${declared}" ]] \
    || die "${TFVARS_PATH#"${ROOT}"/} does not declare env_class"
  [[ "${declared}" == "${ENV_CLASS}" ]] \
    || die "${TFVARS_PATH#"${ROOT}"/} declares env_class=\"${declared}\" but lives in envs/${ENV_CLASS}/"
}

require_env() {
  local missing=()
  local v
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || missing+=("${v}")
  done
  (( ${#missing[@]} == 0 )) || die "missing required environment variables: ${missing[*]}"
}

# ---------------------------------------------------------------------------
# init always passes -reconfigure, because the backend key changes with the
# environment. Forgetting it is the single most likely way to operate on the
# wrong state.
# ---------------------------------------------------------------------------
tf_init() {
  require_env ARM_SUBSCRIPTION_ID PLATFORM_RESOURCE_GROUP TFSTATE_STORAGE_ACCOUNT TFSTATE_CONTAINER ACR_NAME

  export TF_VAR_acr_name="${ACR_NAME}"
  export TF_VAR_platform_resource_group_name="${PLATFORM_RESOURCE_GROUP}"
  export TF_VAR_uami_name="${UAMI_NAME:-id-acaplat-platform}"
  export TF_VAR_deployed_by="${DEPLOYED_BY:-local}"
  export TF_VAR_commit_sha="${COMMIT_SHA:-$(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || echo local)}"

  log "init: ${ENV_NAME} (class ${ENV_CLASS}, state ${STATE_KEY})"
  terraform -chdir="${TF_DIR}" init \
    -reconfigure \
    -input=false \
    -backend-config="resource_group_name=${PLATFORM_RESOURCE_GROUP}" \
    -backend-config="storage_account_name=${TFSTATE_STORAGE_ACCOUNT}" \
    -backend-config="container_name=${TFSTATE_CONTAINER}" \
    -backend-config="key=${STATE_KEY}" \
    -backend-config="use_azuread_auth=true"
}

# Static checks only: no backend, no credentials, no environment. This is what
# the PR lint job runs.
tf_lint() {
  log "lint: fmt, validate, tflint"
  terraform -chdir="${TF_DIR}" init -backend=false -input=false >/dev/null
  terraform -chdir="${TF_DIR}" fmt -check -recursive
  terraform -chdir="${TF_DIR}" validate

  if command -v tflint >/dev/null 2>&1; then
    tflint --chdir="${TF_DIR}" --init
    tflint --chdir="${TF_DIR}"
  else
    log "tflint not installed, skipping"
  fi
}

tf_check() {
  log "fmt and validate"
  terraform -chdir="${TF_DIR}" fmt -check -recursive
  terraform -chdir="${TF_DIR}" validate
}

tf_plan() {
  local extra=("$@")
  log "plan: ${ENV_NAME}"
  terraform -chdir="${TF_DIR}" plan \
    -input=false \
    -lock-timeout=5m \
    -var-file="${TFVARS_PATH}" \
    -out="${PLAN_FILE}" \
    "${extra[@]}"

  terraform -chdir="${TF_DIR}" show -no-color "${PLAN_FILE}" > "${PLAN_FILE}.txt"
  log "plan written to ${PLAN_FILE} (human-readable: ${PLAN_FILE}.txt)"
}

tf_apply() {
  if [[ -f "${PLAN_FILE}" ]]; then
    # The reviewed plan is the applied plan. A saved plan needs no approval
    # flag, which is exactly what we want in CI.
    log "apply: ${ENV_NAME} (saved plan)"
    terraform -chdir="${TF_DIR}" apply -input=false -lock-timeout=5m "${PLAN_FILE}"
  else
    log "apply: ${ENV_NAME} (no saved plan; planning now, will prompt)"
    terraform -chdir="${TF_DIR}" apply -lock-timeout=5m -var-file="${TFVARS_PATH}"
  fi
}

main() {
  local action="${1:-}" env="${2:-}"

  # lint takes no environment: it never touches Azure or state.
  if [[ "${action}" == "lint" ]]; then
    tf_lint
    return
  fi

  shift 2 2>/dev/null || true
  [[ -n "${action}" && -n "${env}" ]] || usage

  ENV_NAME="${env}"
  resolve_env "${env}"

  case "${action}" in
    resolve)
      printf 'env_name=%s\n'    "${ENV_NAME}"
      printf 'env_class=%s\n'   "${ENV_CLASS}"
      printf 'tfvars_path=%s\n' "${TFVARS_PATH#"${ROOT}"/}"
      printf 'state_key=%s\n'   "${STATE_KEY}"
      ;;
    init)
      tf_init
      ;;
    fmt|validate|check)
      tf_check
      ;;
    plan)
      tf_init; tf_check; tf_plan "$@"
      ;;
    plan-destroy)
      tf_init; tf_check; tf_plan -destroy "$@"
      ;;
    apply)
      tf_init; tf_apply
      ;;
    destroy)
      tf_init; tf_check; tf_plan -destroy "$@"; tf_apply
      ;;
    output)
      tf_init >/dev/null; terraform -chdir="${TF_DIR}" output "$@"
      ;;
    *)
      die "unknown action '${action}' (expected: lint, resolve, init, check, plan, plan-destroy, apply, destroy, output)"
      ;;
  esac
}

main "$@"
