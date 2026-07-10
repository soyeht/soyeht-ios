#!/usr/bin/env python3
"""Fresh, single-use owner-presence gate for the DEV control-plane run."""

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
PREPARE_ENV = "SOYEHT_PREPARE_MOBILE_CLAW_VPN_DEV_E2E_OWNER_GATE"
RUN_ENV = "SOYEHT_RUN_MOBILE_CLAW_VPN_DEV_E2E_OWNER_GATE"
ACK_ENV = "SOYEHT_MOBILE_CLAW_VPN_OWNER_PRESENT_ACK"
EVIDENCE_ENV = "SOYEHT_MOBILE_CLAW_VPN_EVIDENCE_DIR"
DEVICE_DESTINATION_ENV = "SOYEHT_IOS_DEVICE_DESTINATION"
DEVICE_ID_ENV = "SOYEHT_IOS_DEVICE_ID"
LOGICAL_DEVICE_ID_ENV = "SOYEHT_MOBILE_CLAW_VPN_DEVICE_ID"
CLAW_ID_ENV = "SOYEHT_MOBILE_CLAW_VPN_CLAW_ID"
REQUEST_TTL_SECONDS = 300
EXECUTION_GATE_TTL_SECONDS = 120

SCRIPT_DIR = Path(__file__).resolve().parent
RUNNER = SCRIPT_DIR / "mobile-claw-vpn-dev-e2e-runner.sh"
PREFLIGHT = SCRIPT_DIR / "mobile-claw-vpn-dev-e2e-preflight.sh"

DEVICE_ALIASES = {"Device-D"}
CLAW_ALIASES = {"Claw-M", "Claw-L"}
RELAY_ALIASES = {"Relay-R"}
MESH_ALIASES = {"Mesh-C"}


class GateError(Exception):
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
    owner_acknowledged: bool = False,
    execution_gate_written: bool = False,
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
        "owner_acknowledged": owner_acknowledged,
        "execution_gate_written": execution_gate_written,
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
        raise GateError("refused", "repository_state_unavailable") from error
    return completed.stdout.strip()


def validated_artifact_sha(repo_root: Path) -> str:
    head = run_git(repo_root, "rev-parse", "HEAD")
    main = run_git(repo_root, "rev-parse", "origin/main")
    if len(head) != 40 or any(ch not in "0123456789abcdef" for ch in head):
        raise GateError("refused", "repository_head_invalid")
    if head != main:
        raise GateError("refused", "repository_head_not_merged_main")
    if run_git(repo_root, "status", "--porcelain"):
        raise GateError("refused", "repository_not_clean")
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
        raise GateError("refused", "evidence_dir_missing")
    evidence_dir = Path(os.path.realpath(os.path.expanduser(raw)))
    if is_inside(evidence_dir, repo_root):
        raise GateError("refused", "evidence_dir_inside_repo_refused")
    if must_exist and not evidence_dir.is_dir():
        raise GateError("refused", "evidence_dir_missing_after_readiness")
    if evidence_dir.exists():
        metadata = evidence_dir.stat()
        if metadata.st_uid != os.getuid():
            raise GateError("refused", "evidence_dir_not_owned")
        if stat.S_IMODE(metadata.st_mode) != 0o700:
            raise GateError("refused", "evidence_dir_mode_refused")
    return evidence_dir


def validated_private_inputs() -> tuple[str, dict[str, str]]:
    if (
        os.environ.get("SOYEHT_MOBILE_CLAW_VPN_BUNDLE_ID", DEV_BUNDLE_ID)
        != DEV_BUNDLE_ID
    ):
        raise GateError("refused", "bundle_id_not_dev_refused")

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
        raise GateError("refused", "alias_not_public_refused")

    destination = os.environ.get(DEVICE_DESTINATION_ENV, "")
    device_id = os.environ.get(DEVICE_ID_ENV, "")
    logical_device_id = os.environ.get(LOGICAL_DEVICE_ID_ENV, "")
    claw_id = os.environ.get(CLAW_ID_ENV, "")
    if not destination:
        raise GateError(
            "skipped", "ios_device_destination_missing_explicit_selection_required"
        )
    if not device_id:
        raise GateError("skipped", "ios_device_id_missing_explicit_selection_required")
    if not logical_device_id:
        raise GateError("skipped", "mobile_device_id_missing")
    if not claw_id:
        raise GateError("skipped", "mobile_claw_id_missing")
    if destination != f"platform=iOS,id={device_id}":
        raise GateError("refused", "device_destination_id_mismatch")

    values = {
        "destination": destination,
        "device_id": device_id,
        "logical_device_id": logical_device_id,
        "claw_id": claw_id,
    }
    return DEV_BUNDLE_ID, values


def uuid_string(value: object, *, reason: str) -> str:
    if not isinstance(value, str):
        raise GateError("refused", reason)
    try:
        parsed = uuid.UUID(value)
    except ValueError as error:
        raise GateError("refused", reason) from error
    if str(parsed) != value.lower():
        raise GateError("refused", reason)
    return str(parsed)


def read_json(path: Path, *, reason: str) -> dict[str, object]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise GateError("refused", reason) from error
    if not isinstance(payload, dict):
        raise GateError("refused", reason)
    return payload


def require_mode(path: Path, expected: int, *, reason: str) -> None:
    try:
        mode = stat.S_IMODE(path.stat().st_mode)
    except OSError as error:
        raise GateError("refused", reason) from error
    if mode != expected:
        raise GateError("refused", reason)


def atomic_create_json(path: Path, payload: dict[str, object]) -> None:
    temporary = path.with_name(f".{path.name}.{uuid.uuid4()}.tmp")
    descriptor: int | None = None
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        data = (json.dumps(payload, sort_keys=True) + "\n").encode("utf-8")
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            descriptor = None
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.link(temporary, path)
        os.unlink(temporary)
    except FileExistsError as error:
        raise GateError("refused", "owner_gate_artifact_already_exists") from error
    except OSError as error:
        raise GateError(
            "failed", "owner_gate_artifact_write_failed", exit_code=1
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
        raise GateError("refused", "runner_stdout_schema_invalid")
    if payload.get("status") != "ready_for_owner_present":
        raise GateError("skipped", "runner_not_ready_for_owner_present")
    if payload.get("summary_written") is not True:
        raise GateError("refused", "runner_ready_without_summary")
    if payload.get("owner_present_required") is not True:
        raise GateError("refused", "runner_owner_present_contract_invalid")
    if payload.get("app_launch_attempted") is not False:
        raise GateError("refused", "runner_app_launch_state_invalid")
    if payload.get("relay_contact_attempted") is not False:
        raise GateError("refused", "runner_relay_contact_state_invalid")
    if payload.get("raw_values_printed") is not False:
        raise GateError("refused", "runner_raw_values_state_invalid")
    if payload.get("bundle_id") != DEV_BUNDLE_ID:
        raise GateError("refused", "runner_bundle_id_not_dev_refused")
    aliases = public_aliases()
    for key, expected in aliases.items():
        if payload.get(key) != expected:
            raise GateError("refused", "runner_alias_mismatch")
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
        raise GateError("refused", "runner_summary_schema_invalid")
    if payload.get("status") != "ready_for_owner_present":
        raise GateError("refused", "runner_summary_status_invalid")
    if payload.get("preflight_status") != "ready":
        raise GateError("refused", "runner_summary_preflight_status_invalid")
    if payload.get("preflight_summary_observed") is not True:
        raise GateError("refused", "runner_summary_preflight_evidence_invalid")
    if payload.get("owner_present_required") is not True:
        raise GateError("refused", "runner_summary_owner_present_contract_invalid")
    if payload.get("app_launch_attempted") is not False:
        raise GateError("refused", "runner_summary_app_launch_state_invalid")
    if payload.get("relay_contact_attempted") is not False:
        raise GateError("refused", "runner_summary_relay_contact_state_invalid")
    if payload.get("raw_values_printed") is not False:
        raise GateError("refused", "runner_summary_raw_values_state_invalid")
    if payload.get("bundle_id") != DEV_BUNDLE_ID:
        raise GateError("refused", "runner_summary_bundle_id_not_dev_refused")
    for key, expected in public_aliases().items():
        if payload.get(key) != expected:
            raise GateError("refused", "runner_summary_alias_mismatch")
    return uuid_string(payload.get("run_id"), reason="runner_summary_run_id_invalid")


def invoke_fresh_runner(evidence_dir: Path) -> tuple[str, dict[str, object]]:
    summary_path = runner_summary_path(evidence_dir)
    previous_run_id: object | None = None
    if summary_path.is_file():
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
        raise GateError("failed", "runner_command_failed", exit_code=1) from error
    if completed.returncode != 0:
        raise GateError("failed", "runner_command_failed", exit_code=1)
    try:
        stdout_payload = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise GateError("failed", "runner_json_invalid", exit_code=1) from error
    if not isinstance(stdout_payload, dict):
        raise GateError("failed", "runner_json_invalid", exit_code=1)
    run_id = validate_runner_payload(stdout_payload)
    if run_id == previous_run_id:
        raise GateError("refused", "runner_run_id_not_fresh")

    if not summary_path.is_file():
        raise GateError("refused", "runner_summary_missing")
    require_mode(summary_path, 0o600, reason="runner_summary_mode_refused")
    if summary_path.stat().st_mtime < started_at - 2:
        raise GateError("refused", "runner_summary_not_fresh")
    summary = read_json(summary_path, reason="runner_summary_invalid")
    summary_run_id = validate_runner_summary(summary)
    if summary_run_id != run_id:
        raise GateError("refused", "runner_stdout_summary_run_id_mismatch")
    return run_id, summary


def validate_current_runner_summary(evidence_dir: Path, expected_run_id: str) -> None:
    summary_path = runner_summary_path(evidence_dir)
    if not summary_path.is_file():
        raise GateError("refused", "runner_summary_missing")
    require_mode(summary_path, 0o600, reason="runner_summary_mode_refused")
    summary = read_json(summary_path, reason="runner_summary_invalid")
    run_id = validate_runner_summary(summary)
    if run_id != expected_run_id:
        raise GateError("refused", "runner_readiness_run_id_changed")


def device_binding(attempt_id: str, values: dict[str, str]) -> str:
    digest = hashlib.sha256()
    digest.update(b"soyeht-mobile-claw-vpn-owner-gate-v1\0")
    digest.update(attempt_id.encode("utf-8"))
    for key in ("destination", "device_id", "logical_device_id", "claw_id"):
        digest.update(b"\0")
        digest.update(values[key].encode("utf-8"))
    return digest.hexdigest()


def prepare(repo_root: Path) -> None:
    artifact_sha = validated_artifact_sha(repo_root)
    _, private_values = validated_private_inputs()
    evidence_dir = validate_evidence_dir(repo_root, must_exist=False)
    readiness_run_id, _ = invoke_fresh_runner(evidence_dir)
    evidence_dir = validate_evidence_dir(repo_root, must_exist=True)

    attempt_id = str(uuid.uuid4())
    now = int(time.time())
    aliases = public_aliases()
    request = {
        "contract": "mobile_claw_vpn_dev_owner_gate_v1",
        "status": "awaiting_owner_ack",
        "attempt_id": attempt_id,
        "readiness_run_id": readiness_run_id,
        "artifact_sha": artifact_sha,
        "created_at_unix": now,
        "expires_at_unix": now + REQUEST_TTL_SECONDS,
        "bundle_id": DEV_BUNDLE_ID,
        **aliases,
        "device_binding": device_binding(attempt_id, private_values),
        "owner_present_required": True,
        "owner_acknowledged": False,
        "app_launch_attempted": False,
        "relay_contact_attempted": False,
        "raw_values_printed": False,
    }
    request_path = evidence_dir / f"mobile-claw-vpn-owner-request-{attempt_id}.json"
    atomic_create_json(request_path, request)
    emit(
        "owner_ack_required",
        None,
        attempt_id=attempt_id,
        readiness_run_id=readiness_run_id,
        artifact_sha=artifact_sha,
    )


def consume_request(request_path: Path, in_progress_path: Path) -> None:
    try:
        os.link(request_path, in_progress_path)
        request_path.unlink()
    except FileExistsError as error:
        raise GateError("refused", "owner_attempt_already_in_progress") from error
    except FileNotFoundError as error:
        raise GateError(
            "refused", "owner_request_not_found_or_already_consumed"
        ) from error
    except OSError as error:
        raise GateError(
            "failed", "owner_request_consume_failed", exit_code=1
        ) from error


def execute(repo_root: Path, ack: str) -> None:
    attempt_id = uuid_string(ack, reason="owner_ack_invalid")
    artifact_sha = validated_artifact_sha(repo_root)
    _, private_values = validated_private_inputs()
    evidence_dir = validate_evidence_dir(repo_root, must_exist=True)
    request_path = evidence_dir / f"mobile-claw-vpn-owner-request-{attempt_id}.json"
    if not request_path.is_file():
        raise GateError("refused", "owner_request_not_found_or_already_consumed")
    require_mode(request_path, 0o600, reason="owner_request_mode_refused")
    request = read_json(request_path, reason="owner_request_invalid")

    expected_request_keys = {
        "contract",
        "status",
        "attempt_id",
        "readiness_run_id",
        "artifact_sha",
        "created_at_unix",
        "expires_at_unix",
        "bundle_id",
        "device_alias",
        "claw_alias",
        "relay_alias",
        "mesh_alias",
        "device_binding",
        "owner_present_required",
        "owner_acknowledged",
        "app_launch_attempted",
        "relay_contact_attempted",
        "raw_values_printed",
    }
    if set(request) != expected_request_keys:
        raise GateError("refused", "owner_request_schema_invalid")

    if request.get("contract") != "mobile_claw_vpn_dev_owner_gate_v1":
        raise GateError("refused", "owner_request_contract_invalid")
    if request.get("status") != "awaiting_owner_ack":
        raise GateError("refused", "owner_request_state_invalid")
    if request.get("attempt_id") != attempt_id:
        raise GateError("refused", "owner_request_attempt_id_mismatch")
    readiness_run_id = uuid_string(
        request.get("readiness_run_id"),
        reason="owner_request_readiness_run_id_invalid",
    )
    now = int(time.time())
    created_at = request.get("created_at_unix")
    expires_at = request.get("expires_at_unix")
    if not isinstance(created_at, int) or not isinstance(expires_at, int):
        raise GateError("refused", "owner_request_time_invalid")
    if created_at > now + 5 or expires_at < now:
        raise GateError("refused", "owner_request_expired")
    if request.get("artifact_sha") != artifact_sha:
        raise GateError("refused", "owner_request_artifact_sha_mismatch")
    if request.get("bundle_id") != DEV_BUNDLE_ID:
        raise GateError("refused", "owner_request_bundle_id_not_dev_refused")
    for key, expected in public_aliases().items():
        if request.get(key) != expected:
            raise GateError("refused", "owner_request_alias_mismatch")
    if request.get("device_binding") != device_binding(attempt_id, private_values):
        raise GateError("refused", "owner_request_device_binding_mismatch")
    if request.get("owner_present_required") is not True:
        raise GateError("refused", "owner_request_presence_contract_invalid")
    if request.get("owner_acknowledged") is not False:
        raise GateError("refused", "owner_request_state_invalid")
    if request.get("app_launch_attempted") is not False:
        raise GateError("refused", "owner_request_app_launch_state_invalid")
    if request.get("relay_contact_attempted") is not False:
        raise GateError("refused", "owner_request_relay_contact_state_invalid")
    if request.get("raw_values_printed") is not False:
        raise GateError("refused", "owner_request_raw_values_state_invalid")

    validate_current_runner_summary(evidence_dir, readiness_run_id)

    in_progress_path = (
        evidence_dir / f"mobile-claw-vpn-owner-in-progress-{attempt_id}.json"
    )
    consume_request(request_path, in_progress_path)

    acknowledged = dict(request)
    acknowledged["status"] = "owner_acknowledged"
    acknowledged["owner_acknowledged"] = True
    acknowledged["acknowledged_at_unix"] = now
    acknowledged_path = (
        evidence_dir / f"mobile-claw-vpn-owner-acknowledged-{attempt_id}.json"
    )
    atomic_create_json(acknowledged_path, acknowledged)

    gate = {
        "contract": "mobile_claw_vpn_dev_execution_gate_v1",
        "status": "ready_for_dev_control_plane_run",
        "attempt_id": attempt_id,
        "readiness_run_id": readiness_run_id,
        "artifact_sha": artifact_sha,
        "created_at_unix": now,
        "expires_at_unix": min(expires_at, now + EXECUTION_GATE_TTL_SECONDS),
        "bundle_id": DEV_BUNDLE_ID,
        **public_aliases(),
        "device_binding": request["device_binding"],
        "owner_present_required": True,
        "owner_acknowledged": True,
        "consumed": False,
        "app_launch_attempted": False,
        "relay_contact_attempted": False,
        "raw_values_printed": False,
    }
    gate_path = evidence_dir / f"mobile-claw-vpn-owner-execution-gate-{attempt_id}.json"
    atomic_create_json(gate_path, gate)
    try:
        in_progress_path.unlink()
    except OSError:
        pass

    emit(
        "ready_for_dev_control_plane_run",
        None,
        attempt_id=attempt_id,
        readiness_run_id=readiness_run_id,
        artifact_sha=artifact_sha,
        owner_acknowledged=True,
        execution_gate_written=True,
    )


def main() -> int:
    if len(sys.argv) != 2:
        emit("failed", "repository_root_argument_invalid")
        return 1
    repo_root = Path(sys.argv[1]).resolve()
    prepare_requested = os.environ.get(PREPARE_ENV) == "1"
    run_requested = os.environ.get(RUN_ENV) == "1"
    if not prepare_requested and not run_requested:
        emit("skipped", "owner_gate_opt_in_not_set")
        return 0
    if prepare_requested and run_requested:
        emit("refused", "owner_gate_modes_conflict")
        return 0

    try:
        if prepare_requested:
            prepare(repo_root)
        else:
            ack = os.environ.get(ACK_ENV, "")
            if not ack:
                raise GateError("skipped", "owner_present_ack_missing")
            execute(repo_root, ack)
    except GateError as error:
        emit(error.status, error.reason)
        return error.exit_code
    except Exception:
        emit("failed", "owner_gate_internal_error")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
