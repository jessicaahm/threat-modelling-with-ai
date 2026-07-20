#!/usr/bin/env bash
#
# Deterministic checks for least-privilege agent declarations and the
# separately approved reflection-comment boundary.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

ok()  { printf 'PASS %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

expect_tools() {
  local file="$1" expected="$2" actual
  actual="$(sed -n 's/^tools:[[:space:]]*//p' "${REPO_ROOT}/${file}")"
  if [ "${actual}" = "${expected}" ]; then
    ok "${file} tools are exactly: ${expected}"
  else
    bad "${file} tools are '${actual}', expected '${expected}'"
  fi
}

expect_tools ".claude/agents/remediation.md" "Read, Grep, Glob"
expect_tools ".claude/agents/reflection.md" "Read, Grep, Glob"
expect_tools ".claude/agents/apply-fix.md" "Read, Grep, Glob, Edit"

for agent in remediation reflection; do
  tools="$(sed -n 's/^tools:[[:space:]]*//p' "${REPO_ROOT}/.claude/agents/${agent}.md")"
  if printf '%s\n' "${tools}" | grep -Eq '(^|, )(Bash|Edit|Write)(, |$)'; then
    bad "${agent} exposes a mutation-capable tool"
  else
    ok "${agent} exposes no Bash/Edit/Write tool"
  fi
done
unset tools agent

if jq -e '
  .permissions.ask
  | index("Bash(script/post-reflection-comment.sh *)") != null
    and index("Bash(./script/post-reflection-comment.sh *)") != null
' "${REPO_ROOT}/.claude/settings.json" >/dev/null; then
  ok "reflection posting helper always enters the permission prompt path"
else
  bad "reflection posting helper is not covered by explicit ask rules"
fi

if grep -q 'only Read/Grep/Glob' "${REPO_ROOT}/.claude/skills/fix-commits/SKILL.md" &&
   grep -q 'post-reflection-comment.sh' "${REPO_ROOT}/.claude/skills/fix-commits/SKILL.md"; then
  ok "orchestration documents structural read-only review and delegated posting"
else
  bad "orchestration does not match the least-privilege split"
fi

HELPER="${REPO_ROOT}/script/post-reflection-comment.sh"
if [ -x "${HELPER}" ] && bash -n "${HELPER}"; then
  ok "reflection posting helper is executable and syntactically valid"
else
  bad "reflection posting helper is missing, non-executable, or invalid"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view") printf '%s\n' "${GH_STUB_REPO}" ;;
  "pr view")
    printf '{"headRefOid":"%s","headRefName":"%s","state":"%s","url":"https://example.invalid/pr/7"}\n' \
      "${GH_STUB_HEAD}" "${GH_STUB_BRANCH}" "${GH_STUB_STATE}"
    ;;
  "pr comment")
    printf 'comment\n' >> "${GH_STUB_LOG}"
    ;;
  *) exit 9 ;;
esac
GH_STUB
chmod 0755 "${WORK}/bin/gh"

HEAD_SHA="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
export GH_STUB_REPO="owner/repo"
export GH_STUB_HEAD="${HEAD_SHA}"
export GH_STUB_BRANCH="feature-test"
export GH_STUB_STATE="OPEN"
export GH_STUB_LOG="${WORK}/gh.log"
TEST_PATH="${WORK}/bin:${PATH}"

GOOD_BODY="Reflection on ${HEAD_SHA:0:7} (branch feature-test)

[follow-up] Test finding — README.md:1 — deterministic fixture."

if printf '%s\n' "${GOOD_BODY}" |
   PATH="${TEST_PATH}" "${HELPER}" owner/repo 7 "${HEAD_SHA}" >/dev/null 2>&1 &&
   [ "$(wc -l < "${GH_STUB_LOG}")" -eq 1 ]; then
  ok "approved comment posts once when repository, PR, HEAD, and header match"
else
  bad "valid approved comment did not post exactly once"
fi

if printf '%s\n' "${GOOD_BODY}" |
   PATH="${TEST_PATH}" "${HELPER}" other/repo 7 "${HEAD_SHA}" >/dev/null 2>&1; then
  bad "repository mismatch was accepted"
else
  ok "repository mismatch fails closed"
fi

STALE_SHA="0000000000000000000000000000000000000000"
if printf '%s\n' "${GOOD_BODY}" |
   PATH="${TEST_PATH}" "${HELPER}" owner/repo 7 "${STALE_SHA}" >/dev/null 2>&1; then
  bad "stale local HEAD was accepted"
else
  ok "stale local HEAD fails closed"
fi

BAD_BODY="Reflection on deadbee (branch feature-test)

No findings."
if printf '%s\n' "${BAD_BODY}" |
   PATH="${TEST_PATH}" "${HELPER}" owner/repo 7 "${HEAD_SHA}" >/dev/null 2>&1; then
  bad "mismatched comment header was accepted"
else
  ok "mismatched comment header fails closed"
fi

export GH_STUB_HEAD="${STALE_SHA}"
if printf '%s\n' "${GOOD_BODY}" |
   PATH="${TEST_PATH}" "${HELPER}" owner/repo 7 "${HEAD_SHA}" >/dev/null 2>&1; then
  bad "changed PR head was accepted"
else
  ok "changed PR head fails closed"
fi

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
