#!/usr/bin/env python3
"""Fail-closed contract for the governed macOS release and required build.

This checker intentionally uses only Python's standard library.  The same
validator consumes the tracked files and every in-memory adversarial mutant.
It does not publish, tag, upload, read secrets, or call the network.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
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
DEV_ISOLATION_DOC = "docs/dev-build-isolation.md"
BUILD_DMG = "scripts/build-dmg.sh"
BUNDLE_APNS_HELPER = "scripts/bundle-apns-key.sh"
ENGINE_PACKAGER = "TerminalApp/SoyehtMac/Installer/EnginePackager.swift"
INSTALL_PROFILE = "Packages/SoyehtCore/Sources/SoyehtCore/Install/SoyehtInstallProfile.swift"
LAUNCH_SPEC = "Packages/SoyehtCore/Sources/SoyehtCore/Install/EmbeddedEngineLaunchAgentSpec.swift"
RELEASE_LAUNCH_AGENT = "TerminalApp/SoyehtMac/Library/LaunchAgents/com.soyeht.engine.plist"
DEV_LAUNCH_AGENT = "TerminalApp/SoyehtMac/Library/LaunchAgents/com.soyeht.engine.dev.plist"
LAUNCH_AGENT_TESTS = "TerminalApp/SoyehtMacTests/Tests/EmbeddedEngineLaunchAgentTests.swift"
ENGINE_PIN = "scripts/theyos-engine.version"
ENGINE_CHECKSUMS = "scripts/theyos-engine.sha256"
ENGINE_COMPAT = "Packages/SoyehtCore/Sources/SoyehtCore/EngineVersion/EngineVersion.swift"
ENGINE_COMPAT_TESTS = "Packages/SoyehtCore/Tests/SoyehtCoreTests/EngineCompatTests.swift"
CLAW_INSTALL_DOC = "docs/claw-install-target.md"
ENGINE_SAFE_STAGES = "scripts/ci/engine-safe-stages.txt"
ABSENT_FILE_SENTINEL = "<ABSENT>"
PRIVATE_KEY_MARKER = b"-----BEGIN PRIVATE KEY-----"

ENGINE_RELEASE_VERSION = "0.1.27"
ENGINE_RELEASE_SHA256 = "e85657de58fad61f20c1e3692b3dcfbb4dd3f7450a1940dd8cb48b97871c71d6"
ENGINE_RELEASE_SOURCE = "c1e5455adb9b4cbc4ce430a6c6303c09b1f508d3"
ENGINE_RELEASE_TREE = "999a82bbabc3a1a900f31cfc08d0caab5413d000"
CANONICAL_SEMVER = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)")
LOWER_SHA256 = re.compile(r"[0-9a-f]{64}")

CONTRACT_PATHS = (
    RELEASE_WORKFLOW,
    REQUIRED_WORKFLOW,
    DISPATCHER,
    RELEASE_DOC,
    AGENT_DOC,
    CLAUDE_DOC,
    DEV_ISOLATION_DOC,
    BUILD_DMG,
    BUNDLE_APNS_HELPER,
    ENGINE_PACKAGER,
    INSTALL_PROFILE,
    LAUNCH_SPEC,
    RELEASE_LAUNCH_AGENT,
    DEV_LAUNCH_AGENT,
    LAUNCH_AGENT_TESTS,
    ENGINE_PIN,
    ENGINE_CHECKSUMS,
    ENGINE_COMPAT,
    ENGINE_COMPAT_TESTS,
    CLAW_INSTALL_DOC,
    ENGINE_SAFE_STAGES,
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

REQUIRED_RELEASE_SECRETS = (
    "SPARKLE_PRIVATE_KEY",
    "SOYEHT_SPARKLE_PUBLIC_ED_KEY",
    "APPLE_DEVELOPER_ID_P12_BASE64",
    "APPLE_DEVELOPER_ID_P12_PASSWORD",
    "APPLE_NOTARY_KEY_P8_BASE64",
    "APPLE_NOTARY_KEY_ID",
    "APPLE_NOTARY_ISSUER_ID",
    "APPLE_TEAM_ID",
    "APPLE_CODESIGN_IDENTITY",
)


class ContractError(RuntimeError):
    """The versioned release contract is absent, ambiguous, or bypassable."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ContractError(message)


def require_once(text: str, needle: str, message: str) -> None:
    require(text.count(needle) == 1, message)


def is_p8_name(name: str) -> bool:
    return name.casefold().endswith(".p8")


def file_contains_private_key_marker(path: Path) -> bool:
    overlap = len(PRIVATE_KEY_MARKER) - 1
    previous = b""
    try:
        with path.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                combined = previous + chunk
                if PRIVATE_KEY_MARKER in combined:
                    return True
                previous = combined[-overlap:] if overlap else b""
    except OSError as error:
        raise ContractError(f"cannot read product payload {path}: {error}") from error
    return False


def scan_product_root(product_root: Path) -> None:
    """Reject provider private keys and unsafe links in a public product tree."""

    try:
        root = product_root.resolve(strict=True)
    except OSError as error:
        raise ContractError(f"product root is missing or ambiguous: {product_root}: {error}") from error
    require(root.is_dir(), f"product root is not a directory: {root}")

    stack = [root]
    visited_directories: set[tuple[int, int]] = set()
    while stack:
        path = stack.pop()
        try:
            metadata = path.lstat()
        except OSError as error:
            raise ContractError(f"cannot inspect product payload {path}: {error}") from error

        if path.is_symlink():
            try:
                target_text = os.readlink(path)
            except OSError as error:
                raise ContractError(f"cannot read product symlink {path}: {error}") from error
            relative = path.relative_to(root)
            if relative == Path("Applications") and target_text == "/Applications":
                continue
            require(
                not is_p8_name(path.name) and not is_p8_name(Path(target_text).name),
                f"provider-key symlink is forbidden in public product: {relative} -> {target_text}",
            )
            try:
                resolved = path.resolve(strict=True)
                resolved.relative_to(root)
            except (OSError, RuntimeError, ValueError) as error:
                raise ContractError(
                    f"external, broken, or ambiguous product symlink: {relative} -> {target_text}"
                ) from error
            stack.append(resolved)
            continue

        relative = path.relative_to(root)
        require(not is_p8_name(path.name), f"provider-key file is forbidden in public product: {relative}")

        if path.is_dir():
            identity = (metadata.st_dev, metadata.st_ino)
            if identity in visited_directories:
                continue
            visited_directories.add(identity)
            try:
                children = sorted(path.iterdir(), key=lambda child: child.name)
            except OSError as error:
                raise ContractError(f"cannot enumerate product directory {path}: {error}") from error
            stack.extend(reversed(children))
            continue

        require(path.is_file(), f"unsupported special file in public product: {relative}")
        require(
            not file_contains_private_key_marker(path),
            f"PKCS8 private-key marker is forbidden in public product: {relative}",
        )


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


def workflow_step(text: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    require(text.count(marker) == 1, f"workflow step is missing or ambiguous: {name}")
    start = text.index(marker)
    end = text.find("\n      - name:", start + len(marker))
    return text[start : end if end >= 0 else len(text)]


def multiline_run_body(step: str) -> str:
    lines = step.splitlines()
    run_index = next(
        (index for index, line in enumerate(lines) if line.strip() == "run: |"),
        None,
    )
    require(run_index is not None, "workflow step must carry one multiline run block")
    assert run_index is not None
    run_indent = len(lines[run_index]) - len(lines[run_index].lstrip())
    body = []
    for line in lines[run_index + 1 :]:
        if line and len(line) - len(line.lstrip()) <= run_indent:
            break
        body.append(line[run_indent + 2 :] if line else "")
    require(body, "workflow multiline run body is empty")
    return "\n".join(body) + "\n"


def workflow_run_bodies(text: str) -> tuple[str, ...]:
    """Return every inline or block ``run`` value from the tracked workflow."""

    lines = text.splitlines()
    bodies = []
    index = 0
    while index < len(lines):
        match = re.match(r"^(?P<indent> *)run:\s*(?P<value>.*)$", lines[index])
        if match is None:
            index += 1
            continue
        value = match.group("value")
        if value not in ("|", "|-", "|+", ">", ">-", ">+"):
            bodies.append(value + "\n")
            index += 1
            continue
        run_indent = len(match.group("indent"))
        body = []
        index += 1
        while index < len(lines):
            line = lines[index]
            if line and len(line) - len(line.lstrip()) <= run_indent:
                break
            body.append(line[run_indent + 2 :] if line else "")
            index += 1
        bodies.append("\n".join(body) + "\n")
    require(bodies, "release workflow has no run commands")
    return tuple(bodies)


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

    resolve_step = workflow_step(text, "Resolve version")
    safe_dispatch_env = """        env:
          DISPATCH_EXPECTED_REF: ${{ inputs.expected_ref }}
          DISPATCH_EXPECTED_OID: ${{ inputs.expected_oid }}
        run: |
"""
    require_once(
        resolve_step,
        safe_dispatch_env,
        "workflow_dispatch inputs must cross the shell boundary through step env",
    )
    resolve_run = multiline_run_body(resolve_step)
    require(
        all("${{ inputs." not in body for body in workflow_run_bodies(text)),
        "workflow_dispatch input is interpolated directly inside a run command",
    )
    require_once(
        resolve_run,
        'if [[ "$GITHUB_EVENT_NAME" == "workflow_dispatch" ]]; then',
        "workflow_dispatch branch must use the trusted runner event variable",
    )
    require_once(
        resolve_run,
        'expected_ref="$DISPATCH_EXPECTED_REF"',
        "expected_ref must be copied from the quoted step environment",
    )
    require_once(
        resolve_run,
        'expected_oid="$DISPATCH_EXPECTED_OID"',
        "expected_oid must be copied from the quoted step environment",
    )
    require("eval " not in resolve_run, "release workflow must not eval dispatch inputs")

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


def validate_release_secret_inventory(workflow: str, release_doc: str) -> None:
    check_run = multiline_run_body(workflow_step(workflow, "Check release secrets"))
    match = re.search(r"for name in \\\n(?P<names>.*?)\n\s*do\n", check_run, re.DOTALL)
    require(match is not None, "release workflow required-secret loop is missing")
    assert match is not None
    workflow_names = tuple(
        re.findall(r"^\s*([A-Z][A-Z0-9_]*)\s*(?:\\)?$", match.group("names"), re.MULTILINE)
    )
    require(
        workflow_names == REQUIRED_RELEASE_SECRETS,
        "release workflow required-secret inventory/order drifted",
    )

    sparkle_names = tuple(
        re.findall(r"^gh secret set ([A-Z][A-Z0-9_]*)\s", release_doc, re.MULTILINE)
    )
    heading = "Required GitHub Actions secrets:\n"
    require_once(release_doc, heading, "release documentation required-secret heading drifted")
    table_start = release_doc.index(heading) + len(heading)
    table_end = release_doc.find("\n\n", table_start)
    require(table_end >= 0, "release documentation required-secret table is unterminated")
    table_names = tuple(
        re.findall(
            r"^\| `([A-Z][A-Z0-9_]*)` \|",
            release_doc[table_start:table_end],
            re.MULTILINE,
        )
    )
    documented_names = sparkle_names + table_names
    require(
        documented_names == workflow_names,
        "release documentation required-secret inventory/classification differs from workflow",
    )


PROVIDER_ENVIRONMENT_KEYS = (
    "THEYOS_APNS_KEY_PATH",
    "THEYOS_APNS_KEY_ID",
    "THEYOS_APNS_TEAM_ID",
    "THEYOS_APNS_TOPIC",
)


def validate_apns_provider_boundary(files: Mapping[str, str]) -> None:
    workflow = files[RELEASE_WORKFLOW]
    build_dmg = files[BUILD_DMG]
    engine_packager = files[ENGINE_PACKAGER]
    install_profile = files[INSTALL_PROFILE]
    launch_spec = files[LAUNCH_SPEC]
    release_plist = files[RELEASE_LAUNCH_AGENT]
    dev_plist = files[DEV_LAUNCH_AGENT]
    launch_tests = files[LAUNCH_AGENT_TESTS]

    for forbidden in (
        "SOYEHT_APNS_P8_BASE64",
        "APNS_KEY_SOURCE",
        "APNS_KEY_PATH",
        "Prepare APNs key",
    ):
        require(forbidden not in workflow, f"release workflow admits APNs provider authority: {forbidden}")

    require(
        files[BUNDLE_APNS_HELPER] == ABSENT_FILE_SENTINEL,
        "dangerous APNs bundle helper still exists",
    )
    require("${HOME}/.soyeht/apns.p8" not in build_dmg,
            "DMG builder reads the legacy local APNs provider key")
    require("Contents/Resources/apns.p8" not in build_dmg,
            "DMG builder names a bundled APNs provider key")
    require("APNS_KEY_DEST" not in build_dmg, "DMG builder retains APNs provider copy logic")
    rejection_loop = (
        "for forbidden_provider_variable in APNS_KEY_SOURCE APNS_KEY_PATH SOYEHT_APNS_P8_BASE64; do\n"
        "    if [[ -n \"${!forbidden_provider_variable:-}\" ]]; then\n"
    )
    require_once(
        build_dmg,
        rejection_loop,
        "DMG builder must reject every legacy provider-key input",
    )

    scanner_function = """scan_product_root() {
    local product_root="$1"
    python3 "${REPO_ROOT}/scripts/ci/check-governed-macos-release.py" \\
        --scan-product "${product_root}"
}
"""
    require_once(
        build_dmg,
        scanner_function,
        "DMG builder must invoke the governed product scanner directly and fail-loud",
    )
    require_once(
        build_dmg,
        'scan_product_root "${STAGING_DIR}"',
        "complete staging root must be scanned before image creation",
    )
    require(
        build_dmg.count('scan_dmg_contents "${DMG_PATH}"') == 2,
        "signed pre-notary and final stapled DMGs must both be mounted and scanned",
    )
    for fragment in (
        "hdiutil attach \\\n        -readonly \\\n        -nobrowse \\\n        -mountpoint \"${DMG_MOUNT_DIR}\"",
        'scan_product_root "${DMG_MOUNT_DIR}"',
    ):
        require_once(build_dmg, fragment, f"DMG mount/scan contract drifted: {fragment}")
    require(
        build_dmg.count('hdiutil detach "${DMG_MOUNT_DIR}"') == 2,
        "DMG scan must detach on success and from the exit trap",
    )
    require(
        build_dmg.index('scan_product_root "${STAGING_DIR}"') < build_dmg.index("hdiutil create"),
        "staging scan occurs after image creation",
    )
    first_dmg_scan = build_dmg.index('scan_dmg_contents "${DMG_PATH}"')
    require(first_dmg_scan < build_dmg.index("notarytool submit"),
            "DMG is disclosed to notarization before its provider-key scan")
    require(build_dmg.rindex('scan_dmg_contents "${DMG_PATH}"') > build_dmg.index("stapler staple"),
            "final stapled DMG is not scanned")

    for forbidden in ("apnsKeyDestinationURL", "installApnsKey", "Contents/Resources/apns.p8"):
        require(forbidden not in engine_packager,
                f"EnginePackager retains client-side provider key handling: {forbidden}")
    require("APNs provider signing keys are" in install_profile,
            "install profile still classifies provider authority as client state")

    for provider_key in PROVIDER_ENVIRONMENT_KEYS:
        require(provider_key not in launch_spec,
                f"LaunchAgent spec exports provider authority: {provider_key}")
        require(provider_key not in release_plist,
                f"release LaunchAgent exports provider authority: {provider_key}")
        require(provider_key not in dev_plist,
                f"dev LaunchAgent exports provider authority: {provider_key}")
        require_once(
            launch_tests,
            f'"{provider_key}"',
            f"LaunchAgent negative test does not name {provider_key}",
        )
    require_once(
        launch_tests,
        "func test_launchAgentsNeverExportAPNsProviderCredentials()",
        "LaunchAgent provider-credential absence test is missing",
    )


def parse_engine_pin(text: str) -> str:
    lines = active_lines(text)
    require(len(lines) == 1, "engine version pin must contain exactly one active line")
    pin = lines[0]
    require(CANONICAL_SEMVER.fullmatch(pin) is not None,
            "engine version pin is not canonical MAJOR.MINOR.PATCH")
    return pin


def parse_engine_checksums(text: str) -> dict[str, str]:
    checksums: dict[str, str] = {}
    for line in active_lines(text):
        match = re.fullmatch(
            r"((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))  ([0-9a-f]{64})",
            line,
        )
        require(match is not None, f"malformed engine checksum entry: {line}")
        assert match is not None
        version, digest = match.groups()
        require(version not in checksums, f"duplicate engine checksum key: {version}")
        checksums[version] = digest
    require(checksums, "engine checksum inventory is empty")
    return checksums


def parse_engine_compat_floor(text: str) -> str:
    pattern = r'public static let minSupportedEngineVersion = "([^"]+)"'
    matches = re.findall(pattern, text)
    require(len(matches) == 1, "engine compatibility floor is missing or ambiguous")
    floor = matches[0]
    require(CANONICAL_SEMVER.fullmatch(floor) is not None,
            "engine compatibility floor is not canonical MAJOR.MINOR.PATCH")
    return floor


def validate_engine_release_pin(files: Mapping[str, str]) -> None:
    """Bind the shipped engine pin, checksum, client floor, tests, and receipt."""

    pin = parse_engine_pin(files[ENGINE_PIN])
    checksums = parse_engine_checksums(files[ENGINE_CHECKSUMS])
    floor = parse_engine_compat_floor(files[ENGINE_COMPAT])

    require(pin == ENGINE_RELEASE_VERSION,
            f"engine version pin must be {ENGINE_RELEASE_VERSION}, found {pin}")
    require(pin in checksums, f"engine checksum is missing for canonical pin {pin}")
    require(LOWER_SHA256.fullmatch(checksums[pin]) is not None,
            f"engine checksum is malformed for canonical pin {pin}")
    require(checksums[pin] == ENGINE_RELEASE_SHA256,
            f"engine checksum differs from the authenticated {pin} release asset")
    require(floor == pin, f"engine compatibility floor {floor} differs from pin {pin}")

    tests = files[ENGINE_COMPAT_TESTS]
    required_test = "func test_currentReleaseRequiresFirstOwnerPhase3Engine()"
    require_once(tests, required_test, "first-owner Phase 3 engine compatibility regression test is missing")
    test_start = tests.index(required_test)
    test_end = tests.find("\n    func ", test_start + len(required_test))
    test_body = tests[test_start : test_end if test_end >= 0 else len(tests)]
    for fragment in (
        f'XCTAssertEqual(EngineCompat.minSupportedEngineVersion, "{pin}")',
        'XCTAssertFalse(EngineCompat.isCompatible("0.1.26"))',
        f'XCTAssertTrue(EngineCompat.isCompatible("{pin}"))',
    ):
        require_once(test_body, fragment, f"engine compatibility regression test drifted: {fragment}")

    require_once(
        files[CLAW_INSTALL_DOC],
        f"# Expected: {pin}",
        "install documentation does not expose the canonical engine pin",
    )

    safe_stages = files[ENGINE_SAFE_STAGES]
    for fragment in (
        f"theyos@{ENGINE_RELEASE_SOURCE}",
        f"refs/tags/v{pin}",
        ENGINE_RELEASE_TREE,
    ):
        require_once(safe_stages, fragment, f"engine diagnostic provenance drifted: {fragment}")
    for stale in ("refs/tags/v0.1.25", "theyos@eb1da518"):
        require(stale not in safe_stages, f"stale engine diagnostic provenance remains: {stale}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        raise ContractError(f"cannot read engine artifact {path}: {error}") from error
    return digest.hexdigest()


def read_json_object(path: Path, label: str) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ContractError(f"cannot read {label} JSON {path}: {error}") from error
    require(isinstance(value, dict), f"{label} JSON must be an object")
    return value


def attestation_subject_digests(document: object) -> list[str]:
    """Extract sha256 subjects from gh attestation verify --format json output."""

    require(isinstance(document, list), "verified attestation JSON must be an array")
    require(len(document) == 1, "verified attestation JSON must contain exactly one entry")
    entry = document[0]
    require(isinstance(entry, dict), "verified attestation entry must be an object")
    verification_result = entry.get("verificationResult")
    require(isinstance(verification_result, dict),
            "verified attestation entry lacks verificationResult")
    statement = verification_result.get("statement")
    require(isinstance(statement, dict), "verified attestation result lacks statement")
    subjects = statement.get("subject")
    require(isinstance(subjects, list), "verified attestation statement lacks subjects")
    digests: list[str] = []
    for subject in subjects:
        require(isinstance(subject, dict), "verified attestation subject must be an object")
        digest = subject.get("digest")
        require(isinstance(digest, dict), "verified attestation subject lacks digest")
        value = digest.get("sha256")
        require(isinstance(value, str) and LOWER_SHA256.fullmatch(value) is not None,
                "verified attestation subject has malformed sha256")
        digests.append(value)
    require(len(digests) == 1, "verified attestation must contain exactly one subject")
    return digests


def validate_engine_artifact(
    files: Mapping[str, str],
    tarball: Path,
    provenance_path: Path,
    verified_attestation_path: Path,
) -> None:
    """Cross-check an artifact after a separately authenticated gh verification.

    This function does not authenticate the JSON. The caller must first run
    ``gh attestation verify`` with the pinned repository, signer workflow,
    source digest, tag ref, and self-hosted-runner denial and pass JSON only
    from that command's successful stdout.
    """

    pin = parse_engine_pin(files[ENGINE_PIN])
    checksums = parse_engine_checksums(files[ENGINE_CHECKSUMS])
    artifact_sha = sha256_file(tarball)
    require(checksums.get(pin) == artifact_sha,
            "engine tarball sha256 differs from the canonical checksum pin")

    provenance = read_json_object(provenance_path, "engine provenance")
    require(provenance.get("schema") == "theyos-engine-release-provenance-v2",
            "engine provenance schema must be theyos-engine-release-provenance-v2")
    require(provenance.get("final_package_sha256") == artifact_sha,
            "engine provenance final_package_sha256 differs from tarball")
    require(provenance.get("source_sha") == ENGINE_RELEASE_SOURCE,
            "engine provenance source_sha differs from the governed release source")
    require(provenance.get("source_tree") == ENGINE_RELEASE_TREE,
            "engine provenance source tree differs from the governed release tree")
    require(provenance.get("signing_job_has_source_checkout") is False,
            "engine signing job provenance reports a source checkout")
    require(provenance.get("signing_job_runs_cargo") is False,
            "engine signing job provenance reports cargo execution")

    try:
        attestation = json.loads(verified_attestation_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ContractError(
            f"cannot read verified attestation JSON {verified_attestation_path}: {error}"
        ) from error
    require(attestation_subject_digests(attestation) == [artifact_sha],
            "verified attestation subject differs from tarball sha256")


def validate_docs(
    release_doc: str,
    agent_doc: str,
    claude_doc: str,
    dev_isolation_doc: str,
) -> None:
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

    provider_boundary = (
        "An APNs provider signing key is server-side authority and must never enter "
        "a client archive, app bundle, installer, DMG, or public release asset."
    )
    require_once(flattened(agent_block), provider_boundary, "AGENTS omits the public-client provider-key boundary")
    require_once(flattened(claude_block), provider_boundary, "CLAUDE omits the public-client provider-key boundary")
    require_once(flattened(release_doc), provider_boundary, "release docs omit the public-client provider-key boundary")
    require_once(
        flattened(dev_isolation_doc),
        "APNs provider signing keys are not client state and are never installed by either profile.",
        "dev isolation docs still classify provider authority as client state",
    )

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
    validate_release_secret_inventory(files[RELEASE_WORKFLOW], files[RELEASE_DOC])
    validate_apns_provider_boundary(files)
    validate_engine_release_pin(files)
    validate_docs(
        files[RELEASE_DOC],
        files[AGENT_DOC],
        files[CLAUDE_DOC],
        files[DEV_ISOLATION_DOC],
    )


def read_snapshot() -> dict[str, str]:
    result = {}
    for relative in CONTRACT_PATHS:
        path = REPO_ROOT / relative
        if relative == BUNDLE_APNS_HELPER and not path.exists():
            result[relative] = ABSENT_FILE_SENTINEL
            continue
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


def replace_nth(text: str, old: str, new: str, occurrence: int) -> str:
    require(occurrence >= 1, "self-test occurrence must be positive")
    starts = [match.start() for match in re.finditer(re.escape(old), text)]
    require(len(starts) >= occurrence, f"self-test occurrence is missing: {old}")
    start = starts[occurrence - 1]
    changed = text[:start] + new + text[start + len(old):]
    require(changed != text, f"self-test did not mutate occurrence {occurrence}: {old}")
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
        Mutant("release-direct-dispatch-interpolation", RELEASE_WORKFLOW,
               lambda s: replace_once(s, 'expected_ref="$DISPATCH_EXPECTED_REF"', 'expected_ref="${{ inputs.expected_ref }}"')),
        Mutant("release-provider-secret-added", RELEASE_WORKFLOW,
               lambda s: s + "\n# SOYEHT_APNS_P8_BASE64 must never be admitted here\n"),
        Mutant("build-provider-fallback-restored", BUILD_DMG,
               lambda s: s + '\nAPNS_KEY_SOURCE="${HOME}/.soyeht/apns.p8"\n'),
        Mutant("bundle-provider-helper-restored", BUNDLE_APNS_HELPER,
               lambda s: replace_once(s, ABSENT_FILE_SENTINEL, "#!/bin/bash\ncp provider.p8 app.p8\n")),
        Mutant("engine-packager-provider-copy-restored", ENGINE_PACKAGER,
               lambda s: s + '\n// installApnsKey Contents/Resources/apns.p8\n'),
        Mutant("install-profile-provider-state-restored", INSTALL_PROFILE,
               lambda s: replace_once(s, "APNs provider signing keys are", "Provider signing keys are")),
        Mutant("launch-spec-provider-path-restored", LAUNCH_SPEC,
               lambda s: s + '\n// THEYOS_APNS_KEY_PATH\n'),
        Mutant("release-plist-provider-path-restored", RELEASE_LAUNCH_AGENT,
               lambda s: s + '\n<!-- THEYOS_APNS_KEY_PATH -->\n'),
        Mutant("dev-plist-provider-path-restored", DEV_LAUNCH_AGENT,
               lambda s: s + '\n<!-- THEYOS_APNS_KEY_PATH -->\n'),
        Mutant("launch-negative-test-weakened", LAUNCH_AGENT_TESTS,
               lambda s: replace_once(s, '        "THEYOS_APNS_TOPIC",\n', "")),
        Mutant("staging-product-scan-removed", BUILD_DMG,
               lambda s: replace_once(s, 'scan_product_root "${STAGING_DIR}"', ': # staging scan removed')),
        Mutant("pre-notary-dmg-scan-removed", BUILD_DMG,
               lambda s: replace_nth(s, 'scan_dmg_contents "${DMG_PATH}"', ': # pre-notary scan removed', 1)),
        Mutant("final-dmg-scan-removed", BUILD_DMG,
               lambda s: replace_nth(s, 'scan_dmg_contents "${DMG_PATH}"', ': # final scan removed', 2)),
        Mutant("product-scanner-masked", BUILD_DMG,
               lambda s: replace_once(
                   s,
                   '        --scan-product "${product_root}"',
                   '        --scan-product "${product_root}" || true',
               )),
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
        Mutant("engine-pin-wrong", ENGINE_PIN,
               lambda s: replace_once(s, "0.1.27\n", "0.1.26\n")),
        Mutant("engine-pin-missing", ENGINE_PIN,
               lambda s: replace_once(s, "0.1.27\n", "# pin removed\n")),
        Mutant("engine-pin-duplicate", ENGINE_PIN,
               lambda s: s + "0.1.27\n"),
        Mutant("engine-pin-malformed", ENGINE_PIN,
               lambda s: replace_once(s, "0.1.27\n", "v0.1.27\n")),
        Mutant("engine-checksum-missing", ENGINE_CHECKSUMS,
               lambda s: replace_once(
                   s,
                   f"0.1.27  {ENGINE_RELEASE_SHA256}\n",
                   "",
               )),
        Mutant("engine-checksum-wrong", ENGINE_CHECKSUMS,
               lambda s: replace_once(s, ENGINE_RELEASE_SHA256, "0" * 64)),
        Mutant("engine-checksum-duplicate", ENGINE_CHECKSUMS,
               lambda s: s + "0.1.27  " + "0" * 64 + "\n"),
        Mutant("engine-checksum-malformed", ENGINE_CHECKSUMS,
               lambda s: replace_once(
                   s,
                   f"0.1.27  {ENGINE_RELEASE_SHA256}\n",
                   f"0.1.27 {ENGINE_RELEASE_SHA256}\n",
               )),
        Mutant("engine-compat-floor-drift", ENGINE_COMPAT,
               lambda s: replace_once(
                   s,
                   'public static let minSupportedEngineVersion = "0.1.27"',
                   'public static let minSupportedEngineVersion = "0.1.26"',
               )),
        Mutant("engine-compat-test-removed", ENGINE_COMPAT_TESTS,
               lambda s: replace_once(
                   s,
                   "func test_currentReleaseRequiresFirstOwnerPhase3Engine()",
                   "func removed_currentReleaseRequiresFirstOwnerPhase3Engine()",
               )),
        Mutant("engine-install-doc-drift", CLAW_INSTALL_DOC,
               lambda s: replace_once(s, "# Expected: 0.1.27", "# Expected: 0.1.26")),
        Mutant("engine-diagnostic-provenance-drift", ENGINE_SAFE_STAGES,
               lambda s: replace_once(s, "refs/tags/v0.1.27", "refs/tags/v0.1.26")),
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
        Mutant("docs-provider-boundary-removed", RELEASE_DOC,
               lambda s: replace_once(
                   s,
                   "An APNs provider signing key is server-side authority and must never enter a",
                   "An APNs provider signing key may enter a",
               )),
        Mutant("agent-provider-boundary-removed", AGENT_DOC,
               lambda s: replace_once(
                   s,
                   "An APNs provider signing key is server-side authority and must never enter a",
                   "An APNs provider signing key may enter a",
               )),
        Mutant("dev-isolation-provider-state-restored", DEV_ISOLATION_DOC,
               lambda s: replace_once(
                   s,
                   "APNs provider signing keys are not client state",
                   "APNs provider signing keys are client state",
               )),
        Mutant("docs-required-secret-extra", RELEASE_DOC,
               lambda s: replace_once(
                   s,
                   "| `APPLE_CODESIGN_IDENTITY` | `Developer ID Application: Gilberto Filho (W7677A5BK2)`. |",
                   "| `APPLE_CODESIGN_IDENTITY` | `Developer ID Application: Gilberto Filho (W7677A5BK2)`. |\n"
                   "| `UNEXPECTED_RELEASE_SECRET` | Self-test-only unexpected inventory entry. |",
               )),
    )


def run_dispatch_injection_control(snapshot: Mapping[str, str]) -> None:
    """Execute the real Resolve-version shell against an adversarial input.

    The safe workflow must reject the payload without executing it.  A
    controlled direct-interpolation mutant must create the marker before the
    same validation turns the run red, proving this control distinguishes the
    vulnerable grammar from inert data transport.
    """

    workflow = snapshot[RELEASE_WORKFLOW]
    run_body = multiline_run_body(workflow_step(workflow, "Resolve version"))
    payload = '\"; printf \'INJECTED_BEFORE_VALIDATION\\n\' > injection-marker; #'

    with tempfile.TemporaryDirectory(prefix="governed-release-injection-") as directory:
        marker = Path(directory) / "injection-marker"
        environment = os.environ.copy()
        environment.update(
            {
                "GITHUB_EVENT_NAME": "workflow_dispatch",
                "GITHUB_REF": "refs/heads/main",
                "DISPATCH_EXPECTED_REF": payload,
                "DISPATCH_EXPECTED_OID": "0" * 40,
            }
        )

        safe = subprocess.run(
            ["bash", "-c", run_body],
            cwd=directory,
            env=environment,
            text=True,
            capture_output=True,
            timeout=5,
            check=False,
        )
        require(safe.returncode != 0, "adversarial dispatch input did not turn the workflow red")
        require(not marker.exists(), "adversarial dispatch input executed before validation")
        require(
            "Expected ref must be a complete macOS annotated tag ref." in safe.stderr,
            "adversarial dispatch input failed for the wrong reason",
        )

        vulnerable = replace_once(
            run_body,
            'expected_ref="$DISPATCH_EXPECTED_REF"',
            'expected_ref="${{ inputs.expected_ref }}"',
        ).replace("${{ inputs.expected_ref }}", payload)
        unsafe = subprocess.run(
            ["bash", "-c", vulnerable],
            cwd=directory,
            env=environment,
            text=True,
            capture_output=True,
            timeout=5,
            check=False,
        )
        require(unsafe.returncode != 0, "direct-interpolation control did not finish red")
        require(marker.read_text(encoding="utf-8") == "INJECTED_BEFORE_VALIDATION\n",
                "direct-interpolation control did not execute the adversarial payload")


def run_product_scan_controls() -> int:
    """Exercise clean and adversarial product trees through the real scanner."""

    passed = 0
    with tempfile.TemporaryDirectory(prefix="governed-product-scan-") as directory:
        fixture_root = Path(directory)
        clean_root = fixture_root / "clean-product"
        framework_version = clean_root / "Soyeht.app/Contents/Frameworks/Example.framework/Versions/A"
        framework_version.mkdir(parents=True)
        (framework_version / "Example").write_bytes(b"signed framework payload\n")
        (framework_version.parent / "Current").symlink_to("A")
        (clean_root / "Applications").symlink_to("/Applications")

        # The notarization key is intentionally outside the scanned product.
        # Its presence proves the scanner is scoped to public payload roots.
        notary_key = fixture_root / "runner/AuthKey_NOTARY.p8"
        notary_key.parent.mkdir()
        notary_key.write_bytes(PRIVATE_KEY_MARKER + b"\nfixture only\n")
        scan_product_root(clean_root)

        cases: tuple[tuple[str, Callable[[Path], None]], ...] = (
            (
                "nested-p8",
                lambda root: (root / "Soyeht.app/Contents/Resources/apns.p8").write_bytes(b"fixture"),
            ),
            (
                "case-insensitive-p8",
                lambda root: (root / "Soyeht.app/Contents/Resources/AuthKey_PROVIDER.P8").write_bytes(b"fixture"),
            ),
            (
                "renamed-pkcs8",
                lambda root: (root / "Soyeht.app/Contents/Resources/provider.dat").write_bytes(
                    b"prefix\n" + PRIVATE_KEY_MARKER + b"\nsuffix\n"
                ),
            ),
            (
                "external-symlink",
                lambda root: (root / "Soyeht.app/Contents/Resources/provider").symlink_to(notary_key),
            ),
            (
                "p8-symlink-name",
                lambda root: (root / "Soyeht.app/Contents/Resources/provider.p8").symlink_to(
                    root / "Soyeht.app/Contents/Resources/clean.txt"
                ),
            ),
            (
                "p8-symlink-target",
                lambda root: (root / "Soyeht.app/Contents/Resources/provider").symlink_to(
                    root / "Soyeht.app/Contents/Resources/AuthKey_PROVIDER.P8"
                ),
            ),
            (
                "broken-symlink",
                lambda root: (root / "Soyeht.app/Contents/Resources/missing").symlink_to("absent"),
            ),
            (
                "noncanonical-applications-link",
                lambda root: (root / "Applications").symlink_to(fixture_root / "elsewhere"),
            ),
        )

        for name, mutate in cases:
            case_root = fixture_root / f"case-{name}"
            resources = case_root / "Soyeht.app/Contents/Resources"
            resources.mkdir(parents=True)
            (resources / "clean.txt").write_bytes(b"clean fixture\n")
            if name != "noncanonical-applications-link":
                (case_root / "Applications").symlink_to("/Applications")
            mutate(case_root)
            try:
                scan_product_root(case_root)
            except ContractError:
                passed += 1
                continue
            raise ContractError(f"product scanner control survived: {name}")

    print(f"public product scanner: {passed}/{len(cases)} adversarial fixtures rejected")
    return passed


def run_engine_artifact_controls(snapshot: Mapping[str, str]) -> int:
    """Prove the artifact cross-check distinguishes each authenticated subject."""

    passed = 0
    with tempfile.TemporaryDirectory(prefix="governed-engine-artifact-") as directory:
        fixture_root = Path(directory)
        tarball = fixture_root / f"theyos-engine-{ENGINE_RELEASE_VERSION}-macos-arm64.tar.gz"
        provenance_path = fixture_root / "provenance.json"
        attestation_path = fixture_root / "verified-attestation.json"
        tarball.write_bytes(b"synthetic engine artifact for checker control\n")
        digest = sha256_file(tarball)

        fixture_snapshot = dict(snapshot)
        fixture_snapshot[ENGINE_CHECKSUMS] = replace_once(
            fixture_snapshot[ENGINE_CHECKSUMS],
            f"0.1.27  {ENGINE_RELEASE_SHA256}",
            f"0.1.27  {digest}",
        )
        provenance: dict[str, object] = {
            "final_package_sha256": digest,
            "phase0_package_manifest_sha256": "1" * 64,
            "published_signed_engine_sha256": "2" * 64,
            "schema": "theyos-engine-release-provenance-v2",
            "signing_job_has_source_checkout": False,
            "signing_job_runs_cargo": False,
            "source_sha": ENGINE_RELEASE_SOURCE,
            "source_tree": ENGINE_RELEASE_TREE,
        }
        attestation: list[object] = [
            {
                "verificationResult": {
                    "statement": {
                        "subject": [
                            {
                                "name": tarball.name,
                                "digest": {"sha256": digest},
                            }
                        ]
                    }
                }
            }
        ]

        def write_fixture() -> None:
            provenance_path.write_text(json.dumps(provenance), encoding="utf-8")
            attestation_path.write_text(json.dumps(attestation), encoding="utf-8")

        write_fixture()
        validate_engine_artifact(
            fixture_snapshot,
            tarball,
            provenance_path,
            attestation_path,
        )

        controls: tuple[tuple[str, Callable[[], None], Callable[[], None]], ...] = (
            (
                "wrong-checksum",
                lambda: fixture_snapshot.__setitem__(
                    ENGINE_CHECKSUMS,
                    replace_once(fixture_snapshot[ENGINE_CHECKSUMS], digest, "0" * 64),
                ),
                lambda: fixture_snapshot.__setitem__(
                    ENGINE_CHECKSUMS,
                    replace_once(fixture_snapshot[ENGINE_CHECKSUMS], "0" * 64, digest),
                ),
            ),
            (
                "wrong-provenance",
                lambda: provenance.__setitem__("final_package_sha256", "0" * 64),
                lambda: provenance.__setitem__("final_package_sha256", digest),
            ),
            (
                "wrong-attestation-subject",
                lambda: attestation[0]["verificationResult"]["statement"]["subject"][0][
                    "digest"
                ].__setitem__("sha256", "0" * 64),
                lambda: attestation[0]["verificationResult"]["statement"]["subject"][0][
                    "digest"
                ].__setitem__("sha256", digest),
            ),
        )

        for name, mutate, restore in controls:
            mutate()
            write_fixture()
            try:
                validate_engine_artifact(
                    fixture_snapshot,
                    tarball,
                    provenance_path,
                    attestation_path,
                )
            except ContractError:
                passed += 1
            else:
                raise ContractError(f"engine artifact control survived: {name}")
            finally:
                restore()
                write_fixture()

        validate_engine_artifact(
            fixture_snapshot,
            tarball,
            provenance_path,
            attestation_path,
        )

    print(f"engine artifact cross-check: {passed}/{len(controls)} adversarial fixtures rejected")
    return passed


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
    run_dispatch_injection_control(snapshot)
    run_product_scan_controls()
    run_engine_artifact_controls(snapshot)
    print(f"governed macOS release contract: {passed}/{len(mutants())} mutants rejected")
    return passed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true", help="also reject the adversarial mutant table")
    parser.add_argument(
        "--scan-product",
        type=Path,
        help="fail if a public product tree contains provider-key material or unsafe links",
    )
    parser.add_argument(
        "--engine-tarball",
        type=Path,
        help="cross-check the pinned engine tarball after separate attestation verification",
    )
    parser.add_argument(
        "--engine-provenance",
        type=Path,
        help="release provenance JSON paired with --engine-tarball",
    )
    parser.add_argument(
        "--verified-attestation-json",
        type=Path,
        help=(
            "stdout JSON from a successful, pinned gh attestation verify invocation; "
            "this checker cross-checks but does not authenticate that JSON"
        ),
    )
    args = parser.parse_args(argv)

    try:
        if args.scan_product is not None:
            require(
                not args.self_test
                and args.engine_tarball is None
                and args.engine_provenance is None
                and args.verified_attestation_json is None,
                "--scan-product cannot be combined with self-test or engine artifact inputs",
            )
            scan_product_root(args.scan_product)
            print(f"public product scanner: PASS: {args.scan_product}")
            return 0
        snapshot = read_snapshot()
        validate_snapshot(snapshot)
        artifact_inputs = (
            args.engine_tarball,
            args.engine_provenance,
            args.verified_attestation_json,
        )
        require(
            all(value is None for value in artifact_inputs)
            or all(value is not None for value in artifact_inputs),
            "engine artifact cross-check requires tarball, provenance, and verified attestation JSON",
        )
        if args.engine_tarball is not None:
            assert args.engine_provenance is not None
            assert args.verified_attestation_json is not None
            validate_engine_artifact(
                snapshot,
                args.engine_tarball,
                args.engine_provenance,
                args.verified_attestation_json,
            )
            print(
                "engine artifact cross-check: PASS "
                "(attestation authentication was performed separately by gh)"
            )
        if args.self_test:
            run_self_tests(snapshot)
    except ContractError as error:
        print(f"governed macOS release contract: FAIL: {error}", file=sys.stderr)
        return 1

    print("governed macOS release contract: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
