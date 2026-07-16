"""Semgrep SAST scan.

Defaults to the vendored ruleset in agent/semgrep-rules/ so scans are
offline-deterministic under the egress firewall and the eval's pinned rule
IDs stay stable; `semgrep_rules` in vuln-agent.config.json can point at a
registry ruleset (e.g. "auto") when broader coverage is wanted.

Severity mapping (pinned by eval/eval-scanners.sh):
  ERROR -> high, WARNING -> medium, INFO -> low
"""

from __future__ import annotations

import json
from pathlib import Path

from ..config import AGENT_ROOT
from ..model import Finding
from .base import PreconditionError, Scanner

DEFAULT_RULES = AGENT_ROOT / "agent" / "semgrep-rules"

SEVERITY_MAP = {"ERROR": "high", "WARNING": "medium", "INFO": "low"}


class SemgrepScanner(Scanner):
    name = "semgrep"

    def __init__(self, rules: str | None = None) -> None:
        self.rules = rules or str(DEFAULT_RULES)

    def check_preconditions(self, target: Path) -> None:
        if not self.binary_on_path("semgrep"):
            raise PreconditionError("'semgrep' not found on PATH -- cannot run SAST.")
        rules_path = Path(self.rules)
        # A local rules path must exist and be non-empty; registry refs
        # ("auto", "p/...") are left to semgrep itself, which errors loudly.
        if not self.rules.startswith(("p/", "r/")) and self.rules != "auto":
            if not rules_path.exists() or (
                rules_path.is_dir() and not any(rules_path.iterdir())
            ):
                raise PreconditionError(
                    f"semgrep rules missing or empty ({rules_path}). Refusing to "
                    "scan with no rules rather than reporting a false CLEAN."
                )

    def run(self, target: Path, workdir: Path) -> list[Finding]:
        proc = self.run_tool(
            [
                "semgrep", "scan",
                "--config", self.rules,
                "--json",
                "--quiet",
                "--metrics=off",
                "--disable-version-check",
                str(target),
            ],
            # 0 = clean, 1 = findings (with default --error behavior off,
            # semgrep exits 0 even with findings; accept 1 defensively).
            ok_returncodes=(0, 1),
        )
        (workdir / "semgrep-raw.json").write_text(proc.stdout)
        data = json.loads(proc.stdout)
        findings: list[Finding] = []
        for r in data.get("results", []):
            native = str(r.get("extra", {}).get("severity", "WARNING")).upper()
            path = r.get("path", "")
            try:
                path = str(Path(path).resolve().relative_to(target.resolve()))
            except ValueError:
                pass
            findings.append(
                Finding(
                    scanner="semgrep",
                    rule_id=str(r.get("check_id", "unknown-rule")),
                    severity=SEVERITY_MAP.get(native, "medium"),
                    message=str(r.get("extra", {}).get("message", "")).strip(),
                    file=str(path),
                    line=int(r.get("start", {}).get("line", 0)),
                )
            )
        return findings
