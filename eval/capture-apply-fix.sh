#!/usr/bin/env bash
#
# capture-apply-fix.sh
#
# Produce a LIVE apply-fix transcript for one fixture and one or more candidate
# models, then freeze it under captured/<alias>.json for the deterministic eval
# (eval/eval-apply-fix.sh) to replay. This is the missing producer the eval's
# "captured once, then frozen" contract assumes: eval-apply-fix.sh REPLAYS these
# transcripts, run-judge.sh REFRESHES only the judge field, and THIS script is
# the only thing that calls the candidate model to generate the edit itself.
#
# Each capture records what the model actually wrote (edited_files), the REAL
# token usage returned by the API, and a provenance marker proving it came from
# a live call. The harness's fail-closed provenance gate rejects any candidate
# capture lacking `provenance.live == true`, so hand-authored placeholders can no
# longer masquerade as evidence.
#
# Usage:
#   ./eval/capture-apply-fix.sh <fixture_dir> [alias ...]
#     <fixture_dir>  e.g. eval/fixtures/apply-fix/secret-to-vault
#     [alias ...]    one or more ladder aliases (default: haiku sonnet opus)
#
# Env:
#   ANTHROPIC_API_KEY   optional. If unset, the `ant` CLI uses your `ant auth
#                       login` OAuth profile instead -- no static key needed.
#
# Auth goes through the official Anthropic CLI (`ant messages create`), which
# resolves credentials the same way the SDKs do (ANTHROPIC_API_KEY, else the
# active OAuth profile) and refreshes tokens for us -- so this script builds no
# auth headers of its own. Request shape intentionally mirrors
# eval/judge/run-judge.sh so the two live tools stay consistent. NOTE ON
# DETERMINISM: temperature 0 is only sent to models that still accept sampling
# params; Opus 4.8 / Sonnet 5 reject it with a 400, so it is omitted there (same
# handling as run-judge.sh).
#
# SECURITY: fixtures use FAKE, HashiCorpIgnore-marked credentials. This script
# never prints a secret value and never puts one in argv; it only moves file
# contents between the fixture, the request body (stdin to jq/ant), and the
# captured JSON.

set -euo pipefail
IFS=$'\n\t'

FX="${1:?usage: capture-apply-fix.sh <fixture_dir> [alias ...]}"
shift || true
ALIASES=("$@")
[ "${#ALIASES[@]}" -gt 0 ] || ALIASES=(haiku sonnet opus)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRICING="${REPO_ROOT}/eval/model-pricing.json"
AGENT="${REPO_ROOT}/.claude/agents/apply-fix.md"

command -v jq  >/dev/null 2>&1 || { echo "ERROR: jq required."  >&2; exit 1; }
command -v ant >/dev/null 2>&1 || { echo "ERROR: ant CLI required (Anthropic CLI; run 'ant auth login' or set ANTHROPIC_API_KEY)." >&2; exit 1; }
[ -d "$FX" ]        || { echo "ERROR: fixture dir not found: $FX" >&2; exit 1; }
[ -s "$PRICING" ]   || { echo "ERROR: pricing file missing: $PRICING" >&2; exit 1; }
[ -s "${FX}/plan.md" ]   || { echo "ERROR: fixture missing plan.md: $FX" >&2; exit 1; }
[ -s "${FX}/meta.json" ] || { echo "ERROR: fixture missing meta.json: $FX" >&2; exit 1; }

# --- Fixture inputs -------------------------------------------------------
target="$(jq -r '.target_file' "${FX}/meta.json")"
mapfile -t shell_files < <(jq -r '.shell_files[]? // empty' "${FX}/meta.json")
# The set of files the model is allowed to see/edit: shell_files if listed,
# else just the target. Paths are relative to start/.
edit_scope=("${shell_files[@]}")
[ "${#edit_scope[@]}" -gt 0 ] || edit_scope=("$target")

# Build a JSON object { "<path>": [lines...] } of the current start/ contents so
# the model sees exactly what it must edit.
start_json='{}'
for rel in "${edit_scope[@]}"; do
  f="${FX}/start/${rel}"
  [ -f "$f" ] || { echo "ERROR: start file missing: ${rel}" >&2; exit 1; }
  start_json="$(jq --arg k "$rel" --rawfile body "$f" \
    '. + {($k): ($body | rtrimstr("\n") | split("\n"))}' <<<"$start_json")"
done

plan_text="$(cat "${FX}/plan.md")"
contract="$(cat "$AGENT")"

# --- Prompt + structured-output schema ------------------------------------
sys="You are the apply-fix WRITER for a secure-SDLC repo. Apply EXACTLY ONE
approved remediation plan with surgical edits and nothing else; do not redesign
the fix or expand scope. Preserve each shell file's existing set flags and
quoting, keep secrets out of argv/stdout, and fail closed. If the code no longer
matches the plan, make no edit and say so. Output ONLY the JSON object the schema
describes: for every file you change, return its COMPLETE new contents as an
array of lines (no trailing newline element); set made_edit=false with an empty
edited_files object if you correctly bail."

user="$(printf 'APPLY-FIX CONTRACT (for reference):\n%s\n\nAPPROVED PLAN:\n%s\n\nCURRENT FILES (path -> lines), rooted at the repo working dir:\n%s\n\nReturn the edited files (full new contents per changed file), made_edit, and a one-line report.\n' \
  "$contract" "$plan_text" "$start_json")"

SCHEMA='{"type":"object","additionalProperties":false,
  "properties":{
    "made_edit":{"type":"boolean"},
    "edited_files":{"type":"object","additionalProperties":{"type":"array","items":{"type":"string"}}},
    "report":{"type":"string"}},
  "required":["made_edit","edited_files","report"]}'

capture_one() {
  local alias="$1"
  local model_id
  model_id="$(jq -r --arg a "$alias" '._alias_map[$a] // empty' "$PRICING")"
  [ -n "$model_id" ] || { echo "  ERROR: unknown alias '${alias}' (not in ${PRICING##*/}._alias_map)" >&2; return 1; }

  # Sampling param only where the model accepts it (see run-judge.sh note).
  local extra=""
  case "$model_id" in
    claude-sonnet-4-6|claude-sonnet-4-5|claude-haiku-4-5) extra='"temperature":0,' ;;
  esac

  local body
  body="$(jq -n --arg m "$model_id" --arg sys "$sys" --arg user "$user" --argjson schema "$SCHEMA" \
    "{model:\$m, max_tokens:2048, ${extra} system:\$sys,
      output_config:{format:{type:\"json_schema\", schema:\$schema}, effort:\"low\"},
      messages:[{role:\"user\", content:\$user}]}")"

  # `ant messages create` reads the full request body from stdin and resolves
  # auth itself (ANTHROPIC_API_KEY, else the `ant auth login` OAuth profile).
  local resp
  resp="$(printf '%s' "$body" | ant messages create --format json)" \
    || { echo "  ERROR: request failed for ${alias} (check 'ant auth login' or ANTHROPIC_API_KEY)" >&2; return 3; }

  local err
  err="$(jq -r '.error.message // empty' <<<"$resp" 2>/dev/null)"
  [ -z "$err" ] || { echo "  ERROR: API error for ${alias}: ${err}" >&2; return 3; }

  local txt in_tok out_tok
  txt="$(jq -r '.content[]? | select(.type=="text") | .text' <<<"$resp" 2>/dev/null)"
  in_tok="$(jq -r '.usage.input_tokens  // empty' <<<"$resp")"
  out_tok="$(jq -r '.usage.output_tokens // empty' <<<"$resp")"
  [ -n "$txt" ] || { echo "  ERROR: no content returned for ${alias}" >&2; return 3; }
  # A live capture MUST carry real usage; refuse to write a zero/absent-usage one.
  case "${in_tok:-0}" in ''|0) echo "  ERROR: missing/zero input_tokens for ${alias}; refusing to write a non-live capture" >&2; return 3 ;; esac

  local parsed
  parsed="$(jq -e '{made_edit, edited_files, report}' <<<"$txt" 2>/dev/null)" \
    || { echo "  ERROR: model output for ${alias} did not match schema" >&2; return 3; }

  local captured_at out
  captured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  out="${FX}/captured/${alias}.json"
  mkdir -p "${FX}/captured"

  jq -n \
    --arg alias "$alias" \
    --argjson intok "$in_tok" \
    --argjson outtok "${out_tok:-0}" \
    --argjson parsed "$parsed" \
    --arg tool "capture-apply-fix.sh" \
    --arg at "$captured_at" \
    --arg mid "$model_id" \
    '{
      model_alias: $alias,
      usage: { input_tokens: $intok, output_tokens: $outtok },
      made_edit: $parsed.made_edit,
      edited_files: $parsed.edited_files,
      report: $parsed.report,
      provenance: { tool: $tool, captured_at: $at, model_id: $mid, live: true }
    }' > "$out"

  echo "  OK: wrote ${out#"${REPO_ROOT}"/} (in=${in_tok} out=${out_tok:-0} tokens, live)"
}

echo "Capturing apply-fix transcripts for ${FX#"${REPO_ROOT}"/}"
rc=0
for a in "${ALIASES[@]}"; do
  echo "- ${a}"
  capture_one "$a" || rc=1
done
exit "$rc"
