#!/usr/bin/env bash
#
# Fetch Terraform MCP and HCP Terraform values from Vault into the current
# shell. Values are never printed. This script must be sourced so its exports
# reach the MCP client and Terraform CLI launched from the same shell.
#
# Vault location: namespace admin, KV-v2 mount tmai, secret terraform
# Required fields: TFE_TOKEN, TF_CLOUD_ORGANIZATION, TF_WORKSPACE
#
# Usage:
#   source script/fetch-terraform-mcp-creds.sh

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  echo "ERROR: this script must be sourced, not executed:" >&2
  echo "  source script/fetch-terraform-mcp-creds.sh" >&2
  exit 1
fi

export VAULT_ADDR="${VAULT_ADDR:-https://vault-cluster-public-vault-289b32ee.99820ad2.z1.hashicorp.cloud:8200}"
export VAULT_NAMESPACE="${VAULT_NAMESPACE:-admin}"

_FTMC_KV_MOUNT="tmai"
_FTMC_SECRET_NAME="terraform"
_ftmc_status=0
_ftmc_tfe_token=""
_ftmc_organization=""
_ftmc_workspace=""

if ! command -v vault >/dev/null 2>&1; then
  echo "ERROR: 'vault' CLI not found on PATH." >&2
  _ftmc_status=2
elif ! vault token lookup >/dev/null 2>&1; then
  echo "NOT LOGGED IN: no valid Vault token for ${VAULT_ADDR} (namespace ${VAULT_NAMESPACE})." >&2
  echo "Run 'vault login', then re-source this script." >&2
  _ftmc_status=2
else
  echo "OK: logged in to Vault at ${VAULT_ADDR} (namespace ${VAULT_NAMESPACE})."
  for _ftmc_field in TFE_TOKEN TF_CLOUD_ORGANIZATION TF_WORKSPACE; do
    _ftmc_value=$(vault kv get -namespace="${VAULT_NAMESPACE}" -mount="${_FTMC_KV_MOUNT}" -field="${_ftmc_field}" "${_FTMC_SECRET_NAME}" 2>/dev/null) || {
      echo "ERROR: could not read field '${_ftmc_field}' from '${_FTMC_KV_MOUNT}/${_FTMC_SECRET_NAME}'." >&2
      _ftmc_status=3
      continue
    }
    if [ -z "${_ftmc_value}" ]; then
      echo "ERROR: field '${_ftmc_field}' in '${_FTMC_KV_MOUNT}/${_FTMC_SECRET_NAME}' is empty." >&2
      _ftmc_status=3
      continue
    fi
    case "${_ftmc_field}" in
      TFE_TOKEN) _ftmc_tfe_token="${_ftmc_value}" ;;
      TF_CLOUD_ORGANIZATION) _ftmc_organization="${_ftmc_value}" ;;
      TF_WORKSPACE) _ftmc_workspace="${_ftmc_value}" ;;
    esac
  done
fi

if [ "${_ftmc_status}" -eq 0 ]; then
  export TFE_TOKEN="${_ftmc_tfe_token}"
  export TF_TOKEN_app_terraform_io="${_ftmc_tfe_token}"
  export TF_CLOUD_ORGANIZATION="${_ftmc_organization}"
  export TF_WORKSPACE="${_ftmc_workspace}"
  echo "OK: Terraform MCP and HCP Terraform values exported (values not shown)."
  echo "Launch the MCP client from this shell so it inherits them."
fi

_ftmc_return="${_ftmc_status}"
unset _ftmc_status _ftmc_tfe_token _ftmc_organization _ftmc_workspace
unset _ftmc_field _ftmc_value _FTMC_KV_MOUNT _FTMC_SECRET_NAME
return "${_ftmc_return}" 2>/dev/null || exit "${_ftmc_return}"
