#!/usr/bin/env bash
#
# radar-precommit.sh
#
# Pre-commit secret scan, invoked from .pre-commit-config.yaml.
#
# Enforcement is native: `vault-radar scan git pre-commit` reads
# ./.hashicorp/vault-radar/config.json (fail_severity) and exits 1 itself
# when a finding meets that threshold ("found risks with severity higher or
# equal than ..."). This wrapper does not parse or re-implement that
# decision -- it only adds fail-closed preconditions around it and relays
# vault-radar's own message.
#
# Persisted in the repo, unlike an env var: the config file travels with
# every checkout, session, and CI run. But that persistence cuts both ways
# -- if the file is ever missing, vault-radar does NOT fail closed on its
# own. It still reports findings on stdout but exits 0 (warn-only). Verified
# empirically: deleting the config file turns a blocking "error: ... found
# risks" into a non-blocking "warning: ...", exit 0. So this wrapper treats
# a missing/unparseable config the same as a missing license: refuse the
# commit rather than silently downgrading to warn-only.
#
# Fails CLOSED: if the license is missing, the config is missing, the
# binary is absent, or the scan errors, the hook fails rather than silently
# skipping. Run /fix-commits (or script/validate-commits.sh) for the
# license; the config file is checked into the repo at
# .hashicorp/vault-radar/config.json and should not normally be absent.
#
# SECURITY: never prints the license. Radar's findings name the detector and
# the file:line:col only -- not the secret value -- so its output is safe to
# surface to the developer.
#
# Exit codes:
#   0  no findings at or above the configured fail_severity
#   1  findings found, or a precondition/scan failure

set -uo pipefail

# Overridable so the eval harness can point at fixture paths; production
# runs leave these unset and use the repo-checked-in locations.
LICENSE_FILE="${RADAR_LICENSE_FILE:-.devcontainer/.vault-radar-license}"
CONFIG_FILE="${RADAR_CONFIG_FILE:-.hashicorp/vault-radar/config.json}"

# --- Preconditions (all fail closed) -------------------------------------

if ! command -v vault-radar >/dev/null 2>&1; then
  echo "BLOCKED: 'vault-radar' not found on PATH -- cannot scan for secrets." >&2
  exit 1
fi

if [ ! -s "${LICENSE_FILE}" ]; then
  echo "BLOCKED: Vault Radar license missing or empty (${LICENSE_FILE})." >&2
  echo "Secrets cannot be scanned, so this commit is refused." >&2
  echo "Fix: run /fix-commits in Claude Code, or ./script/validate-commits.sh" >&2
  exit 1
fi

if [ ! -s "${CONFIG_FILE}" ]; then
  echo "BLOCKED: Vault Radar config missing or empty (${CONFIG_FILE})." >&2
  echo "Without it, vault-radar only warns and never blocks -- refusing" >&2
  echo "the commit rather than scanning without enforcement." >&2
  echo "Fix: restore ${CONFIG_FILE} with a \"fail_severity\" set, e.g.:" >&2
  echo '  { "fail_severity": "low" }' >&2
  exit 1
fi

# vault-radar validates most malformed configs itself and exits non-zero
# (bad type, unparseable JSON, misspelled severity word) -- this check
# would be redundant for those. It exists for the two cases verified where
# vault-radar does NOT error: fail_severity absent from an otherwise-valid
# config.json, and a wrong-case value like "CRITICAL" -- both silently
# revert to warn-only (exit 0) with no error text, identical to the
# config file not existing at all. Radar's accepted values are lowercase
# only; this mirrors that exactly so a case mismatch is caught here.
fail_severity="$(jq -r '.fail_severity // empty' "${CONFIG_FILE}" 2>/dev/null)"
case "${fail_severity}" in
  info|low|medium|high|critical) ;;
  *)
    echo "BLOCKED: ${CONFIG_FILE} has no valid \"fail_severity\" (got: '${fail_severity:-<empty>}')." >&2
    echo "Refusing the commit rather than scanning without enforcement." >&2
    exit 1
    ;;
esac

# --- Scan (vault-radar enforces fail_severity itself, own exit code) -----

output="$(VAULT_RADAR_LICENSE="$(cat "${LICENSE_FILE}")" \
  vault-radar scan git pre-commit 2>&1)"
scan_rc=$?

if [ "${scan_rc}" -ne 0 ]; then
  echo "BLOCKED: Vault Radar refused the commit (fail_severity: ${fail_severity})." >&2
  [ -n "${output}" ] && echo "${output}" >&2
  echo "" >&2
  echo "Remove the secret(s) and re-stage. Do not commit them -- rewriting" >&2
  echo "history after the fact does not un-leak a credential; rotate it." >&2
  echo "If this is a false positive, bypass deliberately with:" >&2
  echo "  git commit --no-verify" >&2
  exit 1
fi

[ -n "${output}" ] && echo "${output}"
exit 0
