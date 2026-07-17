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
entirely when the tree was clean, the user declined the commit, or the Radar
hook blocked it.

Launch the `reflection` subagent (defined in `.claude/agents/reflection.md`,
runs on Sonnet) via the Agent tool with `subagent_type: reflection`. In the
prompt, give it the current branch name and tell it to review the work just
pushed (`git diff main...HEAD`, falling back to `git show HEAD` if `main` is
unavailable) and post its prioritized improvement suggestions.

The agent posts its own findings **as a comment on the branch's PR** via
`gh pr comment` — it handles the `gh auth status` preflight, finds the PR, and
falls back to returning the suggestions in its message when the CLI is
unauthenticated or no PR exists. The agent never edits code, never creates a PR,
and never files issues; its only state-changing action is the PR comment.

When it finishes, relay its suggestions (and whether they were posted to the PR
or skipped) to the user as a short prioritized list. Each suggestion is tagged
`[blocking-this-diff]` or `[follow-up]` — keep those tags when relaying. Do
**not** apply any of them automatically — if the user wants one applied, that is
a new edit followed by another `/fix-commits` run, which closes the reflection
loop. The reflection pass never blocks or undoes the push that already happened.

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
- The reflection agent (step 5) posts feedback only as a comment on an existing
  PR, and only when `gh` is authenticated. It must never create a PR, file
  issues, edit code, or include a secret value in a comment — detectors and
  `file:line` only.
