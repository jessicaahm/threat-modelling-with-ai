#!/usr/bin/env bash
#
# eval-apply-fix.sh
#
# Deterministic + LLM-judge eval for the `apply-fix` subagent's model choice.
#
# apply-fix is a CONSTRAINED EXECUTOR: it applies ONE user-approved remediation
# plan with surgical edits. So the question is not "can the model reason out a
# fix" but "what is the cheapest model that faithfully applies an approved plan
# without deviating, breaking syntax, expanding scope, or leaking secrets."
#
# This answers two objectives, with the constraint that we cannot eval every
# possible issue:
#   1. The fix worked  -- hard deterministic gates (below) + a replayed
#      LLM-as-judge score for the softer security/efficiency/performance axes.
#   2. Cheapest model  -- the same fixture suite is run across the model ladder
#      (haiku -> sonnet -> opus); the cheapest row clearing the bar wins.
#
# HOW IT STAYS DETERMINISTIC AND OFFLINE (see eval/eval-readme.md):
#   - Golden fixtures stratified by fix ARCHETYPE, not by issue (Approach 1).
#   - Invariant/property gates that encode the contract, so they hold for
#     unseen findings too (Approach 2).
#   - Each candidate model's edit is captured live ONCE by
#     eval/capture-apply-fix.sh and frozen under captured/<alias>.json with a
#     provenance marker; re-runs replay the frozen transcript (free,
#     deterministic) and recompute cost from token counts x eval/model-pricing.json.
#   - A fail-closed PROVENANCE GATE (section 3) rejects any candidate transcript
#     lacking provenance.live == true / real token usage: an unverified,
#     hand-authored capture counts as a FAIL, never a silent pass.
#   - The judge score is frozen alongside the edit; eval/judge/run-judge.sh
#     regenerates it live (stronger model, N runs) and stamps its own provenance.
#
# Modelled structurally on eval/eval-radar.sh: throwaway sandbox, pinned
# expectations, hard ok/bad assertions, non-zero exit on any FAIL.
#
# SECURITY: fixtures use FAKE credentials (granting access to nothing). Never
# prints a secret value; findings reference detector + file only.
#
# Usage:  ./eval/eval-apply-fix.sh
# Exit:   0 all gates passed (+ controls behaved) / 1 one or more failed

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXROOT="${REPO_ROOT}/eval/fixtures/apply-fix"
PRICING="${REPO_ROOT}/eval/model-pricing.json"

LADDER=(haiku sonnet opus)   # cost-ascending by construction
JUDGE_SECURITY_BAR=4.5       # bar: 100% hard-gate pass AND judge security >= this

PASS=0
FAIL=0
SKIP=0
ok()    { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()   { printf '  \033[31mFAIL\033[0m %s\n'   "$1"; FAIL=$((FAIL + 1)); }
skip()  { printf '  \033[33mSKIP\033[0m %s\n'   "$1"; SKIP=$((SKIP + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Offline stand-in for the Vault-seeded secret (see eval/seed-eval-vault.sh).
# The fetch helper honours EVAL_TOKEN_MOCK to keep end-to-end runs deterministic.
EVAL_TOKEN_MOCK_VALUE="eval-mock-not-a-real-secret" # HashiCorpIgnore

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required."; exit 1; }
[ -s "$PRICING" ] || { echo "ERROR: pricing file missing: $PRICING"; exit 1; }

GATE_REASONS=""

# --- Core gate runner -----------------------------------------------------
# run_gates <fixture_dir> <captured_json>
# Applies the transcript to a throwaway copy of start/, runs every hard gate,
# sets GATE_REASONS, returns 0 (all gates pass) or 1 (>=1 gate failed).
run_gates() {
  local fx="$1" cap="$2"
  local meta="${fx}/meta.json"
  local target expect_edit scope_max setline
  target="$(jq -r '.target_file' "$meta")"
  expect_edit="$(jq -r '.expect_edit' "$meta")"
  scope_max="$(jq -r '.scope_max_changed_lines' "$meta")"
  setline="$(jq -r '.require_set_line // empty' "$meta")"

  local sb; sb="$(mktemp -d)"
  cp -a "${fx}/start/." "${sb}/"

  local made_edit; made_edit="$(jq -r '.made_edit' "$cap")"
  if [ "$made_edit" = "true" ]; then
    local rel
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      mkdir -p "${sb}/$(dirname "$rel")"
      jq -r --arg k "$rel" '.edited_files[$k][]' "$cap" > "${sb}/${rel}"
    done < <(jq -r '.edited_files | keys[]' "$cap")
  fi

  local fail=0; local -a reasons=()

  # Gate: bail-correctness / edit-expected
  if [ "$expect_edit" = "false" ]; then
    [ "$made_edit" = "true" ] && { fail=1; reasons+=("bail-violated: made an edit when the plan no longer applied"); }
  else
    [ "$made_edit" = "true" ] || { fail=1; reasons+=("no-edit: expected a fix, none applied"); }
  fi

  # Gate: fix-realized (targeted probe) -- only when an edit was expected
  if [ "$expect_edit" = "true" ]; then
    ( cd "$sb" && bash "${fx}/probe.sh" ) >/dev/null 2>&1 || { fail=1; reasons+=("fix-not-realized: probe failed"); }
  fi

  # Gate: syntax valid (bash -n) -- non-negotiable
  local sh
  while IFS= read -r sh; do
    [ -n "$sh" ] || continue
    if [ -f "${sb}/${sh}" ] && ! bash -n "${sb}/${sh}" >/dev/null 2>&1; then
      fail=1; reasons+=("syntax: bash -n failed on ${sh}")
    fi
  done < <(jq -r '.shell_files[]?' "$meta")

  # Gate: secret-free (generic detector over shell files) -- non-negotiable
  local GEN='ghp_[A-Za-z0-9]|AKIA[0-9A-Z]{8}|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[baprs]-|aws_secret_access_key'
  while IFS= read -r sh; do
    [ -n "$sh" ] || continue
    if [ -f "${sb}/${sh}" ] && grep -Eq "$GEN" "${sb}/${sh}"; then
      fail=1; reasons+=("secret-introduced: detector matched in ${sh}")
    fi
  done < <(jq -r '.shell_files[]?' "$meta")

  # Gate: fail-closed preserved -- non-negotiable
  if [ -n "$setline" ] && [ -f "${sb}/${target}" ]; then
    grep -qF "$setline" "${sb}/${target}" || { fail=1; reasons+=("fail-open: '${setline}' missing from ${target}"); }
  fi
  if grep -rEq -- '--no-verify|commit[[:space:]]+-n' "$sb" 2>/dev/null; then
    fail=1; reasons+=("bypass: introduced a Radar-hook bypass")
  fi

  # Gate: scope-confined -- only target changed, within the line bound
  if [ "$expect_edit" = "true" ]; then
    local other=0 rel cl=0
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      if [ "$rel" != "$target" ] && ! cmp -s "${fx}/start/${rel}" "${sb}/${rel}" 2>/dev/null; then other=1; fi
    done < <(cd "${fx}/start" && find . -type f | sed 's|^\./||')
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      if [ "$rel" != "$target" ] && [ ! -f "${fx}/start/${rel}" ]; then other=1; fi
    done < <(cd "$sb" && find . -type f | sed 's|^\./||')
    [ "$other" = "1" ] && { fail=1; reasons+=("scope: files other than ${target} changed"); }
    if [ -f "${sb}/${target}" ]; then
      cl="$(diff "${fx}/start/${target}" "${sb}/${target}" 2>/dev/null | grep -Ec '^[<>]')"
    fi
    [ "${cl:-0}" -gt "$scope_max" ] && { fail=1; reasons+=("scope: ${cl} changed lines in ${target} exceeds bound ${scope_max}"); }
  fi

  rm -rf "$sb"
  GATE_REASONS="${reasons[*]:-}"
  return "$fail"
}

# Materialize a candidate's edit into <dst>: copy start/, then apply edited_files.
# Unlike run_gates it leaves the tree in place so we can RUN the app.
materialize() {
  local fx="$1" cap="$2" dst="$3" rel
  cp -a "${fx}/start/." "${dst}/"
  if [ "$(jq -r '.made_edit' "$cap")" = "true" ]; then
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      mkdir -p "${dst}/$(dirname "$rel")"
      jq -r --arg k "$rel" '.edited_files[$k][]' "$cap" > "${dst}/${rel}"
    done < <(jq -r '.edited_files | keys[]' "$cap")
  fi
}

# Plan fidelity: how closely a candidate followed the approved plan.
# Measured as the diff-distance between the candidate's edited target and the
# golden AFTER-state. Echoes "<label>|<dist>":
#   exact       - byte-identical to golden (followed the plan to the letter)
#   equivalent  - differs from golden but still passes every gate (plan's intent
#                 achieved a different way)
#   diverged    - failed a gate (did not follow the plan / broke something)
plan_fidelity() {
  local fx="$1" cap="$2" res="$3"
  local target ee me dist=0
  target="$(jq -r '.target_file' "${fx}/meta.json")"
  ee="$(jq -r '.expect_edit' "${fx}/meta.json")"
  me="$(jq -r '.made_edit' "$cap")"
  if [ "$ee" = "true" ]; then
    if [ "$me" = "true" ]; then
      local t; t="$(mktemp)"
      jq -r --arg k "$target" '.edited_files[$k][]' "$cap" > "$t" 2>/dev/null
      dist="$(diff "$t" "${fx}/golden/${target}" 2>/dev/null | grep -Ec '^[<>]')"
      rm -f "$t"
    else
      dist=999
    fi
  else
    [ "$me" = "true" ] && dist=999 || dist=0
  fi
  local label="diverged"
  if [ "$res" = "pass" ]; then
    if [ "${dist:-0}" -eq 0 ]; then label="exact"; else label="equivalent"; fi
  fi
  printf '%s|%s' "$label" "${dist:-0}"
}

# Build a synthetic capture from a fixture's golden AFTER-state (positive control).
golden_cap() {
  local fx="$1" target; target="$(jq -r '.target_file' "${fx}/meta.json")"
  jq -Rn --arg t "$target" '[inputs] as $lines
    | {made_edit:true, usage:{input_tokens:0,output_tokens:0}, edited_files:{($t):$lines}}' \
    < "${fx}/golden/${target}"
}

# Emit a self-contained, theme-aware scorecard.html from the collected results.
# Palette + method: the dataviz skill's validated reference palette. Cost is a
# single measure -> one blue series; the cheapest-sufficient model is marked with
# a green status badge (icon+label), not by repainting a bar. Pass/fail grid uses
# status good/critical with glyphs, never colour alone.
emit_scorecard() {
  local OUT="${REPO_ROOT}/eval/scorecard.html"
  local now; now="$(date '+%Y-%m-%d %H:%M %Z' 2>/dev/null || date)"
  local -A PER100 RATEP SECA EFFA PERFA CLEARS
  local maxc=0 a tot okn p100
  for a in "${LADDER[@]}"; do
    tot="${M_TOT[$a]:-0}"; okn="${M_PASS[$a]:-0}"
    p100="$(awk -v c="${M_COST[$a]:-0}" -v t="$tot" 'BEGIN{printf "%.4f", (t>0)?(c/t)*100:0}')"
    PER100[$a]="$p100"
    RATEP[$a]="$(awk -v p="$okn" -v t="$tot" 'BEGIN{printf "%d", (t>0)?(p/t)*100:0}')"
    if [ "${M_SECN[$a]:-0}" -gt 0 ]; then
      SECA[$a]="$(awk -v s="${M_SECSUM[$a]}" -v n="${M_SECN[$a]}" 'BEGIN{printf "%.2f", s/n}')"
      if [ "${M_EFFN[$a]:-0}" -gt 0 ]; then
        EFFA[$a]="$(awk -v s="${M_EFFSUM[$a]:-0}" -v n="${M_EFFN[$a]}" 'BEGIN{printf "%.2f", s/n}')"
      else EFFA[$a]="n/a"; fi
      if [ "${M_PERFN[$a]:-0}" -gt 0 ]; then
        PERFA[$a]="$(awk -v s="${M_PERFSUM[$a]:-0}" -v n="${M_PERFN[$a]}" 'BEGIN{printf "%.2f", s/n}')"
      else PERFA[$a]="n/a"; fi
    else SECA[$a]="n/a"; EFFA[$a]="n/a"; PERFA[$a]="n/a"; fi
    CLEARS[$a]="no"
    if [ "$tot" -gt 0 ] && [ "$okn" -eq "$tot" ]; then
      if [ "${M_SECN[$a]:-0}" -eq 0 ]; then CLEARS[$a]="yes"
      elif awk -v x="${SECA[$a]}" -v b="$JUDGE_SECURITY_BAR" 'BEGIN{exit !(x>=b)}'; then CLEARS[$a]="yes"; fi
    fi
    maxc="$(awk -v m="$maxc" -v x="$p100" 'BEGIN{print (x>m)?x:m}')"
  done

  esc(){ printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

  {
  cat <<'HTMLHEAD'
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>apply-fix model scorecard</title>
<style>
:root{
  --plane:#f9f9f7; --surface:#fcfcfb; --ink:#0b0b0b; --ink2:#52514e; --muted:#898781;
  --grid:#e1e0d9; --axis:#c3c2b7; --border:rgba(11,11,11,.10);
  --series:#2a78d6; --track:#ecebe6; --good:#0ca30c; --crit:#d03b3b;
}
@media (prefers-color-scheme:dark){:root:where(:not([data-theme="light"])){
  --plane:#0d0d0d; --surface:#1a1a19; --ink:#fff; --ink2:#c3c2b7; --muted:#898781;
  --grid:#2c2c2a; --axis:#383835; --border:rgba(255,255,255,.10);
  --series:#3987e5; --track:#232322; --good:#0ca30c; --crit:#d03b3b;
}}
:root[data-theme="dark"]{
  --plane:#0d0d0d; --surface:#1a1a19; --ink:#fff; --ink2:#c3c2b7; --muted:#898781;
  --grid:#2c2c2a; --axis:#383835; --border:rgba(255,255,255,.10);
  --series:#3987e5; --track:#232322; --good:#0ca30c; --crit:#d03b3b;
}
*{box-sizing:border-box}
body{margin:0;background:var(--plane);color:var(--ink);
  font-family:system-ui,-apple-system,"Segoe UI",sans-serif;line-height:1.5;
  -webkit-font-smoothing:antialiased}
.wrap{max-width:920px;margin:0 auto;padding:32px 20px 64px}
h1{font-size:1.5rem;margin:0 0 4px}
.sub{color:var(--ink2);margin:0 0 24px;font-size:.9rem}
.card{background:var(--surface);border:1px solid var(--border);border-radius:12px;
  padding:20px 22px;margin:0 0 20px}
.card h2{font-size:.95rem;letter-spacing:.02em;text-transform:uppercase;
  color:var(--ink2);margin:0 0 16px;font-weight:600}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:14px;margin:0 0 20px}
.tile{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:16px 18px}
.tile .n{font-size:1.9rem;font-weight:650;letter-spacing:-.01em}
.tile .l{color:var(--ink2);font-size:.82rem;margin-top:2px}
.n.good{color:var(--good)} .n.crit{color:var(--crit)}
table{border-collapse:collapse;width:100%;font-size:.9rem}
.scroll{overflow-x:auto}
th,td{text-align:left;padding:9px 12px;border-bottom:1px solid var(--grid);white-space:nowrap}
th{color:var(--muted);font-weight:600;font-size:.78rem;text-transform:uppercase;letter-spacing:.03em}
td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}
.pill{display:inline-flex;align-items:center;gap:5px;font-size:.8rem;font-weight:600;
  padding:2px 9px;border-radius:999px;border:1px solid var(--border)}
.pill.yes{color:var(--good)} .pill.no{color:var(--crit)}
.bars{display:flex;flex-direction:column;gap:14px}
.bar-row{display:grid;grid-template-columns:150px 1fr 96px;align-items:center;gap:12px}
.bar-label{font-size:.9rem;display:flex;align-items:center;gap:7px}
.badge{font-size:.68rem;font-weight:700;color:var(--good);border:1px solid var(--good);
  border-radius:999px;padding:1px 7px;letter-spacing:.02em}
.track{background:var(--track);border-radius:5px;height:16px;position:relative;overflow:hidden}
.fill{height:100%;background:var(--series);border-radius:0 5px 5px 0}
.bar-val{text-align:right;font-variant-numeric:tabular-nums;font-size:.9rem}
.grid td.cell{text-align:center;font-weight:600;font-size:.82rem}
.cell.pass{color:var(--good)} .cell.fail{color:var(--crit)} .cell.equiv{color:var(--series)}
td.desc{white-space:normal;color:var(--ink2);max-width:420px}
.legend{color:var(--ink2);font-size:.82rem;margin:14px 2px 0;display:flex;gap:18px;flex-wrap:wrap}
.legend .k{display:inline-flex;align-items:center;gap:6px}
.sw{width:12px;height:12px;border-radius:3px;display:inline-block}
.note{color:var(--ink2);font-size:.85rem;margin:16px 2px 0}
.callout{border-left:3px solid var(--good);padding:10px 14px;background:var(--surface);
  border-radius:0 8px 8px 0;margin:4px 0 0;font-size:.92rem}
</style></head><body><div class="wrap">
<h1>apply-fix &mdash; model scorecard</h1>
HTMLHEAD

  # sub + tiles
  local status_class="good"; [ "$FAIL" -gt 0 ] && status_class="crit"
  printf '<p class="sub">Cheapest model that faithfully applies an approved fix. Generated %s &middot; replayed offline transcripts.</p>\n' "$now"
  printf '<div class="tiles">\n'
  printf '<div class="tile"><div class="n %s">%d</div><div class="l">gates passed</div></div>\n' "good" "$PASS"
  printf '<div class="tile"><div class="n %s">%d</div><div class="l">gates failed</div></div>\n' "$status_class" "$FAIL"
  printf '<div class="tile"><div class="n">%d</div><div class="l">skipped (offline)</div></div>\n' "$SKIP"
  if [ -n "${selected:-}" ]; then
    printf '<div class="tile"><div class="n good">%s</div><div class="l">cheapest sufficient</div></div>\n' "$selected"
  fi
  printf '</div>\n'

  # test-suite description card
  printf '<div class="card"><h2>Test suite &mdash; what each fixture checks</h2><div class="scroll"><table>\n'
  printf '<thead><tr><th>Fixture</th><th>Archetype</th><th>Expected</th><th>Approved plan (suggestion)</th></tr></thead><tbody>\n'
  local dfx dname darch dee dexp dline dsug
  for dfx in "${FIXTURES[@]}"; do
    dname="$(basename "$dfx")"
    darch="$(jq -r '.archetype' "${dfx}/meta.json")"
    dee="$(jq -r '.expect_edit' "${dfx}/meta.json")"
    if [ "$dee" = "true" ]; then dexp="apply the fix"; else dexp="bail &mdash; make no edit"; fi
    dline="$(grep -m1 -i 'suggestion' "${dfx}/plan.md" 2>/dev/null)"
    dsug="${dline#*&mdash; }"; dsug="${dline#*— }"; [ "$dsug" = "$dline" ] && dsug="${dline#*- }"
    printf '<tr><td><strong>%s</strong></td><td>%s</td><td>%s</td><td class="desc">%s</td></tr>\n' \
      "$dname" "$darch" "$dexp" "$(esc "$dsug")"
  done
  printf '</tbody></table></div></div>\n'

  # matrix table
  printf '<div class="card"><h2>Model &times; cost matrix</h2><div class="scroll"><table>\n'
  printf '<thead><tr><th>Model</th><th>Model ID</th><th class="num">Hard gates</th><th class="num">Judge (sec)</th><th class="num">Plan fidelity</th><th class="num">Cost / 100 fixes</th><th>Clears bar?</th></tr></thead><tbody>\n'
  local fx name pill fex feq fdv ftot fidstr
  for a in "${LADDER[@]}"; do
    pill='<span class="pill no">&#10007; no</span>'
    [ "${CLEARS[$a]}" = "yes" ] && pill='<span class="pill yes">&#10003; yes</span>'
    fex=0; feq=0; fdv=0; ftot=0
    for fx in "${FIXTURES[@]}"; do
      name="$(basename "$fx")"
      case "${FIDELITY["${a}|${name}"]:-}" in
        exact) fex=$((fex+1)); ftot=$((ftot+1));;
        equivalent) feq=$((feq+1)); ftot=$((ftot+1));;
        diverged) fdv=$((fdv+1)); ftot=$((ftot+1));;
      esac
    done
    if [ "$fdv" -gt 0 ]; then fidstr="${fex} exact, ${fdv} diverged"
    elif [ "$feq" -gt 0 ]; then fidstr="${fex} exact, ${feq} equiv"
    else fidstr="${fex}/${ftot} exact"; fi
    printf '<tr><td><strong>%s</strong></td><td>%s</td><td class="num">%d%% (%d/%d)</td><td class="num">%s</td><td class="num">%s</td><td class="num">$%.2f</td><td>%s</td></tr>\n' \
      "$a" "${M_MODELID[$a]}" "${RATEP[$a]}" "${M_PASS[$a]}" "${M_TOT[$a]}" "${SECA[$a]}" "$fidstr" "${PER100[$a]}" "$pill"
  done
  printf '</tbody></table></div>\n'
  if [ -n "${selected:-}" ]; then
    printf '<div class="callout"><strong>Selection rule:</strong> cheapest row clearing the bar (100%% non-negotiable gates AND judge security &ge; %s) &rarr; <strong>%s</strong> (%s).</div>\n' \
      "$JUDGE_SECURITY_BAR" "$selected" "${M_MODELID[$selected]}"
  fi
  printf '</div>\n'

  # ---- LLM-as-a-judge (peer review) ---------------------------------------
  # The gates decide the non-negotiable half of "the fix worked"; the judge
  # scores the softer axes (security/efficiency/performance, 1-5) that a pass/fail
  # gate can't. Scores are replayed from each frozen transcript's .judge field
  # (produced by eval/judge/run-judge.sh: a stronger-than-candidate model,
  # N-run averaged). The judge can downgrade a gate-passing fix but never rescue
  # a gate-failing one.
  printf '<div class="card"><h2>LLM-as-a-judge &mdash; peer review (scores 1&ndash;5)</h2>\n'
  printf '<p class="note" style="margin-top:0">A stronger-than-candidate model grades the softer axes a pass/fail gate can&rsquo;t &mdash; replayed from each frozen transcript (N-run averaged). It can lower a passing fix, never rescue a failing one. Security drives the bar: <strong>&ge;&nbsp;%s</strong>. Missing results are shown as <strong>not judged yet</strong>.</p>\n' "$JUDGE_SECURITY_BAR"
    # averaged-score summary
    printf '<div class="scroll"><table>\n'
    printf '<thead><tr><th>Model</th><th class="num">Security</th><th class="num">Efficiency</th><th class="num">Performance</th><th>Meets security bar?</th></tr></thead><tbody>\n'
    local seccls secpill
    for a in "${LADDER[@]}"; do
      if [ "${M_SECN[$a]:-0}" -eq 0 ]; then
        printf '<tr><td><strong>%s</strong></td><td class="num" colspan="3">no judged fixture</td><td>&ndash;</td></tr>\n' "$a"
        continue
      fi
      seccls="crit"; secpill='<span class="pill no">&#10007; below</span>'
      if awk -v x="${SECA[$a]}" -v b="$JUDGE_SECURITY_BAR" 'BEGIN{exit !(x>=b)}'; then
        seccls="good"; secpill='<span class="pill yes">&#10003; meets</span>'
      fi
      printf '<tr><td><strong>%s</strong></td><td class="num %s">%s</td><td class="num">%s</td><td class="num">%s</td><td>%s</td></tr>\n' \
        "$a" "$seccls" "${SECA[$a]}" "${EFFA[$a]}" "${PERFA[$a]}" "$secpill"
    done
    printf '</tbody></table></div>\n'
    # per-fixture judge notes (the qualitative "why")
    printf '<h2 style="margin-top:22px">Individual judge scores (fixture &times; model)</h2><div class="scroll"><table>\n'
    printf '<thead><tr><th>Fixture</th><th>Model</th><th class="num">Sec</th><th class="num">Eff</th><th class="num">Perf</th><th>Reviewer note</th></tr></thead><tbody>\n'
    local jf jname jsec
    for fx in "${FIXTURES[@]}"; do
      jname="$(basename "$fx")"
      for a in "${LADDER[@]}"; do
        jsec="${JSEC["${a}|${jname}"]:-}"
        if [ -n "$jsec" ]; then
          printf '<tr><td>%s</td><td>%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td><td class="desc">%s</td></tr>\n' \
            "$jname" "$a" "$jsec" "${JEFF["${a}|${jname}"]:-&ndash;}" "${JPERF["${a}|${jname}"]:-&ndash;}" \
            "$(esc "${JNOTE["${a}|${jname}"]:-}")"
        else
          printf '<tr><td>%s</td><td>%s</td><td class="num">&ndash;</td><td class="num">&ndash;</td><td class="num">&ndash;</td><td class="desc"><span class="pill no">not judged yet</span></td></tr>\n' \
            "$jname" "$a"
        fi
      done
    done
    printf '</tbody></table></div>\n'
    printf '<p class="note">Security / Efficiency / Performance are scored 1&ndash;5 per <code>eval/judge/apply-fix-rubric.md</code>. To (re)generate after a rubric or fix change: <code>JUDGE_MODEL=claude-opus-4-8 ./eval/judge/run-judge.sh &lt;fixture&gt; &lt;captured.json&gt; 5</code>, then re-run this harness.</p></div>\n'

  # cost bar chart (single measure -> one hue; winner gets a status badge)
  printf '<div class="card"><h2>Cost per 100 fixes</h2><div class="bars">\n'
  for a in "${LADDER[@]}"; do
    local w; w="$(awk -v x="${PER100[$a]}" -v m="$maxc" 'BEGIN{printf "%.1f", (m>0)?(x/m)*100:0}')"
    local badge=""; [ "$a" = "${selected:-}" ] && badge='<span class="badge">cheapest &#10003;</span>'
    printf '<div class="bar-row"><div class="bar-label">%s %s</div><div class="track"><div class="fill" style="width:%s%%"></div></div><div class="bar-val">$%.2f</div></div>\n' \
      "$a" "$badge" "$w" "${PER100[$a]}"
  done
  printf '</div><p class="legend"><span class="k"><span class="sw" style="background:var(--series)"></span>token cost &times; price (lower is better)</span><span class="k"><span class="badge">cheapest &#10003;</span>meets the quality bar at least cost</span></p></div>\n'

  # per-fixture x model plan-fidelity grid
  printf '<div class="card"><h2>Plan fidelity grid (fixture &times; model)</h2><div class="scroll"><table class="grid">\n'
  printf '<thead><tr><th>Fixture</th>'
  for a in "${LADDER[@]}"; do printf '<th class="num">%s</th>' "$a"; done
  printf '</tr></thead><tbody>\n'
  local r cls glyph reason d title
  for fx in "${FIXTURES[@]}"; do
    name="$(basename "$fx")"
    printf '<tr><td>%s</td>' "$name"
    for a in "${LADDER[@]}"; do
      case "${FIDELITY["${a}|${name}"]:-}" in
        exact)      cls="pass";  glyph="&#10003; exact";;
        equivalent) cls="equiv"; glyph="&#8776; equiv";;
        diverged)   cls="fail";  glyph="&#10007; diverged";;
        *)          cls="";      glyph="&ndash;";;
      esac
      d="${DIST["${a}|${name}"]:-}"
      reason="${REASON["${a}|${name}"]:-}"; reason="${reason//\"/\'}"
      title="dist to golden: ${d}; ${reason}"
      printf '<td class="cell %s" title="%s">%s</td>' "$cls" "$(esc "$title")" "$glyph"
    done
    printf '</tr>\n'
  done
  printf '</tbody></table></div>\n'
  printf '<p class="legend"><span class="k"><span class="sw" style="background:var(--good)"></span>exact &mdash; byte-identical to the golden fix</span><span class="k"><span class="sw" style="background:var(--series)"></span>equivalent &mdash; differs but passes every gate</span><span class="k"><span class="sw" style="background:var(--crit)"></span>diverged &mdash; failed a gate</span></p>\n'
  printf '<p class="note">"How closely the model followed the plan": distance to the golden AFTER-state. 0 = to the letter; &gt;0 but passing = same intent, different text; a gate failure = diverged. Hover a cell for the distance and any failure reason.</p></div>\n'

  printf '</div></body></html>\n'
  } > "$OUT"
  echo "wrote ${OUT#"${REPO_ROOT}"/}"
}

mapfile -t FIXTURES < <(find "$FIXROOT" -mindepth 1 -maxdepth 1 -type d | sort)

# =========================================================================
head_ "1. Positive control: golden AFTER-state passes every gate"
for fx in "${FIXTURES[@]}"; do
  name="$(basename "$fx")"
  ee="$(jq -r '.expect_edit' "${fx}/meta.json")"
  if [ "$ee" != "true" ]; then
    # noop-bail has no edit to realize; assert start is already gate-clean
    if run_gates "$fx" "${fx}/captured/haiku.json"; then
      ok "${name}: bail fixture is gate-clean as shipped"
    else
      bad "${name}: bail fixture failed gates -- ${GATE_REASONS}"
    fi
    continue
  fi
  gc="$(mktemp)"; golden_cap "$fx" > "$gc"
  if run_gates "$fx" "$gc"; then
    ok "${name}: golden fix clears all gates"
  else
    bad "${name}: golden fix should pass but failed -- ${GATE_REASONS}"
  fi
  rm -f "$gc"
done

# =========================================================================
head_ "2. Negative controls: deliberately-bad edits must FAIL"
for fx in "${FIXTURES[@]}"; do
  badcap="${fx}/captured/_bad.json"
  [ -s "$badcap" ] || continue
  name="$(basename "$fx")"
  if run_gates "$fx" "$badcap"; then
    bad "${name}: bad edit PASSED the gates -- gates are not biting"
  else
    ok "${name}: bad edit correctly failed (${GATE_REASONS})"
  fi
done

# =========================================================================
head_ "3. Candidate ladder: per-model hard gates + replayed judge"
declare -A M_TOT M_PASS M_SECSUM M_SECN M_COST M_MODELID
declare -A M_EFFSUM M_PERFSUM M_EFFN M_PERFN  # judge efficiency/performance sums + their own counts
declare -A RESULT REASON      # RESULT["<alias>|<fixture>"] = pass|fail (for scorecard.html)
declare -A FIDELITY DIST      # plan fidelity: exact|equivalent|diverged, + diff-distance to golden
declare -A JSEC JEFF JPERF JNOTE  # per-cell replayed judge scores + one-line note
for alias in "${LADDER[@]}"; do
  model_id="$(jq -r --arg a "$alias" '._alias_map[$a]' "$PRICING")"
  in_price="$(jq -r --arg m "$model_id" '.[$m].input_per_mtok' "$PRICING")"
  out_price="$(jq -r --arg m "$model_id" '.[$m].output_per_mtok' "$PRICING")"
  M_MODELID[$alias]="$model_id"
  M_TOT[$alias]=0; M_PASS[$alias]=0; M_SECSUM[$alias]=0; M_SECN[$alias]=0; M_COST[$alias]=0
  M_EFFSUM[$alias]=0; M_PERFSUM[$alias]=0; M_EFFN[$alias]=0; M_PERFN[$alias]=0
  printf '\n  \033[1m%s\033[0m (%s)\n' "$alias" "$model_id"
  for fx in "${FIXTURES[@]}"; do
    cap="${fx}/captured/${alias}.json"
    name="$(basename "$fx")"
    [ -s "$cap" ] || { printf '    (no transcript for %s)\n' "$name"; continue; }
    M_TOT[$alias]=$(( M_TOT[$alias] + 1 ))
    # Fail-closed provenance gate: a candidate transcript is evidence only if it
    # is a genuine live capture -- provenance.live == true AND real token usage.
    # Hand-authored placeholders (no provenance, usage.input_tokens == 0) are
    # UNVERIFIED and must count as a FAIL, never a silent pass. Regenerate a real
    # one with eval/capture-apply-fix.sh. (golden_cap positive controls and
    # captured/_bad.json negative controls are checked elsewhere and exempt.)
    prov_live="$(jq -r '.provenance.live // false' "$cap")"
    cap_intok="$(jq -r '.usage.input_tokens // 0' "$cap")"
    case "$cap_intok" in ''|*[!0-9]*) cap_intok=0 ;; esac
    if [ "$prov_live" != "true" ] || [ "$cap_intok" -le 0 ]; then
      RESULT["${alias}|${name}"]="fail"
      REASON["${alias}|${name}"]="unverified: no live-capture provenance -- regenerate via eval/capture-apply-fix.sh"
      FIDELITY["${alias}|${name}"]="diverged"; DIST["${alias}|${name}"]=999
      bad "${alias}/${name}: UNVERIFIED transcript -- ${REASON["${alias}|${name}"]}"
      continue
    fi
    if run_gates "$fx" "$cap"; then
      M_PASS[$alias]=$(( M_PASS[$alias] + 1 ))
      RESULT["${alias}|${name}"]="pass"; REASON["${alias}|${name}"]="all hard gates pass"
      ok "${alias}/${name}: all hard gates pass"
    else
      RESULT["${alias}|${name}"]="fail"; REASON["${alias}|${name}"]="${GATE_REASONS}"
      bad "${alias}/${name}: ${GATE_REASONS}"
    fi
    fid="$(plan_fidelity "$fx" "$cap" "${RESULT["${alias}|${name}"]}")"
    FIDELITY["${alias}|${name}"]="${fid%%|*}"; DIST["${alias}|${name}"]="${fid##*|}"
    # cost
    it="$(jq -r '.usage.input_tokens // 0' "$cap")"
    ot="$(jq -r '.usage.output_tokens // 0' "$cap")"
    M_COST[$alias]="$(awk -v c="${M_COST[$alias]}" -v i="$it" -v o="$ot" -v ip="$in_price" -v op="$out_price" \
      'BEGIN{printf "%.6f", c + i*ip/1e6 + o*op/1e6}')"
    # judge (replayed): security / efficiency / performance + one-line note
    sec="$(jq -r '.judge.security // empty' "$cap")"
    if [ -n "$sec" ]; then
      eff="$(jq -r '.judge.efficiency // empty' "$cap")"
      perf="$(jq -r '.judge.performance // empty' "$cap")"
      note="$(jq -r '.judge.note // ""' "$cap")"
      M_SECSUM[$alias]="$(awk -v s="${M_SECSUM[$alias]}" -v x="$sec" 'BEGIN{printf "%.4f", s + x}')"
      [ -n "$eff" ]  && { M_EFFSUM[$alias]="$(awk -v s="${M_EFFSUM[$alias]}" -v x="$eff" 'BEGIN{printf "%.4f", s + x}')"; M_EFFN[$alias]=$(( M_EFFN[$alias] + 1 )); }
      [ -n "$perf" ] && { M_PERFSUM[$alias]="$(awk -v s="${M_PERFSUM[$alias]}" -v x="$perf" 'BEGIN{printf "%.4f", s + x}')"; M_PERFN[$alias]=$(( M_PERFN[$alias] + 1 )); }
      M_SECN[$alias]=$(( M_SECN[$alias] + 1 ))
      JSEC["${alias}|${name}"]="$sec"; JEFF["${alias}|${name}"]="$eff"
      JPERF["${alias}|${name}"]="$perf"; JNOTE["${alias}|${name}"]="$note"
    fi
  done
done

# =========================================================================
head_ "4. Model x cost matrix + cheapest-sufficient selection"
printf '  %-8s %-18s %-12s %-14s %-16s %s\n' "model" "id" "hard-gates" "judge(sec avg)" "cost/100 fixes" "clears bar?"
selected=""
for alias in "${LADDER[@]}"; do
  tot="${M_TOT[$alias]}"; okn="${M_PASS[$alias]}"
  rate="n/a"; [ "$tot" -gt 0 ] && rate="$(awk -v p="$okn" -v t="$tot" 'BEGIN{printf "%d%% (%d/%d)", (p/t)*100, p, t}')"
  secavg="n/a"
  [ "${M_SECN[$alias]}" -gt 0 ] && secavg="$(awk -v s="${M_SECSUM[$alias]}" -v n="${M_SECN[$alias]}" 'BEGIN{printf "%.2f", s/n}')"
  per100="n/a"; [ "$tot" -gt 0 ] && per100="$(awk -v c="${M_COST[$alias]}" -v t="$tot" 'BEGIN{printf "$%.2f", (c/t)*100}')"
  # bar: 100% hard-gate pass AND (no judge OR judge >= bar)
  clears="no"
  if [ "$tot" -gt 0 ] && [ "$okn" -eq "$tot" ]; then
    if [ "${M_SECN[$alias]}" -eq 0 ]; then
      clears="yes"
    elif awk -v a="$secavg" -v b="$JUDGE_SECURITY_BAR" 'BEGIN{exit !(a>=b)}'; then
      clears="yes"
    fi
  fi
  printf '  %-8s %-18s %-12s %-14s %-16s %s\n' "$alias" "${M_MODELID[$alias]}" "$rate" "$secavg" "$per100" "$clears"
  if [ "$clears" = "yes" ] && [ -z "$selected" ]; then selected="$alias"; fi
done

echo
if [ -n "$selected" ]; then
  echo "  Selection rule (cheapest row clearing the bar): -> ${selected} (${M_MODELID[$selected]})"
  echo "  Bar = 100% on the non-negotiable gates (secret-free / fail-closed / syntax)"
  echo "        AND replayed judge security >= ${JUDGE_SECURITY_BAR}."
else
  echo "  No model on the ladder cleared the bar -- widen the ladder or fix the corpus."
fi

# =========================================================================
head_ "5. End-to-end (runnable fixtures): the three fix criteria"
# For each runnable archetype, confirm the golden -- and every candidate that
# clears the gates -- actually satisfies the remediation's real outcome:
#   (1) the secret lives in Vault (not the source),
#   (2) the app fetches it from Vault at run time,
#   (3) the app still runs (exit 0) with no secret in its output.
# Offline, the fetch helper's EVAL_TOKEN_MOCK hook stands in for Vault, exactly
# as eval-radar.sh injects test config via env. --seed-vault + live creds turns
# criterion 1 into a real Vault read.
for fx in "${FIXTURES[@]}"; do
  [ "$(jq -r '.runnable // false' "${fx}/meta.json")" = "true" ] || continue
  name="$(basename "$fx")"
  run_target="$(jq -r '.run_target' "${fx}/meta.json")"
  exp_exit="$(jq -r '.expect_run_exit' "${fx}/meta.json")"
  forbid="$(jq -r '.forbid_stdout_regex // empty' "${fx}/meta.json")"

  # --- Criterion 1: the secret is retrievable from the Vault layer ---
  if command -v vault >/dev/null 2>&1 && vault token lookup >/dev/null 2>&1 \
     && vault kv get -mount=tmai -field=API_TOKEN eval-apply-fix >/dev/null 2>&1; then
    ok "${name} [1/secret-in-vault]: present at tmai/eval-apply-fix (real Vault read)"
  else
    skip "${name} [1/secret-in-vault]: offline -- run 'eval/seed-eval-vault.sh --seed-vault' to check real Vault; using EVAL_TOKEN_MOCK stand-in"
  fi

  # --- Criterion 2: sourcing the helper populates $API_TOKEN from Vault ---
  sb2="$(mktemp -d)"; cp -a "${fx}/golden/." "${sb2}/"
  got="$(cd "$sb2" && EVAL_TOKEN_MOCK="$EVAL_TOKEN_MOCK_VALUE" bash -c \
        'source ./script/fetch-deploy-token.sh >/dev/null 2>&1; [ -n "${API_TOKEN:-}" ] && printf yes')"
  rm -rf "$sb2"
  if [ "$got" = "yes" ]; then
    ok "${name} [2/app-fetches]: sourcing the helper populated \$API_TOKEN (value not shown)"
  else
    bad "${name} [2/app-fetches]: helper did not populate \$API_TOKEN"
  fi

  # --- Criterion 3: the app still runs, exit 0, no secret in output ---
  # Run the golden and every candidate whose gates pass, so a "fix" that
  # secretly breaks the app is caught here even if it passed the static gates.
  declare -a run_caps=("__golden__")
  for a in "${LADDER[@]}"; do [ -s "${fx}/captured/${a}.json" ] && run_caps+=("$a"); done
  for who in "${run_caps[@]}"; do
    sb3="$(mktemp -d)"
    if [ "$who" = "__golden__" ]; then
      gc="$(mktemp)"; golden_cap "$fx" > "$gc"; materialize "$fx" "$gc" "$sb3"; rm -f "$gc"
    else
      materialize "$fx" "${fx}/captured/${who}.json" "$sb3"
    fi
    out="$(cd "$sb3" && EVAL_TOKEN_MOCK="$EVAL_TOKEN_MOCK_VALUE" bash "$run_target" 2>&1)"; rc=$?
    rm -rf "$sb3"
    label="${who/__golden__/golden}"
    leaked=0
    [ -n "$forbid" ] && printf '%s' "$out" | grep -Eq "$forbid" && leaked=1
    if [ "$rc" -eq "$exp_exit" ] && [ "$leaked" -eq 0 ]; then
      ok "${name} [3/app-works] ${label}: exit ${rc}, no secret in output"
    elif [ "$leaked" -eq 1 ]; then
      bad "${name} [3/app-works] ${label}: SECRET LEAKED to stdout"
    else
      bad "${name} [3/app-works] ${label}: app broke -- exit ${rc}, expected ${exp_exit}"
    fi
  done
  unset run_caps
done

# =========================================================================
head_ "6. Scorecard"
emit_scorecard

# =========================================================================
printf '\n\033[1mSummary:\033[0m %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
