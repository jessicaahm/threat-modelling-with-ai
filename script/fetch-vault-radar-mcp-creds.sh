#!/usr/bin/env bash
#
# fetch-vault-radar-mcp-creds.sh
#
# Populates HCP_PROJECT_ID, HCP_CLIENT_ID, and HCP_CLIENT_SECRET in the
# current shell so the Vault Radar MCP server (.mcp.json) can pick them up
# via `docker run -e VARNAME` (pass-through, no value written to disk).
#
#   1. Verify the vault CLI is present and the caller is logged in.
#   2. Fetch the three fields from kv-v2 (namespace admin, mount tmai,
#      secret radar) and export them into the calling shell.
#
# SECURITY: this script must NEVER print a secret value to stdout/stderr --
# it may be invoked from an AI assistant session and its output can land in
# AI context. It prints status lines only.
#
# Usage: must be sourced, not executed, so the exports reach your shell:
#   source script/fetch-vault-radar-mcp-creds.sh
#
# Exit codes (as return codes when sourced):
#   0  all three vars exported
#   2  not logged in to Vault / cannot reach Vault -- run `vault login`
#   3  fetch failed (permissions, missing field, empty secret, ...)

# Detect execution instead of sourcing so we can `return` on error.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  echo "ERROR: this script must be sourced, not executed:" >&2
  echo "  source script/fetch-vault-radar-mcp-creds.sh" >&2
  exit 1
fi

_fvrmc_fail() {
  echo "$1" >&2
  return "$2"
}

export VAULT_ADDR="${VAULT_ADDR:-https://vault-cluster-public-vault-289b32ee.99820ad2.z1.hashicorp.cloud:8200}"
export VAULT_NAMESPACE="${VAULT_NAMESPACE:-admin}"

_FVRMC_KV_MOUNT="tmai"
_FVRMC_SECRET_NAME="radar"

if ! command -v vault >/dev/null 2>&1; then
  _fvrmc_fail "ERROR: 'vault' CLI not found on PATH." 2
  return 2 2>/dev/null || exit 2
fi

if ! vault token lookup >/dev/null 2>&1; then
  echo "NOT LOGGED IN: no valid Vault token for ${VAULT_ADDR} (namespace ${VAULT_NAMESPACE})." >&2
  echo "Run 'vault login', then re-source this script." >&2
  return 2 2>/dev/null || exit 2
fi

echo "OK: logged in to Vault at ${VAULT_ADDR} (namespace ${VAULT_NAMESPACE})."

_fvrmc_status=0
for field in HCP_PROJECT_ID HCP_CLIENT_ID HCP_CLIENT_SECRET; do
  value=$(vault kv get -mount="${_FVRMC_KV_MOUNT}" -field="${field}" "${_FVRMC_SECRET_NAME}" 2>/dev/null) || {
    echo "ERROR: could not read field '${field}' from '${_FVRMC_KV_MOUNT}/${_FVRMC_SECRET_NAME}'." >&2
    _fvrmc_status=3
    continue
  }
  if [ -z "${value}" ]; then
    echo "ERROR: field '${field}' in '${_FVRMC_KV_MOUNT}/${_FVRMC_SECRET_NAME}' is empty." >&2
    _fvrmc_status=3
    continue
  fi
  export "${field}=${value}"
  echo "OK: ${field} set (value not shown)."
done
unset value field

if [ "${_fvrmc_status}" -ne 0 ]; then
  echo "ERROR: one or more credentials could not be fetched -- check token policy for '${_FVRMC_KV_MOUNT}/data/${_FVRMC_SECRET_NAME}' and that HCP_PROJECT_ID/HCP_CLIENT_ID/HCP_CLIENT_SECRET subkeys exist on the secret." >&2
else
  echo "OK: HCP_PROJECT_ID, HCP_CLIENT_ID, HCP_CLIENT_SECRET exported for this shell session."
  echo "Launch your MCP client from this shell so it inherits them."
fi

unset -f _fvrmc_fail
_fvrmc_ret="${_fvrmc_status}"
unset _fvrmc_status _fvrmc_KV_MOUNT _FVRMC_KV_MOUNT _FVRMC_SECRET_NAME
return "${_fvrmc_ret}" 2>/dev/null || exit "${_fvrmc_ret}"
