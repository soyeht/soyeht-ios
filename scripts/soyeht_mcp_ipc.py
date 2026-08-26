"""Atomic file IPC with event-driven response waiting on macOS."""

import json
import os
import select
import threading
import time
import fcntl
from contextlib import contextmanager
from pathlib import Path


def write_request(root, request):
    requests_dir = root / "Requests"
    requests_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(requests_dir, 0o700)
    tmp = requests_dir / f".{request['id']}.tmp"
    destination = requests_dir / f"{request['id']}.json"
    descriptor = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(request, handle, indent=2, sort_keys=True)
    except BaseException:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
        raise
    os.replace(tmp, destination)
    return destination


@contextmanager
def locked_file_slot(path):
    """Serialize generation changes to one replaceable file path."""
    if path is None:
        yield None
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    lock_path = path.parent / f".{path.name}.lock"
    descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield path
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def _runtime_binding_generation(payload):
    return (
        int(payload["runtimeOwnerProcessStartedAtSeconds"]),
        int(payload["runtimeOwnerProcessStartedAtMicroseconds"]),
        int(payload["runtimeProcessStartedAtSeconds"]),
        int(payload["runtimeProcessStartedAtMicroseconds"]),
    )


def publish_generation_binding(path, payload):
    """Atomically publish unless a newer process generation owns the slot."""
    with locked_file_slot(path) as path:
        if path is None:
            return None
        try:
            current = json.loads(path.read_text(encoding="utf-8"))
            current_generation = _runtime_binding_generation(current)
        except (FileNotFoundError, OSError, KeyError, TypeError, ValueError):
            current_generation = None
        candidate_generation = _runtime_binding_generation(payload)
        if current_generation is not None and current_generation > candidate_generation:
            return None
        temporary = path.parent / f".{path.name}.{os.urandom(16).hex()}.tmp"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, separators=(",", ":"), sort_keys=True)
            os.replace(temporary, path)
        except BaseException:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass
            raise
        return path


def remove_generation_binding(path, expected_instance_id):
    """Compare and remove under the same lock used by every publisher."""
    with locked_file_slot(path) as path:
        if path is None:
            return False
        try:
            current = json.loads(path.read_text(encoding="utf-8"))
        except (FileNotFoundError, OSError, ValueError):
            return False
        if current.get("runtimeInstanceID") != expected_instance_id:
            return False
        try:
            path.unlink()
        except FileNotFoundError:
            return False
        return True


def wait_response(root, request_id, timeout):
    responses_dir = root / "Responses"
    responses_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(responses_dir, 0o700)
    response = responses_dir / f"{request_id}.json"
    if response.exists():
        return _consume_response(response)

    deadline = time.monotonic() + timeout
    if hasattr(select, "kqueue"):
        descriptor = os.open(responses_dir, os.O_RDONLY)
        queue = select.kqueue()
        event = select.kevent(
            descriptor,
            filter=select.KQ_FILTER_VNODE,
            flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
            fflags=(
                select.KQ_NOTE_WRITE
                | select.KQ_NOTE_EXTEND
                | select.KQ_NOTE_RENAME
                | select.KQ_NOTE_DELETE
            ),
        )
        try:
            while True:
                if response.exists():
                    return _consume_response(response)
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return None
                queue.control([event], 1, remaining)
        finally:
            queue.close()
            os.close(descriptor)

    # Non-macOS test/development fallback. Event.wait yields the thread and is
    # deliberately isolated from the production kqueue transport.
    wake = threading.Event()
    while time.monotonic() < deadline:
        if response.exists():
            return _consume_response(response)
        wake.wait(min(0.25, max(0, deadline - time.monotonic())))
    return None


def _consume_response(path):
    """Read one atomic response and remove it only after valid JSON decode."""
    payload = json.loads(path.read_text(encoding="utf-8"))
    try:
        path.unlink()
    except FileNotFoundError:
        pass
    return payload
