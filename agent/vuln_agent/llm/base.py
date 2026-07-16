"""Triage adapter protocol and output validation.

The LLM layer NEVER changes the verdict: adapters take the already-final
findings and verdict and return an explanation. Scanned repos are untrusted
input -- finding messages flow into the prompt, so adapters must frame them
as data, and every adapter's output is schema-validated here before use.
Invalid output degrades to "no triage", it never degrades the verdict.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass

from ..model import Finding, is_valid_severity


class TriageError(Exception):
    """Triage unavailable/invalid -- report and continue, verdict stands."""


@dataclass
class TriageItem:
    fingerprint: str
    priority: int          # 1 = fix first
    why_it_matters: str
    how_to_fix: str


@dataclass
class TriageReport:
    summary: str
    items: list[TriageItem]


class TriageAdapter(ABC):
    @abstractmethod
    def triage(self, findings: list[Finding], verdict: dict) -> TriageReport:
        """Return a validated TriageReport, or raise TriageError."""


def validate_triage_dict(data: dict, findings: list[Finding]) -> TriageReport:
    """Validate raw LLM output against the report schema. Fail closed."""
    known = {f.fingerprint for f in findings}
    if not isinstance(data, dict) or not isinstance(data.get("summary"), str):
        raise TriageError("triage output missing 'summary' string")
    raw_items = data.get("items")
    if not isinstance(raw_items, list):
        raise TriageError("triage output missing 'items' list")
    items: list[TriageItem] = []
    for it in raw_items:
        if not isinstance(it, dict):
            raise TriageError("triage item is not an object")
        fp = it.get("fingerprint")
        if fp not in known:
            # The model may not invent findings -- only rank real ones.
            raise TriageError(f"triage referenced unknown finding {fp!r}")
        if not isinstance(it.get("priority"), int):
            raise TriageError("triage item priority is not an integer")
        items.append(
            TriageItem(
                fingerprint=str(fp),
                priority=int(it["priority"]),
                why_it_matters=str(it.get("why_it_matters", "")),
                how_to_fix=str(it.get("how_to_fix", "")),
            )
        )
    return TriageReport(summary=data["summary"], items=sorted(items, key=lambda i: i.priority))
