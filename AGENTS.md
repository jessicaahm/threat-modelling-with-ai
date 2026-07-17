# Repository Guidelines

## Project Structure & Module Organization

This repository is a Bash-based DevSecOps and agent-workflow prototype. Operational scripts live in `script/`; keep reusable entry points there and name them with lowercase kebab-case (for example, `radar-precommit.sh`). Deterministic security checks live in `eval/`. Development-container setup is under `.devcontainer/`, CI is defined in `.github/workflows/devsecops.yml`, and Vault Radar policy is split between `.pre-commit-config.yaml` and `.hashicorp/vault-radar/config.json`. Agent definitions and permissions are under `.claude/`. Update `README.md` when setup, credential flow, or security controls change.

## Build, Test, and Development Commands

There is no compiled build. Use the dev container for pinned tools and consistent hooks.

- `bash script/devcontainer-postcreate.sh` installs the pre-commit hook and shell startup integration.
- `./script/validate-commits.sh` verifies or securely fetches the local Vault Radar license.
- `pre-commit run --all-files` runs the fail-closed secret scan against the repository.
- `bash eval/eval-radar.sh` exercises Radar detection and enforcement in a disposable Git repository.
- `semgrep scan --config=p/security-audit --config=p/dockerfile --error --metrics=off` mirrors CI SAST.
- `trivy fs --scanners vuln --severity HIGH,CRITICAL --exit-code 1 .` checks dependencies; `trivy config --severity HIGH,CRITICAL --exit-code 1 .` checks configuration.

## Coding Style & Naming Conventions

Write Bash with two-space indentation, quoted expansions, and explicit error handling. Executable scripts should use `#!/usr/bin/env bash`; prefer `set -euo pipefail` for straightforward programs and document deliberate exceptions. Use `UPPER_SNAKE_CASE` for constants/environment variables and lowercase names for locals and functions. Run `bash -n script/*.sh eval/*.sh` before submitting. Preserve pinned tool versions and action commit SHAs.

## Testing Guidelines

Add deterministic, non-secret fixtures to `eval/`; never use live credentials in tests. Name evaluation scripts `eval-<feature>.sh`, return nonzero on failure, and isolate mutations in `mktemp` directories. For security-control changes, test both successful detection and fail-closed behavior when required configuration or tools are absent.

## Commit & Pull Request Guidelines

Recent commits use concise, imperative subjects such as `Add reused-reflection detection` and `Fix reflection PR-comment posting`. Keep each commit focused. Pull requests should explain the security impact, list validation commands run, link the relevant issue, and include logs or screenshots only when they clarify behavior. All required SAST, SCA, and secret-scanning checks must pass; do not bypass hooks except for a documented false positive. Never paste license keys, tokens, or Vault values into commits, issues, logs, or review comments.
