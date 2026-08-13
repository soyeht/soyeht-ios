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
RUST = "Install Rust toolchain"
RELAY = "Build RelayStreamGuestFFI XCFramework"
NAT = "Build NatProbeFFI XCFramework"
IOS_BUILD = "Build Soyeht iOS"


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
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("#!/bin/sh\nset -eu\n" + body, encoding="utf-8")
            path.chmod(path.stat().st_mode | stat.S_IXUSR)
        env = os.environ.copy()
        env["PATH"] = f"{directory}:{env['PATH']}"
        env["RUNNER_TEMP"] = str(directory)
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


def require_ios_build_prerequisites(onboarding: str) -> None:
    block = job(onboarding, "ios-build")
    names = (RUST, RELAY, NAT, IOS_BUILD)
    positions = [block.find(f"      - name: {name}\n") for name in names]
    assert all(position >= 0 for position in positions), "missing iOS build prerequisite"
    assert positions == sorted(positions), "iOS build prerequisites are out of order"
    assert re.search(
        r"^          RELAY_STREAM_GUEST_FFI_PROFILE:\s*release\s*$",
        step(block, RELAY),
        re.M,
    )
    assert re.search(
        r"^          NAT_PROBE_FFI_PROFILE:\s*release\s*$",
        step(block, NAT),
        re.M,
    )
    assert script(step(block, RELAY)).strip() == "scripts/bootstrap-relay-stream-guest-ffi.sh"
    assert script(step(block, NAT)).strip() == "scripts/bootstrap-nat-probe-ffi.sh"


def main() -> None:
    onboarding = ONBOARDING.read_text(encoding="utf-8")
    accessibility = ACCESSIBILITY.read_text(encoding="utf-8")
    assert '- "TerminalApp/SoyehtTests/**"' in accessibility
    require_ios_build_prerequisites(onboarding)

    prerequisite_mutants = []
    for name in (RELAY, NAT):
        block = step(onboarding, name)
        prerequisite_mutants.append(onboarding.replace(block, "", 1))
    relay_block = step(onboarding, RELAY)
    relay_after_build = onboarding.replace(relay_block, "", 1)
    build_block = step(relay_after_build, IOS_BUILD)
    relay_after_build = relay_after_build.replace(
        build_block,
        build_block + "\n\n" + relay_block,
        1,
    )
    prerequisite_mutants.append(relay_after_build)
    for mutant in prerequisite_mutants:
        try:
            require_ios_build_prerequisites(mutant)
        except AssertionError:
            continue
        raise AssertionError("iOS build prerequisite mutant passed")

    prebuild_run = "\n".join(
        script(step(onboarding, name)) for name in (RELAY, NAT, IOS_BUILD)
    )
    prebuild_tools = {
        "uname": "printf 'arm64\\n'",
        "scripts/bootstrap-relay-stream-guest-ffi.sh": (
            'test "$RELAY_STREAM_GUEST_FFI_PROFILE" = release\n'
            'touch "$RUNNER_TEMP/relay.ready"'
        ),
        "scripts/bootstrap-nat-probe-ffi.sh": (
            'test "$NAT_PROBE_FFI_PROFILE" = release\n'
            'touch "$RUNNER_TEMP/nat.ready"'
        ),
        "xcodebuild": (
            'test -f "$RUNNER_TEMP/relay.ready"\n'
            'test -f "$RUNNER_TEMP/nat.ready"\n'
            'printf "BUILD SUCCEEDED\\n"\n'
            'printf reached > "$BUILD_REACHED"'
        ),
    }
    profiles = {
        "RELAY_STREAM_GUEST_FFI_PROFILE": "release",
        "NAT_PROBE_FFI_PROFILE": "release",
    }
    with tempfile.TemporaryDirectory() as raw:
        reached = Path(raw) / "build-reached"
        expect(
            execute(prebuild_run, prebuild_tools, profiles | {"BUILD_REACHED": str(reached)}),
            True,
            "iOS build prerequisites",
        )
        assert reached.read_text(encoding="utf-8") == "reached"
        blocked = Path(raw) / "build-blocked"
        failing_tools = prebuild_tools | {
            "scripts/bootstrap-relay-stream-guest-ffi.sh": "exit 31"
        }
        expect(
            execute(prebuild_run, failing_tools, profiles | {"BUILD_REACHED": str(blocked)}),
            False,
            "iOS build prerequisite failure",
        )
        assert not blocked.exists()

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
    xcodebuild = r'''
bundle=
selected=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -resultBundlePath) bundle="$2"; shift 2 ;;
    -only-testing:*) selected="${1#-only-testing:SoyehtTests/}"; shift ;;
    *) shift ;;
  esac
done
test -n "$bundle"
test -n "$selected"
case "${XCODE_MODE:-}" in
  fail-ar) case "$bundle" in *accessibility-ar.xcresult) exit 17;; esac ;;
  fail-ax5) case "$bundle" in *accessibility-ax5.xcresult) exit 17;; esac ;;
  missing-ar) case "$bundle" in *accessibility-ar.xcresult) exit 0;; esac ;;
esac
mkdir -p "$bundle"
if [ "${XCODE_MODE:-}" = same-root ]; then
  root=shared-root
else
  case "$bundle" in
    *accessibility-ar.xcresult) root=ar-root ;;
    *accessibility-ax5.xcresult) root=ax5-root ;;
    *) root=unexpected-root ;;
  esac
fi
printf '%s\n' "$root" > "$bundle/root"
printf '%s()\n' "$selected" > "$bundle/node"
'''
    xcrun = r'''
test "${XCRUN_MODE:-}" != fail
path=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --path) path="$2"; shift 2 ;;
    *) shift ;;
  esac
done
test -d "$path"
case "${XCRUN_MODE:-}" in
  malformed) printf '{not-json\n'; exit 0 ;;
  zero-ar) case "$path" in *accessibility-ar.xcresult) printf '{"testNodes":[{"nodeType":"Test Plan"}]}\n'; exit 0;; esac ;;
  zero-ax5) case "$path" in *accessibility-ax5.xcresult) printf '{"testNodes":[{"nodeType":"Test Plan"}]}\n'; exit 0;; esac ;;
esac
node="$(cat "$path/node")"
case "${XCRUN_MODE:-}" in
  wrong-ar) case "$path" in *accessibility-ar.xcresult) node='ParkingLotSnapshotTests/testParkingLot_en_AX5()';; esac ;;
esac
printf '{"testNodes":[{"children":[{"children":[{"children":[{"nodeIdentifier":"%s","nodeType":"Test Case"}],"name":"ParkingLotSnapshotTests","nodeType":"Test Suite"}],"nodeType":"Unit test bundle"}],"nodeType":"Test Plan"}]}\n' "$node"
'''
    plutil = r'''
for argument in "$@"; do path="$argument"; done
cat "${path%/Info.plist}/root"
'''
    access_tools = {
        "uname": "printf 'arm64\\n'",
        "xcodebuild": xcodebuild,
        "xcrun": xcrun,
        "plutil": plutil,
    }
    expect(execute(access_run, access_tools), True, "accessibility evidence")
    for mode in ("fail-ar", "fail-ax5", "missing-ar", "same-root"):
        expect(
            execute(access_run, access_tools, {"XCODE_MODE": mode}),
            False,
            f"accessibility {mode}",
        )
    for mode in ("zero-ar", "zero-ax5", "wrong-ar", "malformed", "fail"):
        expect(
            execute(access_run, access_tools, {"XCRUN_MODE": mode}),
            False,
            f"accessibility {mode}",
        )

    shared = access_run.replace(
        'AX5_RESULT="$RUNNER_TEMP/accessibility-ax5.xcresult"',
        'AX5_RESULT="$RUNNER_TEMP/accessibility-ar.xcresult"',
        1,
    )
    assert shared != access_run
    expect(execute(shared, access_tools), False, "accessibility shared bundle")

    ar_path = '-resultBundlePath "$AR_RESULT"'
    ax5_path = '-resultBundlePath "$AX5_RESULT"'
    assert access_run.count(ar_path) == access_run.count(ax5_path) == 1
    swapped = access_run.replace(ar_path, "-resultBundlePath \"$SWAP_RESULT\"", 1)
    swapped = swapped.replace(ax5_path, ar_path, 1)
    swapped = swapped.replace("-resultBundlePath \"$SWAP_RESULT\"", ax5_path, 1)
    expect(execute(swapped, access_tools), False, "accessibility swapped bundles")

    diff_run = script(step(accessibility, "Verify no snapshot regressions"))
    expect(execute(diff_run, {"git": "exit 0"}), True, "snapshot clean")
    expect(execute(diff_run, {"git": "exit 1"}), False, "snapshot mutation")
    expect(execute(access_run, access_tools, {"XCRUN_MODE": "zero-ar"}), False, "clean diff cannot rescue zero tests")

    core = "Run SoyehtCore tests"
    harness = "Run EngineHarnessTests in isolated CI"
    assert job_of(onboarding, core) != job_of(onboarding, harness)
    assert job_of(onboarding, DIAGNOSTIC) == job_of(onboarding, harness)
    expect(execute(script(step(onboarding, core)), {"swift": "exit 0"}), True, "core")
    expect(execute(script(step(onboarding, harness)), {"swift": "exit 29"}), False, "harness")
    print("workflow-signal-hardening: all controls passed")


if __name__ == "__main__":
    main()
