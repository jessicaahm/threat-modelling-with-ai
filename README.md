# What does this repo must do:
- [] Proof that this ./ai-secure-sdlc is using secure sdlc in the developer workflow to build agent.
  - [x] Get secrets, license key from Vault (see "Fetching the Vault Radar license" below)
  - [x] Set up .devcontainer
  - [x] Set up radar

## Fetching the Vault Radar license

The pre-commit Radar scan reads the license from `.devcontainer/.vault-radar-license`
(gitignored). The scan is **mandatory**: if the file is missing or empty, the hook
blocks the commit and tells you how to fix it. The primary way to fetch the license
is the `/validate-commits` skill (it runs `./script/validate-commits.sh`, which
writes the value straight from Vault into the file so it never enters AI chat
context). Fallback: fetch it manually in your own terminal:

```bash
export VAULT_ADDR="https://vault-cluster-public-vault-289b32ee.99820ad2.z1.hashicorp.cloud:8200"
export VAULT_NAMESPACE=admin
vault login   # if not already logged in

# If unsure of the field name, inspect the secret first: vault kv get -mount=tmai radar
vault kv get -mount=tmai -field=VAULT_RADAR_LICENSE radar > .devcontainer/.vault-radar-license
chmod 600 .devcontainer/.vault-radar-license
```

The hook in `.pre-commit-config.yaml` fails closed — a missing/empty license file
(or missing `vault-radar` CLI) blocks the commit with a message explaining how to
fix it. When present, it loads the file into the scan subprocess only — the license
is never exported in your interactive shell (where the AI assistant would inherit
it). `.claude/settings.json` additionally denies the assistant read access to
the file (Read deny rules + a PreToolUse hook blocking any Bash command referencing
it) and denies edits to `.pre-commit-config.yaml` so the hook can't be rewritten to
leak it via the allowlisted `pre-commit run`. Note these are harness-level controls,
not OS-level guarantees.

## Vault Radar VS Code extension connection

The `hashicorp.vault-radar` extension (installed via `.devcontainer/devcontainer.json`) has no
`settings.json` key for its Vault connection (address/namespace/token) -- that's entered once
through the extension's own "Add Vault Connection" dialog in the Activity Bar. After the
devcontainer starts (with `VAULT_USERNAME`/`VAULT_PASSWORD` set on the host so
`script/devcontainer-poststart.sh` can log in via userpass), run:

```bash
script/print-radar-ide-connection.sh
```

in your own terminal (don't paste its output back into an AI assistant) to get the address and
namespace to paste in, plus a reminder to read the token yourself from `~/.vault-token`.

## Vault Radar MCP server

`.mcp.json` configures the [Vault Radar MCP
server](https://developer.hashicorp.com/hcp/docs/vault-radar/mcp-server/deploy) as a direct stdio
binary. It needs `HCP_PROJECT_ID`, `HCP_CLIENT_ID`, and `HCP_CLIENT_SECRET` (an HCP service
principal with viewer role) in the environment. No secret is written into `.mcp.json`. Fetch them
into your shell before launching a client that uses the MCP server:

```bash
source script/fetch-vault-radar-mcp-creds.sh
```

This reads the three values from the same Vault secret as the Radar license (namespace `admin`,
mount `tmai`, secret `radar`, subkeys `HCP_PROJECT_ID`/`HCP_CLIENT_ID`/`HCP_CLIENT_SECRET`) and
exports them for the current session only — values are never printed. Start Claude Code (or
another MCP client) from that same shell so it inherits the exports. The binary version is pinned
in `.devcontainer/Dockerfile`.

## Terraform MCP server

`.mcp.json` also configures the [Terraform MCP
server](https://developer.hashicorp.com/terraform/mcp-server) as a direct stdio binary with the
public Registry and HCP Terraform toolsets. The binary is pinned and installed during the
devcontainer build; Docker is not required inside the container.

Terraform MCP authenticates to HCP Terraform with `TFE_TOKEN`. The Terraform CLI uses the same
token through `TF_TOKEN_app_terraform_io`, while `TF_CLOUD_ORGANIZATION` and `TF_WORKSPACE` select
the existing HCP Terraform target for the empty `cloud {}` block in `infrastructure/versions.tf`.
All three source values live in Vault KV-v2 at namespace `admin`, mount `tmai`, secret `terraform`:

- `TFE_TOKEN`
- `TF_CLOUD_ORGANIZATION`
- `TF_WORKSPACE`

For a memory-only manual session, log in to Vault and source the fetch script before starting the
MCP client:

```bash
vault login
source script/fetch-terraform-mcp-creds.sh
claude
```

The script exports the token under both client-specific names and never prints any value. Do not
put the token in `.mcp.json`, a prompt, shell history, or a tracked file. Destructive Terraform MCP
operations remain disabled because `ENABLE_TF_OPERATIONS` is not set. Claude hooks also deny direct
access to the runtime token file and Bash commands that name either token environment variable.

Example read-only prompt:

```text
Read TF_CLOUD_ORGANIZATION and TF_WORKSPACE from the environment. Use those values
with Terraform MCP to get the workspace details. Do not read or print TFE_TOKEN,
and do not create a run or make changes.
```

### Automatic MCP credential fetch on devcontainer startup (optional)

To skip the manual `source` steps, the devcontainer can fetch both MCP servers' credentials
automatically on every start using Vault **userpass** auth (non-interactive: credentials are passed
as arguments, not typed at a prompt):

1. Ensure you have a Vault userpass account with read-only access to `tmai/data/radar` and
   `tmai/data/terraform` in namespace `admin`.
2. On your **host** (not in the container), set `VAULT_USERNAME` and `VAULT_PASSWORD` in your shell
   profile or an untracked `.env` — `devcontainer.json`'s `remoteEnv` passes them through via
   `${localEnv:...}`.
3. On every container start, `postStartCommand` runs `script/devcontainer-poststart.sh`, which logs
   in via userpass and writes `~/.hcp-radar-env` and `~/.hcp-terraform-env` (mode 600, never printed,
   not in the repo). If `VAULT_USERNAME`/`VAULT_PASSWORD` aren't set, this step falls back to the
   manual sourced-script flows above.
4. `postCreateCommand` runs `script/devcontainer-postcreate.sh` once, which adds lines to
   `~/.zshrc`/`~/.bashrc` sourcing each runtime environment file if present — so every new shell
   (and anything launched from it, including Claude Code and the MCP subprocesses) picks up the
   variables automatically.

Trade-off: this keeps HCP credentials live in mode-600 files in the container for the whole session
(vs. the manual flow's momentary, per-shell exposure), and your Vault **password** sits in a host
env var/file long-term. Unlike an AppRole `secret_id`, this is a shared human credential rather than
a scoped machine identity — rotating your personal Vault password breaks this integration until you
update it here too, and anyone with that password has the same access this automation uses.

## DevSecOps checklist for the scanning agent

### 1. Secrets & Credential Management
- [x] Vault Radar pre-commit scan wired up (`.pre-commit-config.yaml`), fails closed when the license is missing so commits can't skip the scan
- [x] Pull secrets/license keys from Vault at runtime (no `.env` files committed, no hardcoded LLM API keys)
- [ ] Vault Radar also running in CI, not just pre-commit (pre-commit can be bypassed with `--no-verify`)
- [ ] Short-lived/rotated credentials for any scanning targets

### 2. Dev Environment Hardening
- [x] `.devcontainer` set up
- [ ] Confirm `init-firewall.sh` restricts egress to only what the agent needs (LLM API, Vault, package registries)
- [ ] Pin base image digest (not just tag) in `Dockerfile`

### 3. Secure Coding / SAST
- [ ] Add SAST (Semgrep, CodeQL) to pre-commit and CI
- [ ] Dependency scanning (`pip-audit`/`npm audit`/Snyk) for the agent's own dependencies
- [ ] Lockfile committed and pinned versions

### 4. Agent-Specific Controls
- [ ] Sandboxing: agent tool/function calls execute in an isolated environment, not directly on the host
- [ ] Approval-gated side effects for any destructive or state-changing action
- [ ] Auditability: log every tool call, prompt, and output with enough context to reconstruct decisions
- [ ] Structured output validation before using LLM output to drive control flow

### 5. AI Security Validation
- [ ] Evals covering prompt injection resilience (scan target responses fed back into context)
- [ ] Guardrails on tool scope so the agent can't exceed its declared scanning targets
- [ ] Telemetry on agent decisions (tools called, confidence, false-positive rate)
- [ ] Map findings/threat model against OWASP LLM Top 10 and MITRE ATLAS
- [ ] Red-team pass: prompt injection via scan target responses, out-of-scope target escalation

### 6. CI/CD Pipeline
- [ ] CI re-runs secret scan + SAST + dependency scan (not just pre-commit)
- [ ] Branch protection requiring these checks before merge
- [ ] Secrets/license keys pulled from Vault in pipeline, not plaintext env vars

### 7. Governance / Documentation
- [ ] Document the agent's declared scope/permissions (targets, tools)
- [ ] Incident response plan for the agent misfiring against an unintended target

### 8. AI Workflow in the Developer Workflow
This repo's own dev workflow uses an AI coding assistant (Claude Code, `.claude/`) — that workflow needs the same controls as the agent being built.
- [x] AI assistant permissions scoped explicitly (`.claude/settings.local.json` allowlist, currently just `pre-commit run *`)
- [x] No secrets/license keys ever pasted into AI chat context — Vault pull happens outside the assistant's visible context (manual fetch to a gitignored file; `.claude/settings.json` deny rules + PreToolUse hook block the assistant from reading it)
- [ ] Destructive/irreversible commands (force-push, `rm -rf`, `git reset --hard`) require explicit human confirmation, not auto-approved permissions
- [ ] AI-generated commits/PRs pass through the same pre-commit + CI gates as human-written code (no bypass for "the AI wrote it")
- [ ] Human review required before merging AI-authored or AI-assisted changes — no self-merge by the assistant
- [ ] AI-authored commits/PRs are attributable (co-author tag or similar) so changes are auditable after the fact
- [ ] Prompt/session transcripts retained or logged where feasible, for post-incident review of *why* an AI-driven change was made

### 8a. Reflection in the developer workflow

The workflow applies the **reflection** agentic pattern (generate → critique →
revise) using signals the repo already produces as critics:

- The **pre-commit Radar scan** and **CI SAST/SCA**
  (`.github/workflows/devsecops.yml`) are enforced critics.
- After a successful commit and push, the `/fix-commits` orchestrator collects
  the branch, exact HEAD, committed diff, PR identity, and any reusable
  reflection for that SHA.
- The `reflection` subagent is structurally read-only: it has only
  Read/Grep/Glob. It reviews the supplied context and returns tagged findings
  plus literal proposed PR-comment text; it cannot run Git or `gh`, edit files,
  access credentials, or post externally.
- A fresh comment is shown to the user for separate approval. Only then may the
  orchestrator invoke `script/post-reflection-comment.sh`, which fails closed
  unless the repository, open PR, local HEAD, PR head, and comment header still
  match the reviewed context.
- Reused comments are never posted again. If approval, authentication, or PR
  validation fails, the findings remain visible in chat and GitHub is unchanged.
- Findings and comments reference detector names and `file:line` only, never
  secret values.
### 9. GitHub Best Practices
> Note: This is not allowed in a private repo
- [x] Add a branch protection rule on `main` (require PR review before merge, no direct pushes)
- [x] Require status checks (CI, SAST, secret scan) to pass before merge
- [x] Restrict force-pushes and branch deletion on protected branches
