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