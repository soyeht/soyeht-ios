#!/usr/bin/env python3
"""Reproducible Claw Store QA matrix runner.

The default run is intentionally a reporting matrix, not a release-readiness
claim. Rows that need a live engine, VZ, Firecracker, or client UI automation
are default SKIP and only run when their explicit opt-in environment is present.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Iterable


STATUS_PASS = "PASS"
STATUS_FAIL = "FAIL"
STATUS_SKIP = "SKIP"
LIVE_ENV = "SOYEHT_F3_RUN_LIVE"
LINUX_LIFECYCLE_ENV = "SOYEHT_F3_RUN_LINUX_LIFECYCLE"
LINUX_SSH_KEY_ENV = "SOYEHT_F3_LINUX_SSH_KEY"
LINUX_STATE_DIR_ENV = "SOYEHT_F3_LINUX_STATE_DIR"
LINUX_TERMINAL_ENV = "SOYEHT_F3_LINUX_RUN_TERMINAL"
ADMIN_PASSWORD_ENV = "SOYEHT_ADMIN_PASSWORD"
MAC_VZ_ENV = "SOYEHT_F3_RUN_MAC_VZ"
MAC_LIFECYCLE_ENV = "SOYEHT_F3_RUN_MAC_LIFECYCLE"
MAC_SSH_KEY_ENV = "SOYEHT_F3_MAC_SSH_KEY"
MAC_TERMINAL_ENV = "SOYEHT_F3_MAC_RUN_TERMINAL"
S1_TRANSPORT_ENV = "SOYEHT_F3_RUN_S1_TRANSPORT"
S1_READY_LOOPBACK_URL_ENV = "SOYEHT_F3_S1_READY_LOOPBACK_URL"
S1_READY_TAILNET_URL_ENV = "SOYEHT_F3_S1_READY_TAILNET_URL"
S1_READY_LAN_URL_ENV = "SOYEHT_F3_S1_READY_LAN_URL"
S1_ONBOARDING_LAN_URL_ENV = "SOYEHT_F3_S1_ONBOARDING_LAN_URL"
CLIENT_UI_ENV = "SOYEHT_F3_RUN_CLIENT_UI"
CLIENT_UI_BUILD_INSTALL_ENV = "SOYEHT_F3_CLIENT_UI_BUILD_INSTALL"
CLIENT_UI_DEV_BUNDLE_ID = "com.soyeht.app.dev"
CLIENT_UI_SMOKE_SCRIPT = "QA/scripts/run_claw_client_ui_smoke.py"
RELAY_FFI_PATH = Path("Native/RelayStreamGuestFFI/RelayStreamGuestFFI.xcframework")
RELAY_FFI_LEGACY_PATH = Path("Native/RelayStreamGuestFFI/RelayStreamGuestFFIBinary.xcframework")
VZ_ISOLATION_ENVS = (
    "THEYOS_VM_VMS_PATH",
    "THEYOS_VM_STATE_DIR",
    "THEYOS_SNAPSHOTS_DIR",
    "THEYOS_VM_ASSETS_DIR",
)
VZ_SCRATCH_SENTINEL = "live-vz-scratch"


@dataclass
class CommandSpec:
    argv: list[str]
    cwd: Path
    env: dict[str, str] = field(default_factory=dict)


@dataclass
class MatrixRow:
    row_id: str
    title: str
    coverage: str
    commands: list[CommandSpec] = field(default_factory=list)
    skip_reason: str | None = None
    fail_reason: str | None = None


@dataclass
class RowResult:
    row_id: str
    title: str
    status: str
    coverage: str
    duration_seconds: float = 0.0
    commands: list[str] = field(default_factory=list)
    notes: str = ""
    log: str | None = None


class Redactor:
    def __init__(self, replacements: Iterable[tuple[str, str]] = ()) -> None:
        self.replacements = [(old, new) for old, new in replacements if old]

    def text(self, value: str) -> str:
        redacted = value
        for old, new in self.replacements:
            redacted = redacted.replace(old, new)
        patterns = [
            (r"Bearer\s+[A-Za-z0-9._~+/=-]+", "Bearer <redacted>"),
            (r"(--user\s+)(?:'[^']*'|\"[^\"]*\"|[^\s)]+)", r"\1<user-redacted>"),
            (r"(--user=)(?:'[^']*'|\"[^\"]*\"|[^\s)]+)", r"\1<user-redacted>"),
            (r"(--base-url\s+)(?:'[^']*'|\"[^\"]*\"|[^\s)]+)", r"\1<url-redacted>"),
            (r"(--base-url=)(?:'[^']*'|\"[^\"]*\"|[^\s)]+)", r"\1<url-redacted>"),
            (r"(--ssh-key\s+)(?:'[^']*'|\"[^\"]*\"|[^\s)]+)", r"\1<path-redacted>"),
            (r"(--ssh-key=)(?:'[^']*'|\"[^\"]*\"|[^\s)]+)", r"\1<path-redacted>"),
            (r"(--state-dir\s+)(?:'[^']*'|\"[^\"]*\"|[^\s)]+)", r"\1<path-redacted>"),
            (r"(--state-dir=)(?:'[^']*'|\"[^\"]*\"|[^\s)]+)", r"\1<path-redacted>"),
            (r"(?i)(token|secret|password|authorization)(=|:)\s*[^,\s\"']+", r"\1\2 <redacted>"),
            (r"https?://[^\s\"')>]+", "<url-redacted>"),
            (r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "192.0.2.10"),
            (r"/Users/[^/\s]+", "/Users/<user>"),
        ]
        for pattern, replacement in patterns:
            redacted = re.sub(pattern, replacement, redacted)
        return redacted


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def display_cwd(path: Path, repo_root: Path, theyos_dir: Path | None) -> str:
    try:
        return f"<soyeht-ios>/{path.relative_to(repo_root)}"
    except ValueError:
        pass
    if theyos_dir is not None:
        try:
            return f"<theyos>/{path.relative_to(theyos_dir)}"
        except ValueError:
            pass
    return "<external>"


def display_command(command: CommandSpec, repo_root: Path, theyos_dir: Path | None) -> str:
    quoted = shlex.join(command.argv)
    return f"(cd {display_cwd(command.cwd, repo_root, theyos_dir)} && {quoted})"


def resolve_theyos_dir(repo_root: Path, explicit: str | None) -> Path | None:
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit).expanduser())
    if os.environ.get("THEYOS_DIR"):
        candidates.append(Path(os.environ["THEYOS_DIR"]).expanduser())
    candidates.extend([
        repo_root.parent / "theyos",
        Path.home() / "Documents" / "theyos",
        Path.home() / "Documents" / "SwiftProjects" / "theyos",
    ])
    for candidate in candidates:
        if (candidate / "admin" / "rust" / "Cargo.toml").is_file():
            return candidate.resolve()
    return None


def command_exists(name: str) -> bool:
    return shutil.which(name) is not None


def run_commands(
    row: MatrixRow,
    *,
    repo_root: Path,
    theyos_dir: Path | None,
    run_dir: Path,
    redactor: Redactor,
    timeout_seconds: int,
) -> RowResult:
    started = time.monotonic()
    if row.fail_reason:
        return RowResult(
            row_id=row.row_id,
            title=row.title,
            status=STATUS_FAIL,
            coverage=row.coverage,
            notes=row.fail_reason,
        )
    if row.skip_reason:
        return RowResult(
            row_id=row.row_id,
            title=row.title,
            status=STATUS_SKIP,
            coverage=row.coverage,
            notes=row.skip_reason,
        )

    log_path = run_dir / f"{row.row_id}.log"
    command_strings = [
        redactor.text(display_command(cmd, repo_root, theyos_dir))
        for cmd in row.commands
    ]
    with log_path.open("w", encoding="utf-8") as handle:
        for index, command in enumerate(row.commands, start=1):
            handle.write(f"$ {command_strings[index - 1]}\n")
            env = os.environ.copy()
            env.update(command.env)
            try:
                completed = subprocess.run(
                    command.argv,
                    cwd=command.cwd,
                    env=env,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    timeout=timeout_seconds,
                    check=False,
                )
            except subprocess.TimeoutExpired as exc:
                output = exc.stdout or ""
                handle.write(redactor.text(output))
                handle.write(f"\nTIMEOUT after {timeout_seconds}s\n")
                return RowResult(
                    row_id=row.row_id,
                    title=row.title,
                    status=STATUS_FAIL,
                    coverage=row.coverage,
                    duration_seconds=round(time.monotonic() - started, 2),
                    commands=command_strings,
                    notes=f"Command timed out after {timeout_seconds}s",
                    log=str(log_path.relative_to(run_dir.parent)),
                )

            handle.write(redactor.text(completed.stdout))
            if completed.returncode != 0:
                handle.write(f"\nEXIT {completed.returncode}\n")
                return RowResult(
                    row_id=row.row_id,
                    title=row.title,
                    status=STATUS_FAIL,
                    coverage=row.coverage,
                    duration_seconds=round(time.monotonic() - started, 2),
                    commands=command_strings,
                    notes=f"Command {index} exited {completed.returncode}",
                    log=str(log_path.relative_to(run_dir.parent)),
                )
            handle.write("\n")

    return RowResult(
        row_id=row.row_id,
        title=row.title,
        status=STATUS_PASS,
        coverage=row.coverage,
        duration_seconds=round(time.monotonic() - started, 2),
        commands=command_strings,
        notes=f"{len(row.commands)} command(s) passed",
        log=str(log_path.relative_to(run_dir.parent)),
    )


def linux_lifecycle_preflight(theyos_dir: Path | None) -> list[str]:
    missing: list[str] = []
    if theyos_dir is None:
        missing.append("THEYOS_DIR")
    if not command_exists("cargo"):
        missing.append("cargo")
    if not os.environ.get(ADMIN_PASSWORD_ENV):
        missing.append(ADMIN_PASSWORD_ENV)

    ssh_key = os.environ.get(LINUX_SSH_KEY_ENV)
    if not ssh_key:
        missing.append(LINUX_SSH_KEY_ENV)
    elif not Path(ssh_key).expanduser().is_file():
        missing.append(f"{LINUX_SSH_KEY_ENV} file")

    state_dir = os.environ.get(LINUX_STATE_DIR_ENV)
    if not state_dir:
        missing.append(LINUX_STATE_DIR_ENV)
    elif not Path(state_dir).expanduser().is_dir():
        missing.append(f"{LINUX_STATE_DIR_ENV} directory")

    return missing


def scratch_dir_issue(var: str) -> str | None:
    value = os.environ.get(var)
    if not value:
        return var
    path = Path(value).expanduser()
    rendered = str(path)
    if not path.is_absolute():
        return f"{var} absolute path"
    if VZ_SCRATCH_SENTINEL not in rendered:
        return f"{var} under {VZ_SCRATCH_SENTINEL}"
    if "/Applications/Soyeht.app" in rendered or "/Applications/Soyeht Dev.app" in rendered:
        return f"{var} must not be inside app bundle"
    if not path.is_dir():
        return f"{var} directory"
    return None


def mac_lifecycle_preflight(theyos_dir: Path | None) -> list[str]:
    missing: list[str] = []
    if theyos_dir is None:
        missing.append("THEYOS_DIR")
    if not command_exists("cargo"):
        missing.append("cargo")
    if not (os.environ.get("SOYEHT_F3_BASE_URL") or os.environ.get("SOYEHT_BASE_URL")):
        missing.append("SOYEHT_F3_BASE_URL or SOYEHT_BASE_URL")
    if os.environ.get("THEYOS_LIVE_VZ") != "1":
        missing.append("THEYOS_LIVE_VZ=1")
    if not os.environ.get(ADMIN_PASSWORD_ENV):
        missing.append(ADMIN_PASSWORD_ENV)

    ssh_key = os.environ.get(MAC_SSH_KEY_ENV)
    if not ssh_key:
        missing.append(MAC_SSH_KEY_ENV)
    elif not Path(ssh_key).expanduser().is_file():
        missing.append(f"{MAC_SSH_KEY_ENV} file")

    for var in VZ_ISOLATION_ENVS:
        issue = scratch_dir_issue(var)
        if issue:
            missing.append(issue)

    assets_dir = os.environ.get("THEYOS_VM_ASSETS_DIR")
    if assets_dir:
        base_dir = Path(assets_dir).expanduser() / "macos-base"
        if not base_dir.is_dir():
            missing.append("THEYOS_VM_ASSETS_DIR/macos-base directory")

    return missing


def build_mac_lifecycle_row(
    *,
    theyos_dir: Path | None,
    live_base_url: str,
    live_user: str,
) -> MatrixRow:
    live_enabled = os.environ.get(LIVE_ENV) == "1"
    lifecycle_enabled = os.environ.get(MAC_LIFECYCLE_ENV) == "1"
    if not live_enabled or not lifecycle_enabled:
        return MatrixRow(
            row_id="mac-admin-lifecycle",
            title="Mac VZ admin-host Claw lifecycle",
            coverage=(
                "Opt-in destructive Mac/VZ admin-host create, poll, active, SSH, "
                "claw-binary, delete, and verify cleanup for picoclaw against Dev/scratch state."
            ),
            skip_reason=(
                f"default SKIP; set {LIVE_ENV}=1 and {MAC_LIFECYCLE_ENV}=1 "
                "for destructive Mac/VZ admin-host lifecycle"
            ),
        )

    missing = mac_lifecycle_preflight(theyos_dir)
    if missing:
        return MatrixRow(
            row_id="mac-admin-lifecycle",
            title="Mac VZ admin-host Claw lifecycle",
            coverage=(
                "Opt-in destructive Mac/VZ admin-host create, poll, active, SSH, "
                "claw-binary, delete, and verify cleanup for picoclaw against Dev/scratch state."
            ),
            fail_reason=(
                "live Mac lifecycle gate is set but preflight is missing or invalid: "
                + ", ".join(missing)
            ),
        )

    assert theyos_dir is not None
    ssh_key = str(Path(os.environ[MAC_SSH_KEY_ENV]).expanduser())
    vms_dir = str(Path(os.environ["THEYOS_VM_VMS_PATH"]).expanduser())
    argv = [
        "cargo", "run", "-p", "e2e-rs", "--",
        "--base-url", live_base_url,
        "--user", live_user,
        "--ssh-key", ssh_key,
        "--state-dir", vms_dir,
        "test", "picoclaw",
        "--guest-os", "macos",
    ]
    if os.environ.get(MAC_TERMINAL_ENV) != "1":
        argv.extend([
            "--skip-terminal",
            "--skip-terminal-restart",
            "--skip-terminal-persist",
        ])
    argv.append("--skip-refill-test")

    return MatrixRow(
        row_id="mac-admin-lifecycle",
        title="Mac VZ admin-host Claw lifecycle",
        coverage=(
            "Opt-in destructive Mac/VZ admin-host create, poll, active, SSH via scratch vm_ip, "
            "claw-binary, delete, and verify cleanup for picoclaw; terminal/attach is excluded "
            f"unless {MAC_TERMINAL_ENV}=1."
        ),
        commands=[CommandSpec(
            argv,
            theyos_dir / "admin" / "rust",
            {ADMIN_PASSWORD_ENV: os.environ[ADMIN_PASSWORD_ENV]},
        )],
    )


def s1_transport_preflight() -> list[str]:
    missing: list[str] = []
    if not command_exists("python3"):
        missing.append("python3")
    for var in (
        S1_READY_LOOPBACK_URL_ENV,
        S1_READY_TAILNET_URL_ENV,
        S1_READY_LAN_URL_ENV,
        S1_ONBOARDING_LAN_URL_ENV,
    ):
        if not os.environ.get(var):
            missing.append(var)
    return missing


def build_s1_transport_row(repo_root: Path) -> MatrixRow:
    live_enabled = os.environ.get(LIVE_ENV) == "1"
    transport_enabled = os.environ.get(S1_TRANSPORT_ENV) == "1"
    coverage = (
        "Opt-in Dev/scratch S1-A HTTP probe: onboarding LAN allowed, Ready loopback/Tailnet "
        "allowed, and Ready LAN refused. Bonjour Ready filtering remains assisted/manual until "
        "a safe browser harness is added."
    )
    if not live_enabled or not transport_enabled:
        return MatrixRow(
            row_id="household-transport-live",
            title="Household transport S1-A live probe",
            coverage=coverage,
            skip_reason=(
                f"default SKIP; set {LIVE_ENV}=1 and {S1_TRANSPORT_ENV}=1 "
                "with Dev/scratch probe URLs for S1-A transport validation"
            ),
        )

    missing = s1_transport_preflight()
    if missing:
        return MatrixRow(
            row_id="household-transport-live",
            title="Household transport S1-A live probe",
            coverage=coverage,
            fail_reason=(
                "live S1 transport gate is set but preflight is missing or invalid: "
                + ", ".join(missing)
            ),
        )

    probe = (
        "import os, sys, urllib.request\n"
        "def expect_ok(label, env):\n"
        "    url = os.environ[env]\n"
        "    try:\n"
        "        with urllib.request.urlopen(url, timeout=5) as response:\n"
        "            if response.status >= 500:\n"
        "                raise RuntimeError(f'{label}: HTTP {response.status}')\n"
        "    except Exception as exc:\n"
        "        raise SystemExit(f'{label}: expected reachable endpoint, got {type(exc).__name__}') from exc\n"
        "def expect_blocked(label, env):\n"
        "    url = os.environ[env]\n"
        "    try:\n"
        "        with urllib.request.urlopen(url, timeout=5) as response:\n"
        "            raise SystemExit(f'{label}: expected refused/timeout, got HTTP {response.status}')\n"
        "    except SystemExit:\n"
        "        raise\n"
        "    except Exception:\n"
        "        return\n"
        f"expect_ok('ready loopback', '{S1_READY_LOOPBACK_URL_ENV}')\n"
        f"expect_ok('ready tailnet', '{S1_READY_TAILNET_URL_ENV}')\n"
        f"expect_blocked('ready lan', '{S1_READY_LAN_URL_ENV}')\n"
        f"expect_ok('onboarding lan', '{S1_ONBOARDING_LAN_URL_ENV}')\n"
        "print('S1-A HTTP transport probe OK')\n"
    )
    env = {
        S1_READY_LOOPBACK_URL_ENV: os.environ[S1_READY_LOOPBACK_URL_ENV],
        S1_READY_TAILNET_URL_ENV: os.environ[S1_READY_TAILNET_URL_ENV],
        S1_READY_LAN_URL_ENV: os.environ[S1_READY_LAN_URL_ENV],
        S1_ONBOARDING_LAN_URL_ENV: os.environ[S1_ONBOARDING_LAN_URL_ENV],
    }
    return MatrixRow(
        row_id="household-transport-live",
        title="Household transport S1-A live probe",
        coverage=coverage,
        commands=[CommandSpec(["python3", "-c", probe], repo_root, env)],
    )


def relay_framework_present(repo_root: Path) -> bool:
    return (
        repo_root.joinpath(RELAY_FFI_PATH).is_dir()
        or repo_root.joinpath(RELAY_FFI_LEGACY_PATH).is_dir()
    )


def build_client_ui_ios_dev_smoke_row(repo_root: Path) -> MatrixRow:
    coverage = (
        "Opt-in non-destructive iOS Dev app Claw Store UI smoke: open Store, handle server picker, "
        "verify card/gate/unavailable state, open Detail, and verify status plus action/gate/unavailable wiring."
    )
    live_enabled = os.environ.get(LIVE_ENV) == "1"
    client_ui_enabled = os.environ.get(CLIENT_UI_ENV) == "1"
    if not live_enabled or not client_ui_enabled:
        return MatrixRow(
            row_id="client-ui-ios-dev-smoke",
            title="iOS Dev app Claw Store UI smoke",
            coverage=coverage,
            skip_reason=f"default SKIP; set {LIVE_ENV}=1 and {CLIENT_UI_ENV}=1 for Dev app UI automation",
        )

    if os.environ.get(CLIENT_UI_BUILD_INSTALL_ENV) == "1" and not relay_framework_present(repo_root):
        return MatrixRow(
            row_id="client-ui-ios-dev-smoke",
            title="iOS Dev app Claw Store UI smoke",
            coverage=coverage,
            skip_reason=(
                "relay_stream_guest_ffi_missing; run scripts/bootstrap-relay-stream-guest-ffi.sh "
                "before any Xcode build/install path"
            ),
        )

    return MatrixRow(
        row_id="client-ui-ios-dev-smoke",
        title="iOS Dev app Claw Store UI smoke",
        coverage=coverage,
        commands=[CommandSpec(
            ["python3", CLIENT_UI_SMOKE_SCRIPT],
            repo_root,
            {"SOYEHT_BUNDLE_ID": CLIENT_UI_DEV_BUNDLE_ID},
        )],
    )


def build_linux_lifecycle_row(
    *,
    theyos_dir: Path | None,
    live_base_url: str,
    live_user: str,
) -> MatrixRow:
    live_enabled = os.environ.get(LIVE_ENV) == "1"
    lifecycle_enabled = os.environ.get(LINUX_LIFECYCLE_ENV) == "1"
    if not live_enabled or not lifecycle_enabled:
        return MatrixRow(
            row_id="linux-admin-lifecycle",
            title="Linux admin-host Claw lifecycle",
            coverage="Opt-in destructive Linux/Firecracker admin-host create, poll, active, SSH, claw-binary, delete, and verify cleanup for picoclaw.",
            skip_reason=f"default SKIP; set {LIVE_ENV}=1 and {LINUX_LIFECYCLE_ENV}=1 for destructive Linux admin-host lifecycle",
        )

    missing = linux_lifecycle_preflight(theyos_dir)
    if missing:
        return MatrixRow(
            row_id="linux-admin-lifecycle",
            title="Linux admin-host Claw lifecycle",
            coverage="Opt-in destructive Linux/Firecracker admin-host create, poll, active, SSH, claw-binary, delete, and verify cleanup for picoclaw.",
            fail_reason=(
                "live Linux lifecycle gate is set but preflight is missing or invalid: "
                + ", ".join(missing)
            ),
        )

    assert theyos_dir is not None
    ssh_key = str(Path(os.environ[LINUX_SSH_KEY_ENV]).expanduser())
    state_dir = str(Path(os.environ[LINUX_STATE_DIR_ENV]).expanduser())
    argv = [
        "cargo", "run", "-p", "e2e-rs", "--",
        "--base-url", live_base_url,
        "--user", live_user,
        "--ssh-key", ssh_key,
        "--state-dir", state_dir,
        "test", "picoclaw",
    ]
    if os.environ.get(LINUX_TERMINAL_ENV) != "1":
        argv.extend([
            "--skip-terminal",
            "--skip-terminal-restart",
            "--skip-terminal-persist",
        ])
    argv.append("--skip-refill-test")

    return MatrixRow(
        row_id="linux-admin-lifecycle",
        title="Linux admin-host Claw lifecycle",
        coverage=(
            "Opt-in destructive Linux/Firecracker admin-host create, poll, active, "
            "SSH, claw-binary, delete, and verify cleanup for picoclaw; terminal/attach "
            f"is excluded unless {LINUX_TERMINAL_ENV}=1."
        ),
        commands=[CommandSpec(
            argv,
            theyos_dir / "admin" / "rust",
            {ADMIN_PASSWORD_ENV: os.environ[ADMIN_PASSWORD_ENV]},
        )],
    )


def build_rows(repo_root: Path, theyos_dir: Path | None) -> list[MatrixRow]:
    rows: list[MatrixRow] = []

    fixture_env = {}
    if theyos_dir is not None:
        fixture_env["THEYOS_DIR"] = str(theyos_dir)
    rows.append(MatrixRow(
        row_id="contract-fixtures-sync",
        title="Cross-repo Claw Store fixtures are in sync",
        coverage="Vendored Swift fixtures byte-match theyos Claw Store and household contracts.",
        commands=[CommandSpec(["bash", "scripts/check-cross-repo-fixtures.sh"], repo_root, fixture_env)],
    ))

    swift_filter_core = (
        "ClawStoreContractFixtureTests|ClawInstallabilityTests|"
        "ClawDetailActionAvailabilityTests|ClawUnavailableReasonCodeFixtureTests|"
        "GuestImageReadinessTests|SoyehtInstallProfileTests"
    )
    swift_filter_mac = (
        "InstalledClawsProviderTests|MacGuestImageReadinessGateTests|"
        "MacClawInstallDecisionTests|MacClawInstallSurfaceGuardTests|"
        "ClawNotificationTests|EmbeddedEngineLaunchAgentTests|DevEmbeddedEngineSmokeTests"
    )
    rows.append(MatrixRow(
        row_id="swift-client-pure",
        title="Swift Claw client pure contract tests",
        coverage="Swift package tests for shared Claw contract, installability, readiness, macOS provider, and F1/F2 smoke gates.",
        commands=[
            CommandSpec(["swift", "test", "--filter", swift_filter_core], repo_root / "Packages" / "SoyehtCore"),
            CommandSpec(["swift", "test", "--filter", swift_filter_mac], repo_root / "TerminalApp" / "SoyehtMacTests"),
        ],
        skip_reason=None if command_exists("swift") else "swift not found on PATH",
    ))

    rust_tests = [
        "claw_store_route_contract",
        "claw_store_wire_contract",
        "claw_store_contract",
        "admin_guest_image_gate_guard",
    ]
    rust_commands = [
        CommandSpec(["cargo", "test", "-p", "server-rs", "--test", test_name], theyos_dir / "admin" / "rust")
        for test_name in rust_tests
    ] if theyos_dir is not None else []
    rows.append(MatrixRow(
        row_id="rust-backend-contract",
        title="Rust backend Claw Store route and wire contracts",
        coverage="theyos server-rs in-memory contract tests for admin, mobile, household, auth failure, unavailable capability, and rollback.",
        commands=rust_commands,
        skip_reason=(
            "THEYOS_DIR not found; set THEYOS_DIR to a local theyos checkout"
            if theyos_dir is None else
            ("cargo not found on PATH" if not command_exists("cargo") else None)
        ),
    ))

    live_base_url = os.environ.get("SOYEHT_F3_BASE_URL") or os.environ.get("SOYEHT_BASE_URL") or "http://127.0.0.1:8892"
    live_user = os.environ.get("SOYEHT_F3_ADMIN_USER") or os.environ.get("SOYEHT_ADMIN_USER") or "admin"
    if os.environ.get(LIVE_ENV) == "1" and theyos_dir is not None:
        live_commands = [CommandSpec(
            ["cargo", "run", "-p", "e2e-rs", "--", "--base-url", live_base_url, "--user", live_user, "smoke"],
            theyos_dir / "admin" / "rust",
        )]
        live_skip = None
    else:
        live_commands = []
        live_skip = f"default SKIP; set {LIVE_ENV}=1 and THEYOS_DIR for backend live smoke"
    rows.append(MatrixRow(
        row_id="backend-live-smoke",
        title="Backend live smoke, no VM creation",
        coverage="Opt-in theyos e2e smoke against a running Dev backend: health, ready, login, catalog, version, instances.",
        commands=live_commands,
        skip_reason=live_skip,
    ))

    rows.append(build_linux_lifecycle_row(
        theyos_dir=theyos_dir,
        live_base_url=live_base_url,
        live_user=live_user,
    ))

    if os.environ.get(MAC_VZ_ENV) == "1" and os.environ.get("THEYOS_LIVE_VZ") == "1" and theyos_dir is not None:
        mac_vz_commands = [CommandSpec(
            ["cargo", "test", "-p", "vmrunner-macos-rs", "--test", "live_vz_validation", "--", "--ignored", "live_isolation_precheck"],
            theyos_dir / "admin" / "rust",
        )]
        mac_vz_skip = None
    else:
        mac_vz_commands = []
        mac_vz_skip = f"default SKIP; set {MAC_VZ_ENV}=1 and THEYOS_LIVE_VZ=1 for safe VZ isolation precheck only"
    rows.append(MatrixRow(
        row_id="mac-vz-live",
        title="Mac VZ live validation precheck",
        coverage="Opt-in isolation precheck only; VM boot remains authorized-manual and outside F3.1.",
        commands=mac_vz_commands,
        skip_reason=mac_vz_skip,
    ))

    rows.append(build_mac_lifecycle_row(
        theyos_dir=theyos_dir,
        live_base_url=live_base_url,
        live_user=live_user,
    ))

    rows.append(build_s1_transport_row(repo_root))
    rows.append(build_client_ui_ios_dev_smoke_row(repo_root))

    client_ui_reason = (
        f"default SKIP; use client-ui-ios-dev-smoke for the first non-destructive Dev app UI gate. "
        f"{CLIENT_UI_ENV}=1 remains reserved here for the broader iOS+macOS live flow."
    )
    rows.append(MatrixRow(
        row_id="client-ui-live",
        title="iOS and macOS Claw client UI live flow",
        coverage="Reserved for F3.3: iOS client, macOS Store/Drawer, household/mobile Claw lifecycle against Dev engine.",
        skip_reason=client_ui_reason,
    ))

    return rows


def write_reports(
    *,
    run_dir: Path,
    repo_root: Path,
    theyos_dir: Path | None,
    results: list[RowResult],
    redactor: Redactor,
    started_at: str,
    finished_at: str,
) -> None:
    counts = {STATUS_PASS: 0, STATUS_FAIL: 0, STATUS_SKIP: 0}
    for result in results:
        counts[result.status] += 1

    payload = {
        "matrix": "claw-store-f3",
        "started_at": started_at,
        "finished_at": finished_at,
        "summary": counts,
        "repo": {
            "soyeht_ios": "<soyeht-ios>",
            "theyos": "<theyos>" if theyos_dir else None,
        },
        "rows": [asdict(result) for result in results],
        "release_readiness_note": "SKIP is not PASS. Default F3 covers contracts and pure tests; opt-in live rows add scoped runtime coverage but are not full release readiness.",
    }
    (run_dir / "report.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    lines = [
        "# Claw Store F3 QA Matrix",
        "",
        f"- Started: {started_at}",
        f"- Finished: {finished_at}",
        f"- Summary: PASS={counts[STATUS_PASS]} FAIL={counts[STATUS_FAIL]} SKIP={counts[STATUS_SKIP]}",
        "- Readiness: SKIP is not PASS. The default run is a reproducible matrix report, not full release-readiness.",
        "",
        "## Rows",
        "",
        "| Row | Status | Coverage | Notes |",
        "|-----|--------|----------|-------|",
    ]
    for result in results:
        notes = result.notes
        if result.log:
            notes = f"{notes}; log: `{result.log}`"
        lines.append(
            "| {row} | {status} | {coverage} | {notes} |".format(
                row=result.row_id,
                status=result.status,
                coverage=redactor.text(result.coverage).replace("|", "\\|"),
                notes=redactor.text(notes).replace("|", "\\|"),
            )
        )

    lines.extend([
        "",
        "## Commands",
        "",
    ])
    for result in results:
        lines.append(f"### {result.row_id} ({result.status})")
        if result.commands:
            for command in result.commands:
                lines.append(f"- `{redactor.text(command)}`")
        else:
            lines.append(f"- {redactor.text(result.notes)}")
        lines.append("")

    (run_dir / "report.md").write_text("\n".join(lines), encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the Claw Store F3 QA matrix.")
    parser.add_argument("--theyos-dir", help="Local theyos checkout. Defaults to THEYOS_DIR or common sibling paths.")
    parser.add_argument("--output-dir", help="Report directory. Defaults to QA/runs/<date>-claw-store-matrix.")
    parser.add_argument("--only", help="Comma-separated row IDs to run/report.")
    parser.add_argument("--timeout-seconds", type=int, default=int(os.environ.get("SOYEHT_F3_COMMAND_TIMEOUT_SECS", "1200")))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[2]
    theyos_dir = resolve_theyos_dir(repo_root, args.theyos_dir)
    run_dir = Path(args.output_dir).expanduser() if args.output_dir else repo_root / "QA" / "runs" / f"{date.today().isoformat()}-claw-store-matrix"
    if not run_dir.is_absolute():
        run_dir = repo_root / run_dir
    run_dir.mkdir(parents=True, exist_ok=True)

    replacements = [
        (str(repo_root), "<soyeht-ios>"),
    ]
    if theyos_dir is not None:
        replacements.append((str(theyos_dir), "<theyos>"))
    for path_env in (
        LINUX_SSH_KEY_ENV,
        LINUX_STATE_DIR_ENV,
        MAC_SSH_KEY_ENV,
        *VZ_ISOLATION_ENVS,
    ):
        if os.environ.get(path_env):
            replacements.append((str(Path(os.environ[path_env]).expanduser()), "<path-redacted>"))
    for url_env in (
        "SOYEHT_F3_BASE_URL",
        "SOYEHT_BASE_URL",
        S1_READY_LOOPBACK_URL_ENV,
        S1_READY_TAILNET_URL_ENV,
        S1_READY_LAN_URL_ENV,
        S1_ONBOARDING_LAN_URL_ENV,
    ):
        value = os.environ.get(url_env)
        if value:
            replacements.append((value, "<url-redacted>"))
    for user_env in ("SOYEHT_F3_ADMIN_USER", "SOYEHT_ADMIN_USER"):
        value = os.environ.get(user_env)
        if value and value != "admin":
            replacements.append((value, "<user-redacted>"))
    redactor = Redactor(replacements)

    rows = build_rows(repo_root, theyos_dir)
    if args.only:
        wanted = {item.strip() for item in args.only.split(",") if item.strip()}
        rows = [row for row in rows if row.row_id in wanted]
        missing = wanted.difference({row.row_id for row in rows})
        if missing:
            print(f"Unknown row id(s): {', '.join(sorted(missing))}", file=sys.stderr)
            return 2

    started_at = utc_now()
    results: list[RowResult] = []
    for row in rows:
        result = run_commands(
            row,
            repo_root=repo_root,
            theyos_dir=theyos_dir,
            run_dir=run_dir,
            redactor=redactor,
            timeout_seconds=args.timeout_seconds,
        )
        results.append(result)
        print(f"{result.status:4} {result.row_id} - {redactor.text(result.notes)}")

    finished_at = utc_now()
    write_reports(
        run_dir=run_dir,
        repo_root=repo_root,
        theyos_dir=theyos_dir,
        results=results,
        redactor=redactor,
        started_at=started_at,
        finished_at=finished_at,
    )
    print(f"Report: {run_dir / 'report.md'}")
    return 1 if any(result.status == STATUS_FAIL for result in results) else 0


if __name__ == "__main__":
    raise SystemExit(main())
