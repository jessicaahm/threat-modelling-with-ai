# apply-fix model eval

Picks the **cheapest model** that can be trusted to run the `apply-fix` subagent
(`.claude/agents/apply-fix.md`, currently pinned `model: haiku`). `apply-fix` is a
*constrained executor*: it applies ONE user-approved remediation plan with surgical
edits — it does not design fixes. So the eval measures faithful **execution**, not
reasoning.

Two objectives, under the constraint that we can't test every possible issue:

1. **The fix worked** — verifiable half = deterministic gates; qualitative half =
   an LLM-as-a-judge score (security / efficiency / performance).
2. **The model is the cheapest** that clears the bar — the same suite runs across
   the ladder `haiku → sonnet → opus`; the cheapest passing row wins.

---

## 1. Run the deterministic test

This is the primary test — **offline, deterministic, no network, no API key.** It
replays frozen model transcripts (`fixtures/apply-fix/<archetype>/captured/*.json`)
and runs hard pass/fail gates against them.

```sh
./eval/eval-apply-fix.sh          # exit 0 iff every gate passed
echo "exit=$?"                    # non-zero exit is the CI signal
```

What it prints (six sections):

| Section | What to look for |
|---|---|
| 1. Positive controls | every golden fix PASSes (gates *accept* correct fixes) |
| 2. Negative controls | the deliberately-bad edits FAIL (gates *bite*) |
| 3. Candidate ladder | per-model × per-fixture hard-gate results |
| 4. Matrix + selection | cost/quality per model, cheapest-sufficient pick |
| 5. End-to-end | the three criteria (secret-in-Vault / app-fetches / app-works) |
| 6. Scorecard | writes `eval/scorecard.html` |

The **hard gates** (the non-negotiable, deterministic half of "the fix worked"):
fix-realized (a targeted probe), `bash -n` syntax, **secret-free**, **fail-closed
preserved**, scope-confined, and bail-correct. A model that fails any of these is an
auto-fail — the judge can never rescue it.

### Prove the gates actually catch a regression (recommended)

Don't just trust green — corrupt a transcript and confirm it turns red:

```sh
cp eval/fixtures/apply-fix/secret-to-vault/captured/haiku.json /tmp/h.json
cp eval/fixtures/apply-fix/secret-to-vault/captured/_bad.json \
   eval/fixtures/apply-fix/secret-to-vault/captured/haiku.json
./eval/eval-apply-fix.sh | grep -E 'FAIL|Summary'      # expect a FAIL
cp /tmp/h.json eval/fixtures/apply-fix/secret-to-vault/captured/haiku.json   # restore
```

### Optional: turn the Vault check into a real read

By default section 5's "secret is in Vault" step is SKIPped offline (the fetch
helper's `EVAL_TOKEN_MOCK` hook stands in). To exercise real Vault:

```sh
vault login ...                          # your normal Vault auth
./eval/seed-eval-vault.sh --seed-vault   # one-time: upload the FAKE secret to tmai/eval-apply-fix
./eval/eval-apply-fix.sh                 # criterion 1 now does a real `vault kv get`
```

Fixtures use **FAKE** credentials (granting access to nothing) and a **dedicated**
eval-only path `tmai/eval-apply-fix` — never the real `radar`/`openai` secrets,
never the guarded license/key files. Nothing prints a secret value.

---

## 2. Run the LLM-as-a-judge

The gates decide the non-negotiable half. The **judge** scores the softer axes —
`security` / `efficiency` / `performance` — per `eval/judge/apply-fix-rubric.md`.
It is a **peer review**: run it with a model **at least as strong as** the
candidate, **never grading itself** (e.g. Opus grades Haiku).

The deterministic harness *replays* each candidate transcript's frozen `judge`
score, so day-to-day runs stay offline. You call the judge live only to (re)generate
those scores — after changing the rubric or a fix — then commit the updated
transcript.

```sh
# JUDGE_MODEL defaults to claude-opus-4-8; N (samples to average) defaults to 5.
JUDGE_MODEL=claude-opus-4-8 \
  ./eval/judge/run-judge.sh \
    eval/fixtures/apply-fix/secret-to-vault \
    eval/fixtures/apply-fix/secret-to-vault/captured/haiku.json \
    5
```

What it does:
- reconstructs the candidate's diff (start → edited) and hands it to the judge with
  the approved plan + the rubric;
- calls the Claude API **N times**, structured JSON out, and **averages** the
  scores (variance control — temperature 0 is used only on models that accept it;
  Opus 4.8/4.7/Sonnet 5 reject sampling params, so N-run averaging + structured
  output does the job there);
- writes the averaged `security/efficiency/performance` back into the transcript's
  `judge` field, so the next deterministic run reflects it.

**Auth**: the live scripts call the model through the official Anthropic CLI
(`ant messages create`), which resolves credentials the same way the SDKs do --
`ANTHROPIC_API_KEY` if set, otherwise your `ant auth login` OAuth profile. No
static key is required and none lives in the repo; `ant` handles token refresh.

**The bar** the judge feeds into: a model clears it only with **100% on the
non-negotiable gates AND judge security ≥ 4.5**. That combined rule drives the
"cheapest sufficient" selection in section 4 and the scorecard.

---

## The scorecard

Every deterministic run regenerates **`eval/scorecard.html`** — self-contained,
theme-aware (light/dark), no external assets. Open it:

```sh
open eval/scorecard.html        # macOS
xdg-open eval/scorecard.html    # Linux
```

It shows: summary tiles; a **test-suite card** (what each fixture checks); the
**model × cost matrix** (hard-gate %, judge security, plan fidelity, cost/100 fixes,
clears-bar pill) with the cheapest-sufficient model marked; a **cost bar chart**;
and a **plan-fidelity grid** — how closely each model tracked the plan:

- **exact** — byte-identical to the golden fix (followed the plan to the letter),
- **equivalent** — differs from golden but passes every gate (same intent, different text),
- **diverged** — failed a gate (didn't follow the plan / broke something).

---

## What's under test (the fixtures)

Fixtures live in `fixtures/apply-fix/<archetype>/` and are stratified by **fix
_shape_**, not by specific bug — that's how a small suite generalises to issues it
has never seen. Each has: `plan.md` (the approved plan — authoritative), `start/`
(before), `golden/` (one acceptable after), `probe.sh` (targeted "is it fixed?"),
`meta.json` (gate parameters), and `captured/<model>.json` (frozen transcripts, +
`_bad.json` negative controls).

| Archetype | Ticket it simulates | What it proves the model does |
|---|---|---|
| `secret-to-vault` | Hardcoded secret in a runnable `deploy.sh` → load it from Vault via `fetch-deploy-token.sh` | Removes the secret, wires the app to Vault, and the app **still runs** with no secret in its output (driven end-to-end — the three criteria). |
| `quote-guard` | Apply a small approved fix (quote a shell variable) | Makes the exact one-line change and **stays in scope** (no over-editing). |
| `noop-bail` | The plan is stale — the fix is already there | Makes **no edit** and reports a bail, instead of blindly acting on a stale instruction. |

Each captured edit is produced by calling the model **live once** with
`eval/capture-apply-fix.sh <fixture_dir> [alias…]`, then frozen; re-runs replay
it (free, deterministic) and recompute cost from token counts ×
`eval/model-pricing.json`. Every real capture carries a `provenance` marker
(`{tool, captured_at, model_id, live:true}`) and true `usage`; the harness's
**fail-closed provenance gate** (§3) fails any candidate transcript that lacks
`provenance.live == true` or real token usage, so a hand-authored placeholder
counts as a FAIL instead of masquerading as evidence. Regenerate a real transcript
with `capture-apply-fix.sh` (needs the `ant` CLI: an `ant auth login` profile or `ANTHROPIC_API_KEY`);
refresh its judge field with `eval/judge/run-judge.sh`, which stamps its own
liveness provenance.

### Add a fixture

Create `fixtures/apply-fix/<new-archetype>/` with `start/`, `golden/`, `plan.md`,
`probe.sh`, `meta.json`, and one `captured/<model>.json` per ladder model (+ an
optional `captured/_bad.json`). Generate the `captured/<model>.json` transcripts
with `eval/capture-apply-fix.sh` rather than hand-writing them — the provenance
gate rejects captures without a live marker. Cover a new *edit shape*, not another
instance of one you already have. The harness auto-discovers it and adds it to
every section and the scorecard.

---

## Files

| Path | Role |
|---|---|
| `eval/eval-apply-fix.sh` | The deterministic harness (§1). |
| `eval/capture-apply-fix.sh` | Live producer: generates `captured/<model>.json` transcripts with provenance. |
| `eval/judge/run-judge.sh` | The LLM-as-a-judge runner (§2). |
| `eval/judge/apply-fix-rubric.md` | The judge's scoring rubric. |
| `eval/seed-eval-vault.sh` | One-time FAKE-secret upload to Vault (`--seed-vault`). |
| `eval/model-pricing.json` | Per-model token prices (from the `claude-api` skill). |
| `eval/fixtures/apply-fix/` | The test corpus. |
| `eval/scorecard.html` | Generated visual scorecard. |
