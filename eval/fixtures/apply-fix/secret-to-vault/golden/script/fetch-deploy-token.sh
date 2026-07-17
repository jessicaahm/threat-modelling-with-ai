#!/usr/bin/env bash
#
# fetch-deploy-token.sh
#
# Pre-existing infrastructure, sourced by deploy.sh. Loads the deploy API token
# from Vault into the shell as $API_TOKEN. Mirrors the repo's real helpers
# (script/fetch-vault-radar-mcp-creds.sh): fetch from kv-v2 (namespace admin,
# mount tmai, secret eval-apply-fix) and export -- the value goes from
# `vault kv get` straight into an env var, never onto argv/stdout/logs.
#
# SECURITY: never prints the token; status lines only.
#
# Eval hook (mirrors eval-radar.sh's env-injected test config, e.g.
# RADAR_LICENSE_FILE): if EVAL_TOKEN_MOCK is set, use it and skip Vault so the
# eval can drive the app end-to-end offline and deterministically.

if [ -n "${EVAL_TOKEN_MOCK:-}" ]; then
  export API_TOKEN="${EVAL_TOKEN_MOCK}"
  return 0 2>/dev/null || exit 0
fi

export VAULT_ADDR="${VAULT_ADDR:-https://vault-cluster-public-vault-289b32ee.99820ad2.z1.hashicorp.cloud:8200}"
export VAULT_NAMESPACE="${VAULT_NAMESPACE:-admin}"
_DT_MOUNT="tmai"
_DT_SECRET="eval-apply-fix"
_DT_FIELD="API_TOKEN"

if ! command -v vault >/dev/null 2>&1; then
  echo "ERROR: 'vault' CLI not found on PATH." >&2
  return 2 2>/dev/null || exit 2
fi
if ! vault token lookup >/dev/null 2>&1; then
  echo "NOT LOGGED IN: no valid Vault token for ${VAULT_ADDR} (namespace ${VAULT_NAMESPACE})." >&2
  return 2 2>/dev/null || exit 2
fi

_dt_val="$(vault kv get -mount="${_DT_MOUNT}" -field="${_DT_FIELD}" "${_DT_SECRET}" 2>/dev/null)" || {
  echo "ERROR: could not read ${_DT_MOUNT}/${_DT_SECRET} -- token policy, or secret not seeded (run eval/seed-eval-vault.sh --seed-vault)." >&2
  unset _DT_MOUNT _DT_SECRET _DT_FIELD
  return 3 2>/dev/null || exit 3
}
if [ -z "${_dt_val}" ]; then
  echo "ERROR: fetched token was empty." >&2
  unset _dt_val _DT_MOUNT _DT_SECRET _DT_FIELD
  return 3 2>/dev/null || exit 3
fi
export API_TOKEN="${_dt_val}"
unset _dt_val _DT_MOUNT _DT_SECRET _DT_FIELD
echo "OK: API_TOKEN loaded from Vault (value not shown)."
