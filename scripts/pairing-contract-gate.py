#!/usr/bin/env python3
"""Run local Swift clients against Rust test routers; require every catalog route.

This gate never installs an app, starts an engine binary, or uses fixed service
ports. Both checkouts are mandatory. Missing execution evidence is a failure.
"""

import argparse
import json
import hashlib
import re
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

BRIDGE_TEST = "household_listener::pairing_cross_repo_bridge::serve_cross_repo_contract"


def run(command, *, cwd, env, log):
    with log.open("w") as stream:
        result = subprocess.run(command, cwd=cwd, env=env, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=900)
    if result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}); see {log}")


def require_checkout(path, required):
    path = path.resolve(strict=True)
    subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=path,
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    for relative in required:
        if not (path / relative).is_file():
            raise RuntimeError(f"required source missing: {path / relative}")
    return path


def source_receipt(swift, rust, catalog):
    paths = {(swift, "Packages/SoyehtCore/Package.swift"),
             (swift, "Packages/SoyehtCore/Tests/PairingContractTests/PairingContractTests.swift"),
             (swift, "docs/contracts/pairing/v1/route-catalog.json"),
             (swift, "scripts/pairing-contract-gate.py"),
             (rust, "admin/rust/server-rs/src/pairing_cross_repo_bridge.rs"),
             (rust, "admin/rust/server-rs/src/household_bootstrap.rs")}
    for entry in catalog["routes"]:
        for field, root in [("swift_source", swift), ("rust_source", rust)]:
            if entry.get(field):
                paths.add((root, entry[field]))
    for relative in ["Packages/SoyehtCore/Sources", "TerminalApp/SoyehtMac/Pairing",
                     "TerminalApp/SoyehtMac/Welcome/SetupInvitationListener"]:
        paths.update((swift, str(p.relative_to(swift))) for p in (swift / relative).rglob("*.swift"))
    return {f"{'swift' if root == swift else 'rust'}/{relative}":
            hashlib.sha256((root / relative).read_bytes()).hexdigest()
            for root, relative in sorted(paths, key=lambda value: str(value))}


def dependency_guards(swift, rust):
    # Legacy administrative selectors must not choose a household destination.
    files = [(rust, "admin/rust/server-rs/src/handlers_bootstrap.rs"),
             (rust, "admin/rust/server-rs/src/pairing_addresses.rs"),
             (swift, "TerminalApp/SoyehtMac/Welcome/SetupInvitationListener/MacEngineAdvertisedURL.swift")]
    for root, relative in files:
        source = (root / relative).read_text()
        source = re.sub(r"/\*.*?\*/|//[^\n]*", "", source, flags=re.S)
        for symbol in ["best_qr_host", "build_mac_engine_url"]:
            if symbol in source:
                raise RuntimeError(f"administrative selector in household dependency: {relative}: {symbol}")
    production = (rust / "admin/rust/server-rs/src/household_bootstrap.rs").read_text().split("#[cfg(test)]\nmod tests")[0]
    for call in ["handlers_device_pairing::device_pairing_router(", "handlers_pair_device::pair_device_router("]:
        if production.count(call) != 1:
            raise RuntimeError(f"production does not mount the tested router exactly once: {call}")
    stale = "SOYEHT_SETUP_INVITATION_ALLOW_LAN"
    for path in (swift / "TerminalApp/SoyehtMac").rglob("*.swift"):
        if stale in path.read_text():
            raise RuntimeError(f"unused LAN environment switch returned: {path.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--theyos-root", type=Path, required=True)
    parser.add_argument("--swift-build", type=Path, default=Path("/tmp/soyeht-jaime-pairing-core"))
    parser.add_argument("--rust-build", type=Path, default=Path("/tmp/soyeht-jaime-pairing-rust"))
    args = parser.parse_args()
    swift = require_checkout(args.swift_root, ["Packages/SoyehtCore/Package.swift",
        "Packages/SoyehtCore/Tests/PairingContractTests/PairingContractTests.swift",
        "docs/contracts/pairing/v1/route-catalog.json"])
    rust = require_checkout(args.theyos_root, ["admin/rust/Cargo.toml",
        "admin/rust/server-rs/src/pairing_cross_repo_bridge.rs"])
    catalog = json.loads((swift / "docs/contracts/pairing/v1/route-catalog.json").read_text())
    expected = {entry["id"] for entry in catalog["routes"]}
    if not expected or len(expected) != len(catalog["routes"]):
        raise RuntimeError("empty or duplicate route inventory")
    for entry in catalog["routes"]:
        if entry.get("planned_route") or not entry.get("execution"):
            raise RuntimeError(f"route is not executable: {entry['id']}")
        for field, root in [("swift_source", swift), ("rust_source", rust)]:
            source = entry.get(field)
            if source and not (root / source).is_file():
                raise RuntimeError(f"{entry['id']}: missing {field}: {source}")

    dependency_guards(swift, rust)
    receipt = source_receipt(swift, rust, catalog)
    output = Path(tempfile.mkdtemp(prefix="soyeht-pairing-contract-"))
    print(f"Contract evidence: {output}", flush=True)
    env = {**os.environ, "SOYEHT_PAIRING_CONTRACT": "1",
           "SOYEHT_PAIRING_CONTRACT_DIR": str(output), "SOYEHT_PAIRING_SWIFT_ROOT": str(swift)}
    swift_base = ["swift", "test", "--disable-build-manifest-caching", "--package-path",
                  str(swift / "Packages/SoyehtCore"), "--scratch-path", str(args.swift_build), "--jobs", "2"]
    cargo = ["cargo", "test", "--manifest-path", str(rust / "admin/rust/Cargo.toml"),
             "-p", "server-rs", "--lib", "--target-dir", str(args.rust_build), "--jobs", "2"]
    build = ["swift", "build", "--build-tests", *swift_base[2:]]
    run(build, cwd=swift, env=env, log=output / "swift-build.log")
    run([*cargo, "--no-run", "--message-format=json"], cwd=rust, env=env, log=output / "rust-build.log")
    executables = []
    for line in (output / "rust-build.log").read_text().splitlines():
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if (message.get("reason") == "compiler-artifact" and message.get("executable")
                and message.get("target", {}).get("name") == "server_rs"
                and message.get("profile", {}).get("test")):
            executables.append(message["executable"])
    if len(set(executables)) != 1:
        raise RuntimeError("could not identify the compiled Rust contract host")
    executable = executables[0]
    for fault, marker in [(None, None), ("renamed-route", "renamed-route:404"),
                          ("renamed-expiry", "renamed-expiry:200"),
                          ("persisted-lan", "persisted-lan:after-confirm")]:
        scenario = output / (fault or "positive")
        scenario.mkdir()
        scenario_env = {**env, "SOYEHT_PAIRING_CONTRACT_DIR": str(scenario)}
        scenario_env.pop("SOYEHT_PAIRING_CONTRACT_FAULT", None)
        if fault:
            scenario_env["SOYEHT_PAIRING_CONTRACT_FAULT"] = fault
        exercise(executable, swift_base, swift, rust, scenario_env, scenario, expected, marker)
    if receipt != source_receipt(swift, rust, catalog):
        raise RuntimeError("contract sources changed during verification; rerun the gate")
    (output / "receipt.json").write_text(json.dumps({
        "routes": sorted(expected), "negative_controls": ["renamed-route", "renamed-expiry", "persisted-lan"],
        "sources_sha256": receipt,
        "swift_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=swift, text=True).strip(),
        "rust_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=rust, text=True).strip(),
    }, indent=2) + "\n")
    print(f"PASS: {len(expected)} routes; 3 activated regressions rejected; evidence: {output}")


def exercise(executable, swift_base, swift, rust, env, output, expected, marker):

    with (output / "rust-run.log").open("w") as rust_log:
        host = subprocess.Popen([executable, BRIDGE_TEST, "--ignored", "--exact", "--nocapture"],
                                cwd=rust, env=env, stdout=rust_log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 60
            while not (output / "bridge.json").is_file():
                if host.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError(f"Rust host did not start; see {output / 'rust-run.log'}")
                time.sleep(0.1)
            failure = None
            try:
                run([*swift_base, "--skip-build", "--filter", "PairingContractTests.testLivePairingContract"],
                    cwd=swift, env=env, log=output / "swift-run.log")
            except RuntimeError as error:
                failure = error
            log = (output / "swift-run.log").read_text()
            if not re.search(r"Executed 1 test, with [0-9]+ failure", log) or " skipped" in log:
                raise RuntimeError(f"missing execution or skipped contract test: {output}")
            if marker:
                activated = output / "fault-activated"
                if not activated.is_file() or activated.read_text() != marker or failure is None:
                    raise RuntimeError(f"negative control did not activate and fail: {output}")
                # A crash, host failure, or unrelated assertion cannot calibrate a control.
                expected_diagnostic = {
                    "renamed-route:404": "wrongContentType(returned: nil)",
                    "renamed-expiry:200": "protocolViolation",
                    "persisted-lan:after-confirm": "XCTAssertEqual failed",
                }[marker]
                if expected_diagnostic not in log:
                    raise RuntimeError(f"negative control failed for an unrelated reason: {output}")
            else:
                if failure:
                    raise failure
                actual = set(json.loads((output / "swift-routes.json").read_text()))
                missing = sorted(expected - actual)
                extra = sorted(actual - expected)
                if missing or extra:
                    raise RuntimeError(f"route coverage mismatch: missing={missing}, unlisted={extra}")
            (output / "stop").touch()
            if host.wait(timeout=30):
                raise RuntimeError(f"Rust host failed; see {output / 'rust-run.log'}")
        finally:
            (output / "stop").touch()
            if host.poll() is None:
                try:
                    host.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    host.terminate()
                    host.wait(timeout=10)
    rust_log_text = (output / "rust-run.log").read_text()
    if "1 passed; 0 failed; 0 ignored" not in rust_log_text:
        raise RuntimeError(f"missing Rust execution or skipped host: {output}")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
