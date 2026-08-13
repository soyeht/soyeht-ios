#!/usr/bin/env python3
"""Exercise the shell contracts that keep iOS CI signals fail-loud.

The tests execute the workflow run blocks with controlled tool doubles. They
therefore check exit behavior, marker behavior, variant coverage, and job
separation without invoking Xcode or changing snapshot baselines.
"""

from __future__ import annotations

import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
ONBOARDING = ROOT / ".github/workflows/onboarding-quality.yml"
ACCESSIBILITY = ROOT / ".github/workflows/accessibility-audit.yml"


def fail(message: str) -> None:
    raise AssertionError(message)


def workflow_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def step_block(text: str, step_name: str) -> str:
    marker = f"      - name: {step_name}\n"
    start = text.find(marker)
    if start < 0:
        fail(f"missing workflow step: {step_name}")
    end = text.find("\n      - ", start + len(marker))
    if end < 0:
        end = len(text)
    return text[start:end]


def run_script(block: str) -> str:
    marker = "        run: |\n"
    start = block.find(marker)
    if start < 0:
        inline = re.search(r"^        run: (.+)$", block, re.M)
        if inline:
            return inline.group(1) + "\n"
        fail("step is missing a run block")
    body: list[str] = []
    for line in block[start + len(marker) :].splitlines():
        if line.startswith("          "):
            body.append(line[10:])
        elif not line:
            body.append("")
        else:
            break
    return "\n".join(body) + "\n"


def job_for_step(text: str, step_name: str) -> str:
    marker = f"      - name: {step_name}\n"
    step_at = text.find(marker)
    if step_at < 0:
        fail(f"missing workflow step: {step_name}")
    jobs = list(re.finditer(r"^  ([a-z0-9-]+):\n", text[:step_at], re.M))
    if not jobs:
        fail(f"step has no enclosing job: {step_name}")
    return jobs[-1].group(1)


def write_tool(directory: Path, name: str, body: str) -> None:
    path = directory / name
    path.write_text("#!/bin/sh\nset -eu\n" + body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def execute(script: str, tools: dict[str, str], extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as raw:
        directory = Path(raw)
        for name, body in tools.items():
            write_tool(directory, name, body)
        env = os.environ.copy()
        env["PATH"] = f"{directory}:{env['PATH']}"
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            ["/bin/bash", "-e", "-o", "pipefail", "-c", script],
            cwd=directory,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )


def require_success(result: subprocess.CompletedProcess[str], label: str) -> None:
    if result.returncode != 0:
        fail(f"{label}: expected success, got {result.returncode}\n{result.stdout}")
    print(f"PASS green: {label}")


def require_failure(result: subprocess.CompletedProcess[str], label: str) -> None:
    if result.returncode == 0:
        fail(f"{label}: false green\n{result.stdout}")
    print(f"PASS red: {label} (exit {result.returncode})")


def test_onboarding_markers(text: str) -> None:
    cases = (
        ("Build Soyeht iOS", "BUILD SUCCEEDED"),
        ("Run iOS unit tests", "TEST SUCCEEDED"),
    )
    for name, marker in cases:
        script = run_script(step_block(text, name))
        require_success(
            execute(script, {"uname": "printf 'arm64\\n'", "xcodebuild": f"printf '%s\\n' '{marker}'"}),
            f"{name} positive control",
        )
        require_failure(
            execute(script, {"uname": "printf 'arm64\\n'", "xcodebuild": "printf '%s\\n' 'tool failed'; exit 17"}),
            f"{name} propagates xcodebuild failure",
        )
        require_failure(
            execute(script, {"uname": "printf 'arm64\\n'", "xcodebuild": "printf '%s\\n' 'no success marker'"}),
            f"{name} rejects missing positive marker",
        )


def test_accessibility_variants(text: str) -> None:
    script = run_script(step_block(text, "iOS Accessibility Snapshot Tests (RTL + AX5)"))
    with tempfile.TemporaryDirectory() as raw:
        calls = Path(raw) / "calls"
        tool = "printf '%s\\n' \"$*\" >> \"$CALLS_FILE\"\nexit \"${XCODEBUILD_EXIT:-0}\""
        green = execute(script, {"uname": "printf 'arm64\\n'", "xcodebuild": tool}, {"CALLS_FILE": str(calls)})
        require_success(green, "accessibility positive control")
        recorded = calls.read_text(encoding="utf-8")
        if recorded.count("-only-testing:SoyehtTests/AccessibilitySnapshotTests") != 2:
            fail("accessibility control did not execute exactly two test invocations")
        if "TEST_LOCALE=ar" not in recorded or "DYNAMIC_TYPE_SIZE=AX5" not in recorded:
            fail("accessibility control lost the ar or AX5 variant")

    require_failure(
        execute(
            script,
            {
                "uname": "printf 'arm64\\n'",
                "xcodebuild": "case \"$*\" in *TEST_LOCALE=ar*) exit 23;; *) exit 0;; esac",
            },
        ),
        "accessibility ar failure",
    )


def test_snapshot_diff_gate(text: str) -> None:
    script = run_script(step_block(text, "Verify no snapshot regressions"))
    require_success(execute(script, {"git": "exit 0"}), "snapshot diff positive control")
    require_failure(execute(script, {"git": "exit 1"}), "snapshot diff mutation")


def test_core_harness_separation(text: str) -> None:
    core = "Run SoyehtCore tests"
    harness = "Run EngineHarnessTests in isolated CI"
    diagnostic = "Engine-log privacy-safe diagnostic"
    core_job = job_for_step(text, core)
    harness_job = job_for_step(text, harness)
    if core_job == harness_job:
        fail("SoyehtCore and EngineHarness still share one job signal")
    if job_for_step(text, diagnostic) != harness_job:
        fail("EngineHarness diagnostic is not attached to the harness signal")
    if "        if: always()\n" not in step_block(text, diagnostic):
        fail("EngineHarness diagnostic no longer runs after a harness failure")

    core_script = run_script(step_block(text, core))
    require_success(
        execute(core_script, {"swift": "exit 0"}),
        "SoyehtCore deterministic step remains independently green",
    )

    harness_script = run_script(step_block(text, harness))
    require_failure(
        execute(harness_script, {"swift": "exit 29"}),
        "EngineHarness failure remains red",
    )
    print(f"PASS split: {core_job} != {harness_job}; diagnostic stays with {harness_job}")


def main() -> None:
    onboarding = workflow_text(ONBOARDING)
    accessibility = workflow_text(ACCESSIBILITY)
    test_onboarding_markers(onboarding)
    test_accessibility_variants(accessibility)
    test_snapshot_diff_gate(accessibility)
    test_core_harness_separation(onboarding)
    print("workflow-signal-hardening: all controls passed")


if __name__ == "__main__":
    main()
