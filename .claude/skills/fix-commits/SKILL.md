---
name: fix-commits
description: Pre-commit readiness check — ensures the Vault Radar license file exists in .devcontainer, fetching it from Vault (namespace admin, mount tmai, secret radar) if missing without ever exposing the secret to AI context; then ensures the work lands on a feature branch (creating featureNN-<slug> when on main/master), commits and pushes once the user approves, and finishes with a reflection subagent that reviews the committed code and posts its suggestions as PR comments.
---

# Fix commits

Get the repo ready to commit: the Vault Radar license must be in place so the
pre-commit secret scan can run (the hook fails closed and blocks the commit when
the file is absent), and the work must land on a feature branch rather than the
protected `main`.

## Steps

### 1. Check the license

Run the helper script from the repo root:

```bash
./script/validate-commits.sh
```

The script does all license-file handling internally and prints status only — it
never outputs the license value.

### 2. Interpret the exit code

- **0** — license file present (already existed, or was just fetched from
  Vault). The Radar scan will run on commit. Continue to step 3.
- **2** — not logged in to Vault (or Vault unreachable), so the license
  cannot be fetched. **Stop the skill here.** Give the user the login
  command, tell them to re-run `/fix-commits` once they are logged in, and
  end the turn. Do not proceed to step 3, do not re-run the script hoping
  the state changed, and do not attempt any other route to the license —
  nothing further can succeed until they log in.

  They must run the login themselves via the **userpass** auth method
  (never type or ask for their password in chat — it would enter AI
  context). Tell them to type this in the prompt, where the `!` prefix
  runs it interactively in this session and Vault prompts for the password
  securely (no echo):

  ```
  ! VAULT_ADDR=https://vault-cluster-public-vault-289b32ee.99820ad2.z1.hashicorp.cloud:8200 VAULT_NAMESPACE=admin vault login -method=userpass username=<their-username>
  ```

  Substitute their actual Vault username for `<their-username>`. Use the
  `VAULT_ADDR`/`VAULT_NAMESPACE` values printed by the script if they
  differ. Remind them NOT to pass `password=...` on the command line (it
  would be captured in shell history and this session's output) — let
  Vault prompt for it.
- **3** — logged in but the fetch failed (missing policy rights, wrong
  field name, empty secret). Relay the script's error message verbatim.
  A common cause is a userpass account that isn't bound to the `tmai`
  policy — the login succeeds but the token can't read `tmai/radar`.
  **Stop the skill here** — do not proceed to step 3.

### 3. Ensure a feature branch

Only reached when step 1 exited 0.

Read the current branch:

```bash
git rev-parse --abbrev-ref HEAD
```

If it is anything other than `main` or `master`, keep it — the user is already on
a feature branch. Go to step 4.

If it is `main` or `master` (or `HEAD`, meaning detached), create a feature branch:

1. Pick the number. List every branch, local and remote, and find the highest
   number already used by a `feature<NN>` branch:

   ```bash
   git branch -a --format='%(refname:short)'
   ```

   Match names against `feature([0-9]+)`, take the highest, add 1, and zero-pad
   to two digits. No matches at all → `01`. If the name you land on already
   exists, keep incrementing until one is free.

2. Derive `<slug>` from the pending changes (`git status --short` and
   `git diff --stat`): kebab-case, roughly 2–4 words, describing what changed.

3. Create and switch to it:

   ```bash
   git switch -c feature<NN>-<slug>
   ```

   Uncommitted changes carry over to the new branch automatically — do not stash.

Report the branch name you created.

### 4. Ask before committing, then commit and push

If the working tree is clean (`git status --porcelain` prints nothing), say so
and stop — there is nothing to commit. Report the branch either way.

Otherwise, use **AskUserQuestion** to get explicit approval before anything is
committed. Show the branch name and the files that would be staged, and offer
"commit and push" against "stop here, I'll commit myself".

Only on approval:

```bash
git add <the intended paths>
git commit    # the Vault Radar hook runs here
git push -u origin <branch>
```

End the commit message with the attribution trailer, so AI-assisted commits stay
auditable (README §8):

```
Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

If the Radar hook blocks the commit, relay its output verbatim, do not push, and
stop. The scan found something — that is the hook working, not a problem to route
around.

### 5. Reflect on the committed code

Only reached after a successful commit **and** push in step 4. Skip this step
when the tree was clean, the user declined, or the Radar hook blocked the commit.

The orchestrator, not the reflection agent, collects the review context:

```bash
branch=$(git rev-parse --abbrev-ref HEAD)
head_sha=$(git rev-parse HEAD)
repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
git diff main...HEAD             # fall back to: git show HEAD
gh pr view --json number,url,headRefOid,headRefName
gh pr view <number> --json comments
```

Treat GitHub authentication or a missing PR as a non-fatal reason to skip comment
reuse/posting; the local diff review still runs. From the PR comments, select the
newest body beginning with `Reflection on ` whose header SHA is a prefix of the
full current HEAD. Pass that match as **existing reflection**, or `none`; never
pass an older reflection as reusable context.

Launch the read-only `reflection` subagent with `subagent_type: reflection`.
Supply the branch, full HEAD SHA, literal diff, PR number/URL (or `none`), and
matching existing reflection body/URL (or `none`). The agent has only
Read/Grep/Glob: it returns findings and, for a fresh review with a PR, literal
proposed comment text. It cannot run Git, access credentials, edit files, or
post externally.

If a matching reflection was reused, do not post. Otherwise, when the agent
returned a proposed comment, use **AskUserQuestion** to show the exact comment
and ask whether to post it. Approval covers that comment, PR, and HEAD only.
On approval, feed the literal body over stdin with a quoted heredoc:

```bash
script/post-reflection-comment.sh "$repo" "$pr_number" "$head_sha" <<'REFLECTION'
<the exact approved proposed comment>
REFLECTION
```

The helper fails closed unless the authenticated repository, open PR, local
HEAD, PR head, comment header, and supplied SHA all match. If approval is
declined or posting fails, leave GitHub unchanged and return the findings in
chat. Never create a PR or issue as a fallback.

Relay the findings as a short prioritized list, preserving each
`[blocking-this-diff]` or `[follow-up]` tag. Do not apply them automatically.
### 6. Optionally remediate the findings

Only offered after step 5 produced findings. This step **edits code** and is
opt-in — use **AskUserQuestion** to ask whether to remediate at all, and which
scope: all findings, only the `[blocking-this-diff]` ones, or none. Do not run it
automatically.

On approval, take the reflection agent's structured output and **split it into
individual findings** — one item per tagged suggestion (tag, one-sentence
suggestion, `file:line`, why). Then run each finding through a **plan → approve →
apply** cycle so the user sees and approves every change before it touches a file.
The plan and the write are done by **two different agents**: the `remediation`
planner has **no edit tools** (read-only is structural, not a promise), and the
separate `apply-fix` writer performs the edit only after approval.

**6a. Plan.** For each in-scope finding, launch a `remediation` subagent
(defined in `.claude/agents/remediation.md`, runs on Sonnet) via the Agent tool
with `subagent_type: remediation`, passing that **one** finding:

```
tag: [blocking-this-diff]
suggestion: <the one-sentence suggestion>
location: <file:line>
why: <the brief rationale>
```

The `remediation` planner has no Edit/Write tools, so it **cannot** modify the
tree — it returns a proposal only: the file(s) it would change, the ordered steps
of the edit, and why. Because the planner is read-only by construction (not just
by instruction), plan passes cannot race and may all run in parallel — unlike the
apply passes in 6c, which must serialize edits that touch the same file.

**6b. Approve — batched, still per finding.** Relay the returned plans to the
user and gather approvals with **AskUserQuestion**, but *batch* them: put one
question per finding (each showing its file changed, steps, and why, with
approve / skip options) into a single AskUserQuestion call, using as few calls as
the tool's per-call question limit allows instead of one call per finding. Every
finding still gets its own approve/skip gate, and the answers map back
one-to-one to individual plans; never apply a plan the user has not approved.

**6c. Apply.** For each approved plan, launch an `apply-fix` subagent (defined in
`.claude/agents/apply-fix.md`, runs on Sonnet) via the Agent tool with
`subagent_type: apply-fix`, passing the same finding **plus the approved plan
text** so the writer applies exactly what was approved:

```
tag: [blocking-this-diff]
suggestion: <the one-sentence suggestion>
location: <file:line>
why: <the brief rationale>
approved plan: <the plan text the user approved in 6b>
```

Launch one `apply-fix` subagent per approved finding — each applies exactly its
assigned plan and nothing else. They may run in parallel since each edits an
independent finding; if two findings touch the same file, run those sequentially
to avoid conflicting edits. The `apply-fix` agents have Edit but no Bash/Write; they edit code only
— they never
commit, push, or touch secrets.

After each writer returns, the orchestrator runs the cheap executable checks named
in the approved plan (at minimum, `bash -n` for every changed shell script). If a
check fails, report it and leave the edit uncommitted; never let the writer gain
Bash merely to run verification.

When they finish, aggregate their one-line reports and show the user which
findings were applied, skipped (declined at 6b), or judged false positives. The
edits are now in the working tree, uncommitted — tell the user to re-run
`/fix-commits` to scan and commit them, which closes the loop.

## Hard rules

- NEVER read, cat, echo, or otherwise display the license file or its
  contents — `.claude/settings.json` deny rules and a PreToolUse hook block
  this, and any Bash command mentioning the license filename will be denied.
  Interact with the file only through `./script/validate-commits.sh`.
- NEVER run `vault kv get` against the `tmai` mount directly; only the
  helper script may do that (it redirects the value straight to the file).
- NEVER commit or push without the user's approval from step 4. Approval covers
  that one commit — re-ask on the next run.
- NEVER bypass the Radar scan: no `git commit --no-verify`, no `-n`, no
  disabling or editing the hook. A blocked commit gets reported, not worked
  around.
- NEVER commit or push to `main` or `master`, and never force-push.
- NEVER stage `.devcontainer/.vault-radar-license`. It is gitignored; keep it
  that way and stage explicit paths rather than reaching for `git add -A` when
  the tree is dirty in ways you have not looked at.
- The reflection agent (step 5) only proposes feedback. After separate approval,
  the orchestrator posts it as a comment on an existing
  PR, and only when `gh` is authenticated. It must never create a PR, file
  issues, edit code, or include a secret value in a comment — detectors and
  `file:line` only.
- The step 6 remediation flow is opt-in and splits into two agents, each scoped
  to exactly one reflection finding: the `remediation` planner is **read-only**
  (only Read/Grep/Glob — it only proposes a plan), and the `apply-fix` writer
  edits source files only after the user approves that plan. Neither commits,
  stages, pushes, bypasses the Radar hook, touches secrets, or reads the
  license/`tmai` mount. The applied edits land uncommitted; committing them is a
  fresh `/fix-commits` run.
