"""vuln-agent CLI.

  python -m vuln_agent scan <TARGET_PATH> [--scanners radar,semgrep,deps]
                            [--config FILE] [--output DIR]
                            [--format text|json] [--triage | --no-llm]

Exit codes (contract used by CI and the eval harness):
  0  CLEAN      -- no finding at or above any scanner's fail_severity
  1  VULNERABLE -- at least one blocking finding
  2  BLOCKED    -- precondition/config failure; refused to scan (fail closed)
  3  scanner runtime error

The verdict is computed before and independently of any LLM call; a triage
failure prints a warning and leaves the exit code untouched.
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path

from .config import ConfigError, load_config
from .model import Finding
from .scanners.base import PreconditionError, ScanError
from .scanners.deps import DepsScanner
from .scanners.radar import RadarScanner
from .scanners.semgrep import SemgrepScanner
from .verdict import compute_verdict

EXIT_CLEAN, EXIT_VULNERABLE, EXIT_BLOCKED, EXIT_SCAN_ERROR = 0, 1, 2, 3


def _build_scanners(config: dict, names: list[str]) -> list:
    registry = {
        "radar": lambda: RadarScanner(),
        "semgrep": lambda: SemgrepScanner(rules=config.get("semgrep_rules")),
        "deps": lambda: DepsScanner(),
    }
    return [registry[n]() for n in names]


def _print_text_report(verdict: dict, findings: list[Finding]) -> None:
    print(f"\nVerdict: {verdict['verdict']}  ({verdict['total_findings']} finding(s))")
    for name, s in verdict["scanners"].items():
        print(
            f"  {name:8s} findings={s['findings']} max={s['max_severity'] or '-'} "
            f"threshold={s['fail_severity']} blocking={s['blocking']}"
        )
    for f in sorted(findings, key=lambda f: f.severity, reverse=True):
        loc = f"{f.file}:{f.line}" if f.line else f.file
        print(f"  [{f.severity:8s}] {f.scanner}/{f.rule_id} {loc}\n             {f.message[:160]}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="vuln-agent")
    sub = parser.add_subparsers(dest="command", required=True)
    scan = sub.add_parser("scan", help="scan a repo/path for vulnerabilities")
    scan.add_argument("target", help="path to the application to scan")
    scan.add_argument("--scanners", default=None, help="comma list: radar,semgrep,deps")
    scan.add_argument("--config", default=None, help="vuln-agent.config.json path")
    scan.add_argument("--output", default=None, help="run directory for findings.json")
    scan.add_argument("--format", choices=("text", "json"), default="text")
    triage_group = scan.add_mutually_exclusive_group()
    triage_group.add_argument("--triage", action="store_true", help="LLM triage report")
    triage_group.add_argument("--no-llm", action="store_true", help="no LLM (default)")
    args = parser.parse_args(argv)

    # --- Stage 0: preflight (fail closed) ---------------------------------
    try:
        config = load_config(args.config)
    except ConfigError as e:
        print(f"BLOCKED: {e}", file=sys.stderr)
        return EXIT_BLOCKED

    target = Path(args.target)
    if not target.is_dir():
        print(f"BLOCKED: target {target} is not a readable directory.", file=sys.stderr)
        return EXIT_BLOCKED

    names = (
        [s.strip() for s in args.scanners.split(",") if s.strip()]
        if args.scanners else list(config["scanners"])
    )
    unknown = [n for n in names if n not in config["scanners"]]
    if unknown:
        print(f"BLOCKED: scanner(s) {unknown} not enabled in {config['_path']}.", file=sys.stderr)
        return EXIT_BLOCKED

    scanners = _build_scanners(config, names)
    for s in scanners:
        try:
            s.check_preconditions(target)
        except PreconditionError as e:
            print(f"BLOCKED: [{s.name}] {e}", file=sys.stderr)
            return EXIT_BLOCKED

    workdir = Path(args.output) if args.output else Path(tempfile.mkdtemp(prefix="vuln-agent-"))
    workdir.mkdir(parents=True, exist_ok=True)

    # --- Stage 1+2: scan and normalize ------------------------------------
    findings: list[Finding] = []
    for s in scanners:
        try:
            found = s.run(target, workdir)
        except ScanError as e:
            print(f"SCAN ERROR: [{s.name}] {e}", file=sys.stderr)
            return EXIT_SCAN_ERROR
        findings.extend(found)
        print(f"[{s.name}] {len(found)} finding(s)", file=sys.stderr)

    # --- Stage 3: deterministic verdict ------------------------------------
    verdict = compute_verdict(findings, {**config, "scanners": names})
    report = {
        "target": str(target.resolve()),
        "scanners_run": names,
        **verdict,
        "findings": [f.to_dict() for f in findings],
    }
    findings_path = workdir / "findings.json"
    findings_path.write_text(json.dumps(report, indent=2) + "\n")
    print(f"findings written to {findings_path}", file=sys.stderr)

    if args.format == "json":
        print(json.dumps(report, indent=2))
    else:
        _print_text_report(verdict, findings)

    # --- Stage 4: optional LLM triage (never changes the exit code) --------
    if args.triage:
        try:
            from .llm.base import TriageError
            from .llm.openai_adapter import OpenAIAdapter

            report_out = OpenAIAdapter(config.get("triage") or {}).triage(findings, verdict)
            print(f"\n--- Triage ---\n{report_out.summary}")
            by_fp = {f.fingerprint: f for f in findings}
            for item in report_out.items:
                f = by_fp[item.fingerprint]
                print(f"\n{item.priority}. [{f.severity}] {f.scanner}/{f.rule_id} {f.file}:{f.line}")
                print(f"   Why: {item.why_it_matters}")
                print(f"   Fix: {item.how_to_fix}")
        except (TriageError, ImportError) as e:
            print(f"\nWARNING: triage unavailable ({e}); the verdict above stands.", file=sys.stderr)

    return EXIT_VULNERABLE if verdict["verdict"] == "VULNERABLE" else EXIT_CLEAN


if __name__ == "__main__":
    sys.exit(main())
