#!/bin/bash
#
# init-script.sh
#
# Bootstraps the Vault-side prerequisites so the agent (and this repo's
# other tooling) can pull secrets/license keys from Vault at runtime,
# instead of committing .env files or hardcoding LLM API keys.
also#
# Prerequisites (NOT performed by this script):
#   - `vault` CLI installed and on PATH
#   - VAULT_TOKEN exported in the environment with an admin/root token
#     (e.g. via a prior `vault login`)
#   - Assigning a user/identity to the "tmai" policy this script creates
#     (a separate, manual step)
#
# This script is idempotent: re-running it after the mount/policy already
# exist is a no-op, not an error.
#
# Usage: ./init-script.sh   (run it, don't source it -- `set -euo pipefail`
# below is unsafe to leave enabled in an interactive shell via `source`)

set -euo pipefail
IFS=$'\n\t'

# Set up init script
export VAULT_ADDR="${VAULT_ADDR:-https://vault-cluster-public-vault-289b32ee.99820ad2.z1.hashicorp.cloud:8200}"
export VAULT_NAMESPACE="${VAULT_NAMESPACE:-admin}"

KV_MOUNT="tmai"
POLICY_NAME="tmai"

echo "== Vault init =="
echo "VAULT_ADDR:      ${VAULT_ADDR}"
echo "VAULT_NAMESPACE: ${VAULT_NAMESPACE}"
echo

# --- Preflight ---------------------------------------------------------

if ! command -v vault >/dev/null 2>&1; then
  echo "ERROR: 'vault' CLI not found on PATH. Install it before running this script." >&2
  exit 1
fi

if [ -z "${VAULT_TOKEN:-}" ]; then
  echo "ERROR: VAULT_TOKEN is not set. Run 'vault login' (or export an admin/root token) first." >&2
  exit 1
fi

# --- KV v2 mount ---------------------------------------------------------

echo "-- Ensuring KV v2 secrets engine is mounted at '${KV_MOUNT}/' --"

# Enable-then-detect-already-exists pattern: this call is directly tested
# by the trailing `||`, so a non-zero exit does NOT trip `set -e` here --
# `set -e` only aborts on an *untested* command's failure, and
# `cmd || { ... }` counts as tested.
enable_output=$(vault secrets enable -path="${KV_MOUNT}" -version=2 kv 2>&1) || {
  if grep -qi "path is already in use" <<<"${enable_output}"; then
    enable_output="(already mounted, skipping enable)"
  else
    echo "ERROR: failed to enable KV v2 secrets engine at '${KV_MOUNT}/':" >&2
    echo "${enable_output}" >&2
    exit 1
  fi
}
echo "OK: ${enable_output}"
echo

# --- Policy: full CRUD on the tmai mount --------------------------------

echo "-- Writing policy '${POLICY_NAME}' (full CRUD on ${KV_MOUNT}/) --"

# `vault policy write` upserts, so this is inherently idempotent -- no
# existence check needed here.
vault policy write "${POLICY_NAME}" - <<EOF
# Full CRUD access to the ${KV_MOUNT} KV v2 secrets engine.
# Assign a user/identity to the "${POLICY_NAME}" policy (separate, manual
# step -- not done by this script) to grant it these rights.

# Current secret values: create/upsert new versions, read the latest
# version, and soft-delete the latest version (recoverable via
# tmai/undelete/<path>, which this policy intentionally does not grant --
# see README/plan notes on scoping delete/undelete/destroy out).
path "${KV_MOUNT}/data/*" {
  capabilities = ["create", "read", "update", "delete"]
}

# List secret names and read version metadata; also fully remove a
# secret (all versions + metadata in one shot) -- distinct from the
# soft-delete above, and the closest kv-v2 equivalent of a hard DELETE.
path "${KV_MOUNT}/metadata/*" {
  capabilities = ["read", "list", "delete"]
}
EOF

echo "OK: policy '${POLICY_NAME}' written."
echo

# --- Summary ---------------------------------------------------------

echo "== Done =="
echo "Mount:  ${KV_MOUNT}/ (kv-v2)"
echo "Policy: ${POLICY_NAME}"
echo
echo "Next steps (manual, not done by this script):"
echo "  - Assign a user/identity to the '${POLICY_NAME}' policy."
echo "  - e.g.: vault token create -policy=${POLICY_NAME}"
echo
echo "This script ran in a subshell, so VAULT_ADDR/VAULT_NAMESPACE were"
echo "not left set in your current shell. To reuse them interactively:"
echo "  export VAULT_ADDR=${VAULT_ADDR}"
echo "  export VAULT_NAMESPACE=${VAULT_NAMESPACE}"
