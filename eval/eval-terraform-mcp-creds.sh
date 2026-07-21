#!/usr/bin/env bash
#
# Deterministic evaluation for the Terraform MCP Vault credential flow.
# Uses a fake Vault CLI in a disposable directory; no live credentials or
# network access are required, and fixture values grant access to nothing.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FETCH_SCRIPT="${REPO_ROOT}/script/fetch-terraform-mcp-creds.sh"
POSTSTART_SCRIPT="${REPO_ROOT}/script/devcontainer-poststart.sh"
CLAUDE_SETTINGS="${REPO_ROOT}/.claude/settings.json"

PASS=0
FAIL=0

ok() {
  printf 'PASS %s\n' "$1"
  PASS=$((PASS + 1))
}

bad() {
  printf 'FAIL %s\n' "$1"
  FAIL=$((FAIL + 1))
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin" "${WORK}/home"

FAKE_TOKEN="test"
FAKE_ORGANIZATION="example-org"
FAKE_WORKSPACE="example-workspace"
export FAKE_TOKEN FAKE_ORGANIZATION FAKE_WORKSPACE
export FAKE_VAULT_LOG="${WORK}/vault.log"

cat > "${WORK}/bin/vault" <<'FAKE_VAULT'
#!/usr/bin/env bash
set -u

if [ "${1:-}" = "login" ]; then
  [ "${FAKE_VAULT_LOGIN_FAIL:-0}" != "1" ]
  exit $?
fi

if [ "${1:-}" = "token" ] && [ "${2:-}" = "lookup" ]; then
  [ "${FAKE_VAULT_LOGIN_FAIL:-0}" != "1" ]
  exit $?
fi

if [ "${1:-}" != "kv" ] || [ "${2:-}" != "get" ]; then
  exit 1
fi

printf '%s\n' "$*" >> "${FAKE_VAULT_LOG}"
field=""
for arg in "$@"; do
  case "${arg}" in
    -field=*) field="${arg#-field=}" ;;
  esac
done
secret="${!#}"

if [ "${field}" = "${FAKE_VAULT_MISSING:-}" ]; then
  exit 1
fi

case "${secret}:${field}" in
  radar:HCP_PROJECT_ID) printf '%s' 'project' ;;
  radar:HCP_CLIENT_ID) printf '%s' 'client' ;;
  radar:HCP_CLIENT_SECRET) printf '%s' 'test' ;;
  terraform:TFE_TOKEN) printf '%s' "${FAKE_TOKEN}" ;;
  terraform:TF_CLOUD_ORGANIZATION) printf '%s' "${FAKE_ORGANIZATION}" ;;
  terraform:TF_WORKSPACE) printf '%s' "${FAKE_WORKSPACE}" ;;
  *) exit 1 ;;
esac
FAKE_VAULT
chmod 0755 "${WORK}/bin/vault"

manual_output="$({
  PATH="${WORK}/bin:${PATH}"
  source "${FETCH_SCRIPT}"
  [ "${TFE_TOKEN}" = "${FAKE_TOKEN}" ]
  [ "${TF_TOKEN_app_terraform_io}" = "${FAKE_TOKEN}" ]
  [ "${TF_CLOUD_ORGANIZATION}" = "${FAKE_ORGANIZATION}" ]
  [ "${TF_WORKSPACE}" = "${FAKE_WORKSPACE}" ]
} 2>&1)"
manual_rc=$?
if [ "${manual_rc}" -eq 0 ]; then
  ok "manual fetch exports MCP, CLI, organization, and workspace variables"
else
  bad "manual fetch failed with exit ${manual_rc}"
fi

if printf '%s' "${manual_output}" | grep -Fq "${FAKE_ORGANIZATION}" ||
   printf '%s' "${manual_output}" | grep -Fq "${FAKE_WORKSPACE}"; then
  bad "manual fetch printed a Vault value"
else
  ok "manual fetch does not print Vault values"
fi

expected_call='kv get -namespace=admin -mount=tmai -field=TFE_TOKEN terraform'
if grep -Fq "${expected_call}" "${FAKE_VAULT_LOG}"; then
  ok "manual fetch uses namespace admin, mount tmai, secret terraform"
else
  bad "manual fetch did not use the required Vault path"
fi

missing_output="$(env \
  -u TFE_TOKEN \
  -u TF_TOKEN_app_terraform_io \
  -u TF_CLOUD_ORGANIZATION \
  -u TF_WORKSPACE \
  PATH="${WORK}/bin:${PATH}" \
  FAKE_VAULT_MISSING=TF_WORKSPACE \
  FAKE_VAULT_LOG="${FAKE_VAULT_LOG}" \
  FAKE_TOKEN="${FAKE_TOKEN}" \
  FAKE_ORGANIZATION="${FAKE_ORGANIZATION}" \
  FAKE_WORKSPACE="${FAKE_WORKSPACE}" \
  bash -c '
    source "$1"
    rc=$?
    [ "${rc}" -eq 3 ] || exit 10
    [ -z "${TFE_TOKEN+x}" ] || exit 11
    [ -z "${TF_TOKEN_app_terraform_io+x}" ] || exit 12
    [ -z "${TF_CLOUD_ORGANIZATION+x}" ] || exit 13
    [ -z "${TF_WORKSPACE+x}" ] || exit 14
  ' _ "${FETCH_SCRIPT}" 2>&1)"
missing_rc=$?
if [ "${missing_rc}" -eq 0 ]; then
  ok "manual fetch fails atomically when a field is missing"
else
  bad "manual missing-field behavior failed with exit ${missing_rc}: ${missing_output}"
fi

missing_cli_output="$(PATH=/nonexistent /bin/bash -c '
  source "$1"
  [ "$?" -eq 2 ]
' _ "${FETCH_SCRIPT}" 2>&1)"
missing_cli_rc=$?
if [ "${missing_cli_rc}" -eq 0 ]; then
  ok "manual fetch fails when the Vault CLI is unavailable"
else
  bad "missing Vault CLI behavior failed: ${missing_cli_output}"
fi

automatic_output="$(env \
  HOME="${WORK}/home" \
  PATH="${WORK}/bin:${PATH}" \
  VAULT_USERNAME=test-user \
  VAULT_PASSWORD=test-password `# HashiCorpIgnore` \
  FAKE_VAULT_LOG="${FAKE_VAULT_LOG}" \
  FAKE_TOKEN="${FAKE_TOKEN}" \
  FAKE_ORGANIZATION="${FAKE_ORGANIZATION}" \
  FAKE_WORKSPACE="${FAKE_WORKSPACE}" \
  bash "${POSTSTART_SCRIPT}" 2>&1)"
automatic_rc=$?
terraform_env="${WORK}/home/.hcp-terraform-env"
if [ "${automatic_rc}" -eq 0 ] && [ -f "${terraform_env}" ]; then
  ok "automatic startup writes the Terraform environment file"
else
  bad "automatic startup did not write the Terraform environment file"
fi

if [ -f "${terraform_env}" ] && [ "$(stat -c '%a' "${terraform_env}")" = "600" ]; then
  ok "automatic Terraform environment file has mode 600"
else
  bad "automatic Terraform environment file does not have mode 600"
fi

if (
  source "${terraform_env}"
  [ "${TFE_TOKEN}" = "${FAKE_TOKEN}" ] &&
    [ "${TF_TOKEN_app_terraform_io}" = "${FAKE_TOKEN}" ] &&
    [ "${TF_CLOUD_ORGANIZATION}" = "${FAKE_ORGANIZATION}" ] &&
    [ "${TF_WORKSPACE}" = "${FAKE_WORKSPACE}" ]
); then
  ok "automatic environment file contains all required exports"
else
  bad "automatic environment file exports are incomplete"
fi

if printf '%s' "${automatic_output}" | grep -Fq "${FAKE_ORGANIZATION}" ||
   printf '%s' "${automatic_output}" | grep -Fq "${FAKE_WORKSPACE}"; then
  bad "automatic startup printed a Vault value"
else
  ok "automatic startup does not print Vault values"
fi

printf '%s\n' 'export TFE_TOKEN=stale' > "${terraform_env}"
chmod 600 "${terraform_env}"
env \
  HOME="${WORK}/home" \
  PATH="${WORK}/bin:${PATH}" \
  VAULT_USERNAME=test-user \
  VAULT_PASSWORD=test-password `# HashiCorpIgnore` \
  FAKE_VAULT_MISSING=TF_WORKSPACE \
  FAKE_VAULT_LOG="${FAKE_VAULT_LOG}" \
  FAKE_TOKEN="${FAKE_TOKEN}" \
  FAKE_ORGANIZATION="${FAKE_ORGANIZATION}" \
  FAKE_WORKSPACE="${FAKE_WORKSPACE}" \
  bash "${POSTSTART_SCRIPT}" >/dev/null 2>&1

if [ ! -e "${terraform_env}" ]; then
  ok "automatic startup removes stale Terraform credentials after refresh failure"
else
  bad "automatic startup retained stale Terraform credentials"
fi

guard_command="$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0].command' "${CLAUDE_SETTINGS}")"
guard_output="$(printf '%s' '{"tool_input":{"command":"printenv TFE_TOKEN"}}' | bash -c "${guard_command}")"
if printf '%s' "${guard_output}" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  ok "Claude Bash guard denies access to Terraform token variables"
else
  bad "Claude Bash guard did not deny Terraform token access"
fi

target_output="$(printf '%s' '{"tool_input":{"command":"printenv TF_CLOUD_ORGANIZATION TF_WORKSPACE"}}' | bash -c "${guard_command}")"
if [ -z "${target_output}" ]; then
  ok "Claude Bash guard permits access to non-secret Terraform target variables"
else
  bad "Claude Bash guard unexpectedly blocked Terraform target variables"
fi

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
