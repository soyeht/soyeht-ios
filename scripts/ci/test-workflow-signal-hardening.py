#!/usr/bin/env python3
"""Prove that the three hardened iOS signals cannot fail green."""

from pathlib import Path
import os
import re
import stat
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
ONBOARDING = ROOT / ".github/workflows/onboarding-quality.yml"
ACCESSIBILITY = ROOT / ".github/workflows/accessibility-audit.yml"
EXECUTION_STEPS = (
    "Build Soyeht iOS",
    "Run iOS unit tests",
    "iOS Accessibility Snapshot Tests (RTL + AX5)",
    "Run SoyehtCore tests",
    "Run EngineHarnessTests in isolated CI",
)
EXECUTION_JOBS = ("ios-build", "snapshot-accessibility", "core-tests", "engine-harness")
DIAGNOSTIC = "Engine-log privacy-safe diagnostic"


def step(text: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    start = text.find(marker)
    assert start >= 0, f"missing step: {name}"
    end = text.find("\n      - ", start + len(marker))
    return text[start : len(text) if end < 0 else end]


def job(text: str, name: str) -> str:
    marker = f"  {name}:\n"
    start = text.find(marker)
    assert start >= 0, f"missing job: {name}"
    following = re.search(r"^  [a-z0-9-]+:\n", text[start + len(marker) :], re.M)
    end = len(text) if not following else start + len(marker) + following.start()
    return text[start:end]


def script(block: str) -> str:
    multiline = "        run: |\n"
    start = block.find(multiline)
    if start < 0:
        inline = re.search(r"^        run: (.+)$", block, re.M)
        assert inline, "step has no run block"
        return inline.group(1) + "\n"
    body = []
    for line in block[start + len(multiline) :].splitlines():
        if line.startswith("          "):
            body.append(line[10:])
        elif not line:
            body.append("")
        else:
            break
    return "\n".join(body) + "\n"


def job_of(text: str, name: str) -> str:
    at = text.find(f"      - name: {name}\n")
    assert at >= 0, f"missing step: {name}"
    matches = list(re.finditer(r"^  ([a-z0-9-]+):\n", text[:at], re.M))
    assert matches, f"step has no job: {name}"
    return matches[-1].group(1)


def reject_neutralizers(onboarding: str, accessibility: str) -> None:
    text = onboarding + "\n" + accessibility
    diagnostic = step(text, DIAGNOSTIC)
    assert re.search(r"^        if:\s*always\(\)\s*$", diagnostic, re.M)
    assert not re.search(r"^        continue-on-error\s*:", diagnostic, re.M)
    for name in EXECUTION_STEPS:
        block = step(text, name)
        assert not re.search(r"^        continue-on-error\s*:", block, re.M), name
        assert not re.search(r"^        if:.*\b(?:always|failure)\s*\(", block, re.M), name
    for name in EXECUTION_JOBS:
        block = job(text, name)
        assert not re.search(r"^    continue-on-error\s*:", block, re.M), name
        assert not re.search(r"^    if:.*\b(?:always|failure)\s*\(", block, re.M), name


def execute(shell: str, tools: dict[str, str], extra: dict[str, str] | None = None) -> int:
    with tempfile.TemporaryDirectory() as raw:
        directory = Path(raw)
        for name, body in tools.items():
            path = directory / name
            path.write_text("#!/bin/sh\nset -eu\n" + body, encoding="utf-8")
            path.chmod(path.stat().st_mode | stat.S_IXUSR)
        env = os.environ.copy()
        env["PATH"] = f"{directory}:{env['PATH']}"
        env.update(extra or {})
        return subprocess.run(
            ["/bin/bash", "-e", "-o", "pipefail", "-c", shell],
            cwd=directory,
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        ).returncode


def expect(actual: int, success: bool, label: str) -> None:
    assert (actual == 0) is success, f"{label}: exit {actual}"


def insert(text: str, marker: str, value: str) -> str:
    assert text.count(marker) == 1, f"non-unique mutation anchor: {marker.strip()}"
    return text.replace(marker, marker + value, 1)


def main() -> None:
    onboarding = ONBOARDING.read_text(encoding="utf-8")
    accessibility = ACCESSIBILITY.read_text(encoding="utf-8")
    for name, marker in (("Build Soyeht iOS", "BUILD SUCCEEDED"), ("Run iOS unit tests", "TEST SUCCEEDED")):
        run = script(step(onboarding, name))
        base_tools = {"uname": "printf 'arm64\\n'"}
        expect(execute(run, base_tools | {"xcodebuild": f"printf '%s\\n' '{marker}'"}), True, name)
        expect(execute(run, base_tools | {"xcodebuild": "exit 17"}), False, f"{name} exit")
        expect(execute(run, base_tools | {"xcodebuild": "printf 'no marker\\n'"}), False, f"{name} marker")

    reject_neutralizers(onboarding, accessibility)
    # Same run block and invocation count; only the neutralizer changes.
    build_marker = "      - name: Build Soyeht iOS\n"
    build_run = script(step(onboarding, "Build Soyeht iOS"))
    mutants = (
        insert(onboarding, build_marker, "        continue-on-error: true\n"),
        insert(onboarding, build_marker, '        continue-on-error: "true"\n'),
        insert(onboarding, "  ios-build:\n", '    continue-on-error: "${{ always() }}"\n'),
        insert(onboarding, build_marker, "        if: failure()\n"),
    )
    for mutant in mutants:
        assert script(step(mutant, "Build Soyeht iOS")) == build_run
        assert mutant.count("xcodebuild") == onboarding.count("xcodebuild")
        try:
            reject_neutralizers(mutant, accessibility)
        except AssertionError:
            continue
        raise AssertionError("neutralizer mutant passed")

    access_run = script(step(accessibility, "iOS Accessibility Snapshot Tests (RTL + AX5)"))
    with tempfile.TemporaryDirectory() as raw:
        calls = Path(raw) / "calls"
        logger = "printf '%s\\n' \"$*\" >> \"$CALLS\""
        expect(execute(access_run, {"uname": "printf 'arm64\\n'", "xcodebuild": logger}, {"CALLS": str(calls)}), True, "accessibility")
        recorded = calls.read_text(encoding="utf-8")
        assert recorded.count("-only-testing:SoyehtTests/AccessibilitySnapshotTests") == 2
        assert "TEST_LOCALE=ar" in recorded and "DYNAMIC_TYPE_SIZE=AX5" in recorded
    ar_fails = 'case "$*" in *TEST_LOCALE=ar*) exit 23;; *) exit 0;; esac'
    expect(execute(access_run, {"uname": "printf 'arm64\\n'", "xcodebuild": ar_fails}), False, "accessibility ar")

    diff_run = script(step(accessibility, "Verify no snapshot regressions"))
    expect(execute(diff_run, {"git": "exit 0"}), True, "snapshot clean")
    expect(execute(diff_run, {"git": "exit 1"}), False, "snapshot mutation")

    core = "Run SoyehtCore tests"
    harness = "Run EngineHarnessTests in isolated CI"
    assert job_of(onboarding, core) != job_of(onboarding, harness)
    assert job_of(onboarding, DIAGNOSTIC) == job_of(onboarding, harness)
    expect(execute(script(step(onboarding, core)), {"swift": "exit 0"}), True, "core")
    expect(execute(script(step(onboarding, harness)), {"swift": "exit 29"}), False, "harness")
    print("workflow-signal-hardening: all controls passed")


if __name__ == "__main__":
    main()
