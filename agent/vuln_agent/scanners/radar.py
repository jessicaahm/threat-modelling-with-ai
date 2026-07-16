"""Vault Radar secrets scan of an arbitrary folder.

Wraps `vault-radar scan folder -p <target> -o <out> -f json`. The license is
read from the gitignored file and injected into the subprocess environment
only -- it is never logged, never written to the run directory, and Radar's
findings name detector and file:line only, not secret values (same contract
as script/radar-precommit.sh).
"""

from __future__ import annotations

import json
import os
from pathlib import Path

from ..config import AGENT_ROOT
from ..model import Finding, is_valid_severity
from .base import PreconditionError, Scanner


class RadarScanner(Scanner):
    name = "radar"

    def __init__(self) -> None:
        self.license_file = Path(
            os.environ.get("RADAR_LICENSE_FILE")
            or AGENT_ROOT / ".devcontainer" / ".vault-radar-license"
        )

    def check_preconditions(self, target: Path) -> None:
        if not self.binary_on_path("vault-radar"):
            raise PreconditionError(
                "'vault-radar' not found on PATH -- cannot scan for secrets."
            )
        if not self.license_file.is_file() or self.license_file.stat().st_size == 0:
            raise PreconditionError(
                f"Vault Radar license missing or empty ({self.license_file}). "
                "Fix: run /fix-commits in Claude Code, or ./script/validate-commits.sh"
            )

    def run(self, target: Path, workdir: Path) -> list[Finding]:
        outfile = workdir / "radar-raw.json"
        env = os.environ.copy()
        env["VAULT_RADAR_LICENSE"] = self.license_file.read_text().strip()
        self.run_tool(
            [
                "vault-radar", "scan", "folder",
                "-p", str(target),
                "-o", str(outfile),
                "-f", "json",
                "--disable-ui",
                "--skip-activeness",
            ],
            env=env,
        )
        return self._parse(outfile, target)

    @staticmethod
    def _parse(outfile: Path, target: Path) -> list[Finding]:
        if not outfile.is_file():
            return []
        findings: list[Finding] = []
        # Radar's json format is one JSON object per line (NDJSON).
        for line in outfile.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            severity = str(row.get("severity", "")).lower()
            if not is_valid_severity(severity):
                severity = "medium"  # unknown scale drift: never drop a finding
            path = row.get("path") or row.get("uri") or ""
            try:
                path = str(Path(path).resolve().relative_to(target.resolve()))
            except ValueError:
                pass
            findings.append(
                Finding(
                    scanner="radar",
                    rule_id=str(row.get("category") or row.get("description") or "secret"),
                    severity=severity,
                    message=str(row.get("description") or "secret detected"),
                    file=str(path),
                    line=int(row.get("line") or row.get("line_number") or 0),
                )
            )
        return findings
