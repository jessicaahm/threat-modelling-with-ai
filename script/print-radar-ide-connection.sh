#!/usr/bin/env bash
#
# print-radar-ide-connection.sh
#
# Run this yourself in a terminal (do not paste its output back to an AI
# assistant) to get the values needed for the Vault Radar VS Code extension's
# one-time "Add Vault Connection" dialog. The extension has no settings.json
# key or CLI flag for pre-configuring a Vault connection -- address,
# namespace, and auth must be entered once through its Activity Bar UI.
#
# Requires script/devcontainer-poststart.sh to have already run successfully
# (it persists VAULT_ADDR/VAULT_NAMESPACE to ~/.hcp-radar-env, sourced by your
# shell rc). The Vault token itself is never read or printed by this script --
# `vault login` already writes it to ~/.vault-token (mode 600); reveal it
# yourself with `cat ~/.vault-token` only when pasting it into the extension.
#
# SECURITY: never prints a secret value.

set -uo pipefail

if [ -z "${VAULT_ADDR:-}" ] || [ -z "${VAULT_NAMESPACE:-}" ]; then
  echo "ERROR: VAULT_ADDR/VAULT_NAMESPACE not set in this shell." >&2
  echo "       Open a new terminal (so ~/.zshrc / ~/.bashrc source ~/.hcp-radar-env)," >&2
  echo "       or check that VAULT_USERNAME/VAULT_PASSWORD were set when the devcontainer started" >&2
  echo "       so script/devcontainer-poststart.sh could log in and write those values." >&2
  exit 1
fi

if [ ! -s "${HOME}/.vault-token" ]; then
  echo "ERROR: ${HOME}/.vault-token not found -- you don't appear to be logged in to Vault." >&2
  echo "       Run 'vault login' (or restart the devcontainer with VAULT_USERNAME/VAULT_PASSWORD set)." >&2
  exit 1
fi

cat <<EOF
Vault Radar VS Code extension -- "Add Vault Connection" values:

  Address:   ${VAULT_ADDR}
  Namespace: ${VAULT_NAMESPACE}
  Auth:      Token
  Token:     run 'cat ~/.vault-token' yourself and paste the value shown --
             this script does not print it.

Steps: open the Vault Radar icon in the VS Code Activity Bar -> "Add Vault
Connection" -> paste the values above.
EOF
