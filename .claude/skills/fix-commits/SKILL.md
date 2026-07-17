---
name: fix-commits
description: Pre-commit readiness check — ensures the Vault Radar license file exists in .devcontainer, fetching it from Vault (namespace admin, mount tmai, secret radar) if missing without ever exposing the secret to AI context; then ensures the work lands on a feature branch (creating featureNN-<slug> when on main/master), commits and pushes once the user approves, and finishes with a read-only reflector subagent that suggests improvements to the committed code.
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

Launch the `reflector` subagent (defined in `.claude/agents/reflector.md`,
runs on Sonnet, read-only) via the Agent tool with `subagent_type: reflector`.
In the prompt, give it the current branch name and tell it to review the work
just pushed (`git diff main...HEAD`, falling back to `git show HEAD` if `main`
is unavailable) and return prioritized improvement suggestions.

When it finishes, relay its suggestions to the user as a short prioritized
list. Each suggestion is tagged `[blocking-this-diff]` or `[follow-up]` — keep
those tags when relaying, and preserve them for step 6. Do **not** apply any of
them automatically — if the user wants one applied, that is a new edit followed
by another `/fix-commits` run, which closes the reflection loop. The reflector
never blocks or undoes the push that already happened.

### 6. Optionally post the reflection to GitHub

The reflector is read-only and never touches GitHub. **You** (the skill) do any
posting, and only after the user explicitly approves this run — same gate as the
commit in step 4. The default is relay-only: if the user does not choose to
post, stop here and nothing goes to GitHub.

After relaying, use **AskUserQuestion** to offer:

- **Relay only** (default) — do nothing further.
- **Post to the PR** — post the suggestions as review comments on the branch's
  PR (peer-review feedback belongs on the diff, not in the issue tracker).
- **File follow-up issues** — only for the `[follow-up]`-tagged items.

Preflight before any write: run `gh auth status`. If it is not authenticated or
lacks write scope, skip posting, tell the user, and keep the relayed list — this
never blocks or errors out.

**Post to the PR.** Find the branch's PR with `gh pr view --json number,url`
(or `gh pr list --head <branch>`). If a PR exists, post the suggestions with
`gh pr comment <number> --body ...` (prefer line-anchored `gh pr review
--comment` where a specific hunk applies). If **no** PR exists, tell the user to
open one first and stop — do **not** fall back to filing issues for diff-level
feedback.

**File follow-up issues** (only the `[follow-up]` items). Ensure the label
exists (`gh label create reflection --force` or create-if-missing). Before
filing, dedup against open reflection issues:
`gh issue list --label reflection --search "<file:line or key phrase>"` — skip
anything already tracked. Then `gh issue create --label reflection --title ...
--body ...`, and include the commit SHA and branch as a backlink in each body so
the issue traces to the diff that prompted it.

Never post autonomously. Approval covers only this run — re-ask on the next one.

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
- NEVER post reflector feedback to GitHub (PR comments or issues) without the
  user's explicit approval from step 6. The reflector itself is read-only and
  must never write to GitHub; only the skill posts, and only for the run the
  user approved.
