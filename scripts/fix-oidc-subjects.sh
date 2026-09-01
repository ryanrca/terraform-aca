#!/usr/bin/env bash
#
# Repairs the "AADSTS700213: No matching federated identity record found" error.
#
# GitHub can present two different OIDC subject formats. Azure matches them as
# exact strings, so a credential registered for one format will never match the
# other. This script registers both, for all three deployment identities.
#
# A federated credential's subject cannot be edited in place, so where a
# credential already exists under the right name with the WRONG subject, this
# script deletes it and immediately recreates it correctly. That is the only
# destructive action it takes, it is confined to credentials this platform owns
# (named gh-*), and it is reported on screen before it happens.
#
# Safe to run more than once.
#
# Usage:   ./scripts/fix-oidc-subjects.sh

set -euo pipefail

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mSTOPPED:\033[0m %s\n\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
head_ "1. Checking prerequisites"
# ---------------------------------------------------------------------------
command -v az >/dev/null || die "The Azure CLI is not installed."
command -v gh >/dev/null || die "The GitHub CLI is not installed."

az account show >/dev/null 2>&1 || die "You are not logged in to Azure. Run: az login"
ok "logged in to Azure as $(az account show --query user.name -o tsv)"

gh auth status >/dev/null 2>&1 || die "You are not logged in to GitHub. Run: gh auth login"
ok "logged in to GitHub as $(gh api user --jq .login)"

# ---------------------------------------------------------------------------
head_ "2. Working out which repository this is"
# ---------------------------------------------------------------------------
remote="$(git remote get-url origin 2>/dev/null)" || die "This is not a git repository with an 'origin' remote."
REPO_OWNER="$(basename "$(dirname "${remote}")" | sed 's/.*://')"
REPO_NAME="$(basename "${remote}" .git)"
ok "repository: ${REPO_OWNER}/${REPO_NAME}"

OWNER_ID="$(gh api "users/${REPO_OWNER}" --jq .id 2>/dev/null || true)"
REPO_ID="$(gh api "repos/${REPO_OWNER}/${REPO_NAME}" --jq .id 2>/dev/null || true)"
[ -n "${OWNER_ID}" ] || die "Could not read the owner ID from GitHub."
[ -n "${REPO_ID}" ]  || die "Could not read the repository ID from GitHub."
ok "owner id: ${OWNER_ID}    repo id: ${REPO_ID}"

# ---------------------------------------------------------------------------
head_ "3. Finding the three deployment identities in Azure"
# ---------------------------------------------------------------------------
# Looked up by name, so this works even if /tmp/acaplat-identities.txt is gone.
declare -A APP_IDS
for class in dev staging prod; do
  app_id="$(az ad app list --display-name "gh-acaplat-${class}" --query "[0].appId" -o tsv 2>/dev/null || true)"
  [ -n "${app_id}" ] && [ "${app_id}" != "None" ] \
    || die "No app registration named 'gh-acaplat-${class}'. Re-run scripts/bootstrap-azure.sh first."
  APP_IDS["${class}"]="${app_id}"
  ok "gh-acaplat-${class}  ->  ${app_id}"
done

# ---------------------------------------------------------------------------
head_ "4. Repairing federated credentials"
# ---------------------------------------------------------------------------
# Both subject formats are registered, because which one GitHub sends is not
# controlled from Azure and a mismatch fails with an opaque AADSTS700213.
#
# A credential's subject cannot be updated in place, and "create" on an existing
# name fails silently - which is how a placeholder subject survives a re-run of
# the bootstrap script. So: if the name exists with the wrong subject, delete it
# and recreate it.
note "classic  : repo:${REPO_OWNER}/${REPO_NAME}:environment:<name>"
note "ID-based : repo:${REPO_OWNER}@${OWNER_ID}/${REPO_NAME}@${REPO_ID}:environment:<name>"
echo

ensure_credential() {
  local app_id="$1" cred_name="$2" want_subject="$3"
  local have_subject

  have_subject="$(az ad app federated-credential list --id "${app_id}" \
    --query "[?name=='${cred_name}'].subject | [0]" -o tsv 2>/dev/null || true)"

  if [ "${have_subject}" = "${want_subject}" ]; then
    printf '  \033[32m✓\033[0m %-20s %s\n' "${cred_name}" "already correct"
    return
  fi

  local action="created"
  if [ -n "${have_subject}" ] && [ "${have_subject}" != "None" ]; then
    action="REPAIRED"
    REPAIRED_DETAIL+=("${cred_name}|${have_subject}")
    # No confirmation flag exists on this command; it deletes without prompting.
    az ad app federated-credential delete --id "${app_id}" \
      --federated-credential-id "${cred_name}" --output none
  fi

  az ad app federated-credential create --id "${app_id}" --parameters "$(cat <<JSON
{
  "name": "${cred_name}",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "${want_subject}",
  "description": "GitHub Actions ${cred_name}",
  "audiences": ["api://AzureADTokenExchange"]
}
JSON
)" --output none
  printf '  \033[32m✓\033[0m %-20s %s\n' "${cred_name}" "${action}"
}

REPAIRED_DETAIL=()

for class in dev staging prod; do
  app_id="${APP_IDS[${class}]}"
  for ghenv in "${class}-plan" "${class}"; do
    ensure_credential "${app_id}" "gh-${ghenv}" \
      "repo:${REPO_OWNER}/${REPO_NAME}:environment:${ghenv}"
    ensure_credential "${app_id}" "gh-${ghenv}-id" \
      "repo:${REPO_OWNER}@${OWNER_ID}/${REPO_NAME}@${REPO_ID}:environment:${ghenv}"
  done
done

# ---------------------------------------------------------------------------
head_ "5. Result"
# ---------------------------------------------------------------------------
if [ ${#REPAIRED_DETAIL[@]} -gt 0 ]; then
  note "${#REPAIRED_DETAIL[@]} credential(s) had the wrong subject and were replaced:"
  for entry in "${REPAIRED_DETAIL[@]}"; do
    note "  ${entry%%|*}  was  ${entry#*|}"
  done
  echo
fi
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
expected="repo:${REPO_OWNER}@${OWNER_ID}/${REPO_NAME}@${REPO_ID}:environment:dev-plan"
if az ad app federated-credential list --id "${APP_IDS[dev]}" --query "[].subject" -o tsv | grep -qxF "${expected}"; then
  ok "the dev-plan credential the OIDC check needs is present"
else
  bad "expected subject is still missing:"
  note "${expected}"
  die "Registration did not take effect. Check that you have permission to modify app registrations."
fi

for class in dev staging prod; do
  echo
  printf '  \033[1mgh-acaplat-%s\033[0m\n' "${class}"
  az ad app federated-credential list --id "${APP_IDS[${class}]}" \
    --query "[].subject" -o tsv | sed 's/^/      /'
done

cat <<'NEXT'

───────────────────────────────────────────────────────────────────────────
  Added the missing credentials. Azure can take about a minute to catch up.

  Now re-run the OIDC check:

      git commit --allow-empty -m "retry OIDC check"
      git push
      gh run watch

  Success looks like a table printing your subscription name and ID.
───────────────────────────────────────────────────────────────────────────

NEXT
