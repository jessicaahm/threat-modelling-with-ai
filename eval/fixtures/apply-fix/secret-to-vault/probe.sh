#!/usr/bin/env bash
# Deterministic "is the vuln gone?" probe for the secret-to-vault archetype.
# Runs inside the sandbox working tree. Exit 0 iff the fix is realized:
#   - no hardcoded secret literal remains in the app, AND
#   - the app now sources the Vault helper (so the value comes from Vault).
# (Runtime confirmation that it actually fetches and still works is done by the
# harness's end-to-end section, not here.)
set -u
f="script/deploy.sh"
[ -f "$f" ] || exit 1
! grep -Eq 'ghp_|AKIA|-----BEGIN' "$f" && grep -q 'fetch-deploy-token\.sh' "$f"
