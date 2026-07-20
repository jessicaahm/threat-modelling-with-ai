#!/usr/bin/env bash
#
# devcontainer-postcreate.sh
#
# Runs once when the devcontainer is created (postCreateCommand).
#   1. Installs the pre-commit hooks.
#   2. Adds idempotent lines to ~/.zshrc and ~/.bashrc that source the
#      mode-600 runtime environment files written by devcontainer-poststart.sh.

set -euo pipefail

pre-commit install

RADAR_SOURCE_LINE='[ -f "$HOME/.hcp-radar-env" ] && source "$HOME/.hcp-radar-env"'
TERRAFORM_SOURCE_LINE='[ -f "$HOME/.hcp-terraform-env" ] && source "$HOME/.hcp-terraform-env"'

for rc in "${HOME}/.zshrc" "${HOME}/.bashrc"; do
  [ -f "${rc}" ] || touch "${rc}"
  if ! grep -qF '.hcp-radar-env' "${rc}"; then
    printf '\n# Vault Radar MCP server credentials (see script/devcontainer-poststart.sh)\n%s\n' "${RADAR_SOURCE_LINE}" >> "${rc}"
    echo "OK: added .hcp-radar-env sourcing to ${rc}."
  fi
  if ! grep -qF '.hcp-terraform-env' "${rc}"; then
    printf '\n# Terraform MCP and HCP Terraform credentials (see script/devcontainer-poststart.sh)\n%s\n' "${TERRAFORM_SOURCE_LINE}" >> "${rc}"
    echo "OK: added .hcp-terraform-env sourcing to ${rc}."
  fi
done
