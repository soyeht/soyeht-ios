"""Atomic file IPC with event-driven response waiting on macOS."""

import json
import os
import select
import threading
import time
from pathlib import Path


def write_request(root, request):
    requests_dir = root / "Requests"
    requests_dir.mkdir(parents=True, exist_ok=True)
    tmp = requests_dir / f".{request['id']}.tmp"
    destination = requests_dir / f"{request['id']}.json"
    tmp.write_text(json.dumps(request, indent=2, sort_keys=True), encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, destination)
    return destination


def wait_response(root, request_id, timeout):
    responses_dir = root / "Responses"
    responses_dir.mkdir(parents=True, exist_ok=True)
    response = responses_dir / f"{request_id}.json"
    if response.exists():
        return json.loads(response.read_text(encoding="utf-8"))

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
                    return json.loads(response.read_text(encoding="utf-8"))
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
            return json.loads(response.read_text(encoding="utf-8"))
        wake.wait(min(0.25, max(0, deadline - time.monotonic())))
    return None
