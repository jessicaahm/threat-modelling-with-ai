"""Load and validate vuln-agent.config.json.

Mirrors the philosophy of .hashicorp/vault-radar/config.json and
script/radar-precommit.sh: the config file is checked into the repo so policy
travels with every checkout and CI run, and a missing or invalid config is a
refusal to scan (fail closed), never a silent downgrade to warn-only.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

from .model import is_valid_severity

# The agent's own repo root (config/license defaults live here, not in the
# scan target -- the target is an arbitrary, untrusted path).
AGENT_ROOT = Path(__file__).resolve().parents[2]

DEFAULT_CONFIG_PATH = AGENT_ROOT / "agent" / "vuln-agent.config.json"
KNOWN_SCANNERS = ("radar", "semgrep", "deps")


class ConfigError(Exception):
    """Invalid/missing config -- callers must treat this as BLOCKED, exit 2."""


def load_config(path: str | None = None) -> dict:
    cfg_path = Path(path or os.environ.get("VULN_AGENT_CONFIG") or DEFAULT_CONFIG_PATH)
    if not cfg_path.is_file() or cfg_path.stat().st_size == 0:
        raise ConfigError(
            f"config missing or empty ({cfg_path}). Refusing to scan without "
            "an enforcement policy rather than silently downgrading to warn-only."
        )
    try:
        cfg = json.loads(cfg_path.read_text())
    except json.JSONDecodeError as e:
        raise ConfigError(f"config {cfg_path} is not valid JSON: {e}") from e

    scanners = cfg.get("scanners")
    if not isinstance(scanners, list) or not scanners:
        raise ConfigError(f"config {cfg_path} has no \"scanners\" list.")
    for s in scanners:
        if s not in KNOWN_SCANNERS:
            raise ConfigError(f"config {cfg_path}: unknown scanner {s!r}.")

    fail = cfg.get("fail_severity")
    if not isinstance(fail, dict):
        raise ConfigError(f"config {cfg_path} has no \"fail_severity\" object.")
    for s in scanners:
        sev = fail.get(s)
        if not isinstance(sev, str) or not is_valid_severity(sev):
            # Lowercase only, mirroring vault-radar's accepted values -- a
            # wrong-case "CRITICAL" must be caught here, not silently ignored.
            raise ConfigError(
                f"config {cfg_path}: scanner {s!r} has no valid fail_severity "
                f"(got: {sev!r}); expected one of info|low|medium|high|critical."
            )

    cfg["_path"] = str(cfg_path)
    return cfg
