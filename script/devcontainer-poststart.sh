#!/usr/bin/env bash
#
# devcontainer-poststart.sh
#
# Runs on every devcontainer start (postStartCommand). Non-interactively logs
# in to Vault via userpass and writes separate mode-600 environment files for
# Vault Radar and Terraform MCP. ~/.zshrc and ~/.bashrc source them on shell
# startup so clients launched later inherit the required variables.
#
# Requires VAULT_USERNAME / VAULT_PASSWORD from the host environment (see
# devcontainer.json's remoteEnv). If they aren't set, this is a no-op --
# falls back to the manual sourced credential scripts, so a container without
# userpass credentials still starts successfully.
#
# SECURITY: never prints a secret value (password/HCP creds) to
# stdout/stderr -- this runs at container start and its output can land in
# logs. Status lines only.

set -uo pipefail

RADAR_ENV_FILE="${HOME}/.hcp-radar-env"
TERRAFORM_ENV_FILE="${HOME}/.hcp-terraform-env"

if [ -z "${VAULT_USERNAME:-}" ] || [ -z "${VAULT_PASSWORD:-}" ]; then
  echo "INFO: VAULT_USERNAME/VAULT_PASSWORD not set -- skipping automatic HCP credential fetch."
  echo "      Source the credential fetch scripts manually instead."
  rm -f "${TERRAFORM_ENV_FILE}"
  exit 0
fi

export VAULT_ADDR="${VAULT_ADDR:-https://vault-cluster-public-vault-289b32ee.99820ad2.z1.hashicorp.cloud:8200}"
export VAULT_NAMESPACE="${VAULT_NAMESPACE:-admin}"
KV_MOUNT="tmai"
RADAR_SECRET_NAME="radar"
TERRAFORM_SECRET_NAME="terraform"

if ! command -v vault >/dev/null 2>&1; then
  echo "ERROR: 'vault' CLI not found on PATH -- cannot fetch HCP credentials." >&2
  rm -f "${TERRAFORM_ENV_FILE}"
  exit 0
fi

if ! vault login -method=userpass username="${VAULT_USERNAME}" password="${VAULT_PASSWORD}" >/dev/null 2>&1; then
  echo "ERROR: userpass login failed -- check VAULT_USERNAME/VAULT_PASSWORD and Vault reachability." >&2
  rm -f "${TERRAFORM_ENV_FILE}"
  exit 0
fi

echo "OK: logged in to Vault via userpass at ${VAULT_ADDR} (namespace ${VAULT_NAMESPACE})."

# --- GitHub CLI auth -------------------------------------------------------
# Non-interactively authenticate `gh` (and git) using a PAT stored alongside
# the HCP creds in Vault (field GH_TOKEN of tmai/radar). Optional: if the
# field is absent/empty, we skip without failing the rest of startup.
# SECURITY: token is piped via stdin to `gh auth login --with-token`, so it
# never appears in argv/process listing/logs. Value is never printed.
if command -v gh >/dev/null 2>&1; then
  gh_token=$(vault kv get -mount="${KV_MOUNT}" -field=GH_TOKEN "${RADAR_SECRET_NAME}" 2>/dev/null) || gh_token=""
  if [ -n "${gh_token}" ]; then
    if printf '%s' "${gh_token}" | gh auth login --with-token >/dev/null 2>&1; then
      gh auth setup-git >/dev/null 2>&1 || true
      echo "OK: gh authenticated via Vault token (value not shown)."
    else
      echo "ERROR: gh auth login failed -- check the GH_TOKEN field in ${KV_MOUNT}/${RADAR_SECRET_NAME}." >&2
    fi
  else
    echo "INFO: no GH_TOKEN in ${KV_MOUNT}/${RADAR_SECRET_NAME} -- skipping gh auth."
  fi
  unset gh_token
else
  echo "INFO: 'gh' CLI not found on PATH -- skipping gh auth."
fi
# ---------------------------------------------------------------------------

# --- Vault Radar IDE/CLI license -----------------------------------------
# The Vault Radar VS Code extension resolves its license from the file named
# by the `vault-radar.cli.licenseFilePath` setting (devcontainer.json), which
# is the same gitignored file the pre-commit hook uses. Fetch it here if
# absent so a fresh container has a working extension without a manual
# /fix-commits run. Mirrors script/validate-commits.sh.
# SECURITY: never prints the license; the value goes straight from
# `vault kv get` into the file via redirection.
RADAR_LICENSE_FILE="/workspace/.devcontainer/.vault-radar-license"
if [ -s "${RADAR_LICENSE_FILE}" ]; then
  echo "OK: Vault Radar license already present (contents not shown)."
else
  umask 077
  if vault kv get -mount="${KV_MOUNT}" -field=VAULT_RADAR_LICENSE "${RADAR_SECRET_NAME}" \
      > "${RADAR_LICENSE_FILE}" 2>/dev/null && [ -s "${RADAR_LICENSE_FILE}" ]; then
    chmod 600 "${RADAR_LICENSE_FILE}"
    echo "OK: fetched Vault Radar license to file (mode 600, value not shown)."
  else
    rm -f "${RADAR_LICENSE_FILE}"
    echo "INFO: could not fetch Vault Radar license from ${KV_MOUNT}/${RADAR_SECRET_NAME} (field VAULT_RADAR_LICENSE) -- run /fix-commits later."
  fi
fi
# ---------------------------------------------------------------------------

umask 077
tmp_file="$(mktemp)"
status=0

# VAULT_ADDR/VAULT_NAMESPACE are not secrets -- persist them alongside the HCP
# fields so the Vault Radar IDE extension's Vault connection setup (address,
# namespace) can be read from this file too. See script/print-radar-ide-connection.sh.
printf 'export %s=%q\n' "VAULT_ADDR" "${VAULT_ADDR}" >> "${tmp_file}"
printf 'export %s=%q\n' "VAULT_NAMESPACE" "${VAULT_NAMESPACE}" >> "${tmp_file}"

for field in HCP_PROJECT_ID HCP_CLIENT_ID HCP_CLIENT_SECRET; do
  value=$(vault kv get -mount="${KV_MOUNT}" -field="${field}" "${RADAR_SECRET_NAME}" 2>/dev/null) || {
    echo "ERROR: could not read field '${field}' from '${KV_MOUNT}/${RADAR_SECRET_NAME}'." >&2
    status=1
    continue
  }
  if [ -z "${value}" ]; then
    echo "ERROR: field '${field}' in '${KV_MOUNT}/${RADAR_SECRET_NAME}' is empty." >&2
    status=1
    continue
  fi
  printf 'export %s=%q\n' "${field}" "${value}" >> "${tmp_file}"
done
unset value field

if [ "${status}" -ne 0 ]; then
  echo "ERROR: one or more Vault Radar credentials could not be fetched; not writing ${RADAR_ENV_FILE}." >&2
  rm -f "${tmp_file}"
else
  mv "${tmp_file}" "${RADAR_ENV_FILE}"
  chmod 600 "${RADAR_ENV_FILE}"
  echo "OK: wrote HCP_PROJECT_ID, HCP_CLIENT_ID, HCP_CLIENT_SECRET to ${RADAR_ENV_FILE} (mode 600, values not shown)."
fi

# --- Terraform MCP and HCP Terraform -------------------------------------
# Fetch the token and target from admin/tmai/terraform. The MCP server reads
# TFE_TOKEN; Terraform CLI reads the same token through its hostname-specific
# TF_TOKEN_app_terraform_io variable.
terraform_tmp_file="$(mktemp)"
terraform_status=0
tfe_token=""
tf_cloud_organization=""
tf_workspace=""

for field in TFE_TOKEN TF_CLOUD_ORGANIZATION TF_WORKSPACE; do
  value=$(vault kv get -namespace="${VAULT_NAMESPACE}" -mount="${KV_MOUNT}" -field="${field}" "${TERRAFORM_SECRET_NAME}" 2>/dev/null) || {
    echo "ERROR: could not read field '${field}' from '${KV_MOUNT}/${TERRAFORM_SECRET_NAME}'." >&2
    terraform_status=1
    continue
  }
  if [ -z "${value}" ]; then
    echo "ERROR: field '${field}' in '${KV_MOUNT}/${TERRAFORM_SECRET_NAME}' is empty." >&2
    terraform_status=1
    continue
  fi
  case "${field}" in
    TFE_TOKEN) tfe_token="${value}" ;;
    TF_CLOUD_ORGANIZATION) tf_cloud_organization="${value}" ;;
    TF_WORKSPACE) tf_workspace="${value}" ;;
  esac
done
unset value field

if [ "${terraform_status}" -ne 0 ]; then
  echo "ERROR: one or more Terraform HCP values could not be fetched; removing stale ${TERRAFORM_ENV_FILE}." >&2
  rm -f "${terraform_tmp_file}" "${TERRAFORM_ENV_FILE}"
else
  printf 'export TFE_TOKEN=%q\n' "${tfe_token}" >> "${terraform_tmp_file}"
  printf 'export TF_TOKEN_app_terraform_io=%q\n' "${tfe_token}" >> "${terraform_tmp_file}"
  printf 'export TF_CLOUD_ORGANIZATION=%q\n' "${tf_cloud_organization}" >> "${terraform_tmp_file}"
  printf 'export TF_WORKSPACE=%q\n' "${tf_workspace}" >> "${terraform_tmp_file}"
  chmod 600 "${terraform_tmp_file}"
  mv "${terraform_tmp_file}" "${TERRAFORM_ENV_FILE}"
  echo "OK: wrote Terraform MCP and HCP Terraform values to ${TERRAFORM_ENV_FILE} (mode 600, values not shown)."
fi

unset tfe_token tf_cloud_organization tf_workspace terraform_status
echo "New shells will pick up available HCP credentials via ~/.zshrc / ~/.bashrc."
exit 0
