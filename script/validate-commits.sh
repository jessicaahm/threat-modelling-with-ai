#!/usr/bin/env bash
#
# validate-commits.sh
#
# Pre-commit readiness check for the Vault Radar license, driven by the
# /validate-commits Claude Code skill (.claude/skills/validate-commits/).
#
#   1. If the license file already exists (non-empty), report OK.
#   2. Otherwise, verify the vault CLI is present and the caller is logged
#      in (valid token) and can reach Vault.
#   3. If so, fetch the license from kv-v2 (namespace admin, mount tmai,
#      secret radar) and write it straight to the license file.
#
# SECURITY: this script must NEVER print the license (or any secret value)
# to stdout/stderr -- it is invoked from an AI assistant session and its
# output lands in AI context. It prints status lines only; the secret goes
# directly from `vault kv get` into the file via redirection.
#
# Exit codes:
#   0  license file present (already, or fetched just now)
#   2  not logged in to Vault / cannot reach Vault -- run `vault login`
#   3  fetch failed (permissions, unknown field, empty secret, ...)

set -euo pipefail
IFS=$'\n\t'

LICENSE_FILE=".devcontainer/.vault-radar-license"

export VAULT_ADDR="${VAULT_ADDR:-https://vault-cluster-public-vault-289b32ee.99820ad2.z1.hashicorp.cloud:8200}"
export VAULT_NAMESPACE="${VAULT_NAMESPACE:-admin}"

KV_MOUNT="tmai"
SECRET_NAME="radar"
PREFERRED_FIELD="VAULT_RADAR_LICENSE"

# --- 1. Already present? -------------------------------------------------

if [ -s "${LICENSE_FILE}" ]; then
  echo "OK: license file already present at ${LICENSE_FILE} (not showing contents)."
  exit 0
fi

echo "License file ${LICENSE_FILE} is missing or empty -- checking Vault access..."

# --- 2. Logged in and able to reach Vault? -------------------------------

if ! command -v vault >/dev/null 2>&1; then
  echo "ERROR: 'vault' CLI not found on PATH." >&2
  exit 2
fi

# `vault token lookup` fails on: no token, expired/revoked token, or an
# unreachable cluster -- all of which mean we cannot fetch.
if ! vault token lookup >/dev/null 2>&1; then
  echo "NOT LOGGED IN: no valid Vault token for ${VAULT_ADDR} (namespace ${VAULT_NAMESPACE})." >&2
  echo "Run 'vault login' in your terminal, then re-run /validate-commits." >&2
  exit 2
fi

echo "OK: logged in to Vault at ${VAULT_ADDR} (namespace ${VAULT_NAMESPACE})."

# --- 3. Fetch the license into the file (never onto stdout) --------------

# Discover field names only (keys, never values) to pick the right -field.
mapfile -t fields < <(
  vault kv get -format=json -mount="${KV_MOUNT}" "${SECRET_NAME}" 2>/dev/null \
    | jq -r '.data.data | keys[]'
) || true

if [ "${#fields[@]}" -eq 0 ]; then
  echo "ERROR: could not read '${KV_MOUNT}/${SECRET_NAME}' -- token may lack the '${KV_MOUNT}' policy, or the secret is empty." >&2
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

echo "Fetching field '${field}' from ${KV_MOUNT}/${SECRET_NAME} into ${LICENSE_FILE}..."

umask 077
if ! vault kv get -mount="${KV_MOUNT}" -field="${field}" "${SECRET_NAME}" > "${LICENSE_FILE}" 2>/dev/null; then
  rm -f "${LICENSE_FILE}"
  echo "ERROR: fetch failed writing ${LICENSE_FILE} -- check token policy for '${KV_MOUNT}/data/*'." >&2
  exit 3
fi

if [ ! -s "${LICENSE_FILE}" ]; then
  rm -f "${LICENSE_FILE}"
  echo "ERROR: fetched value was empty; removed ${LICENSE_FILE}." >&2
  exit 3
fi

chmod 600 "${LICENSE_FILE}"
echo "OK: license written to ${LICENSE_FILE} (mode 600, gitignored, contents not shown)."
echo "You can now commit -- the Vault Radar pre-commit scan will run."
exit 0
