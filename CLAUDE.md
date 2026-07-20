# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is
A secure-SDLC demo repo: it proves out building an AI security-scanning agent while following secure practices (Vault-sourced secrets, a fail-closed Vault Radar pre-commit gate, hardened devcontainer, Claude Code reflection/remediation agents). Code today is **Bash** (`script/`, `eval/`); the future Python agent (`agent/vuln_agent`) does not exist yet. No dependency manifests exist yet. Shell is zsh.

## Commands (non-standard)
- `pre-commit run` — Vault Radar secret scan (via `script/radar-precommit.sh`); the only allowlisted Bash command.
- `./script/validate-commits.sh` — license readiness + branch/commit flow (used by the `/fix-commits` skill).
- `source script/fetch-vault-radar-mcp-creds.sh` — load MCP creds into the shell.
- `script/fetch-openai-key.sh` — fetch OpenAI key.
- `eval/eval-radar.sh` — deterministic Radar eval.
- CI (`.github/workflows/devsecops.yml`, on PRs to `main`): Semgrep SAST + Trivy SCA (pinned). Secret scanning is done by the Vault Radar GitHub App, not in-workflow.

## Hard rules
- Scripts fail **closed**: a missing license/config/binary or a scan error must block, never silently skip. Preserve each script's existing `set` flags and quoting; run `bash -n` after editing shell. Don't invent new build tooling.
- Vault is the only secret source: retrieve every secret from Vault (namespace `admin`, mount `tmai`) via the helper scripts — never hardcode, inline, or fetch secrets from anywhere else.
- Only tools read secrets: secrets are read exclusively by tooling (`script/*` helpers, MCP servers), never by Claude directly. A secret must never be visible in AI context, echoed to the terminal, passed in argv, or persisted in the shell — except the sanctioned, session-scoped `HCP_PROJECT_ID`/`HCP_CLIENT_ID`/`HCP_CLIENT_SECRET` exports performed by sourcing `script/fetch-vault-radar-mcp-creds.sh` to hand credentials to the `vault-radar` MCP server (see `## Vault / MCP` below); no other exporting/writing of secret values into the environment or files beyond the guarded, gitignored credential files is permitted.
- Never print, echo, log, or put secrets in argv or AI context. Radar findings reference detector + `file:line:col` only — never secret values.
- Never bypass the Radar hook: no `git commit --no-verify` / `-n`. `.pre-commit-config.yaml` is edit-denied.
- Two guarded, gitignored secret files are read/edit-denied to the assistant: `.devcontainer/.vault-radar-license` and `.devcontainer/.openai-api-key`. Interact only via the helper scripts. A hook denies any Bash command whose text mentions those filenames.
- Deploy commands (`terraform apply`, `kubectl apply/delete/rollout`, `docker push`, `helm upgrade/install`, `make deploy`, `deploy.sh`, …) are hook-denied unless an ExitPlanMode plan was approved within the last 4 hours.
- Branches: never commit/push to `main`/`master`; use `featureNN-<slug>`.
- AI-authored commits end with the trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## Vault / MCP
- `VAULT_ADDR=https://vault-cluster-public-vault-289b32ee.99820ad2.z1.hashicorp.cloud:8200`, namespace `admin`, mount `tmai`, secrets `radar` and `openai`, userpass login.
- The `vault-radar` MCP server needs `HCP_PROJECT_ID` / `HCP_CLIENT_ID` / `HCP_CLIENT_SECRET` in the shell env before launch (no secrets live in `.mcp.json`).

## Environment
- `.claude/settings.json` sets `defaultMode: plan` and `TZ=Asia/Singapore`.
