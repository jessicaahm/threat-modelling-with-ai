#!/usr/bin/env bash
#
# seed-eval-vault.sh
#
# One-time setup for the apply-fix eval (eval/eval-apply-fix.sh).
#
# The apply-fix candidate model is scored only on the CODE EDIT (remove a
# hardcoded secret, source it from a Vault helper). The candidate never runs
# `vault` and never touches the tmai mount -- that is forbidden by its contract.
# So the "upload the secret to Vault" half of the remediation is an operator
# setup step, and it lives here, not in anything the model does.
#
# What this handles:
#   - OFFLINE (default): the eval drives the app deterministically without Vault
#     via the fetch helper's EVAL_TOKEN_MOCK env hook -- nothing to write here,
#     so the default run just prints guidance.
#   - --seed-vault: the one-time, guarded upload of a FAKE credential to a
#     DEDICATED eval-only path (tmai/eval-apply-fix). Never the real radar /
#     openai secrets, never the guarded license/key files. This is what turns
#     the eval's criterion-1 check into a real Vault read.
#
# Every credential here is FAKE, structurally shaped but granting access to
# nothing -- same philosophy as eval/eval-radar.sh's fixtures.
#
# SECURITY: never prints, echoes, or logs a secret value. The --seed-vault put
# feeds the value on stdin (not argv) so it never lands in the process table.
#
# Usage:
#   ./eval/seed-eval-vault.sh              # write the offline mock helper only
#   ./eval/seed-eval-vault.sh --seed-vault # also do the one-time real Vault put
#
# Exit: 0 ok / 2 not logged in to Vault / 3 Vault put failed

set -euo pipefail
IFS=$'\n\t'

export VAULT_ADDR="${VAULT_ADDR:-https://vault-cluster-public-vault-289b32ee.99820ad2.z1.hashicorp.cloud:8200}"
export VAULT_NAMESPACE="${VAULT_NAMESPACE:-admin}"
EVAL_MOUNT="tmai"
EVAL_SECRET="eval-apply-fix"   # dedicated eval-only path -- NOT radar / openai
EVAL_FIELD="API_TOKEN"

# --- 1. Offline path (default) -------------------------------------------
# Nothing to write: the fetch helper (script/fetch-deploy-token.sh in the
# fixtures) honours EVAL_TOKEN_MOCK, and the harness sets it, so end-to-end
# runs are deterministic and need no Vault.
echo "OK: offline runs use the helper's EVAL_TOKEN_MOCK hook -- no file needed."

# --- 2. One-time real Vault seed (opt-in, guarded) -----------------------
if [ "${1:-}" != "--seed-vault" ]; then
  echo "Skipping Vault seed (pass --seed-vault to perform the one-time upload)."
  exit 0
fi

if ! command -v vault >/dev/null 2>&1; then
  echo "ERROR: 'vault' CLI not found on PATH -- cannot seed ${EVAL_MOUNT}/${EVAL_SECRET}." >&2
  exit 2
fi
if ! vault token lookup >/dev/null 2>&1; then
  echo "NOT LOGGED IN: no valid Vault token for ${VAULT_ADDR} (namespace ${VAULT_NAMESPACE})." >&2
  echo "Run 'vault login' in your terminal, then re-run with --seed-vault." >&2
  exit 2
fi

echo "Seeding a FAKE credential into ${EVAL_MOUNT}/${EVAL_SECRET} (value via stdin, never shown)..."
# FAKE value, HashiCorpIgnore-shaped, granting access to nothing. Fed on stdin
# so it never appears in argv / the process table.
if ! printf '%s' 'ghp_FAKE0000example1111HashiCorpIgnore2222deadbeef33' \
     | vault kv put -mount="${EVAL_MOUNT}" "${EVAL_SECRET}" "${EVAL_FIELD}=-" >/dev/null 2>&1; then
  echo "ERROR: Vault put failed -- check the token policy for '${EVAL_MOUNT}/data/${EVAL_SECRET}'." >&2
  exit 3
fi
echo "OK: seeded ${EVAL_MOUNT}/${EVAL_SECRET} (field ${EVAL_FIELD}; value not shown)."
exit 0
