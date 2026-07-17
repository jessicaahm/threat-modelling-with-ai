#!/usr/bin/env bash
#
# fetch-openai-key.sh
#
# Readiness check for the OpenAI API key used by the vulnerability-checker
# agent's LLM triage layer (agent/vuln_agent --triage). Mirrors
# script/validate-commits.sh:
#
#   1. If the key file already exists (non-empty), report OK.
#   2. Otherwise, verify the vault CLI is present and the caller is logged
#      in (valid token) and can reach Vault.
#   3. If so, fetch the key from kv-v2 (namespace admin, mount tmai,
#      secret openai) and write it straight to the key file.
#
# The secret is seeded once, manually, outside any AI session:
#   vault kv put -mount=tmai openai OPENAI_API_KEY=<value>
#
# SECURITY: this script must NEVER print the key (or any secret value)
# to stdout/stderr -- it is invoked from an AI assistant session and its
# output lands in AI context. It prints status lines only; the secret goes
# directly from `vault kv get` into the file via redirection.
#
# Exit codes:
#   0  key file present (already, or fetched just now)
#   2  not logged in to Vault / cannot reach Vault -- run `vault login`
#   3  fetch failed (permissions, unknown field, empty secret, ...)

set -euo pipefail
IFS=$'\n\t'

KEY_FILE="${OPENAI_KEY_FILE:-.devcontainer/.openai-api-key}"

export VAULT_ADDR="${VAULT_ADDR:-https://vault-cluster-public-vault-289b32ee.99820ad2.z1.hashicorp.cloud:8200}"
export VAULT_NAMESPACE="${VAULT_NAMESPACE:-admin}"

KV_MOUNT="tmai"
SECRET_NAME="openai"
PREFERRED_FIELD="OPENAI_API_KEY"

# --- 1. Already present? -------------------------------------------------

if [ -s "${KEY_FILE}" ]; then
  echo "OK: key file already present at ${KEY_FILE} (not showing contents)."
  exit 0
fi

echo "Key file ${KEY_FILE} is missing or empty -- checking Vault access..."

# --- 2. Logged in and able to reach Vault? -------------------------------

if ! command -v vault >/dev/null 2>&1; then
  echo "ERROR: 'vault' CLI not found on PATH." >&2
  exit 2
fi

# `vault token lookup` fails on: no token, expired/revoked token, or an
# unreachable cluster -- all of which mean we cannot fetch.
if ! vault token lookup >/dev/null 2>&1; then
  echo "NOT LOGGED IN: no valid Vault token for ${VAULT_ADDR} (namespace ${VAULT_NAMESPACE})." >&2
  echo "Run 'vault login' in your terminal, then re-run this script." >&2
  exit 2
fi

echo "OK: logged in to Vault at ${VAULT_ADDR} (namespace ${VAULT_NAMESPACE})."

# --- 3. Fetch the key into the file (never onto stdout) ------------------

# Discover field names only (keys, never values) to pick the right -field.
mapfile -t fields < <(
  vault kv get -format=json -mount="${KV_MOUNT}" "${SECRET_NAME}" 2>/dev/null \
    | jq -r '.data.data | keys[]'
) || true

if [ "${#fields[@]}" -eq 0 ]; then
  echo "ERROR: could not read '${KV_MOUNT}/${SECRET_NAME}' -- token may lack the '${KV_MOUNT}' policy, or the secret does not exist yet." >&2
  echo "Seed it once (outside any AI session): vault kv put -mount=${KV_MOUNT} ${SECRET_NAME} ${PREFERRED_FIELD}=<value>" >&2
  exit 3
fi

field=""
for f in "${fields[@]}"; do
  if [ "${f}" = "${PREFERRED_FIELD}" ]; then
    field="${f}"
    break
  fi
done
if [ -z "${field}" ] && [ "${#fields[@]}" -eq 1 ]; then
  field="${fields[0]}"
fi
if [ -z "${field}" ]; then
  echo "ERROR: '${KV_MOUNT}/${SECRET_NAME}' has multiple fields and none is named '${PREFERRED_FIELD}': ${fields[*]}" >&2
  echo "Set PREFERRED_FIELD in $(basename "$0") to the right field name." >&2
  exit 3
fi

echo "Fetching field '${field}' from ${KV_MOUNT}/${SECRET_NAME} into ${KEY_FILE}..."

umask 077
if ! vault kv get -mount="${KV_MOUNT}" -field="${field}" "${SECRET_NAME}" > "${KEY_FILE}" 2>/dev/null; then
  rm -f "${KEY_FILE}"
  echo "ERROR: fetch failed writing ${KEY_FILE} -- check token policy for '${KV_MOUNT}/data/*'." >&2
  exit 3
fi

if [ ! -s "${KEY_FILE}" ]; then
  rm -f "${KEY_FILE}"
  echo "ERROR: fetched value was empty; removed ${KEY_FILE}." >&2
  exit 3
fi

chmod 600 "${KEY_FILE}"
echo "OK: key written to ${KEY_FILE} (mode 600, gitignored, contents not shown)."
echo "The agent's --triage mode can now call the OpenAI API."
exit 0
