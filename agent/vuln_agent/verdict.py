"""Stage 3: the deterministic verdict. No LLM is involved here, ever.

Per-scanner max severity is compared to that scanner's fail_severity from
vuln-agent.config.json. This is what CI gates on and what the exit code
reflects; the LLM triage layer is additive commentary on top.
"""

from __future__ import annotations

from .model import Finding, severity_rank


def compute_verdict(findings: list[Finding], config: dict) -> dict:
    per_scanner: dict[str, dict] = {}
    vulnerable = False
    for scanner in config["scanners"]:
        threshold = config["fail_severity"][scanner]
        scanner_findings = [f for f in findings if f.scanner == scanner]
        blocking = [
            f for f in scanner_findings
            if severity_rank(f.severity) >= severity_rank(threshold)
        ]
        max_severity = (
            max((f.severity for f in scanner_findings), key=severity_rank)
            if scanner_findings else None
        )
        per_scanner[scanner] = {
            "findings": len(scanner_findings),
            "max_severity": max_severity,
            "fail_severity": threshold,
            "blocking": len(blocking),
        }
        if blocking:
            vulnerable = True
    return {
        "verdict": "VULNERABLE" if vulnerable else "CLEAN",
        "scanners": per_scanner,
        "total_findings": len(findings),
    }
