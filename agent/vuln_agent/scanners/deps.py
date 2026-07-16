"""Dependency / SCA scan: known CVEs in third-party packages.

Trivy is the primary tool (one scanner, all ecosystems). If Trivy is absent
but the target contains dependency manifests, that is a PRECONDITION failure
-- a missing tool must never silently turn into a CLEAN verdict. A target
with no manifests at all legitimately yields no findings.

Severity mapping: Trivy's CRITICAL/HIGH/MEDIUM/LOW/UNKNOWN map 1:1 onto the
common scale (UNKNOWN -> info), pinned by eval/eval-scanners.sh.
"""

from __future__ import annotations

import json
from pathlib import Path

from ..model import Finding
from .base import PreconditionError, Scanner

MANIFEST_GLOBS = (
    "requirements*.txt", "poetry.lock", "Pipfile.lock", "uv.lock",
    "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "package.json",
    "go.sum", "Cargo.lock", "Gemfile.lock", "pom.xml", "build.gradle*",
)

SEVERITY_MAP = {
    "CRITICAL": "critical", "HIGH": "high", "MEDIUM": "medium",
    "LOW": "low", "UNKNOWN": "info",
}


def _manifests(target: Path) -> list[Path]:
    found: list[Path] = []
    for pattern in MANIFEST_GLOBS:
        found.extend(p for p in target.rglob(pattern) if "node_modules" not in p.parts)
    return found


class DepsScanner(Scanner):
    name = "deps"

    def check_preconditions(self, target: Path) -> None:
        if self.binary_on_path("trivy"):
            return
        if _manifests(target):
            raise PreconditionError(
                "'trivy' not found on PATH but the target has dependency "
                "manifests -- refusing to skip SCA and report a false CLEAN. "
                "Install trivy (see .devcontainer/Dockerfile)."
            )
        # No tool and nothing to scan: allowed, run() will return [].

    def run(self, target: Path, workdir: Path) -> list[Finding]:
        if not self.binary_on_path("trivy"):
            return []  # preconditions proved there is nothing to scan
        proc = self.run_tool(
            [
                "trivy", "fs",
                "--scanners", "vuln",
                "--format", "json",
                "--quiet",
                str(target),
            ],
        )
        (workdir / "trivy-raw.json").write_text(proc.stdout)
        data = json.loads(proc.stdout)
        findings: list[Finding] = []
        for result in data.get("Results") or []:
            manifest = str(result.get("Target", ""))
            for vuln in result.get("Vulnerabilities") or []:
                fixed = vuln.get("FixedVersion") or "no fix released"
                findings.append(
                    Finding(
                        scanner="deps",
                        rule_id=str(vuln.get("VulnerabilityID", "unknown-cve")),
                        severity=SEVERITY_MAP.get(
                            str(vuln.get("Severity", "UNKNOWN")).upper(), "info"
                        ),
                        message=(
                            f"{vuln.get('PkgName')} {vuln.get('InstalledVersion')}: "
                            f"{str(vuln.get('Title') or vuln.get('Description') or '').strip()[:200]} "
                            f"(fixed in: {fixed})"
                        ),
                        file=manifest,
                        line=0,
                    )
                )
        return findings
