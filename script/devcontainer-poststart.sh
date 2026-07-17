#!/usr/bin/env bash
#
# devcontainer-poststart.sh
#
# Runs on every devcontainer start (postStartCommand). Non-interactively logs
# in to Vault via userpass and writes HCP_PROJECT_ID / HCP_CLIENT_ID /
# HCP_CLIENT_SECRET into ~/.hcp-radar-env, which ~/.zshrc and ~/.bashrc
# source on shell startup -- so any shell that later launches an MCP client
# (Claude Code, etc.) already has the vars .mcp.json's `-e VARNAME`
# pass-through needs.
#
# Requires VAULT_USERNAME / VAULT_PASSWORD from the host environment (see
# devcontainer.json's remoteEnv). If they aren't set, this is a no-op --
# falls back to the manual `source script/fetch-vault-radar-mcp-creds.sh`
# flow, so a container without userpass creds still starts fine.
#
# SECURITY: never prints a secret value (password/HCP creds) to
# stdout/stderr -- this runs at container start and its output can land in
# logs. Status lines only.

set -uo pipefail

ENV_FILE="${HOME}/.hcp-radar-env"

if [ -z "${VAULT_USERNAME:-}" ] || [ -z "${VAULT_PASSWORD:-}" ]; then
  echo "INFO: VAULT_USERNAME/VAULT_PASSWORD not set -- skipping automatic HCP credential fetch."
  echo "      Run 'source script/fetch-vault-radar-mcp-creds.sh' manually instead."
  exit 0
fi

export VAULT_ADDR="${VAULT_ADDR:-https://vault-cluster-public-vault-289b32ee.99820ad2.z1.hashicorp.cloud:8200}"
export VAULT_NAMESPACE="${VAULT_NAMESPACE:-admin}"
KV_MOUNT="tmai"
SECRET_NAME="radar"

if ! command -v vault >/dev/null 2>&1; then
  echo "ERROR: 'vault' CLI not found on PATH -- cannot fetch HCP credentials." >&2
  exit 0
fi

if ! vault login -method=userpass username="${VAULT_USERNAME}" password="${VAULT_PASSWORD}" >/dev/null 2>&1; then
  echo "ERROR: userpass login failed -- check VAULT_USERNAME/VAULT_PASSWORD and Vault reachability." >&2
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
  gh_token=$(vault kv get -mount="${KV_MOUNT}" -field=GH_TOKEN "${SECRET_NAME}" 2>/dev/null) || gh_token=""
  if [ -n "${gh_token}" ]; then
    if printf '%s' "${gh_token}" | gh auth login --with-token >/dev/null 2>&1; then
      gh auth setup-git >/dev/null 2>&1 || true
      echo "OK: gh authenticated via Vault token (value not shown)."
    else
      echo "ERROR: gh auth login failed -- check the GH_TOKEN field in ${KV_MOUNT}/${SECRET_NAME}." >&2
    fi
  else
    echo "INFO: no GH_TOKEN in ${KV_MOUNT}/${SECRET_NAME} -- skipping gh auth."
  fi
  unset gh_token
else
  echo "INFO: 'gh' CLI not found on PATH -- skipping gh auth."
fi
# ---------------------------------------------------------------------------

umask 077
tmp_file="$(mktemp)"
status=0
for field in HCP_PROJECT_ID HCP_CLIENT_ID HCP_CLIENT_SECRET; do
  value=$(vault kv get -mount="${KV_MOUNT}" -field="${field}" "${SECRET_NAME}" 2>/dev/null) || {
    echo "ERROR: could not read field '${field}' from '${KV_MOUNT}/${SECRET_NAME}'." >&2
    status=1
    continue
  }
  if [ -z "${value}" ]; then
    echo "ERROR: field '${field}' in '${KV_MOUNT}/${SECRET_NAME}' is empty." >&2
    status=1
    continue
  fi
  printf 'export %s=%q\n' "${field}" "${value}" >> "${tmp_file}"
done
unset value field

if [ "${status}" -ne 0 ]; then
  echo "ERROR: one or more HCP credentials could not be fetched; not writing ${ENV_FILE}." >&2
  rm -f "${tmp_file}"
  exit 0
fi

mv "${tmp_file}" "${ENV_FILE}"
chmod 600 "${ENV_FILE}"
echo "OK: wrote HCP_PROJECT_ID, HCP_CLIENT_ID, HCP_CLIENT_SECRET to ${ENV_FILE} (mode 600, values not shown)."
echo "New shells will pick them up automatically via ~/.zshrc / ~/.bashrc."
exit 0
