#!/usr/bin/env bash
#
# smoke-ant.sh
#
# Diagnostic: confirm the `ant messages create --format json` request/response
# SHAPE still matches what the live eval tools assume. eval/capture-apply-fix.sh
# and eval/judge/run-judge.sh both feed a Messages body (model / max_tokens /
# system / output_config json_schema / messages) on stdin and parse the reply's
# .content[].text, .usage.*_tokens, and .error.message. If the `ant` CLI ever
# changes how it accepts that body or shapes its JSON output, those tools fail with
# a generic "no content returned" / "no usable judge samples" and no hint that the
# SHAPE is the cause. This script isolates that: it sends one tiny, well-formed
# request and reports, distinctly, whether a failure is an auth/API problem or a
# shape mismatch.
#
# Run it once after a devcontainer rebuild or an `ant` CLI upgrade -- it is NOT
# part of the offline deterministic eval. It makes one real API call (a few tokens)
# and needs `ant auth login` (or ANTHROPIC_API_KEY), same as the live tools.
#
# Usage:  ./eval/smoke-ant.sh [alias]        # alias default: haiku (cheapest)
# Exit:   0 shape OK
#         1 precondition (missing jq/ant/pricing, or unknown alias)
#         2 ant call or API error (auth / network / API -- NOT a shape mismatch)
#         3 shape mismatch (invalid JSON, or missing .content[].text / .usage tokens)
#
# SECURITY: the request carries no repo/Vault secret (a literal dummy prompt), so
# the raw response is safe to print for diagnostics -- this script has no secret to
# leak, and never reads Vault or the guarded license/key files.

set -euo pipefail
IFS=$'\n\t'

alias="${1:-haiku}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRICING="${REPO_ROOT}/eval/model-pricing.json"

command -v jq  >/dev/null 2>&1 || { echo "ERROR: jq required."  >&2; exit 1; }
command -v ant >/dev/null 2>&1 || { echo "ERROR: ant CLI required (Anthropic CLI; run 'ant auth login' or set ANTHROPIC_API_KEY)." >&2; exit 1; }
[ -s "$PRICING" ] || { echo "ERROR: pricing file missing: $PRICING" >&2; exit 1; }

model_id="$(jq -r --arg a "$alias" '._alias_map[$a] // empty' "$PRICING")"
[ -n "$model_id" ] || { echo "ERROR: unknown alias '${alias}' (not in ${PRICING##*/}._alias_map)" >&2; exit 1; }

# Build the SAME request shape the live tools build (see capture-apply-fix.sh /
# run-judge.sh): a Messages body with system + output_config json_schema. The
# sampling param is sent only where the model accepts it, mirroring both scripts.
extra=""
case "$model_id" in
  claude-sonnet-4-6|claude-sonnet-4-5|claude-haiku-4-5) extra='"temperature":0,' ;;
esac
effort=false
case "$model_id" in
  claude-opus-4-5|claude-opus-4-6|claude-opus-4-7|claude-opus-4-8|claude-sonnet-4-6|claude-sonnet-5) effort=true ;;
esac

SCHEMA='{"type":"object","additionalProperties":false,"properties":{"ok":{"type":"boolean"}},"required":["ok"]}'
sys="You are a shape smoke test. Output ONLY the JSON object the schema describes."
user='Return {"ok": true}.'

body="$(jq -n --arg m "$model_id" --arg sys "$sys" --arg user "$user" --argjson schema "$SCHEMA" --argjson effort "$effort" \
  "{model:\$m, max_tokens:64, ${extra} system:\$sys,
    output_config:({format:{type:\"json_schema\", schema:\$schema}} +
      (if \$effort then {effort:\"low\"} else {} end)),
    messages:[{role:\"user\", content:\$user}]}")"

echo "smoke: ${alias} (${model_id}) -> ant messages create --format json"

# 1) The CLI call itself. Capture stdout regardless, but branch on the exit status
#    so a nonzero `ant` exit gets its own clear message rather than a bare set -e
#    abort with no context.
if ! resp="$(printf '%s' "$body" | ant messages create --format json)"; then
  echo "FAIL[2]: 'ant messages create' returned nonzero -- auth / network / CLI, NOT a shape mismatch." >&2
  echo "        Check 'ant auth status' / 'ant auth login', or ANTHROPIC_API_KEY." >&2
  exit 2
fi

# 2) --format json must actually emit JSON. If not, the CLI's own output contract
#    has broken -- distinct from the request/response field shape below.
if ! jq -e . >/dev/null 2>&1 <<<"$resp"; then
  echo "FAIL[3]: response is not valid JSON despite --format json -- the CLI JSON contract is broken." >&2
  printf '        raw (this request has no secrets): %s\n' "$(head -c 500 <<<"$resp")" >&2
  exit 3
fi

# 3) A normal API-level error is not a shape mismatch -- surface it as such so the
#    reader does not go hunting for a schema drift that is not there.
err="$(jq -r '.error.message // empty' <<<"$resp")"
[ -z "$err" ] || { echo "FAIL[2]: API error (not a shape mismatch): ${err}" >&2; exit 2; }

# 4) The live tools read .content[].text of type "text". Its absence means the
#    reply shape has drifted from what capture-apply-fix.sh / run-judge.sh assume.
txt="$(jq -r '.content[]? | select(.type=="text") | .text' <<<"$resp")"
[ -n "$txt" ] || { echo "FAIL[3]: no .content[].text (type text) in the reply -- SHAPE MISMATCH; capture-apply-fix.sh and run-judge.sh both assume this." >&2; exit 3; }

# 5) .usage.input_tokens / .usage.output_tokens drive run-judge's cost math and
#    capture-apply-fix's fail-closed live-usage gate.
in_tok="$(jq -r '.usage.input_tokens  // empty' <<<"$resp")"
out_tok="$(jq -r '.usage.output_tokens // empty' <<<"$resp")"
{ [ -n "$in_tok" ] && [ -n "$out_tok" ]; } || { echo "FAIL[3]: missing .usage.input_tokens/.output_tokens -- SHAPE MISMATCH; cost math and the live-usage gate assume these." >&2; exit 3; }

# 6) Best-effort: did structured output_config actually constrain the text to the
#    schema? Non-fatal -- a warning, since nothing above depends on it here.
if jq -e '.ok == true' >/dev/null 2>&1 <<<"$txt"; then
  :
else
  echo "WARN: reply text did not parse as the requested json_schema ({\"ok\":true}); output_config may not be honored the way the live tools expect." >&2
fi

echo "OK: ant messages create --format json matches the expected shape (content + usage present; in=${in_tok} out=${out_tok} tokens)."
exit 0
