#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
import sys
from datetime import date
from pathlib import Path

from appium_gate_common import build_gate_env, terminate_processes


SMOKE_ONLY = "brow_001,brow_003_004_005_007,brow_006,brow_008_009_010,brow_014_015,brow_016,brow_017"


def main() -> int:
    repo_root = Path(__file__).resolve().parents[2]
    run_dir = Path(
        os.environ.get("SOYEHT_QA_RUN_DIR")
        or repo_root / "QA" / "runs" / f"{date.today().isoformat()}-appium-smoke"
    )

    processes = []
    try:
        env_updates, processes = build_gate_env(run_dir)
        env = os.environ.copy()
        env.update(env_updates)
        command = [
            str(repo_root / ".venv-appium" / "bin" / "python"),
            str(repo_root / "QA" / "scripts" / "run_file_live_appium.py"),
            "--suite",
            "browser",
            "--only",
            SMOKE_ONLY,
        ]
        return subprocess.run(command, cwd=repo_root, env=env).returncode
    finally:
        terminate_processes(processes)


if __name__ == "__main__":
    sys.exit(main())
