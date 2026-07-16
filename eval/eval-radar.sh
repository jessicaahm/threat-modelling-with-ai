#!/usr/bin/env bash
#
# eval-radar.sh
#
# Deterministic eval for the Vault Radar pre-commit secret scan.
#
# Answers three questions:
#   1. Can Radar actually scan? (binary present, license valid, detection live)
#   2. Are medium-and-above findings really uncommittable?
#   3. Does enforcement fail closed if its own config disappears?
#
# Every fixture below is a FAKE credential, structurally shaped to trip a
# detector but granting access to nothing. Fixture severities are PINNED: if
# Radar re-rates one, the eval fails loudly rather than silently weakening.
# That pinning is what makes this deterministic -- severity is an external
# judgement from Radar, so we assert it instead of assuming it.
#
# Enforcement is native, not text-parsed: vault-radar itself reads
# ./.hashicorp/vault-radar/config.json (fail_severity) and sets its own
# exit code. radar-precommit.sh only adds fail-closed preconditions around
# that. This eval drives the real config file mechanism, not an env var --
# an env var only exists for the session that set it, so it can't be the
# thing enforcing policy across every checkout and CI run.
#
# Tests run in a throwaway git repo under $TMPDIR; the real repo, its index,
# the real license file, and the real config file are never modified.
#
# SECURITY: never prints the license. Radar findings name detector and
# file:line:col only, not secret values.
#
# Usage:  ./script/eval/eval-radar.sh
# Exit:   0 all tests passed / 1 one or more failed

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LICENSE="${REPO_ROOT}/.devcontainer/.vault-radar-license"
HOOK="${REPO_ROOT}/script/radar-precommit.sh"
RADAR_CONFIG="${REPO_ROOT}/.hashicorp/vault-radar/config.json"
PRECOMMIT_CONFIG="${REPO_ROOT}/.pre-commit-config.yaml"

PASS=0
FAIL=0
SKIP=0

ok()    { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()   { printf '  \033[31mFAIL\033[0m %s\n'   "$1"; FAIL=$((FAIL + 1)); }
skip()  { printf '  \033[33mSKIP\033[0m %s\n'   "$1"; SKIP=$((SKIP + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# --- Fixtures ------------------------------------------------------------

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

fixture() { printf '%b\n' "$2" > "${WORK}/fixtures/$1"; }

mkdir -p "${WORK}/fixtures"

fixture pw.txt        'db_password = "S3cr3t-Pa55w0rd-abc123"' # HashiCorpIgnore
fixture ghp.txt       'token = "ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"' # HashiCorpIgnore
fixture aws_pair.txt  'aws_access_key_id = "AKIAZZ7QWERTYUIOP42"\naws_secret_access_key = "kL9x/Qw3ErTy7UiOp1AsDf4GhJk6LzXcVbNm8Q2W"' # HashiCorpIgnore
fixture key.pem       '-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAvfake0000TESTKEYnotrealDATAforRADARtestingONLY01\nabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ++\n-----END RSA PRIVATE KEY-----' # HashiCorpIgnore
fixture aws_id.txt    'aws_access_key_id = "AKIAIOSFODNN7EXAMPLE"' # HashiCorpIgnore
fixture clean.txt     'the quick brown fox jumps over the lazy dog'

# Pinned expectations, established by probing this Radar build.
declare -A EXPECTED_SEVERITY=(
  [pw.txt]=medium
  [ghp.txt]=medium
  [aws_pair.txt]=medium
  [key.pem]=low
  [aws_id.txt]=info
  [clean.txt]=none
)

# The contract under test: these must never reach a commit under the
# repo's shipped config (fail_severity: low), which is a superset of
# "medium and above" -- it also catches private keys (severity low).
MEDIUM_AND_ABOVE=(pw.txt ghp.txt aws_pair.txt)

# --- Throwaway repo ------------------------------------------------------

SANDBOX="${WORK}/sandbox"
mkdir -p "${SANDBOX}/script" "${SANDBOX}/.hashicorp/vault-radar"
git init -q "${SANDBOX}"
git -C "${SANDBOX}" config user.name  "radar-eval"
git -C "${SANDBOX}" config user.email "radar-eval@example.invalid"
cp "${HOOK}" "${SANDBOX}/script/radar-precommit.sh"
chmod +x "${SANDBOX}/script/radar-precommit.sh"

write_config() {  # write_config <fail_severity-or-empty-to-delete>
  if [ -z "$1" ]; then
    rm -f "${SANDBOX}/.hashicorp/vault-radar/config.json"
  else
    printf '{\n  "fail_severity": "%s"\n}\n' "$1" > "${SANDBOX}/.hashicorp/vault-radar/config.json"
  fi
}

# Stage exactly one fixture, run the hook, echo "<exit>|<output>".
run_hook() {
  local fixture_name="$1" license_env="${2:-${LICENSE}}" config_env="${3:-${SANDBOX}/.hashicorp/vault-radar/config.json}"
  local out rc
  git -C "${SANDBOX}" rm -rq --cached . 2>/dev/null
  rm -f "${SANDBOX}"/probe-*
  cp "${WORK}/fixtures/${fixture_name}" "${SANDBOX}/probe-${fixture_name}"
  git -C "${SANDBOX}" add "probe-${fixture_name}" 2>/dev/null
  out="$(cd "${SANDBOX}" && env \
        RADAR_LICENSE_FILE="${license_env}" \
        RADAR_CONFIG_FILE="${config_env}" \
        ./script/radar-precommit.sh 2>&1)"
  rc=$?
  printf '%s|%s' "${rc}" "${out}"
}

severity_of() {  # extract the reported severity, or "none"
  local out="$1" sev
  sev="$(printf '%s' "${out}" | grep -oE 'severity [A-Za-z]+' | head -1 | awk '{print $2}')"
  printf '%s' "${sev:-none}"
}

# =========================================================================
head_ "1. Can Radar scan?"

if command -v vault-radar >/dev/null 2>&1; then
  ok "vault-radar is on PATH"
else
  bad "vault-radar not found on PATH -- nothing below can be trusted"
  printf '\nAborting: no scanner.\n'; exit 1
fi

if [ -s "${LICENSE}" ]; then
  ok "license file present and non-empty"
else
  bad "license file missing/empty -- run /fix-commits or ./script/validate-commits.sh"
  printf '\nAborting: no license.\n'; exit 1
fi

if [ -s "${RADAR_CONFIG}" ]; then
  ok "repo config file present (${RADAR_CONFIG#${REPO_ROOT}/})"
else
  bad "repo config file missing/empty -- .hashicorp/vault-radar/config.json must set fail_severity"
  printf '\nAborting: no config.\n'; exit 1
fi

# Positive control: with an info-only threshold (nothing blocks), the scan
# must still REPORT the planted secret. Proves detection is live, not just
# that the exit code happened to be 0 -- a silently-broken license could
# otherwise look identical to a clean repo.
write_config info
result="$(run_hook pw.txt)"
control_out="${result#*|}"
if printf '%s' "${control_out}" | grep -q 'detected\|severity'; then
  ok "positive control: Radar detects a known planted secret"
else
  bad "positive control: Radar reported NO finding on a known secret -- scanning is not working"
  printf '\nAborting: detection is not live.\n'; exit 1
fi

result="$(run_hook clean.txt)"
if [ "${result%%|*}" -eq 0 ]; then
  ok "negative control: clean file produces no block (no false positive)"
else
  bad "negative control: clean file was blocked -- expected exit 0, got ${result%%|*}"
fi

# =========================================================================
head_ "2. Fixture severities are as pinned (drift guard)"
# Use an info-level threshold so everything is reported, nothing blocks --
# this section only observes what severity Radar assigns, independent of
# the blocking contract tested in section 3.

for f in "${!EXPECTED_SEVERITY[@]}"; do
  want="${EXPECTED_SEVERITY[$f]}"
  result="$(run_hook "${f}")"   # config is already fail_severity=info from above
  got="$(severity_of "${result#*|}")"
  if [ "${got}" = "${want}" ]; then
    ok "${f}: severity ${got} (as pinned)"
  else
    bad "${f}: severity drifted -- pinned '${want}', Radar now says '${got}'"
  fi
done

# =========================================================================
head_ "3. Contract: medium-and-above cannot be committed"

write_config medium
for f in "${MEDIUM_AND_ABOVE[@]}"; do
  result="$(run_hook "${f}")"
  rc="${result%%|*}"
  if [ "${rc}" -eq 1 ]; then
    ok "${f} (${EXPECTED_SEVERITY[$f]}) blocked at fail_severity=medium"
  else
    bad "${f} (${EXPECTED_SEVERITY[$f]}) NOT blocked at fail_severity=medium -- exit ${rc}"
  fi
done

# Same must hold under the config actually shipped in the repo.
cp "${RADAR_CONFIG}" "${SANDBOX}/.hashicorp/vault-radar/config.json"
shipped_severity="$(jq -r '.fail_severity' "${RADAR_CONFIG}" 2>/dev/null)"
for f in "${MEDIUM_AND_ABOVE[@]}"; do
  result="$(run_hook "${f}")"
  rc="${result%%|*}"
  if [ "${rc}" -eq 1 ]; then
    ok "${f} blocked under the repo's shipped config (fail_severity: ${shipped_severity})"
  else
    bad "${f} NOT blocked under the repo's shipped config -- exit ${rc}"
  fi
done

# =========================================================================
head_ "4. Fail-closed behaviour"

result="$(run_hook pw.txt "${WORK}/definitely-absent-license")"
rc="${result%%|*}"
if [ "${rc}" -eq 1 ] && printf '%s' "${result#*|}" | grep -q 'BLOCKED'; then
  ok "absent license blocks the commit (fails closed, does not skip)"
else
  bad "absent license did NOT block -- exit ${rc}; this is the fail-open bug"
fi

# The config file is the one enforcing severity; if it silently goes
# missing, vault-radar itself reverts to warn-only (verified empirically:
# no config.json => exit 0 even on a medium finding). The wrapper must
# catch that itself rather than trust vault-radar's own exit code.
result="$(run_hook pw.txt "${LICENSE}" "${WORK}/definitely-absent-config.json")"
rc="${result%%|*}"
if [ "${rc}" -eq 1 ] && printf '%s' "${result#*|}" | grep -q 'BLOCKED'; then
  ok "absent config.json blocks the commit (fails closed, does not silently warn-only)"
else
  bad "absent config.json did NOT block -- exit ${rc}; severity enforcement would silently disappear"
fi

# =========================================================================
head_ "5. Wiring: is the hook actually reachable from a real commit?"

if grep -qE '^\s*entry:\s*script/radar-precommit\.sh\s*$' "${PRECOMMIT_CONFIG}"; then
  ok "pre-commit entry points at script/radar-precommit.sh"

  # End-to-end: a real `git commit` in the sandbox must be refused.
  write_config low
  cp "${PRECOMMIT_CONFIG}" "${SANDBOX}/.pre-commit-config.yaml"
  if (cd "${SANDBOX}" && pre-commit install >/dev/null 2>&1); then
    rm -f "${SANDBOX}"/probe-*
    cp "${WORK}/fixtures/pw.txt" "${SANDBOX}/leak.txt"
    (cd "${SANDBOX}" && git add leak.txt && \
       RADAR_LICENSE_FILE="${LICENSE}" git commit -qm "should be refused") \
       >/dev/null 2>&1
    if git -C "${SANDBOX}" rev-parse HEAD >/dev/null 2>&1; then
      bad "END-TO-END: git commit SUCCEEDED with a medium secret staged"
    else
      ok "END-TO-END: git commit refused with a medium secret staged"
    fi
  else
    skip "pre-commit install unavailable; end-to-end commit test not run"
  fi
else
  bad "pre-commit entry does NOT call script/radar-precommit.sh -- the hook is not wired, so commits are unprotected regardless of the tests above"
fi

# =========================================================================
printf '\n\033[1mSummary:\033[0m %d passed, %d failed, %d skipped\n' \
  "${PASS}" "${FAIL}" "${SKIP}"
[ "${FAIL}" -eq 0 ] || exit 1
exit 0
