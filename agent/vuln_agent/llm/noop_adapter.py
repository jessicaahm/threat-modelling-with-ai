"""--no-llm mode: no triage, no network, no key. The CI default."""

from __future__ import annotations

from ..model import Finding
from .base import TriageAdapter, TriageReport


class NoopAdapter(TriageAdapter):
    def triage(self, findings: list[Finding], verdict: dict) -> TriageReport:
        return TriageReport(
            summary="Triage disabled (--no-llm). The verdict above is "
            "deterministic and final; see findings.json for details.",
            items=[],
        )
