#!/usr/bin/env bash
#
# run-judge.sh
#
# (Re)generate the replayed LLM-judge score for one captured apply-fix
# transcript, following eval/judge/apply-fix-rubric.md. Peer review: the judge
# model must be at least as strong as the candidate, and never grade itself.
#
# The deterministic harness (eval/eval-apply-fix.sh) REPLAYS the `judge` field
# frozen inside each captured/<alias>.json -- it does not call the API. This
# helper is how you refresh that field live (e.g. after changing the rubric or
# the fix), then commit the updated transcript so future runs stay offline.
#
# Usage:
#   ./eval/judge/run-judge.sh <fixture_dir> <captured_json> [N]
# Env:
#   JUDGE_MODEL   default claude-opus-4-8 (must be >= the candidate model)
#   N             number of judge samples to average (default 5)
#
# Auth: goes through the official Anthropic CLI (`ant messages create`), which
# resolves credentials like the SDKs do -- ANTHROPIC_API_KEY if set, otherwise
# the `ant auth login` OAuth profile. No static key or auth headers required.
#
# NOTE ON DETERMINISM: temperature 0 is only accepted by models that still take
# sampling params (e.g. claude-sonnet-4-6). Opus 4.8 / 4.7 / Sonnet 5 reject
# `temperature` with a 400, so this script omits it there and instead controls
# variance via structured output + N samples averaged (per the rubric). Pin
# JUDGE_MODEL and N so the score is reproducible.

set -euo pipefail
IFS=$'\n\t'

FX="${1:?usage: run-judge.sh <fixture_dir> <captured_json> [N]}"
CAP="${2:?usage: run-judge.sh <fixture_dir> <captured_json> [N]}"
N="${3:-${N:-5}}"
JUDGE_MODEL="${JUDGE_MODEL:-claude-opus-4-8}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUBRIC="${REPO_ROOT}/eval/judge/apply-fix-rubric.md"

command -v jq  >/dev/null 2>&1 || { echo "ERROR: jq required."  >&2; exit 1; }
command -v ant >/dev/null 2>&1 || { echo "ERROR: ant CLI required (Anthropic CLI; run 'ant auth login' or set ANTHROPIC_API_KEY)." >&2; exit 1; }

target="$(jq -r '.target_file' "${FX}/meta.json")"

# Reconstruct the candidate diff (start -> edited) for the judge to review.
start_f="${FX}/start/${target}"
edited_f="$(mktemp)"
if [ "$(jq -r '.made_edit' "$CAP")" = "true" ] && jq -e --arg k "$target" '.edited_files[$k]' "$CAP" >/dev/null 2>&1; then
  jq -r --arg k "$target" '.edited_files[$k][]' "$CAP" > "$edited_f"
else
  cp "$start_f" "$edited_f"   # no edit (bail) -> empty diff
fi
diff_text="$(diff -u "$start_f" "$edited_f" || true)"
rm -f "$edited_f"

plan_text="$(cat "${FX}/plan.md")"
rubric_text="$(cat "$RUBRIC")"

SCHEMA='{"type":"object","additionalProperties":false,
  "properties":{
    "security":{"type":"object","additionalProperties":false,"properties":{"score":{"type":"integer","enum":[1,2,3,4,5]},"note":{"type":"string"}},"required":["score","note"]},
    "efficiency":{"type":"object","additionalProperties":false,"properties":{"score":{"type":"integer","enum":[1,2,3,4,5]},"note":{"type":"string"}},"required":["score","note"]},
    "performance":{"type":"object","additionalProperties":false,"properties":{"score":{"type":"integer","enum":[1,2,3,4,5]},"note":{"type":"string"}},"required":["score","note"]},
    "verdict":{"type":"string","enum":["pass","concern"]}},
  "required":["security","efficiency","performance","verdict"]}'

sys="You are a strict peer reviewer scoring an apply-fix edit against a rubric. Output ONLY the JSON object the schema describes. Score conservatively; the deterministic gates already checked correctness, you judge security/efficiency/performance posture."
user="$(printf 'RUBRIC:\n%s\n\nAPPROVED PLAN:\n%s\n\nCANDIDATE DIFF:\n%s\n' "$rubric_text" "$plan_text" "$diff_text")"

# Sampling param only where the model accepts it.
extra=""
case "$JUDGE_MODEL" in
  claude-sonnet-4-6|claude-sonnet-4-5|claude-haiku-4-5) extra=',"temperature":0' ;;
esac
effort=false
case "$JUDGE_MODEL" in
  claude-opus-4-5|claude-opus-4-6|claude-opus-4-7|claude-opus-4-8|claude-sonnet-4-6|claude-sonnet-5) effort=true ;;
esac

body="$(jq -n --arg m "$JUDGE_MODEL" --arg sys "$sys" --arg user "$user" --argjson schema "$SCHEMA" --argjson effort "$effort" \
  '{model:$m, max_tokens:512, system:$sys,
    output_config:({format:{type:"json_schema", schema:$schema}} +
      (if $effort then {effort:"low"} else {} end)),
    messages:[{role:"user", content:$user}]}')"
[ -n "$extra" ] && body="$(printf '%s' "$body" | jq ". + {$( printf '%s' "$extra" | sed 's/^,//' )}")"

sec_sum=0; eff_sum=0; perf_sum=0; got=0
for i in $(seq 1 "$N"); do
  resp="$(printf '%s' "$body" | ant messages create --format json)" || continue
  txt="$(printf '%s' "$resp" | jq -r '.content[]? | select(.type=="text") | .text' 2>/dev/null | head -c 4000)"
  [ -n "$txt" ] || { echo "  sample $i: no content" >&2; continue; }
  s="$(printf '%s' "$txt" | jq -r '.security.score' 2>/dev/null)"
  e="$(printf '%s' "$txt" | jq -r '.efficiency.score' 2>/dev/null)"
  p="$(printf '%s' "$txt" | jq -r '.performance.score' 2>/dev/null)"
  case "$s$e$p" in *[!0-9]*|'') echo "  sample $i: unparseable" >&2; continue ;; esac
  sec_sum=$((sec_sum + s)); eff_sum=$((eff_sum + e)); perf_sum=$((perf_sum + p)); got=$((got + 1))
done

[ "$got" -gt 0 ] || { echo "ERROR: no usable judge samples." >&2; exit 3; }

sec_avg="$(awk -v s="$sec_sum" -v n="$got" 'BEGIN{printf "%.2f", s/n}')"
eff_avg="$(awk -v s="$eff_sum" -v n="$got" 'BEGIN{printf "%.2f", s/n}')"
perf_avg="$(awk -v s="$perf_sum" -v n="$got" 'BEGIN{printf "%.2f", s/n}')"
echo "judge (${JUDGE_MODEL}, N=${got}): security=${sec_avg} efficiency=${eff_avg} performance=${perf_avg}"

# Write the averaged scores back into the transcript's judge field, stamped with
# a liveness provenance marker so the harness can tell a genuinely-judged score
# from a hand-authored placeholder (see the provenance gate in eval-apply-fix.sh).
judged_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp="$(mktemp)"
jq --argjson sec "$sec_avg" --argjson eff "$eff_avg" --argjson perf "$perf_avg" \
   --arg jm "$JUDGE_MODEL" --arg at "$judged_at" --argjson n "$got" \
   '.judge = {security:$sec, efficiency:$eff, performance:$perf,
              note:"regenerated by run-judge.sh",
              provenance:{tool:"run-judge.sh", judge_model:$jm, judged_at:$at, n:$n, live:true}}' \
   "$CAP" > "$tmp" && mv "$tmp" "$CAP"
echo "OK: updated judge field in ${CAP}"
