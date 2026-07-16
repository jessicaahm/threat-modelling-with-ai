"""Common finding model shared by every scanner.

Severity is normalized to Vault Radar's scale (info < low < medium < high <
critical) because that is the scale the repo's existing enforcement config
(.hashicorp/vault-radar/config.json) already speaks. Each scanner wrapper owns
the mapping from its tool's native scale; the mapping is pinned by
eval/eval-scanners.sh so drift is loud.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field, asdict

SEVERITIES = ("info", "low", "medium", "high", "critical")


def severity_rank(severity: str) -> int:
    return SEVERITIES.index(severity)


def is_valid_severity(severity: str) -> bool:
    return severity in SEVERITIES


@dataclass
class Finding:
    scanner: str          # radar | semgrep | deps
    rule_id: str          # detector name, semgrep check_id, or CVE id
    severity: str         # normalized: info|low|medium|high|critical
    message: str          # tool's finding text -- never a secret value
    file: str             # path relative to the scan target
    line: int = 0
    fingerprint: str = field(default="", compare=False)

    def __post_init__(self) -> None:
        if not is_valid_severity(self.severity):
            raise ValueError(f"invalid severity {self.severity!r} from {self.scanner}")
        if not self.fingerprint:
            raw = f"{self.scanner}|{self.rule_id}|{self.file}|{self.line}"
            self.fingerprint = hashlib.sha256(raw.encode()).hexdigest()[:16]

    def to_dict(self) -> dict:
        return asdict(self)
