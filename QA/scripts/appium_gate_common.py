#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from env_loader import load_repo_env, require_env


load_repo_env()

DEFAULT_BASE_URL = os.environ.get("QA_BASE_URL") or os.environ.get("SOYEHT_BASE_URL") or "http://127.0.0.1:8892"
DEFAULT_APPIUM_URL = os.environ.get("APPIUM_URL", "http://127.0.0.1:4723")
DEFAULT_UDID = os.environ.get("SOYEHT_IOS_UDID", "").strip()
DEFAULT_SSH_HOST = os.environ.get("SOYEHT_SSH_HOST", "").strip()
DEFAULT_WDA_PROJECT = os.environ.get(
    "SOYEHT_WDA_XCODEPROJ",
    str(
        Path.home()
        / ".appium/node_modules/appium-xcuitest-driver/node_modules/appium-webdriveragent/WebDriverAgent.xcodeproj"
    ),
)
DEFAULT_WDA_TEAM_ID = os.environ.get("SOYEHT_WDA_TEAM_ID", "").strip()
DEFAULT_WDA_BUNDLE_ID = os.environ.get("SOYEHT_WDA_BUNDLE_ID", "com.soyeht.WebDriverAgentRunner")
DEFAULT_WDA_SIGNING_ID = os.environ.get("SOYEHT_WDA_SIGNING_ID", "Apple Development")


@dataclass
class ManagedProcess:
    label: str
    process: subprocess.Popen[str]
    log_path: Path

    def terminate(self) -> None:
        if self.process.poll() is not None:
            return
        try:
            os.killpg(self.process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGKILL)
            self.process.wait(timeout=5)


def _http_request(
    url: str,
    *,
    method: str = "GET",
    headers: dict[str, str] | None = None,
    json_body: dict[str, object] | None = None,
    timeout: float = 10.0,
) -> tuple[int, str]:
    data = None
    request_headers = dict(headers or {})
    if json_body is not None:
        data = json.dumps(json_body).encode("utf-8")
        request_headers.setdefault("Content-Type", "application/json")
    request = urllib.request.Request(url, data=data, headers=request_headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.getcode(), response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode("utf-8", errors="replace")


def _http_ready(url: str, *, timeout: float = 3.0) -> bool:
    status, body = _http_request(url, timeout=timeout)
    if status != 200:
        return False
    if not body:
        return False
    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        return False
    value = payload.get("value") if isinstance(payload, dict) else None
    if isinstance(value, dict):
        return bool(value.get("ready", True))
    return True


def ensure_appium_server(run_dir: Path, appium_url: str = DEFAULT_APPIUM_URL) -> ManagedProcess | None:
    status_url = appium_url.rstrip("/") + "/status"
    if _http_ready(status_url):
        return None

    parsed = urllib.parse.urlparse(appium_url)
    host = parsed.hostname or "127.0.0.1"
    port = str(parsed.port or 4723)
    log_path = run_dir / "appium-server.log"
    handle = log_path.open("w", encoding="utf-8")
    process = subprocess.Popen(
        ["appium", "server", "-a", host, "-p", port, "--log-no-colors"],
        stdout=handle,
        stderr=subprocess.STDOUT,
        text=True,
        cwd=run_dir,
        preexec_fn=os.setsid,
    )
    managed = ManagedProcess("appium", process, log_path)

    deadline = time.time() + 60
    while time.time() < deadline:
        if process.poll() is not None:
            break
        if _http_ready(status_url):
            return managed
        time.sleep(1)

    managed.terminate()
    tail = log_path.read_text(encoding="utf-8", errors="replace")[-2000:] if log_path.exists() else ""
    raise RuntimeError(f"Appium server did not become ready at {status_url}.\n{tail}")


def ensure_session_token(base_url: str = DEFAULT_BASE_URL) -> str:
    existing = os.environ.get("SOYEHT_TOKEN") or os.environ.get("TOKEN")
    if existing:
        return existing
    ssh_host = require_env("SOYEHT_SSH_HOST", DEFAULT_SSH_HOST)

    pair_result = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", ssh_host, "sudo soyeht pair"],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if pair_result.returncode != 0:
        raise RuntimeError(f"Unable to generate pair token over ssh.\n{pair_result.stderr.strip()}")

    match = re.search(r"token=([^\s&]+)", pair_result.stdout)
    if not match:
        raise RuntimeError(f"Unable to parse pair token.\n{pair_result.stdout.strip()}")

    status, body = _http_request(
        base_url.rstrip("/") + "/api/v1/mobile/pair",
        method="POST",
        json_body={"token": match.group(1)},
        timeout=30,
    )
    if status < 200 or status >= 300:
        raise RuntimeError(f"Unable to exchange pair token for session token ({status}).\n{body}")

    payload = json.loads(body)
    session_token = payload.get("session_token") or payload.get("sessionToken")
    if not session_token:
        raise RuntimeError(f"Pair response missing session token.\n{body}")
    return str(session_token)


def discover_terminal_context(base_url: str, token: str) -> tuple[str, str]:
    container = os.environ.get("SOYEHT_CONTAINER") or os.environ.get("CONTAINER")
    session_id = os.environ.get("SOYEHT_SESSION") or os.environ.get("SESSION_ID")
    if container and session_id:
        return container, session_id

    headers = {"Authorization": f"Bearer {token}"}

    if not container:
        status, body = _http_request(base_url.rstrip("/") + "/api/v1/mobile/instances", headers=headers, timeout=30)
        if status < 200 or status >= 300:
            raise RuntimeError(f"Unable to list instances ({status}).\n{body}")
        payload = json.loads(body)
        items = payload.get("data") if isinstance(payload, dict) and "data" in payload else payload
        if not isinstance(items, list) or not items:
            raise RuntimeError("No instances available to drive the Appium gate.")
        first = items[0]
        container = first.get("container")
        if not container:
            raise RuntimeError(f"Instance response missing container field.\n{body}")

    if not session_id:
        status, body = _http_request(
            base_url.rstrip("/") + f"/api/v1/terminals/{container}/workspaces",
            headers=headers,
            timeout=30,
        )
        if status < 200 or status >= 300:
            raise RuntimeError(f"Unable to list workspaces for {container} ({status}).\n{body}")
        payload = json.loads(body)
        items = payload.get("data") if isinstance(payload, dict) and "data" in payload else payload
        if not isinstance(items, list) or not items:
            raise RuntimeError(f"No workspaces available for {container}.")
        first = items[0]
        session_id = first.get("session_id") or first.get("sessionId")
        if not session_id:
            raise RuntimeError(f"Workspace response missing session_id.\n{body}")

    return str(container), str(session_id)


def ensure_wda(run_dir: Path, udid: str = DEFAULT_UDID) -> tuple[str, ManagedProcess]:
    existing = os.environ.get("SOYEHT_WDA_URL")
    if existing and _http_ready(existing.rstrip("/") + "/status", timeout=5):
        raise RuntimeError("SOYEHT_WDA_URL reuse is not supported for managed cleanup.")
    udid = require_env("SOYEHT_IOS_UDID", udid)
    team_id = require_env("SOYEHT_WDA_TEAM_ID", DEFAULT_WDA_TEAM_ID)

    log_path = run_dir / "wda-xcodebuild.log"
    handle = log_path.open("w", encoding="utf-8")
    derived_data_path = run_dir.parent / ".wda-deriveddata"
    derived_data_path.mkdir(parents=True, exist_ok=True)
    command = [
        "xcodebuild",
        "test",
        "-project",
        DEFAULT_WDA_PROJECT,
        "-scheme",
        "WebDriverAgentRunner",
        "-destination",
        f"id={udid}",
        "-derivedDataPath",
        str(derived_data_path),
        "-allowProvisioningUpdates",
        f"DEVELOPMENT_TEAM={team_id}",
        f"PRODUCT_BUNDLE_IDENTIFIER={DEFAULT_WDA_BUNDLE_ID}",
        "CODE_SIGN_STYLE=Automatic",
        f"CODE_SIGN_IDENTITY={DEFAULT_WDA_SIGNING_ID}",
    ]
    process = subprocess.Popen(
        command,
        stdout=handle,
        stderr=subprocess.STDOUT,
        text=True,
        cwd=run_dir,
        preexec_fn=os.setsid,
    )
    managed = ManagedProcess("wda", process, log_path)

    marker = re.compile(r"ServerURLHere->(http://[^<]+)<-ServerURLHere")
    deadline = time.time() + 240
    wda_url: str | None = None
    while time.time() < deadline:
        if log_path.exists():
            text = log_path.read_text(encoding="utf-8", errors="replace")
            match = marker.search(text)
            if match:
                wda_url = match.group(1)
                break
        if process.poll() is not None:
            break
        time.sleep(1)

    if not wda_url:
        managed.terminate()
        tail = log_path.read_text(encoding="utf-8", errors="replace")[-4000:] if log_path.exists() else ""
        raise RuntimeError(f"Unable to discover WebDriverAgent URL from xcodebuild.\n{tail}")

    status_url = wda_url.rstrip("/") + "/status"
    deadline = time.time() + 60
    while time.time() < deadline:
        if _http_ready(status_url, timeout=5):
            return wda_url, managed
        if process.poll() is not None:
            break
        time.sleep(1)

    managed.terminate()
    tail = log_path.read_text(encoding="utf-8", errors="replace")[-4000:] if log_path.exists() else ""
    raise RuntimeError(f"WebDriverAgent never became ready at {status_url}.\n{tail}")


def build_gate_env(run_dir: Path) -> tuple[dict[str, str], list[ManagedProcess]]:
    run_dir.mkdir(parents=True, exist_ok=True)
    managed: list[ManagedProcess] = []
    appium_server = ensure_appium_server(run_dir)
    if appium_server:
        managed.append(appium_server)

    base_url = DEFAULT_BASE_URL.rstrip("/")
    token = ensure_session_token(base_url)
    container, session_id = discover_terminal_context(base_url, token)
    wda_url, wda_process = ensure_wda(run_dir)
    managed.append(wda_process)

    env = {
        "QA_BASE_URL": base_url,
        "SOYEHT_BASE_URL": base_url,
        "TOKEN": token,
        "SOYEHT_TOKEN": token,
        "SOYEHT_CONTAINER": container,
        "SOYEHT_SESSION": session_id,
        "SOYEHT_WDA_URL": wda_url,
        "SOYEHT_QA_RUN_DIR": str(run_dir),
    }
    return env, managed


def terminate_processes(processes: list[ManagedProcess]) -> None:
    for process in reversed(processes):
        process.terminate()
