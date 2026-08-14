#!/usr/bin/env python3
"""Fail-closed contract for the governed macOS release and required build.

This checker intentionally uses only Python's standard library.  The same
validator consumes the tracked files and every in-memory adversarial mutant.
It does not publish, tag, upload, read secrets, or call the network.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Mapping


REPO_ROOT = Path(__file__).resolve().parents[2]

RELEASE_WORKFLOW = ".github/workflows/macos-release.yml"
REQUIRED_WORKFLOW = ".github/workflows/xcode.yml"
DISPATCHER = "scripts/ci/test-ios"
RELEASE_DOC = "docs/macos-updates.md"
AGENT_DOC = "AGENTS.md"
CLAUDE_DOC = "CLAUDE.md"

CONTRACT_PATHS = (
    RELEASE_WORKFLOW,
    REQUIRED_WORKFLOW,
    DISPATCHER,
    RELEASE_DOC,
    AGENT_DOC,
    CLAUDE_DOC,
)

PRODUCT_PHASES = (
    "env",
    "corpus-integrity",
    "vpn-e2e-tooling",
    "rust-toolchain",
    "ffi-relay-stream",
    "ffi-nat-probe",
    "mac-build",
    "ios-build",
    "ios-tests",
    "swift-build",
    "swift-test",
    "coverage",
)
CONTRACT_PHASE = "governed-release-contract"
EXPECTED_PHASES = (PRODUCT_PHASES[0], CONTRACT_PHASE, *PRODUCT_PHASES[1:])


class ContractError(RuntimeError):
    """The versioned release contract is absent, ambiguous, or bypassable."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def require_once(text: str, needle: str, message: str) -> None:
    require(text.count(needle) == 1, message)


def flattened(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def markdown_section(text: str, heading: str) -> str:
    lines = text.splitlines(keepends=True)
    start = next((i for i, line in enumerate(lines) if line.rstrip("\r\n") == heading), None)
    require(start is not None, f"missing documentation section: {heading}")
    assert start is not None
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if lines[index].startswith("## "):
            end = index
            break
    return "".join(lines[start:end])


def active_lines(text: str) -> tuple[str, ...]:
    result = []
    for raw in text.splitlines():
        stripped = raw.strip()
        if stripped and not stripped.startswith("#"):
            result.append(stripped)
    return tuple(result)


def parse_phases(dispatcher: str) -> tuple[str, ...]:
    match = re.search(r"(?ms)^PHASES=\(\n(?P<body>.*?)^\)$", dispatcher)
    require(match is not None, "dispatcher PHASES roster is missing or ambiguous")
    assert match is not None
    phases = []
    for raw in match.group("body").splitlines():
        value = raw.strip()
        if value and not value.startswith("#"):
            phases.append(value)
    return tuple(phases)


def workflow_phase_calls(workflow: str) -> tuple[str, ...]:
    return tuple(
        match.group(1)
        for match in re.finditer(
            r"(?m)^\s+run: scripts/ci/test-ios ([a-z0-9-]+)\s*$", workflow
        )
    )


def validate_release_workflow(text: str) -> None:
    require_once(
        text,
        "# governed-release-contract: theyos-safe-external-write-v1",
        "release workflow must carry exactly one governed adapter marker",
    )
    require_once(
        text,
        "# governed-release-required-build: scripts/ci/check-governed-macos-release.py",
        "release workflow must carry exactly one required-build checker marker",
    )

    trigger = """on:
  push:
    tags:
      - \"mac-v*\"
  workflow_dispatch:
    inputs:
"""
    require_once(text, trigger, "release workflow trigger grammar drifted")
    trigger_block = text.split("permissions:", 1)[0]
    for forbidden_trigger in ("pull_request:", "schedule:", "workflow_call:"):
        require(forbidden_trigger not in trigger_block,
                f"release workflow exposes forbidden trigger: {forbidden_trigger}")
    require_once(text, "permissions:\n  contents: read\n", "release workflow must be read-only")
    require("contents: write" not in text, "release workflow requests write permission")

    required_fragments = (
        ("expected_ref:", 1),
        ("expected_oid:", 1),
        ('if [[ ! "$expected_ref" =~ ^refs/tags/mac-v', 1),
        ('git cat-file -t "$expected_ref"', 1),
        ('git rev-parse "${expected_ref}^{commit}"', 2),
        ('git rev-parse HEAD', 1),
        ('git merge-base --is-ancestor "$expected_oid" refs/remotes/origin/main', 1),
        ('MARKETING_VERSION = \\([^;]*\\);', 1),
        ('if [[ "$declared_versions" != "$version" ]]', 1),
        ("uses: actions/upload-artifact@v4", 1),
        ("if-no-files-found: error", 1),
    )
    for fragment, count in required_fragments:
        require(text.count(fragment) == count, f"release workflow contract drifted: {fragment}")

    active = "\n".join(active_lines(text)).lower()
    forbidden = (
        (r"\bgh\s+release\b", "direct gh release command"),
        (r"\bgit\s+tag\b", "direct git tag command"),
        (r"\bgit\s+push\b", "direct git push command"),
        (r"(?:^|\s)--clobber(?:\s|$)", "clobber bypass"),
        (r"uses:\s*[^\n]*(?:release|gh-release)", "direct release action"),
    )
    for pattern, label in forbidden:
        require(re.search(pattern, active) is None, f"release workflow contains {label}")


def validate_required_build(workflow: str, dispatcher: str) -> None:
    trigger = """on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]
"""
    require_once(workflow, trigger, "required build trigger grammar drifted")
    trigger_block = workflow.split("env:", 1)[0]
    require("paths:" not in trigger_block, "required build is path-scoped")
    require("paths-ignore:" not in trigger_block, "required build ignores contract paths")
    workflow_active = "\n".join(active_lines(workflow))
    require("continue-on-error:" not in workflow_active,
            "required build contains continue-on-error")
    require(re.search(r"(?m)^if:\s*", workflow_active) is None,
            "required build contains a job or step condition")

    step = """    - name: Verify governed macOS release contract
      run: scripts/ci/test-ios governed-release-contract
"""
    require_once(workflow, step, "required build checker step is missing or ambiguous")

    step_start = workflow.index(step)
    next_step = workflow.find("\n    - name:", step_start + len(step))
    checker_step = workflow[step_start : next_step if next_step >= 0 else len(workflow)]
    for forbidden in ("if:", "continue-on-error:", "|| true", "&\n", "| tee"):
        require(forbidden not in checker_step, f"required build checker is neutralized by {forbidden}")

    phases = parse_phases(dispatcher)
    require(phases == EXPECTED_PHASES, "dispatcher phase roster/order drifted")
    calls = workflow_phase_calls(workflow)
    require(calls == EXPECTED_PHASES, "required build phase calls are not an exact 1:1 roster")
    require(tuple(p for p in phases if p != CONTRACT_PHASE) == PRODUCT_PHASES,
            "existing product phase coverage changed")

    function = """phase_governed_release_contract() {
  python3 scripts/ci/check-governed-macos-release.py --self-test
}
"""
    require_once(dispatcher, function, "dispatcher checker function is missing or masked")
    require_once(dispatcher, 'set -Eeuo pipefail\n', "dispatcher must remain fail-loud")
    require_once(dispatcher, '"$fn"\n', "dispatcher must execute the selected phase directly")
    require_once(
        dispatcher,
        "[test-ios] FAILED in phase: %s (exit %d)",
        "dispatcher must name the failing phase and exit",
    )


def validate_docs(release_doc: str, agent_doc: str, claude_doc: str) -> None:
    heading = "## macOS Release Signing"
    agent_block = markdown_section(agent_doc, heading)
    claude_block = markdown_section(claude_doc, heading)
    require(agent_block == claude_block, "AGENTS/CLAUDE release blocks differ byte-for-byte")

    combined = flattened(agent_block + "\n" + release_doc)
    required = (
        "Preserve the governed A-then-B order",
        "The `macOS Release` workflow is build-only",
        "A missing or mismatched guard must fail closed",
        "The adapter pins the reviewed execution quartet",
        "There is no direct `git tag`, `git push`, `gh release`, `--clobber`, or publication fallback.",
        "Each phase performs one mutation and then reads the created object back.",
        "this contract proves the immediate readback and absence of versioned bypasses, not permanence against a later administrator.",
        "The required `build` context validates this release contract",
        "A trusted-base workflow or repository protection is required to make simultaneous removal of both the checker and its invocation mechanically red.",
    )
    for phrase in required:
        require_once(combined, phrase, f"release documentation contract drifted: {phrase}")

    operations = tuple(re.findall(r"\bgoverned-release ([a-z-]+)\b", release_doc))
    expected_operations = (
        "tag-object-create",
        "tag-ref-create",
        "release-draft-create",
        "asset-upload",
        "asset-upload",
        "release-publish",
    )
    require(operations == expected_operations,
            "release documentation operation roster/order drifted")

    safe_absence = "There is no direct `git tag`, `git push`, `gh release`, `--clobber`, or publication fallback."
    scan_text = combined.replace(safe_absence, "")
    direct_patterns = (
        (r"\bgh\s+release\b", "direct gh release instruction"),
        (r"\bgit\s+tag\b", "direct git tag instruction"),
        (r"\bgit\s+push\b", "direct git push instruction"),
        (r"--clobber\b", "clobber instruction"),
    )
    for pattern, label in direct_patterns:
        require(re.search(pattern, scan_text, re.IGNORECASE) is None, f"documentation contains {label}")


def validate_snapshot(files: Mapping[str, str]) -> None:
    missing = sorted(set(CONTRACT_PATHS) - set(files))
    require(not missing, f"contract files missing: {', '.join(missing)}")
    validate_release_workflow(files[RELEASE_WORKFLOW])
    validate_required_build(files[REQUIRED_WORKFLOW], files[DISPATCHER])
    validate_docs(files[RELEASE_DOC], files[AGENT_DOC], files[CLAUDE_DOC])


def read_snapshot() -> dict[str, str]:
    result = {}
    for relative in CONTRACT_PATHS:
        path = REPO_ROOT / relative
        try:
            result[relative] = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            raise ContractError(f"cannot read tracked contract file {relative}: {error}") from error
    return result


def replace_once(text: str, old: str, new: str) -> str:
    require(text.count(old) == 1, f"self-test anchor is not unique: {old}")
    changed = text.replace(old, new, 1)
    require(changed != text, f"self-test did not mutate bytes: {old}")
    return changed


def swap_once(text: str, first: str, second: str) -> str:
    require(text.count(first) == 1, f"self-test first swap anchor is not unique: {first}")
    require(text.count(second) == 1, f"self-test second swap anchor is not unique: {second}")
    placeholder = "__governed_release_self_test_swap__"
    require(placeholder not in text, "self-test swap placeholder already exists")
    changed = text.replace(first, placeholder, 1)
    changed = changed.replace(second, first, 1).replace(placeholder, second, 1)
    require(changed != text, "self-test swap did not mutate bytes")
    return changed


@dataclass(frozen=True)
class Mutant:
    name: str
    path: str
    change: Callable[[str], str]


def mutants() -> tuple[Mutant, ...]:
    return (
        Mutant("release-marker-removed", RELEASE_WORKFLOW,
               lambda s: replace_once(s, "# governed-release-required-build: scripts/ci/check-governed-macos-release.py", "# marker removed")),
        Mutant("release-write-permission", RELEASE_WORKFLOW,
               lambda s: replace_once(s, "contents: read", "contents: write")),
        Mutant("release-pull-request-trigger", RELEASE_WORKFLOW,
               lambda s: replace_once(s, "permissions:\n", "  pull_request:\n    branches: [ main ]\n\npermissions:\n")),
        Mutant("release-artifact-missing-error", RELEASE_WORKFLOW,
               lambda s: replace_once(s, "if-no-files-found: error", "if-no-files-found: warn")),
        Mutant("release-direct-gh", RELEASE_WORKFLOW,
               lambda s: s + "\n# self-test\nrun: gh release create mac-v9.9.9\n"),
        Mutant("release-direct-tag", RELEASE_WORKFLOW,
               lambda s: s + "\n# self-test\nrun: git tag mac-v9.9.9\n"),
        Mutant("release-direct-push", RELEASE_WORKFLOW,
               lambda s: s + "\n# self-test\nrun: git push origin refs/tags/mac-v9.9.9\n"),
        Mutant("release-clobber", RELEASE_WORKFLOW,
               lambda s: s + "\n# self-test\nrun: uploader --clobber asset\n"),
        Mutant("required-build-paths", REQUIRED_WORKFLOW,
               lambda s: replace_once(s, "  pull_request:\n    branches: [ main ]", "  pull_request:\n    branches: [ main ]\n    paths: [ 'TerminalApp/**' ]")),
        Mutant("required-build-paths-ignore", REQUIRED_WORKFLOW,
               lambda s: replace_once(s, "  pull_request:\n    branches: [ main ]", "  pull_request:\n    branches: [ main ]\n    paths-ignore: [ 'docs/**' ]")),
        Mutant("required-build-step-commented", REQUIRED_WORKFLOW,
               lambda s: replace_once(s, "      run: scripts/ci/test-ios governed-release-contract", "      # run: scripts/ci/test-ios governed-release-contract")),
        Mutant("required-build-step-conditional", REQUIRED_WORKFLOW,
               lambda s: replace_once(s, "    - name: Verify governed macOS release contract\n      run:", "    - name: Verify governed macOS release contract\n      if: false\n      run:")),
        Mutant("required-build-continue-on-error", REQUIRED_WORKFLOW,
               lambda s: replace_once(s, "    - name: Verify governed macOS release contract\n      run:", "    - name: Verify governed macOS release contract\n      continue-on-error: true\n      run:")),
        Mutant("required-build-job-conditional", REQUIRED_WORKFLOW,
               lambda s: replace_once(s, "  build:\n\n    runs-on:", "  build:\n    if: false\n\n    runs-on:")),
        Mutant("dispatcher-contract-phase-removed", DISPATCHER,
               lambda s: replace_once(s, "  governed-release-contract\n", "")),
        Mutant("dispatcher-checker-masked", DISPATCHER,
               lambda s: replace_once(s, "python3 scripts/ci/check-governed-macos-release.py --self-test", "python3 scripts/ci/check-governed-macos-release.py --self-test || true")),
        Mutant("dispatcher-product-phase-removed", DISPATCHER,
               lambda s: replace_once(s, "  ios-build\n", "")),
        Mutant("dispatcher-product-phase-reordered", DISPATCHER,
               lambda s: replace_once(s, "  swift-build\n  swift-test\n", "  swift-test\n  swift-build\n")),
        Mutant("docs-block-drift", CLAUDE_DOC,
               lambda s: replace_once(s, "Preserve the governed A-then-B order", "Preserve a governed release order")),
        Mutant("docs-order-removed", AGENT_DOC,
               lambda s: replace_once(s, "Preserve the governed A-then-B order", "Preserve the release order")),
        Mutant("docs-operation-removed", RELEASE_DOC,
               lambda s: replace_once(s, "governed-release tag-ref-create", "governed release tag-ref-create")),
        Mutant("docs-operations-reordered", RELEASE_DOC,
               lambda s: swap_once(s, "governed-release tag-object-create", "governed-release tag-ref-create")),
        Mutant("docs-direct-gh", RELEASE_DOC,
               lambda s: s + "\nRun gh release create as a fallback.\n"),
        Mutant("docs-direct-tag", RELEASE_DOC,
               lambda s: s + "\nRun git tag as a fallback.\n"),
        Mutant("docs-direct-push", RELEASE_DOC,
               lambda s: s + "\nRun git push as a fallback.\n"),
        Mutant("docs-clobber", RELEASE_DOC,
               lambda s: s + "\nRetry with --clobber as a fallback.\n"),
    )


def run_self_tests(snapshot: Mapping[str, str]) -> int:
    passed = 0
    for mutant in mutants():
        changed = dict(snapshot)
        changed[mutant.path] = mutant.change(changed[mutant.path])
        try:
            validate_snapshot(changed)
        except ContractError:
            passed += 1
            continue
        raise ContractError(f"self-test mutant survived: {mutant.name}")
    print(f"governed macOS release contract: {passed}/{len(mutants())} mutants rejected")
    return passed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true", help="also reject the adversarial mutant table")
    args = parser.parse_args(argv)

    try:
        snapshot = read_snapshot()
        validate_snapshot(snapshot)
        if args.self_test:
            run_self_tests(snapshot)
    except ContractError as error:
        print(f"governed macOS release contract: FAIL: {error}", file=sys.stderr)
        return 1

    print("governed macOS release contract: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
