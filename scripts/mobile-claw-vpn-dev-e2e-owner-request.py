#!/usr/bin/env python3
"""Create a fresh, non-authoritative owner-confirmation request for a DEV run."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import time
import uuid


DEV_BUNDLE_ID = "com.soyeht.app.dev"
PREPARE_ENV = "SOYEHT_PREPARE_MOBILE_CLAW_VPN_DEV_E2E_OWNER_REQUEST"
EVIDENCE_ENV = "SOYEHT_MOBILE_CLAW_VPN_EVIDENCE_DIR"
DEVICE_DESTINATION_ENV = "SOYEHT_IOS_DEVICE_DESTINATION"
DEVICE_ID_ENV = "SOYEHT_IOS_DEVICE_ID"
LOGICAL_DEVICE_ID_ENV = "SOYEHT_MOBILE_CLAW_VPN_DEVICE_ID"
CLAW_ID_ENV = "SOYEHT_MOBILE_CLAW_VPN_CLAW_ID"
REQUEST_TTL_SECONDS = 300

SCRIPT_DIR = Path(__file__).resolve().parent
RUNNER = SCRIPT_DIR / "mobile-claw-vpn-dev-e2e-runner.sh"
PREFLIGHT = SCRIPT_DIR / "mobile-claw-vpn-dev-e2e-preflight.sh"

DEVICE_ALIASES = {"Device-D"}
CLAW_ALIASES = {"Claw-M", "Claw-L"}
RELAY_ALIASES = {"Relay-R"}
MESH_ALIASES = {"Mesh-C"}


class RequestError(Exception):
    def __init__(self, status: str, reason: str, *, exit_code: int = 0) -> None:
        super().__init__(reason)
        self.status = status
        self.reason = reason
        self.exit_code = exit_code


def safe_alias(value: str | None, allowed: set[str], fallback: str) -> str:
    return value if value in allowed else fallback


def public_aliases() -> dict[str, str]:
    return {
        "device_alias": safe_alias(
            os.environ.get("SOYEHT_MOBILE_CLAW_VPN_DEVICE_ALIAS"),
            DEVICE_ALIASES,
            "Device-D",
        ),
        "claw_alias": safe_alias(
            os.environ.get("SOYEHT_MOBILE_CLAW_VPN_CLAW_ALIAS"),
            CLAW_ALIASES,
            "Claw-M",
        ),
        "relay_alias": safe_alias(
            os.environ.get("SOYEHT_MOBILE_CLAW_VPN_RELAY_ALIAS"),
            RELAY_ALIASES,
            "Relay-R",
        ),
        "mesh_alias": safe_alias(
            os.environ.get("SOYEHT_MOBILE_CLAW_VPN_MESH_ALIAS"),
            MESH_ALIASES,
            "Mesh-C",
        ),
    }


def emit(
    status: str,
    reason: str | None,
    *,
    attempt_id: str | None = None,
    readiness_run_id: str | None = None,
    artifact_sha: str | None = None,
    request_written: bool = False,
) -> None:
    payload = {
        "status": status,
        "reason": reason,
        "attempt_id": attempt_id,
        "readiness_run_id": readiness_run_id,
        "artifact_sha": artifact_sha,
        "bundle_id": DEV_BUNDLE_ID,
        **public_aliases(),
        "owner_present_required": True,
        "owner_acknowledged": False,
        "execution_authorized": False,
        "request_written": request_written,
        "app_launch_attempted": False,
        "relay_contact_attempted": False,
        "raw_values_printed": False,
    }
    print(json.dumps(payload, sort_keys=True))


def run_git(repo_root: Path, *args: str) -> str:
    try:
        completed = subprocess.run(
            ["/usr/bin/git", "-C", str(repo_root), *args],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise RequestError("refused", "repository_state_unavailable") from error
    return completed.stdout.strip()


def validated_artifact_sha(repo_root: Path) -> str:
    head = run_git(repo_root, "rev-parse", "HEAD")
    main = run_git(repo_root, "rev-parse", "origin/main")
    if len(head) != 40 or any(ch not in "0123456789abcdef" for ch in head):
        raise RequestError("refused", "repository_head_invalid")
    if head != main:
        raise RequestError("refused", "repository_head_not_merged_main")
    if run_git(repo_root, "status", "--porcelain"):
        raise RequestError("refused", "repository_not_clean")
    return head


def is_inside(candidate: Path, parent: Path) -> bool:
    try:
        candidate.relative_to(parent)
        return True
    except ValueError:
        return False


def validate_evidence_dir(repo_root: Path, *, must_exist: bool) -> Path:
    raw = os.environ.get(EVIDENCE_ENV, "")
    if not raw:
        raise RequestError("refused", "evidence_dir_missing")
    evidence_dir = Path(os.path.realpath(os.path.expanduser(raw)))
    if is_inside(evidence_dir, repo_root):
        raise RequestError("refused", "evidence_dir_inside_repo_refused")
    if must_exist and not evidence_dir.is_dir():
        raise RequestError("refused", "evidence_dir_missing_after_readiness")
    if evidence_dir.exists():
        metadata = evidence_dir.stat()
        if metadata.st_uid != os.getuid():
            raise RequestError("refused", "evidence_dir_not_owned")
        if stat.S_IMODE(metadata.st_mode) != 0o700:
            raise RequestError("refused", "evidence_dir_mode_refused")
    return evidence_dir


def validated_private_inputs() -> dict[str, str]:
    if (
        os.environ.get("SOYEHT_MOBILE_CLAW_VPN_BUNDLE_ID", DEV_BUNDLE_ID)
        != DEV_BUNDLE_ID
    ):
        raise RequestError("refused", "bundle_id_not_dev_refused")

    aliases = {
        "device_alias": os.environ.get(
            "SOYEHT_MOBILE_CLAW_VPN_DEVICE_ALIAS", "Device-D"
        ),
        "claw_alias": os.environ.get("SOYEHT_MOBILE_CLAW_VPN_CLAW_ALIAS", "Claw-M"),
        "relay_alias": os.environ.get("SOYEHT_MOBILE_CLAW_VPN_RELAY_ALIAS", "Relay-R"),
        "mesh_alias": os.environ.get("SOYEHT_MOBILE_CLAW_VPN_MESH_ALIAS", "Mesh-C"),
    }
    if (
        aliases["device_alias"] not in DEVICE_ALIASES
        or aliases["claw_alias"] not in CLAW_ALIASES
        or aliases["relay_alias"] not in RELAY_ALIASES
        or aliases["mesh_alias"] not in MESH_ALIASES
    ):
        raise RequestError("refused", "alias_not_public_refused")

    destination = os.environ.get(DEVICE_DESTINATION_ENV, "")
    device_id = os.environ.get(DEVICE_ID_ENV, "")
    logical_device_id = os.environ.get(LOGICAL_DEVICE_ID_ENV, "")
    claw_id = os.environ.get(CLAW_ID_ENV, "")
    if not destination:
        raise RequestError(
            "skipped", "ios_device_destination_missing_explicit_selection_required"
        )
    if not device_id:
        raise RequestError(
            "skipped", "ios_device_id_missing_explicit_selection_required"
        )
    if not logical_device_id:
        raise RequestError("skipped", "mobile_device_id_missing")
    if not claw_id:
        raise RequestError("skipped", "mobile_claw_id_missing")
    if destination != f"platform=iOS,id={device_id}":
        raise RequestError("refused", "device_destination_id_mismatch")

    return {
        "destination": destination,
        "device_id": device_id,
        "logical_device_id": logical_device_id,
        "claw_id": claw_id,
    }


def uuid_string(value: object, *, reason: str) -> str:
    if not isinstance(value, str):
        raise RequestError("refused", reason)
    try:
        parsed = uuid.UUID(value)
    except ValueError as error:
        raise RequestError("refused", reason) from error
    if str(parsed) != value.lower():
        raise RequestError("refused", reason)
    return str(parsed)


def read_json(path: Path, *, reason: str) -> dict[str, object]:
    descriptor: int | None = None
    try:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or stat.S_IMODE(metadata.st_mode) != 0o600
        ):
            raise RequestError("refused", reason)
        with os.fdopen(descriptor, "r", encoding="utf-8", closefd=True) as handle:
            descriptor = None
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise RequestError("refused", reason) from error
    finally:
        if descriptor is not None:
            os.close(descriptor)
    if not isinstance(payload, dict):
        raise RequestError("refused", reason)
    return payload


def require_mode(path: Path, expected: int, *, reason: str) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise RequestError("refused", reason) from error
    if not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != expected:
        raise RequestError("refused", reason)


def atomic_create_json(path: Path, payload: dict[str, object]) -> None:
    temporary = path.with_name(f".{path.name}.{uuid.uuid4()}.tmp")
    descriptor: int | None = None
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        data = (json.dumps(payload, sort_keys=True) + "\n").encode("utf-8")
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            descriptor = None
            os.fchmod(handle.fileno(), 0o600)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.link(temporary, path)
        os.unlink(temporary)
    except FileExistsError as error:
        raise RequestError(
            "refused", "owner_request_artifact_already_exists"
        ) from error
    except OSError as error:
        raise RequestError(
            "failed", "owner_request_artifact_write_failed", exit_code=1
        ) from error
    finally:
        if descriptor is not None:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def runner_summary_path(evidence_dir: Path) -> Path:
    return evidence_dir / "mobile-claw-vpn-dev-e2e-runner-summary.json"


def validate_runner_payload(payload: dict[str, object]) -> str:
    expected_keys = {
        "status",
        "reason",
        "run_id",
        "preflight_status",
        "summary_written",
        "bundle_id",
        "device_alias",
        "claw_alias",
        "relay_alias",
        "mesh_alias",
        "owner_present_required",
        "app_launch_attempted",
        "relay_contact_attempted",
        "raw_values_printed",
    }
    if set(payload) != expected_keys:
        raise RequestError("refused", "runner_stdout_schema_invalid")
    if payload.get("status") != "ready_for_owner_present":
        raise RequestError("skipped", "runner_not_ready_for_owner_present")
    if payload.get("reason") is not None:
        raise RequestError("refused", "runner_stdout_reason_invalid")
    if payload.get("preflight_status") != "ready":
        raise RequestError("refused", "runner_stdout_preflight_status_invalid")
    if payload.get("summary_written") is not True:
        raise RequestError("refused", "runner_ready_without_summary")
    if payload.get("owner_present_required") is not True:
        raise RequestError("refused", "runner_owner_present_contract_invalid")
    if payload.get("app_launch_attempted") is not False:
        raise RequestError("refused", "runner_app_launch_state_invalid")
    if payload.get("relay_contact_attempted") is not False:
        raise RequestError("refused", "runner_relay_contact_state_invalid")
    if payload.get("raw_values_printed") is not False:
        raise RequestError("refused", "runner_raw_values_state_invalid")
    if payload.get("bundle_id") != DEV_BUNDLE_ID:
        raise RequestError("refused", "runner_bundle_id_not_dev_refused")
    aliases = public_aliases()
    for key, expected in aliases.items():
        if payload.get(key) != expected:
            raise RequestError("refused", "runner_alias_mismatch")
    return uuid_string(payload.get("run_id"), reason="runner_run_id_invalid")


def validate_runner_summary(payload: dict[str, object]) -> str:
    expected_keys = {
        "status",
        "reason",
        "run_id",
        "preflight_status",
        "preflight_summary_observed",
        "bundle_id",
        "device_alias",
        "claw_alias",
        "relay_alias",
        "mesh_alias",
        "owner_present_required",
        "app_launch_attempted",
        "relay_contact_attempted",
        "raw_values_printed",
    }
    if set(payload) != expected_keys:
        raise RequestError("refused", "runner_summary_schema_invalid")
    if payload.get("status") != "ready_for_owner_present":
        raise RequestError("refused", "runner_summary_status_invalid")
    if payload.get("reason") is not None:
        raise RequestError("refused", "runner_summary_reason_invalid")
    if payload.get("preflight_status") != "ready":
        raise RequestError("refused", "runner_summary_preflight_status_invalid")
    if payload.get("preflight_summary_observed") is not True:
        raise RequestError("refused", "runner_summary_preflight_evidence_invalid")
    if payload.get("owner_present_required") is not True:
        raise RequestError("refused", "runner_summary_owner_present_contract_invalid")
    if payload.get("app_launch_attempted") is not False:
        raise RequestError("refused", "runner_summary_app_launch_state_invalid")
    if payload.get("relay_contact_attempted") is not False:
        raise RequestError("refused", "runner_summary_relay_contact_state_invalid")
    if payload.get("raw_values_printed") is not False:
        raise RequestError("refused", "runner_summary_raw_values_state_invalid")
    if payload.get("bundle_id") != DEV_BUNDLE_ID:
        raise RequestError("refused", "runner_summary_bundle_id_not_dev_refused")
    for key, expected in public_aliases().items():
        if payload.get(key) != expected:
            raise RequestError("refused", "runner_summary_alias_mismatch")
    return uuid_string(payload.get("run_id"), reason="runner_summary_run_id_invalid")


def invoke_fresh_runner(evidence_dir: Path) -> str:
    summary_path = runner_summary_path(evidence_dir)
    previous_run_id: object | None = None
    if summary_path.is_file():
        require_mode(summary_path, 0o600, reason="runner_previous_summary_mode_refused")
        previous_run_id = read_json(
            summary_path,
            reason="runner_previous_summary_invalid",
        ).get("run_id")

    started_at = time.time()
    child_environment = os.environ.copy()
    child_environment["SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E"] = "1"
    child_environment["SOYEHT_MOBILE_CLAW_VPN_DEV_E2E_PREFLIGHT_BIN"] = str(PREFLIGHT)
    try:
        completed = subprocess.run(
            [str(RUNNER)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            env=child_environment,
            timeout=60,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise RequestError("failed", "runner_command_failed", exit_code=1) from error
    if completed.returncode != 0:
        raise RequestError("failed", "runner_command_failed", exit_code=1)
    try:
        stdout_payload = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise RequestError("failed", "runner_json_invalid", exit_code=1) from error
    if not isinstance(stdout_payload, dict):
        raise RequestError("failed", "runner_json_invalid", exit_code=1)
    run_id = validate_runner_payload(stdout_payload)
    if run_id == previous_run_id:
        raise RequestError("refused", "runner_run_id_not_fresh")

    if not summary_path.is_file():
        raise RequestError("refused", "runner_summary_missing")
    require_mode(summary_path, 0o600, reason="runner_summary_mode_refused")
    if summary_path.stat().st_mtime < started_at - 2:
        raise RequestError("refused", "runner_summary_not_fresh")
    summary = read_json(summary_path, reason="runner_summary_invalid")
    summary_run_id = validate_runner_summary(summary)
    if summary_run_id != run_id:
        raise RequestError("refused", "runner_stdout_summary_run_id_mismatch")
    return run_id


def device_binding(attempt_id: str, values: dict[str, str]) -> str:
    digest = hashlib.sha256()
    digest.update(b"soyeht-mobile-claw-vpn-owner-request-v1\0")
    digest.update(attempt_id.encode("utf-8"))
    for key in ("destination", "device_id", "logical_device_id", "claw_id"):
        digest.update(b"\0")
        digest.update(values[key].encode("utf-8"))
    return digest.hexdigest()


def prepare(repo_root: Path) -> None:
    artifact_sha = validated_artifact_sha(repo_root)
    private_values = validated_private_inputs()
    evidence_dir = validate_evidence_dir(repo_root, must_exist=False)
    readiness_run_id = invoke_fresh_runner(evidence_dir)
    evidence_dir = validate_evidence_dir(repo_root, must_exist=True)

    attempt_id = str(uuid.uuid4())
    now = int(time.time())
    request = {
        "contract": "mobile_claw_vpn_dev_owner_request_v1",
        "status": "awaiting_owner_confirmation",
        "attempt_id": attempt_id,
        "readiness_run_id": readiness_run_id,
        "artifact_sha": artifact_sha,
        "created_at_unix": now,
        "expires_at_unix": now + REQUEST_TTL_SECONDS,
        "bundle_id": DEV_BUNDLE_ID,
        **public_aliases(),
        "device_binding": device_binding(attempt_id, private_values),
        "owner_present_required": True,
        "owner_acknowledged": False,
        "execution_authorized": False,
        "app_launch_attempted": False,
        "relay_contact_attempted": False,
        "raw_values_printed": False,
    }
    request_path = evidence_dir / f"mobile-claw-vpn-owner-request-{attempt_id}.json"
    current_artifact_sha = validated_artifact_sha(repo_root)
    if current_artifact_sha != artifact_sha:
        raise RequestError("refused", "repository_artifact_changed_during_readiness")
    atomic_create_json(request_path, request)
    emit(
        "owner_confirmation_required",
        None,
        attempt_id=attempt_id,
        readiness_run_id=readiness_run_id,
        artifact_sha=artifact_sha,
        request_written=True,
    )


def main() -> int:
    if len(sys.argv) != 1:
        emit("failed", "owner_request_argument_refused")
        return 1
    repo_root = SCRIPT_DIR.parent
    if os.environ.get(PREPARE_ENV) != "1":
        emit("skipped", "owner_request_opt_in_not_set")
        return 0

    try:
        prepare(repo_root)
    except RequestError as error:
        emit(error.status, error.reason)
        return error.exit_code
    except Exception:
        emit("failed", "owner_request_internal_error")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
