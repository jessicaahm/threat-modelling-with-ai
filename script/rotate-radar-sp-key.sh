#!/usr/bin/env bash
#
# rotate-radar-sp-key.sh
#
# Mints a new HCP client_id/client_secret key pair for the
# "vault-radar-agent" service principal (created by infrastructure/hcp.tf)
# and stores it in Vault -- never in Terraform state, never in AI context.
#
#   1. Verify the `hcp` and `vault` CLIs are present and the caller is
#      logged in to both.
#   2. Read the SP resource name from the (non-secret) Terraform output
#      `vault_radar_agent_sp_resource_name` in infrastructure/.
#   3. Mint a new key via `hcp iam service-principals keys create`.
#   4. Merge the new HCP_CLIENT_ID/HCP_CLIENT_SECRET into the existing
#      tmai/radar secret in Vault, preserving its other fields
#      (HCP_PROJECT_ID, GH_TOKEN, VAULT_RADAR_LICENSE, ...).
#
# SECURITY: this script must NEVER print a secret value to stdout/stderr --
# it may be invoked from an AI assistant session and its output can land in
# AI context. It prints status lines only; secret values flow directly
# between `hcp`/`jq`/`vault` via shell variables, never through a file,
# argv, or echo.
#
# Usage: script/rotate-radar-sp-key.sh
#
# Exit codes:
#   0  key minted and stored in Vault
#   2  missing CLI / not logged in to HCP or Vault
#   3  could not resolve the SP resource name, mint the key, read the
#      existing secret, or write the updated secret

set -euo pipefail
IFS=$'\n\t'

export VAULT_ADDR="${VAULT_ADDR:-https://vault-cluster-public-vault-289b32ee.99820ad2.z1.hashicorp.cloud:8200}"
export VAULT_NAMESPACE="${VAULT_NAMESPACE:-admin}"

KV_MOUNT="tmai"
SECRET_NAME="radar"
TF_DIR="infrastructure"
TF_OUTPUT="vault_radar_agent_sp_resource_name"

# --- 1. CLIs present and logged in ---------------------------------------

for bin in hcp vault jq terraform; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "ERROR: '${bin}' CLI not found on PATH." >&2
    exit 2
  fi
done

if ! vault token lookup >/dev/null 2>&1; then
  echo "NOT LOGGED IN: no valid Vault token for ${VAULT_ADDR} (namespace ${VAULT_NAMESPACE})." >&2
  echo "Run 'vault login', then re-run this script." >&2
  exit 2
fi

if ! hcp profile display >/dev/null 2>&1; then
  echo "NOT LOGGED IN: no active HCP profile/session." >&2
  echo "Run 'hcp auth login' (or set HCP_CLIENT_ID/HCP_CLIENT_SECRET for a bootstrap principal), then re-run this script." >&2
  exit 2
fi

echo "OK: logged in to Vault (${VAULT_ADDR}, namespace ${VAULT_NAMESPACE}) and HCP."

# --- 2. Resolve the SP resource name (not secret) ------------------------

resource_name=$(terraform -chdir="${TF_DIR}" output -raw "${TF_OUTPUT}" 2>/dev/null) || {
  echo "ERROR: could not read Terraform output '${TF_OUTPUT}' from ${TF_DIR} -- has it been applied?" >&2
  exit 3
}
if [ -z "${resource_name}" ]; then
  echo "ERROR: Terraform output '${TF_OUTPUT}' is empty." >&2
  exit 3
fi

echo "Minting a new key for principal ${resource_name}..."

# --- 3. Mint the new key (captured, never printed) -----------------------

key_json=$(hcp iam service-principals keys create --principal="${resource_name}" --format=json 2>/dev/null) || {
  echo "ERROR: 'hcp iam service-principals keys create' failed for ${resource_name}." >&2
  exit 3
}

new_client_id=$(printf '%s' "${key_json}" | jq -r '.client_id // empty')
new_client_secret=$(printf '%s' "${key_json}" | jq -r '.client_secret // empty')
unset key_json

if [ -z "${new_client_id}" ] || [ -z "${new_client_secret}" ]; then
  unset new_client_id new_client_secret
  echo "ERROR: minted key response did not contain client_id/client_secret." >&2
  exit 3
fi

# --- 4. Merge into the existing tmai/radar secret -------------------------

existing_json=$(vault kv get -format=json -mount="${KV_MOUNT}" "${SECRET_NAME}" 2>/dev/null) || existing_json='{"data":{"data":{}}}'

kv_args=()
while IFS=$'\t' read -r field value; do
  [ "${field}" = "HCP_CLIENT_ID" ] && continue
  [ "${field}" = "HCP_CLIENT_SECRET" ] && continue
  kv_args+=("${field}=${value}")
done < <(printf '%s' "${existing_json}" | jq -r '.data.data | to_entries[] | [.key, .value] | @tsv')
unset existing_json

kv_args+=("HCP_CLIENT_ID=${new_client_id}" "HCP_CLIENT_SECRET=${new_client_secret}")

if ! vault kv put -mount="${KV_MOUNT}" "${SECRET_NAME}" "${kv_args[@]}" >/dev/null 2>&1; then
  unset new_client_id new_client_secret kv_args
  echo "ERROR: failed to write updated secret to ${KV_MOUNT}/${SECRET_NAME} -- check token policy for '${KV_MOUNT}/data/${SECRET_NAME}'." >&2
  exit 3
fi

unset new_client_id new_client_secret kv_args

echo "OK: minted new key for ${resource_name} and updated ${KV_MOUNT}/${SECRET_NAME} (values not shown)."
echo "Re-source script/fetch-vault-radar-mcp-creds.sh in any open shells to pick up the rotated credentials."
exit 0
