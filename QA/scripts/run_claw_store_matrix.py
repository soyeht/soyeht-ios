#!/usr/bin/env python3
"""Reproducible Claw Store QA matrix runner.

F3.1 is intentionally a reporting matrix, not a release-readiness claim. Rows
that need a live engine, VZ, Firecracker, or client UI automation are default
SKIP and only run when their explicit opt-in environment is present.
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
MAC_VZ_ENV = "SOYEHT_F3_RUN_MAC_VZ"
CLIENT_UI_ENV = "SOYEHT_F3_RUN_CLIENT_UI"


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

    if os.environ.get(LIVE_ENV) == "1" and os.environ.get(LINUX_LIFECYCLE_ENV) == "1" and theyos_dir is not None:
        linux_commands = [CommandSpec(
            [
                "cargo", "run", "-p", "e2e-rs", "--",
                "--base-url", live_base_url,
                "--user", live_user,
                "test", "picoclaw",
                "--skip-refill-test",
            ],
            theyos_dir / "admin" / "rust",
        )]
        linux_skip = None
    else:
        linux_commands = []
        linux_skip = f"default SKIP; set {LIVE_ENV}=1 and {LINUX_LIFECYCLE_ENV}=1 for destructive Linux admin-host lifecycle"
    rows.append(MatrixRow(
        row_id="linux-admin-lifecycle",
        title="Linux admin-host Claw lifecycle",
        coverage="Opt-in destructive Linux/Firecracker admin-host create, poll, SSH/terminal, delete, cleanup.",
        commands=linux_commands,
        skip_reason=linux_skip,
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

    client_ui_reason = (
        f"default SKIP; {CLIENT_UI_ENV}=1 is reserved for F3.3 once Dev Mac engine/household/client UI automation exists"
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
        "matrix": "claw-store-f3.1",
        "started_at": started_at,
        "finished_at": finished_at,
        "summary": counts,
        "repo": {
            "soyeht_ios": "<soyeht-ios>",
            "theyos": "<theyos>" if theyos_dir else None,
        },
        "rows": [asdict(result) for result in results],
        "release_readiness_note": "SKIP is not PASS. Default F3.1 covers contracts and pure tests, not full live release readiness.",
    }
    (run_dir / "report.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    lines = [
        "# Claw Store F3.1 QA Matrix",
        "",
        f"- Started: {started_at}",
        f"- Finished: {finished_at}",
        f"- Summary: PASS={counts[STATUS_PASS]} FAIL={counts[STATUS_FAIL]} SKIP={counts[STATUS_SKIP]}",
        "- Readiness: SKIP is not PASS. This F3.1 run is a reproducible matrix report, not full release-readiness.",
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
    parser = argparse.ArgumentParser(description="Run the Claw Store F3.1 QA matrix.")
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
