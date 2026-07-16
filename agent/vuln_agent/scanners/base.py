"""Scanner protocol and shared subprocess runner.

Every scanner is a deterministic subprocess wrapper: preconditions fail
closed (the radar-precommit.sh pattern), the tool's JSON output is parsed
into the common Finding model, and no scanner ever prints or returns a
secret value.
"""

from __future__ import annotations

import shutil
import subprocess
from abc import ABC, abstractmethod
from pathlib import Path

from ..model import Finding

SCAN_TIMEOUT_SECONDS = 600


class PreconditionError(Exception):
    """A scanner cannot run safely -- treat as BLOCKED, exit 2."""


class ScanError(Exception):
    """The tool ran but failed -- treat as scanner runtime error, exit 3."""


class Scanner(ABC):
    name: str = ""

    @abstractmethod
    def check_preconditions(self, target: Path) -> None:
        """Raise PreconditionError if the scan cannot be trusted to run."""

    @abstractmethod
    def run(self, target: Path, workdir: Path) -> list[Finding]:
        """Scan `target`, writing any intermediate files under `workdir`."""

    @staticmethod
    def binary_on_path(binary: str) -> bool:
        return shutil.which(binary) is not None

    @staticmethod
    def run_tool(
        argv: list[str],
        *,
        cwd: Path | None = None,
        env: dict[str, str] | None = None,
        ok_returncodes: tuple[int, ...] = (0,),
    ) -> subprocess.CompletedProcess:
        """Run a scanner subprocess: no shell, bounded time, captured output.

        `env`, when given, is the COMPLETE environment for the child --
        secrets injected this way exist only in the subprocess, mirroring
        radar-precommit.sh's `VAULT_RADAR_LICENSE=$(cat ...) vault-radar ...`.
        """
        try:
            proc = subprocess.run(
                argv,
                cwd=cwd,
                env=env,
                capture_output=True,
                text=True,
                timeout=SCAN_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired as e:
            raise ScanError(f"{argv[0]} timed out after {SCAN_TIMEOUT_SECONDS}s") from e
        except OSError as e:
            raise ScanError(f"failed to execute {argv[0]}: {e}") from e
        if proc.returncode not in ok_returncodes:
            detail = (proc.stderr.strip() or proc.stdout.strip())[:2000]
            raise ScanError(f"{argv[0]} exited {proc.returncode}: {detail}")
        return proc
