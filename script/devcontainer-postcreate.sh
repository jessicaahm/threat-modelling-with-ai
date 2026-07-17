#!/usr/bin/env bash
#
# devcontainer-postcreate.sh
#
# Runs once when the devcontainer is created (postCreateCommand).
#   1. Installs the pre-commit hooks.
#   2. Adds an idempotent line to ~/.zshrc and ~/.bashrc that sources
#      ~/.hcp-radar-env (written by script/devcontainer-poststart.sh) if
#      present, so every new shell inherits HCP_PROJECT_ID/HCP_CLIENT_ID/
#      HCP_CLIENT_SECRET for the Vault Radar MCP server.

set -euo pipefail

pre-commit install

SOURCE_LINE='[ -f "$HOME/.hcp-radar-env" ] && source "$HOME/.hcp-radar-env"'

for rc in "${HOME}/.zshrc" "${HOME}/.bashrc"; do
  [ -f "${rc}" ] || touch "${rc}"
  if ! grep -qF '.hcp-radar-env' "${rc}"; then
    printf '\n# Vault Radar MCP server credentials (see script/devcontainer-poststart.sh)\n%s\n' "${SOURCE_LINE}" >> "${rc}"
    echo "OK: added .hcp-radar-env sourcing to ${rc}."
  fi
done
