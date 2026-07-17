#!/usr/bin/env bash
#
# Post one approved reflection comment to an existing PR after verifying that
# the repository, PR, and head SHA still match the reviewed context.
#
# Usage:
#   script/post-reflection-comment.sh OWNER/REPO PR_NUMBER FULL_HEAD_SHA < comment.md

set -euo pipefail
IFS=$'\n\t'

if [ "$#" -ne 3 ]; then
  echo "ERROR: usage: $0 OWNER/REPO PR_NUMBER FULL_HEAD_SHA < comment.md" >&2
  exit 2
fi

EXPECTED_REPO="$1"
PR_NUMBER="$2"
EXPECTED_HEAD="$3"

case "${EXPECTED_REPO}" in
  */*) ;;
  *) echo "ERROR: repository must be OWNER/REPO." >&2; exit 2 ;;
esac
case "${PR_NUMBER}" in
  ''|*[!0-9]*) echo "ERROR: PR number must be a positive integer." >&2; exit 2 ;;
esac
if [ "${PR_NUMBER}" -eq 0 ]; then
  echo "ERROR: PR number must be a positive integer." >&2
  exit 2
fi
case "${EXPECTED_HEAD}" in
  [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
  *) echo "ERROR: head SHA must contain exactly 40 hexadecimal characters." >&2; exit 2 ;;
esac
EXPECTED_HEAD="$(printf '%s' "${EXPECTED_HEAD}" | tr '[:upper:]' '[:lower:]')"

for cmd in git gh jq mktemp wc head dd; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "ERROR: '${cmd}' is required." >&2
    exit 1
  }
done

CURRENT_HEAD="$(git rev-parse HEAD)"
if [ "${CURRENT_HEAD}" != "${EXPECTED_HEAD}" ]; then
  echo "BLOCKED: local HEAD changed since review (${CURRENT_HEAD})." >&2
  exit 1
fi

gh auth status >/dev/null 2>&1 || {
  echo "BLOCKED: GitHub CLI is not authenticated." >&2
  exit 1
}
CURRENT_REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
if [ "${CURRENT_REPO}" != "${EXPECTED_REPO}" ]; then
  echo "BLOCKED: current repository is '${CURRENT_REPO}', expected '${EXPECTED_REPO}'." >&2
  exit 1
fi

PR_JSON="$(gh pr view "${PR_NUMBER}" --repo "${EXPECTED_REPO}" \
  --json headRefOid,headRefName,state,url)"
PR_HEAD="$(jq -r '.headRefOid' <<<"${PR_JSON}")"
PR_BRANCH="$(jq -r '.headRefName' <<<"${PR_JSON}")"
PR_STATE="$(jq -r '.state' <<<"${PR_JSON}")"
PR_URL="$(jq -r '.url' <<<"${PR_JSON}")"

if [ "${PR_STATE}" != "OPEN" ]; then
  echo "BLOCKED: PR ${PR_NUMBER} is not open." >&2
  exit 1
fi
if [ "${PR_HEAD}" != "${EXPECTED_HEAD}" ]; then
  echo "BLOCKED: PR head changed since review (${PR_HEAD})." >&2
  exit 1
fi

umask 077
BODY_FILE="$(mktemp)"
trap 'rm -f "${BODY_FILE}"' EXIT
dd bs=65537 count=1 of="${BODY_FILE}" status=none
BODY_SIZE="$(wc -c < "${BODY_FILE}")"
if [ "${BODY_SIZE}" -eq 0 ]; then
  echo "BLOCKED: reflection comment is empty." >&2
  exit 1
fi
if [ "${BODY_SIZE}" -gt 65536 ]; then
  echo "BLOCKED: reflection comment exceeds 64 KiB." >&2
  exit 1
fi

EXPECTED_HEADER="Reflection on ${EXPECTED_HEAD:0:7} (branch ${PR_BRANCH})"
if [ "$(head -n 1 "${BODY_FILE}")" != "${EXPECTED_HEADER}" ]; then
  echo "BLOCKED: comment header does not match the reviewed SHA and PR branch." >&2
  exit 1
fi

gh pr comment "${PR_NUMBER}" --repo "${EXPECTED_REPO}" --body-file "${BODY_FILE}" >/dev/null
echo "OK: posted approved reflection comment to ${PR_URL} for ${EXPECTED_HEAD:0:7}."
