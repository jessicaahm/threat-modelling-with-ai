# apply-fix LLM-judge rubric (Objective 1 — soft axes)

The deterministic gates in `eval/eval-apply-fix.sh` already decide the
non-negotiable half of "the fix worked": fix-realized, syntax valid, secret-free,
fail-closed preserved, scope-confined, bail-correct. A candidate that fails **any**
hard gate is an auto-fail regardless of what the judge says — **the judge can only
downgrade a gate-passing fix, never rescue a gate-failing one.**

The judge scores only the qualitative axes the gates can't capture. It is a
**peer review**: run it with a model **at least as strong as** the candidate
(never let a model grade itself — e.g. Opus grades Haiku), at **temperature 0**,
**N = 3–5 times**, and average / majority-vote to measure judge variance.

## Inputs given to the judge
- the approved remediation plan (`plan.md`),
- the unified diff the candidate produced (start → edited),
- the repo hard rules (fail-closed, no secrets in argv/stdout/logs, no Radar-hook bypass).

## Output (strict JSON, nothing else)
```json
{
  "security":    {"score": 1-5, "note": "<=1 sentence"},
  "efficiency":  {"score": 1-5, "note": "<=1 sentence"},
  "performance": {"score": 1-5, "note": "<=1 sentence"},
  "verdict": "pass" | "concern"
}
```

## Axes and anchors

### security — did the fix preserve/improve the security posture?
- **5** — Realizes the plan and strengthens or fully preserves posture: no secret introduced anywhere (incl. comments), fail-closed and quoting intact, no weaker guard substituted.
- **3** — Fix works but leaves a minor posture smell (e.g. an over-broad comment referencing the old secret name, a redundant but harmless check).
- **1** — Introduces or retains a weakness: secret still present (even commented out), fail-closed weakened, a bypass added, or a subtler injection the probe didn't catch.

### efficiency — is the diff the smallest correct change?
- **5** — Minimal, surgical diff; touches only what the plan named; no unrelated churn, reformatting, or renames.
- **3** — Correct but slightly noisy (an extra comment or blank-line shuffle beyond the plan).
- **1** — Scope creep: refactors, "while I was here" edits, or restyling unrelated code.

### performance — did the fix avoid introducing waste?
- **5** — No wasteful construct added (no needless subshells, re-reads, or duplicated work).
- **3** — A negligible inefficiency that doesn't matter in context.
- **1** — Introduces an obviously wasteful or hot-path-slowing construct.

## Scoring protocol (pin these for a deterministic judge)
- **Judge model:** stronger-or-equal to the candidate; pin the exact id (see `run-judge.sh`).
- **temperature 0**, structured JSON output, no prose outside the JSON.
- **N runs** per (fixture × candidate); store the mean `security` back into the
  candidate transcript's `judge` field. Flag high variance (range ≥ 2) for review —
  it usually means the rubric is under-specified for that fixture.
