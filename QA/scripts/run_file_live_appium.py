#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import base64
import os
import re
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import requests
import websockets


APPIUM_URL = os.environ.get("APPIUM_URL", "http://127.0.0.1:4723")
UDID = os.environ.get("SOYEHT_IOS_UDID", "<ios-udid>")
BUNDLE_ID = os.environ.get("SOYEHT_BUNDLE_ID", "com.soyeht.app")
BACKEND_BASE = os.environ.get("SOYEHT_BASE_URL") or os.environ.get("QA_BASE_URL") or "https://<host>.<tailnet>.ts.net"
CONTAINER = os.environ.get("SOYEHT_CONTAINER") or os.environ.get("CONTAINER") or "zeroclaw-qa-caio-0415"
SESSION = os.environ.get("SOYEHT_SESSION") or os.environ.get("SESSION_ID") or "31b0b16356b43cf0"
TOKEN = os.environ.get("SOYEHT_TOKEN") or os.environ.get("TOKEN") or ""
WDA_URL = os.environ.get("SOYEHT_WDA_URL", "")
WDA_BUNDLE_ID = os.environ.get("SOYEHT_WDA_BUNDLE_ID", "com.soyeht.WebDriverAgentRunner")
WDA_TEAM_ID = os.environ.get("SOYEHT_WDA_TEAM_ID", "<IOS_TEAM_ID>")
WDA_SIGNING_ID = os.environ.get("SOYEHT_WDA_SIGNING_ID", "Apple Development")
RUN_DIR = Path(os.environ.get("SOYEHT_QA_RUN_DIR", "QA/runs/2026-04-15-file-browser-real"))
SSH_HOST = os.environ.get("SOYEHT_SSH_HOST", "devs")
FORCE_BROWSER_FALLBACK = os.environ.get("SOYEHT_UI_TEST_FORCE_BROWSER_FALLBACK") == "1"
VM_ROOTFS = os.environ.get(
    "SOYEHT_VM_ROOTFS",
    f"/home/devs/firecracker/instances/{CONTAINER}/rootfs.ext4",
)
LARGE_VIDEO_REMOTE_PATH = "/root/Downloads/0-large-video.mp4"
LARGE_VIDEO_BACKUP_PATH = os.environ.get("SOYEHT_LARGE_VIDEO_BACKUP_PATH", "/root/Downloads/0-large-video.qa-bak")
QA_MARKDOWN_TEXT = (
    "# QA Fixture\n\n"
    "This file validates **markdown** preview.\n\n"
    "1. First item\n"
    "2. Second item\n\n"
    "- Bullet A\n"
    "- Bullet B\n\n"
    "[OpenAI](https://openai.com)\n"
)
QA_PNG_BASE64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aV7EAAAAASUVORK5CYII="
QA_PDF_BASE64 = "JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCAzMDAgMTQ0XSAvQ29udGVudHMgNCAwIFIgL1Jlc291cmNlcyA8PCAvRm9udCA8PCAvRjEgNSAwIFIgPj4gPj4gPj4KZW5kb2JqCjQgMCBvYmoKPDwgL0xlbmd0aCA0NCA+PgpzdHJlYW0KQlQgL0YxIDI0IFRmIDcyIDcyIFRkIChTb3llaHQgUERGIEZpeHR1cmUpIFRqIEVUCmVuZHN0cmVhbQplbmRvYmoKNSAwIG9iago8PCAvVHlwZSAvRm9udCAvU3VidHlwZSAvVHlwZTEgL0Jhc2VGb250IC9IZWx2ZXRpY2EgPj4KZW5kb2JqCnhyZWYKMCA2CjAwMDAwMDAwMDAgNjU1MzUgZiAKMDAwMDAwMDAxMCAwMDAwMCBuIAowMDAwMDAwMDYwIDAwMDAwIG4gCjAwMDAwMDAxMTcgMDAwMDAgbiAKMDAwMDAwMDI0NCAwMDAwMCBuIAowMDAwMDAwMzM4IDAwMDAwIG4gCnRyYWlsZXIKPDwgL1NpemUgNiAvUm9vdCAxIDAgUiA+PgpzdGFydHhyZWYKNDA4CiUlRU9GCg=="
QA_LARGE_VIDEO_BYTES = 12 * 1024 * 1024

W3C_ELEMENT = "element-6066-11e4-a52e-4f735466cecf"


@dataclass
class Result:
    case_id: str
    status: str
    notes: str


class AppiumSession:
    def __init__(self) -> None:
        self.session_id: str | None = None
        self.base: str | None = None

    def start(self) -> None:
        caps = {
            "platformName": "iOS",
            "appium:automationName": "XCUITest",
            "appium:udid": UDID,
            "appium:bundleId": BUNDLE_ID,
            "appium:processArguments": {
                "args": ["-SoyehtUITest"],
                "env": {
                    "SOYEHT_UI_TEST": "1",
                    "SOYEHT_UI_TEST_FORCE_BROWSER_FALLBACK": "1" if FORCE_BROWSER_FALLBACK else "0",
                },
            },
            "appium:noReset": True,
            "appium:shouldUseSingletonTestManager": False,
            "appium:waitForIdleTimeout": 0,
            "appium:waitForQuiescence": False,
            "appium:wdaEventloopIdleDelay": 1,
            "appium:wdaLaunchTimeout": 180000,
            "appium:wdaConnectionTimeout": 180000,
            "appium:newCommandTimeout": 240,
        }
        if WDA_URL:
            caps["appium:webDriverAgentUrl"] = WDA_URL
            caps["appium:useNewWDA"] = False
        else:
            caps["appium:useNewWDA"] = True
            caps["appium:updatedWDABundleId"] = WDA_BUNDLE_ID
            caps["appium:xcodeOrgId"] = WDA_TEAM_ID
            caps["appium:xcodeSigningId"] = WDA_SIGNING_ID
        response = requests.post(
            f"{APPIUM_URL}/session",
            json={"capabilities": {"alwaysMatch": caps, "firstMatch": [{}]}},
            timeout=240,
        )
        response.raise_for_status()
        payload = response.json()
        value = payload["value"]
        self.session_id = value.get("sessionId") or payload.get("sessionId")
        if not self.session_id:
            raise RuntimeError(f"Unable to determine session id: {payload}")
        self.base = f"{APPIUM_URL}/session/{self.session_id}"

    def stop(self) -> None:
        if not self.base:
            return
        try:
            requests.delete(self.base, timeout=120)
        finally:
            self.base = None
            self.session_id = None

    def _post(self, path: str, payload: dict[str, Any] | None = None, timeout: int = 120) -> Any:
        assert self.base
        response = requests.post(f"{self.base}{path}", json=payload or {}, timeout=timeout)
        response.raise_for_status()
        return response.json()["value"]

    def _get_text(self, path: str, timeout: int = 120) -> str:
        assert self.base
        last_error: Exception | None = None
        for _ in range(10):
            try:
                response = requests.get(f"{self.base}{path}", timeout=timeout)
                response.raise_for_status()
                return response.json()["value"]
            except Exception as error:  # noqa: BLE001
                last_error = error
                time.sleep(1)
        raise last_error if last_error else RuntimeError(f"Unable to GET {path}")

    def _get(self, path: str, timeout: int = 120) -> Any:
        assert self.base
        response = requests.get(f"{self.base}{path}", timeout=timeout)
        response.raise_for_status()
        return response.json()["value"]

    def reset_app(self) -> None:
        self._post("/appium/device/terminate_app", {"bundleId": BUNDLE_ID})
        time.sleep(1)
        self._post("/appium/device/activate_app", {"bundleId": BUNDLE_ID})
        time.sleep(2)

    def activate_app(self, bundle_id: str) -> None:
        self._post("/appium/device/activate_app", {"bundleId": bundle_id})

    def terminate_app(self, bundle_id: str) -> None:
        self._post("/appium/device/terminate_app", {"bundleId": bundle_id})

    def source(self) -> str:
        return self._get_text("/source")

    def screenshot(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        data = self._get_text("/screenshot")
        path.write_bytes(base64.b64decode(data))

    def save_source(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.source())

    def _element_id(self, value: Any) -> str:
        if isinstance(value, list):
            if not value:
                raise LookupError("No element returned")
            value = value[0]
        if W3C_ELEMENT in value:
            return value[W3C_ELEMENT]
        return value["ELEMENT"]

    def find(self, using: str, value: str, timeout: float = 8.0) -> str:
        assert self.base
        deadline = time.time() + timeout
        last_error: Exception | None = None
        while time.time() < deadline:
            try:
                payload = self._post("/element", {"using": using, "value": value})
                return self._element_id(payload)
            except Exception as exc:  # noqa: BLE001
                last_error = exc
                time.sleep(0.5)
        raise LookupError(f"Unable to find {using}={value}: {last_error}")

    def find_all(self, using: str, value: str) -> list[str]:
        payload = self._post("/elements", {"using": using, "value": value})
        return [self._element_id(item) for item in payload]

    def click_element(self, element_id: str) -> None:
        self._post(f"/element/{element_id}/click")

    def click_id(self, accessibility_id: str, timeout: float = 8.0) -> None:
        self.click_element(self.find("accessibility id", accessibility_id, timeout=timeout))

    def click_xpath(self, xpath: str, timeout: float = 8.0) -> None:
        self.click_element(self.find("xpath", xpath, timeout=timeout))

    def rect(self, element_id: str) -> dict[str, Any]:
        return self._get(f"/element/{element_id}/rect")

    def long_press(self, element_id: str, duration: float = 0.6) -> None:
        self._post("/execute/sync", {"script": "mobile: touchAndHold", "args": [{"elementId": element_id, "duration": duration}]})

    def background(self, seconds: int) -> None:
        self._post("/execute/sync", {"script": "mobile: backgroundApp", "args": [{"seconds": seconds}]}, timeout=seconds + 120)

    def drag(self, start_x: float, start_y: float, end_x: float, end_y: float, duration: float = 0.2) -> None:
        self._post(
            "/execute/sync",
            {
                "script": "mobile: dragFromToForDuration",
                "args": [
                    {
                        "duration": duration,
                        "fromX": start_x,
                        "fromY": start_y,
                        "toX": end_x,
                        "toY": end_y,
                    }
                ],
            },
        )

    def tap_point(self, x: float, y: float) -> None:
        self._post("/execute/sync", {"script": "mobile: tap", "args": [{"x": x, "y": y}]})

    def swipe_up(self) -> None:
        self.drag(187, 640, 187, 260, duration=0.15)
        time.sleep(1)

    def pull_down(self) -> None:
        self.drag(187, 240, 187, 620, duration=0.25)
        time.sleep(2)

    def get_clipboard_text(self) -> str:
        data = self._post("/appium/device/get_clipboard", {"contentType": "plaintext"})
        return base64.b64decode(data).decode("utf-8", errors="replace")


class BackendHelper:
    def __init__(self) -> None:
        self.headers = {"Authorization": f"Bearer {TOKEN}"}

    def files(self, path: str) -> dict[str, Any]:
        response = requests.get(
            f"{BACKEND_BASE}/api/v1/terminals/{CONTAINER}/files",
            params={"session": SESSION, "path": path},
            headers=self.headers,
            timeout=30,
        )
        response.raise_for_status()
        return response.json()

    def session_info(self) -> dict[str, Any]:
        response = requests.get(
            f"{BACKEND_BASE}/api/v1/terminals/{CONTAINER}/session-info",
            params={"session": SESSION},
            headers=self.headers,
            timeout=30,
        )
        response.raise_for_status()
        return response.json()

    def remote_download_status(self, path: str) -> int:
        response = requests.get(
            f"{BACKEND_BASE}/api/v1/terminals/{CONTAINER}/files/download",
            params={"session": SESSION, "path": path},
            headers=self.headers,
            timeout=30,
            allow_redirects=False,
        )
        return response.status_code

    async def send_pty_command(self, command: str, read_seconds: float = 1.5, client: str = "mobile-script") -> str:
        url = (
            f"{BACKEND_BASE.replace('https://', 'wss://').replace('http://', 'ws://')}"
            f"/api/v1/terminals/{CONTAINER}/pty?session={SESSION}&token={TOKEN}&client={client}"
        )
        chunks: list[str] = []
        async with websockets.connect(url, ping_interval=None) as ws:
            await ws.send(command + "\n")
            end = time.time() + read_seconds
            while time.time() < end:
                try:
                    message = await asyncio.wait_for(ws.recv(), timeout=0.3)
                except asyncio.TimeoutError:
                    continue
                if isinstance(message, bytes):
                    message = message.decode("utf-8", errors="replace")
                chunks.append(message)
        return "".join(chunks)

    def ssh(self, remote_command: str, timeout: int = 90) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["ssh", "-o", "BatchMode=yes", SSH_HOST, remote_command],
            capture_output=True,
            text=True,
            timeout=timeout,
        )

    def debugfs(self, command: str, timeout: int = 90) -> subprocess.CompletedProcess[str]:
        remote_command = (
            f"sudo -n debugfs -w -R {shlex.quote(command)} {shlex.quote(VM_ROOTFS)}"
        )
        return self.ssh(remote_command, timeout=timeout)

    def fc_ssh_exec(self, command: str, timeout: int = 90) -> subprocess.CompletedProcess[str]:
        remote_command = (
            "sudo -n -u soyeht env "
            "HOME=/home/devs "
            "FIRECRACKER_STATE_DIR=/home/devs/firecracker/instances "
            f"/run/current-system/sw/bin/fc-ssh exec {shlex.quote(CONTAINER)} {shlex.quote(command)}"
        )
        return self.ssh(remote_command, timeout=timeout)

    def ensure_large_video_backup(self) -> bool:
        code = (
            "from pathlib import Path\n"
            f"src = Path({LARGE_VIDEO_REMOTE_PATH!r})\n"
            f"bak = Path({LARGE_VIDEO_BACKUP_PATH!r})\n"
            "if not src.exists() and not bak.exists():\n"
            "    raise SystemExit(1)\n"
            "if src.exists() and not bak.exists():\n"
            "    bak.write_bytes(src.read_bytes())\n"
            "print('ok')\n"
        )
        result = self.fc_ssh_exec(f"python3 -c {shlex.quote(code)}", timeout=180)
        return result.returncode == 0

    def remove_large_video_fixture(self) -> bool:
        code = (
            "from pathlib import Path\n"
            f"Path({LARGE_VIDEO_REMOTE_PATH!r}).unlink(missing_ok=True)\n"
            "print('ok')\n"
        )
        result = self.fc_ssh_exec(f"python3 -c {shlex.quote(code)}", timeout=90)
        return result.returncode == 0

    def restore_large_video_fixture(self) -> bool:
        code = (
            "from pathlib import Path\n"
            "import shutil\n"
            f"src = Path({LARGE_VIDEO_BACKUP_PATH!r})\n"
            f"dst = Path({LARGE_VIDEO_REMOTE_PATH!r})\n"
            "if not src.exists():\n"
            "    raise SystemExit(1)\n"
            "dst.parent.mkdir(parents=True, exist_ok=True)\n"
            "shutil.copyfile(src, dst)\n"
            "print('ok')\n"
        )
        result = self.fc_ssh_exec(f"python3 -c {shlex.quote(code)}", timeout=180)
        return result.returncode == 0

    def vm_copy_file(self, source_path: str, destination_path: str) -> bool:
        code = (
            "from pathlib import Path\n"
            "import shutil\n"
            f"src = Path({source_path!r})\n"
            f"dst = Path({destination_path!r})\n"
            "if not src.exists():\n"
            "    raise SystemExit(1)\n"
            "dst.parent.mkdir(parents=True, exist_ok=True)\n"
            "shutil.copyfile(src, dst)\n"
            "print('ok')\n"
        )
        result = self.fc_ssh_exec(f"python3 -c {shlex.quote(code)}", timeout=180)
        return result.returncode == 0

    def vm_remove_file(self, path: str) -> bool:
        code = (
            "from pathlib import Path\n"
            f"Path({path!r}).unlink(missing_ok=True)\n"
            "print('ok')\n"
        )
        result = self.fc_ssh_exec(f"python3 -c {shlex.quote(code)}", timeout=90)
        return result.returncode == 0

    def vm_file_exists(self, path: str) -> bool:
        code = (
            "from pathlib import Path\n"
            f"print('1' if Path({path!r}).exists() else '0')\n"
        )
        result = self.fc_ssh_exec(f"python3 -c {shlex.quote(code)}", timeout=90)
        return result.returncode == 0 and result.stdout.strip().endswith("1")

    def vm_write_text_file(self, path: str, content: str) -> bool:
        code = (
            "from pathlib import Path\n"
            f"dst = Path({path!r})\n"
            "dst.parent.mkdir(parents=True, exist_ok=True)\n"
            f"dst.write_text({content!r}, encoding='utf-8')\n"
            "print('ok')\n"
        )
        result = self.fc_ssh_exec(f"python3 -c {shlex.quote(code)}", timeout=120)
        return result.returncode == 0


class Runner:
    def __init__(self) -> None:
        RUN_DIR.mkdir(parents=True, exist_ok=True)
        self.app = AppiumSession()
        self.backend = BackendHelper()
        self.results: list[Result] = []

    def restart_appium_session(self) -> None:
        try:
            self.app.stop()
        except Exception:  # noqa: BLE001
            pass
        self.app = AppiumSession()
        self.app.start()

    def is_session_level_error(self, error: Exception) -> bool:
        text = str(error)
        needles = [
            "500 Server Error",
            "invalid session id",
            "/source",
            "/appium/device/terminate_app",
            "/appium/device/activate_app",
            "Connection refused",
            "Max retries exceeded",
            "Read timed out",
            "A session is either terminated or not started",
        ]
        return any(needle in text for needle in needles)

    def record(self, case_id: str, status: str, notes: str) -> None:
        self.results.append(Result(case_id, status, notes))
        print(f"{case_id} {status} {notes}", flush=True)

    def fail_artifacts(self, case_id: str) -> None:
        stamp = case_id.lower()
        try:
            self.app.save_source(RUN_DIR / f"{stamp}.xml")
        except Exception:  # noqa: BLE001
            pass
        try:
            self.app.screenshot(RUN_DIR / f"{stamp}.png")
        except Exception:  # noqa: BLE001
            pass

    def assert_true(self, case_id: str, condition: bool, notes: str, fail_notes: str | None = None) -> None:
        if condition:
            self.record(case_id, "PASS", notes)
            return
        self.fail_artifacts(case_id)
        self.record(case_id, "FAIL", fail_notes or notes)

    def ensure_text_fixtures(self) -> None:
        markdown_b64 = base64.b64encode(QA_MARKDOWN_TEXT.encode("utf-8")).decode("ascii")
        command = (
            "from pathlib import Path\n"
            "import base64\n"
            "import shutil\n"
            "downloads = Path('/root/Downloads')\n"
            "downloads.mkdir(parents=True, exist_ok=True)\n"
            "(downloads / 'Documents' / 'Reports' / 'Exports').mkdir(parents=True, exist_ok=True)\n"
            f"(downloads / 'test.md').write_bytes(base64.b64decode({markdown_b64!r}))\n"
            "(downloads / 'test.swift').write_text('import Foundation\\nstruct Fixture { let value = 42 }\\n', encoding='utf-8')\n"
            "(downloads / 'test.json').write_text('{\"hello\":true,\"count\":3}\\n', encoding='utf-8')\n"
            "(downloads / 'test.sh').write_text('#!/bin/bash\\necho from-sh\\n', encoding='utf-8')\n"
            "(downloads / 'test.log').write_text('log-line-1\\n', encoding='utf-8')\n"
            f"(downloads / 'image.png').write_bytes(base64.b64decode({QA_PNG_BASE64!r}))\n"
            f"(downloads / 'document.pdf').write_bytes(base64.b64decode({QA_PDF_BASE64!r}))\n"
            f"video = downloads / {Path(LARGE_VIDEO_REMOTE_PATH).name!r}\n"
            f"backup = downloads / {Path(LARGE_VIDEO_BACKUP_PATH).name!r}\n"
            f"if not video.exists() or video.stat().st_size < {QA_LARGE_VIDEO_BYTES}:\n"
            "    with video.open('wb') as handle:\n"
            f"        handle.truncate({QA_LARGE_VIDEO_BYTES})\n"
            "if not backup.exists() or backup.stat().st_size != video.stat().st_size:\n"
            "    shutil.copyfile(video, backup)\n"
            "(downloads / 'unsupported.bin').write_bytes(b'\\x00\\x01\\x02\\x03unsupported')\n"
            "(downloads / 'huge.txt').write_text('A' * (600 * 1024), encoding='utf-8')\n"
            "(downloads / 'test.sh').chmod(0o755)\n"
            "print('ok')\n"
        )
        result = self.backend.fc_ssh_exec(f"python3 -c {shlex.quote(command)}", timeout=180)
        if result.returncode != 0:
            raise RuntimeError("Unable to create text fixtures inside live VM")

    def ensure_preview_error_fixtures(self) -> None:
        self.ensure_text_fixtures()

    def ensure_commander(self) -> None:
        src = self.app.source()
        if (
            "Take Command" not in src
            and "Session controlled from" not in src
            and "soyeht.websocket.takeCommandButton" not in src
        ):
            return
        try:
            self.app.click_id("soyeht.websocket.takeCommandButton", timeout=4)
        except Exception:
            self.app.click_xpath("//*[@label='Take Command' or @name='Take Command']", timeout=8)
        time.sleep(2)

    def _visible_accessibility_ids(self, src: str, prefix: str) -> list[str]:
        ids: list[str] = []
        for identifier in re.findall(r'<[^>]+name="([^"]+)"[^>]*visible="true"', src):
            if identifier.startswith(prefix) and identifier not in ids:
                ids.append(identifier)
        return ids

    def _pick_instance_card(self, src: str) -> str | None:
        cards = self._visible_accessibility_ids(src, "soyeht.instanceList.instanceCard.")
        if not cards:
            return None

        hints = [
            CONTAINER,
            CONTAINER.removeprefix("zeroclaw-"),
            CONTAINER.removeprefix("zero"),
            SESSION,
        ]
        for hint in hints:
            for card in cards:
                if hint and hint in card:
                    return card
        return cards[0]

    def _pick_window_card(self, src: str) -> str | None:
        cards = self._visible_accessibility_ids(src, "soyeht.sessionSheet.windowCard.")
        return cards[0] if cards else None

    def ensure_terminal_screen(self, allow_mirror: bool = False, timeout: float = 30.0) -> str:
        deadline = time.time() + timeout
        while time.time() < deadline:
            src = self.app.source()
            generic_terminal_chrome = (
                "soyeht.tmuxTabBar.container" in src and
                any(
                    token in src
                    for token in [
                        'label="Move"',
                        'name="folder"',
                        'name="gearshape"',
                        CONTAINER,
                        CONTAINER.removeprefix("zeroclaw-"),
                    ]
                )
            )

            if (
                "soyeht.terminal.fileBrowserButton" in src
                or "soyeht.terminal.terminalView" in src
                or generic_terminal_chrome
            ):
                if not allow_mirror:
                    self.ensure_commander()
                    src = self.app.source()
                return src

            if not allow_mirror and (
                "Take Command" in src
                or "Session controlled from" in src
                or "soyeht.websocket.takeCommandButton" in src
            ):
                self.ensure_commander()
                time.sleep(1)
                continue

            visible_session_sheet = self._visible_accessibility_ids(src, "soyeht.instanceList.sessionSheet")
            if visible_session_sheet:
                if "soyeht.instanceList.connectButton" in src:
                    self.app.click_id("soyeht.instanceList.connectButton", timeout=6)
                    time.sleep(3)
                    continue

                target = self._pick_window_card(src)
                if target:
                    self.app.click_id(target, timeout=6)
                    time.sleep(3)
                    continue

            if self._pick_instance_card(src):
                target = self._pick_instance_card(src)
                if target:
                    self.app.click_id(target, timeout=6)
                    time.sleep(2)
                    continue

            time.sleep(1)

        raise LookupError("Unable to reach terminal screen from current app state")

    def open_browser(self, allow_mirror: bool = False, reset: bool = True) -> str:
        if reset:
            self.app.reset_app()
        self.ensure_terminal_screen(allow_mirror=allow_mirror)
        try:
            self.app.click_id("soyeht.terminal.fileBrowserButton", timeout=8)
        except Exception:
            self.app.click_xpath("//*[@label='Move' or @name='folder']", timeout=8)
        time.sleep(2)
        return self.app.source()

    def source_contains(self, needle: str) -> bool:
        return needle in self.app.source()

    def wait_for_source(self, needle: str, timeout: float = 8.0) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if needle in self.app.source():
                return True
            time.sleep(0.5)
        return False

    def wait_for_remote_download_status(self, path: str, expected_status: int, timeout: float = 8.0) -> bool:
        deadline = time.time() + timeout
        last_status: int | None = None
        while time.time() < deadline:
            try:
                last_status = self.backend.remote_download_status(path)
                if last_status == expected_status:
                    return True
            except Exception:  # noqa: BLE001
                pass
            time.sleep(0.5)
        return last_status == expected_status

    def run_pane_command(self, command: str, read_seconds: float = 2.0) -> str:
        return asyncio.run(
            self.backend.send_pty_command(
                command,
                read_seconds=read_seconds,
                client="file-browser-cwd-qa",
            )
        )

    def capture_terminal_pwd_and_ls(self, command: str, read_seconds: float = 2.0) -> tuple[str | None, list[str], str]:
        marker = f"QA_BROW_{int(time.time() * 1000)}"
        wrapped = (
            f"{command}; "
            f"printf '\\n__{marker}_PWD_START__\\n'; pwd; "
            f"printf '__{marker}_LS_START__\\n'; ls -1A; "
            f"printf '__{marker}_END__\\n'"
        )
        output = self.run_pane_command(wrapped, read_seconds=read_seconds)
        pwd_marker = f"__{marker}_PWD_START__"
        ls_marker = f"__{marker}_LS_START__"
        end_marker = f"__{marker}_END__"

        pwd: str | None = None
        entries: list[str] = []
        if pwd_marker in output and ls_marker in output and end_marker in output:
            pwd_block = output.split(pwd_marker, 1)[1].split(ls_marker, 1)[0]
            pwd_lines = [line.strip() for line in pwd_block.splitlines() if line.strip()]
            if pwd_lines:
                pwd = pwd_lines[-1]

            ls_block = output.split(ls_marker, 1)[1].split(end_marker, 1)[0]
            entries = [
                line.strip()
                for line in ls_block.splitlines()
                if line.strip() and not line.strip().startswith("__")
            ]
        return pwd, entries, output

    def normalized_browser_path(self, path: str) -> str:
        if path == "/root":
            return "~"
        if path.startswith("/root/"):
            return "~" + path[len("/root"):]
        return path

    def breadcrumb_labels(self, src: str | None = None) -> list[str]:
        source = src or self.app.source()
        labels: dict[int, str] = {}
        for match in re.finditer(r'<[^>]+name="soyeht\.fileBrowser\.breadcrumb\.(\d+)"[^>]*>', source):
            element = match.group(0)
            label_match = re.search(r'label="([^"]+)"', element) or re.search(r'value="([^"]+)"', element)
            if not label_match:
                continue
            labels[int(match.group(1))] = label_match.group(1)
        return [labels[index] for index in sorted(labels)]

    def breadcrumb_path(self, src: str | None = None) -> str | None:
        labels = self.breadcrumb_labels(src)
        if not labels:
            return None
        if labels[0] == "~":
            return "~" if len(labels) == 1 else "~/" + "/".join(labels[1:])
        if labels[0] == "/":
            return "/" if len(labels) == 1 else "/" + "/".join(labels[1:])
        return "/".join(labels)

    def find_id_after_swipes(self, accessibility_id: str, max_swipes: int = 4) -> str:
        max_swipes = max(max_swipes, 8)
        for _ in range(max_swipes + 1):
            try:
                return self.app.find("accessibility id", accessibility_id, timeout=1.5)
            except Exception:  # noqa: BLE001
                self.app.swipe_up()
        raise LookupError(f"Unable to find {accessibility_id} after {max_swipes} swipes")

    def copy_saved_remote_file(self, remote_path: str, destination: Path) -> bool:
        destination.parent.mkdir(parents=True, exist_ok=True)
        command = [
            "xcrun",
            "devicectl",
            "device",
            "copy",
            "from",
            "--device",
            UDID,
            "--domain-type",
            "appDataContainer",
            "--domain-identifier",
            BUNDLE_ID,
            "--source",
            f"Documents/RemoteFiles/{CONTAINER}{remote_path}",
            "--destination",
            str(destination),
        ]
        result = subprocess.run(command, capture_output=True, text=True, timeout=90)
        return result.returncode == 0 and destination.exists()

    def tap_row(self, path: str, swipes: int = 0) -> None:
        for _ in range(swipes):
            self.app.swipe_up()
        self.app.click_id(f"soyeht.fileBrowser.row.{path}", timeout=6)
        time.sleep(2)

    def tap_row_center(self, path: str, max_swipes: int = 4, delay: float = 1.5) -> str:
        last_error: Exception | None = None
        for _ in range(3):
            row = self.find_id_after_swipes(f"soyeht.fileBrowser.row.{path}", max_swipes=max_swipes)
            try:
                rect = self.app.rect(row)
                self.app.tap_point(rect["x"] + rect["width"] / 2, rect["y"] + rect["height"] / 2)
                time.sleep(delay)
                return self.app.source()
            except Exception as error:  # noqa: BLE001
                last_error = error
                try:
                    self.app.click_element(row)
                    time.sleep(delay)
                    return self.app.source()
                except Exception as click_error:  # noqa: BLE001
                    last_error = click_error
                    time.sleep(0.5)
        raise last_error if last_error else LookupError(f"Unable to tap row {path}")

    def enter_downloads(self) -> None:
        src = self.app.source()
        already_in_downloads = any(
            token in src
            for token in [
                "soyeht.fileBrowser.row./root/Downloads/document.pdf",
                "soyeht.fileBrowser.row./root/Downloads/test.md",
                "soyeht.fileBrowser.row./root/Downloads/huge.txt",
                "soyeht.fileBrowser.row./root/Downloads/0-large-video.mp4",
            ]
        )
        if already_in_downloads:
            return
        if "soyeht.fileBrowser.row./root/Downloads" in src:
            self.tap_row("/root/Downloads")

    def test_brow_001(self) -> None:
        src = self.open_browser()
        self.assert_true(
            "ST-Q-BROW-001",
            all(token in src for token in ["soyeht.fileBrowser.container", "soyeht.fileBrowser.collection", "soyeht.fileBrowser.breadcrumbBar"]),
            "Browser opens from keybar with list and breadcrumb",
        )

    def test_brow_002(self) -> None:
        src = self.open_browser()
        opened = all(token in src for token in ["soyeht.fileBrowser.container", "soyeht.fileBrowser.collection", "soyeht.fileBrowser.breadcrumbBar"])
        fallback_root = False
        if opened:
            try:
                self.app.find(
                    "xpath",
                    "//*[@name='soyeht.fileBrowser.breadcrumb.0' and (@label='~' or @value='~')]",
                    timeout=8,
                )
                fallback_root = True
            except Exception:  # noqa: BLE001
                src = self.app.source()
                fallback_root = "soyeht.fileBrowser.breadcrumb.0" in src and ('label=\"~\"' in src or 'value=\"~\"' in src)
        self.assert_true("ST-Q-BROW-002", opened and fallback_root, "Browser opens without pane context and falls back to ~")

    def test_brow_026_027_028(self) -> None:
        self.ensure_text_fixtures()

        marker_026 = f"qa-brow-026-{int(time.time())}.txt"
        pwd_026, entries_026, output_026 = self.capture_terminal_pwd_and_ls(
            f"cd /root/Downloads/Documents/Reports && printf 'cwd-sync-026\\n' > {shlex.quote(marker_026)}",
            read_seconds=2.5,
        )
        src_026 = self.open_browser(reset=True)
        expected_026 = self.normalized_browser_path(pwd_026) if pwd_026 else None
        actual_026 = self.breadcrumb_path(src_026)
        row_026_marker = f"soyeht.fileBrowser.row.{pwd_026}/{marker_026}" if pwd_026 else ""
        row_026_exports = f"soyeht.fileBrowser.row.{pwd_026}/Exports" if pwd_026 else ""
        self.assert_true(
            "ST-Q-BROW-026",
            bool(
                expected_026
                and actual_026 == expected_026
                and marker_026 in entries_026
                and "Exports" in entries_026
                and row_026_marker in src_026
                and row_026_exports in src_026
            ),
            f"Browser path matches terminal pwd ({expected_026}) and reflects ls entries",
            fail_notes=f"pwd/ls to browser mismatch. pwd={pwd_026!r} entries={entries_026!r} actual={actual_026!r} output={output_026!r}",
        )
        self.backend.vm_remove_file(f"/root/Downloads/Documents/Reports/{marker_026}")

        nested_dir = "/root/Downloads/qa-cwd-sync/nested"
        nested_file = "from-terminal.txt"
        nested_child = "from-terminal-dir"
        pwd_027, entries_027, output_027 = self.capture_terminal_pwd_and_ls(
            "mkdir -p /root/Downloads/qa-cwd-sync/nested/from-terminal-dir "
            "&& printf 'from-terminal\\n' > /root/Downloads/qa-cwd-sync/nested/from-terminal.txt "
            "&& cd /root/Downloads/qa-cwd-sync/nested",
            read_seconds=2.5,
        )
        src_027 = self.open_browser(reset=True)
        expected_027 = self.normalized_browser_path(pwd_027) if pwd_027 else None
        actual_027 = self.breadcrumb_path(src_027)
        row_027_file = f"soyeht.fileBrowser.row.{nested_dir}/{nested_file}"
        row_027_dir = f"soyeht.fileBrowser.row.{nested_dir}/{nested_child}"
        self.assert_true(
            "ST-Q-BROW-027",
            bool(
                pwd_027 == nested_dir
                and expected_027
                and actual_027 == expected_027
                and nested_file in entries_027
                and nested_child in entries_027
                and row_027_file in src_027
                and row_027_dir in src_027
            ),
            f"Browser opens in nested cwd from terminal ({expected_027}) and mirrors ls output",
            fail_notes=f"Nested cwd mismatch. pwd={pwd_027!r} entries={entries_027!r} actual={actual_027!r} output={output_027!r}",
        )

        first_pwd, _, first_output = self.capture_terminal_pwd_and_ls("cd /root/Downloads", read_seconds=2.0)
        first_src = self.open_browser(reset=True)
        first_path = self.breadcrumb_path(first_src)
        second_marker = f"qa-brow-028-{int(time.time())}.txt"
        second_pwd, second_entries, second_output = self.capture_terminal_pwd_and_ls(
            f"cd /root/Downloads/Documents/Reports/Exports && printf 'cwd-sync-028\\n' > {shlex.quote(second_marker)}",
            read_seconds=2.5,
        )
        second_src = self.open_browser(reset=True)
        second_path = self.breadcrumb_path(second_src)
        expected_first = self.normalized_browser_path(first_pwd) if first_pwd else None
        expected_second = self.normalized_browser_path(second_pwd) if second_pwd else None
        row_028_marker = f"soyeht.fileBrowser.row.{second_pwd}/{second_marker}" if second_pwd else ""
        self.assert_true(
            "ST-Q-BROW-028",
            bool(
                expected_first
                and expected_second
                and first_path == expected_first
                and second_path == expected_second
                and second_path != first_path
                and second_marker in second_entries
                and row_028_marker in second_src
            ),
            f"Browser follows latest pane cwd after terminal cd ({expected_first} -> {expected_second})",
            fail_notes=(
                f"Latest cwd not reflected. first_pwd={first_pwd!r} first_path={first_path!r} "
                f"second_pwd={second_pwd!r} second_path={second_path!r} second_entries={second_entries!r} "
                f"first_output={first_output!r} second_output={second_output!r}"
            ),
        )
        self.backend.vm_remove_file(f"/root/Downloads/Documents/Reports/Exports/{second_marker}")

    def test_brow_003_004_005_007(self) -> None:
        self.open_browser()
        self.enter_downloads()
        self.tap_row("/root/Downloads/Documents")
        in_docs = self.wait_for_source("soyeht.fileBrowser.row./root/Downloads/Documents/Reports", timeout=8)
        self.assert_true("ST-Q-BROW-003", in_docs and self.source_contains("soyeht.fileBrowser.breadcrumb.2"), "Subfolder navigation updates list and breadcrumb")

        self.app.click_id("soyeht.fileBrowser.breadcrumb.1", timeout=5)
        time.sleep(2)
        self.assert_true(
            "ST-Q-BROW-004",
            self.source_contains("soyeht.fileBrowser.row./root/Downloads/Documents") and not self.source_contains("soyeht.fileBrowser.row./root/Downloads/Documents/Reports"),
            "Breadcrumb segment navigates up to Downloads",
        )

        self.tap_row("/root/Downloads/Documents")
        self.tap_row("/root/Downloads/Documents/Reports")
        self.tap_row("/root/Downloads/Documents/Reports/Exports")
        self.app.click_id("soyeht.fileBrowser.breadcrumb.0", timeout=5)
        time.sleep(2)
        self.assert_true("ST-Q-BROW-005", self.source_contains("soyeht.fileBrowser.row./root/Downloads"), "Root breadcrumb jumps directly to root")

        self.tap_row("/root/Downloads")
        self.tap_row("/root/Downloads/Documents")
        self.tap_row("/root/Downloads/Documents/Reports")
        self.assert_true("ST-Q-BROW-007", self.source_contains("soyeht.fileBrowser.row./root/Downloads/Documents/Reports/Exports"), "Agent-created Reports folder appears normally")

    def test_brow_006(self) -> None:
        src = self.open_browser()
        chips = ["Photos", "Camera", "Documents", "Files", "Location"]
        self.assert_true(
            "ST-Q-BROW-006",
            all(f"soyeht.fileBrowser.sourceChip.{name}" in src for name in chips),
            "All five favorite chips are visible",
        )

    def _open_preview(self, row_path: str, swipes: int = 1) -> str:
        self.open_browser()
        self.enter_downloads()
        self.app.pull_down()
        time.sleep(1)
        max_swipes = max(swipes, 8)
        if row_path.lower().endswith((".mp4", ".mov", ".m4v")):
            src = self.app.source()
            for _ in range(3):
                src = self.tap_row_center(row_path, max_swipes=max_swipes)
                if (
                    f"soyeht.fileBrowser.rowProgress.{row_path}" in src
                    or f"soyeht.fileBrowser.rowError.{row_path}" in src
                    or "soyeht.filePreview.textView" in src
                ):
                    break
            return src
        try:
            row = self.find_id_after_swipes(f"soyeht.fileBrowser.row.{row_path}", max_swipes=max_swipes)
            self.app.click_element(row)
            time.sleep(2)
        except Exception:  # noqa: BLE001
            self.tap_row(row_path, swipes=swipes)
        return self.app.source()

    def test_brow_008_009_010(self) -> None:
        self.ensure_text_fixtures()

        src = self._open_preview("/root/Downloads/test.md", swipes=1)
        self.assert_true(
            "ST-Q-BROW-008",
            all(token in src for token in ["soyeht.filePreview.textView", "soyeht.filePreview.saveButton", "soyeht.filePreview.downloadButton", "soyeht.filePreview.shareButton"]),
            "Markdown preview opens with action buttons",
        )

        src = self._open_preview("/root/Downloads/test.log", swipes=1)
        self.assert_true("ST-Q-BROW-009", "soyeht.filePreview.textView" in src, "Plain text preview opens for .log")

        src = ""
        for candidate in [
            "/root/Downloads/test.swift",
            "/root/Downloads/test.json",
            "/root/Downloads/test.sh",
        ]:
            try:
                src = self._open_preview(candidate, swipes=1)
                if "soyeht.filePreview.textView" in src:
                    break
            except Exception:  # noqa: BLE001
                continue
        self.assert_true("ST-Q-BROW-010", "soyeht.filePreview.textView" in src, "Plain text preview opens for .swift/.json/.sh")

    def test_brow_011_012_013(self) -> None:
        self.ensure_text_fixtures()
        src = self._open_preview("/root/Downloads/document.pdf", swipes=1)
        self.assert_true("ST-Q-BROW-011", "soyeht.filePreview.textView" in src, "PDF opens in-app via Quick Look child")

        src = self._open_preview("/root/Downloads/0-large-video.mp4", swipes=0)
        ok = "soyeht.fileBrowser.rowProgress./root/Downloads/0-large-video.mp4" in src or "soyeht.filePreview.textView" in src
        self.assert_true("ST-Q-BROW-012", ok, "Video preview/download flow is reachable in-app")

        src = self._open_preview("/root/Downloads/image.png", swipes=1)
        self.assert_true("ST-Q-BROW-013", "soyeht.filePreview.textView" in src, "Image opens in-app via Quick Look child")

    def test_brow_014_015(self) -> None:
        self.ensure_preview_error_fixtures()
        self.open_browser()
        self.enter_downloads()
        row = self.find_id_after_swipes("soyeht.fileBrowser.row./root/Downloads/unsupported.bin", max_swipes=6)
        self.app.click_element(row)
        time.sleep(2)
        src = self.app.source()
        self.assert_true("ST-Q-BROW-014", "Preview not available for this file type." in src, "Unsupported file shows preview alert")
        try:
            self.app.click_xpath("//*[@label='OK' or @name='OK']", timeout=3)
        except Exception:
            pass

        self.open_browser()
        self.enter_downloads()
        row = self.find_id_after_swipes("soyeht.fileBrowser.row./root/Downloads/huge.txt", max_swipes=6)
        self.app.click_element(row)
        time.sleep(2)
        src = self.app.source()
        self.assert_true("ST-Q-BROW-015", "Preview is limited to UTF-8 text files up to 512 KB." in src, "Large text file limit enforced")

    def test_brow_016(self) -> None:
        src = self.open_browser()
        if "soyeht.fileBrowser.row./root/Downloads" in src:
            self.enter_downloads()
            src = self.app.source()
        folder_subtitle_ok = "/root/Downloads/Documents" in src
        file_subtitle_ok = bool(re.search(r"\d+(?:[.,]\d+)?\s*(?:KB|MB|GB)\s+·\s+[^<\"]+", src))
        ok = folder_subtitle_ok and file_subtitle_ok
        self.assert_true("ST-Q-BROW-016", ok, "File list exposes metadata subtitle content")

    def test_brow_017(self) -> None:
        self.open_browser()
        self.enter_downloads()
        marker = f"refresh-{int(time.time())}.txt"
        if not self.backend.vm_write_text_file(f"/root/Downloads/{marker}", "ok\n"):
            self.assert_true("ST-Q-BROW-017", False, "Unable to create refresh marker inside live VM")
            return
        self.app.pull_down()
        footer_ok = self.wait_for_source("Atualizado agora", timeout=8)
        try:
            self.find_id_after_swipes(f"soyeht.fileBrowser.row./root/Downloads/{marker}", max_swipes=6)
            marker_ok = True
        except Exception:
            marker_ok = False
        ok = marker_ok and footer_ok
        self.assert_true("ST-Q-BROW-017", ok, "Pull-to-refresh reloads list and shows footer")
        self.backend.vm_remove_file(f"/root/Downloads/{marker}")

    def test_brow_018_020_021(self) -> None:
        self.ensure_text_fixtures()
        self._open_preview("/root/Downloads/test.md", swipes=1)
        self.app.click_id("soyeht.filePreview.saveButton", timeout=5)
        time.sleep(0.4)
        src = self.app.source()
        saved_copy = self.copy_saved_remote_file("/root/Downloads/test.md", RUN_DIR / "saved-test.md")
        self.assert_true(
            "ST-Q-BROW-018",
            "soyeht.filePreview.toast" in src or "Saved" in src or saved_copy,
            "Save to iPhone shows Saved toast",
        )

        self.app.click_id("soyeht.filePreview.downloadButton", timeout=5)
        time.sleep(2)
        src = self.app.source()
        save_as_ok = any(token in src for token in ["Document Manager", "Browse", "Recents", "iCloud Drive"])
        self.assert_true("ST-Q-BROW-020", save_as_ok, "Save As opens document picker")

        self._open_preview("/root/Downloads/test.md", swipes=1)
        self.app.click_id("soyeht.filePreview.shareButton", timeout=5)
        time.sleep(2)
        src = self.app.source()
        share_ok = any(token in src for token in ["Copy", "AirDrop", "Messages", "Mail", "Save to Files"])
        self.assert_true("ST-Q-BROW-021", share_ok, "Share button opens activity controller")
        self.app.activate_app(BUNDLE_ID)
        time.sleep(2)

    def test_brow_022(self) -> None:
        self.ensure_text_fixtures()
        self.open_browser()
        self.enter_downloads()
        row = self.find_id_after_swipes("soyeht.fileBrowser.row./root/Downloads/test.md", max_swipes=3)
        self.app.long_press(row, duration=0.8)
        time.sleep(2)
        try:
            self.app.click_xpath("//*[@label='Share Path' or @name='Share Path']", timeout=4)
        except Exception:
            self.fail_artifacts("ST-Q-BROW-022")
            self.record("ST-Q-BROW-022", "FAIL", "Context menu missing Share Path action")
            return
        time.sleep(2)
        src = self.app.source()
        share_ok = any(token in src for token in ["Copy", "AirDrop", "Messages", "Mail", "/root/Downloads/test.md"])
        self.assert_true("ST-Q-BROW-022", share_ok, "Long-press file row can share remote path")
        self.app.activate_app(BUNDLE_ID)
        time.sleep(2)

    def test_brow_019(self) -> None:
        self.ensure_text_fixtures()
        self.open_browser()
        self.enter_downloads()
        row = self.find_id_after_swipes("soyeht.fileBrowser.row./root/Downloads/test.md", max_swipes=3)
        self.app.click_element(row)
        time.sleep(2)
        self.app.click_id("soyeht.filePreview.saveButton", timeout=5)
        time.sleep(0.5)
        saved_copy = self.copy_saved_remote_file("/root/Downloads/test.md", RUN_DIR / "files-app-test.md")
        self.assert_true("ST-Q-BROW-019", saved_copy, "Saved file remains available in app container for offline access")

    def test_brow_023_024(self) -> None:
        self.ensure_text_fixtures()
        remote_path = f"/root/Downloads/0-large-inline-{int(time.time())}.mp4"
        if not self.backend.vm_copy_file(LARGE_VIDEO_REMOTE_PATH, remote_path):
            self.assert_true("ST-Q-BROW-023", False, "Unable to create large inline video fixture inside live VM")
            self.assert_true("ST-Q-BROW-024", False, "Cancel could not be exercised because fixture creation failed")
            return
        self.open_browser()
        self.enter_downloads()
        self.app.pull_down()
        self.find_id_after_swipes(f"soyeht.fileBrowser.row.{remote_path}", max_swipes=6)
        src = self.app.source()
        for _ in range(3):
            src = self.tap_row_center(remote_path, max_swipes=6, delay=1.5)
            if (
                f"soyeht.fileBrowser.rowProgress.{remote_path}" in src
                or f"soyeht.fileBrowser.rowAction.{remote_path}" in src
                or "soyeht.filePreview.textView" in src
            ):
                break
        has_progress = f"soyeht.fileBrowser.rowProgress.{remote_path}" in src
        has_action = f"soyeht.fileBrowser.rowAction.{remote_path}" in src
        self.assert_true("ST-Q-BROW-023", has_progress and has_action and "soyeht.filePreview.textView" not in src, "Large video shows inline download progress without premature preview")
        if has_action:
            try:
                self.app.click_id(f"soyeht.fileBrowser.rowAction.{remote_path}", timeout=1.5)
            except Exception:
                row = self.find_id_after_swipes(f"soyeht.fileBrowser.row.{remote_path}", max_swipes=6)
                rect = self.app.rect(row)
                self.app.tap_point(rect["x"] + rect["width"] - 18, rect["y"] + rect["height"] / 2)
            time.sleep(2)
        src = self.app.source()
        self.assert_true("ST-Q-BROW-024", f"soyeht.fileBrowser.rowProgress.{remote_path}" not in src, "Cancel returns row to normal state")
        self.backend.vm_remove_file(remote_path)

    def test_brow_025(self) -> None:
        self.ensure_text_fixtures()
        remote_path = f"/root/Downloads/0-flaky-video-{int(time.time())}.mp4"
        if not self.backend.vm_copy_file(LARGE_VIDEO_REMOTE_PATH, remote_path):
            self.assert_true("ST-Q-BROW-025", False, "Unable to create flaky video fixture inside live VM")
            return
        if not self.backend.vm_file_exists(remote_path):
            self.assert_true("ST-Q-BROW-025", False, "Flaky video fixture was not created inside live VM")
            return
        self.open_browser()
        self.enter_downloads()
        self.app.pull_down()
        self.find_id_after_swipes(f"soyeht.fileBrowser.row.{remote_path}", max_swipes=5)
        if not self.backend.vm_remove_file(remote_path):
            self.assert_true("ST-Q-BROW-025", False, "Unable to remove flaky video fixture from live VM")
            return
        if not self.wait_for_remote_download_status(remote_path, expected_status=404, timeout=8):
            self.assert_true("ST-Q-BROW-025", False, "Backend still served flaky video after removal")
            return
        src = self.app.source()
        for _ in range(3):
            src = self.tap_row_center(remote_path, max_swipes=5)
            if (
                f"soyeht.fileBrowser.rowError.{remote_path}" in src
                or f"soyeht.fileBrowser.rowAction.{remote_path}" in src
                or "Tentar de novo" in src
            ):
                break
        error_ok = self.wait_for_source(f"soyeht.fileBrowser.rowError.{remote_path}", timeout=12) and self.wait_for_source(
            f"soyeht.fileBrowser.rowAction.{remote_path}",
            timeout=2,
        )
        src = self.app.source()
        error_ok = error_ok or "Tentar de novo" in src
        self.assert_true("ST-Q-BROW-025", error_ok, "Missing remote file renders inline retry state after failed download")
        if not self.backend.vm_copy_file(LARGE_VIDEO_REMOTE_PATH, remote_path):
            self.assert_true("ST-Q-BROW-025", False, "Unable to restore flaky video fixture for retry")
            return
        try:
            self.app.click_id(f"soyeht.fileBrowser.rowAction.{remote_path}", timeout=2)
        except Exception:
            self.app.tap_point(344, 569)
        retry_ok = self.wait_for_source(f"soyeht.fileBrowser.rowProgress.{remote_path}", timeout=12)
        src = self.app.source()
        retry_ok = retry_ok or f"soyeht.fileBrowser.rowAction.{remote_path}" in src
        self.assert_true("ST-Q-BROW-025", retry_ok, "Retry restarts the download flow after restoring the file")
        self.backend.vm_remove_file(remote_path)

    def run(self, suites: list[str], only: set[str] | None = None) -> None:
        self.app.start()
        try:
            browser_tests = [
                self.test_brow_001,
                self.test_brow_026_027_028,
                self.test_brow_003_004_005_007,
                self.test_brow_006,
                self.test_brow_008_009_010,
                self.test_brow_011_012_013,
                self.test_brow_014_015,
                self.test_brow_016,
                self.test_brow_017,
                self.test_brow_018_020_021,
                self.test_brow_019,
                self.test_brow_022,
                self.test_brow_023_024,
                self.test_brow_025,
            ]
            if FORCE_BROWSER_FALLBACK or (only and "brow_002" in only):
                browser_tests.insert(1, self.test_brow_002)
            def selected(tests: list[Any]) -> list[Any]:
                if not only:
                    return tests
                return [test for test in tests if test.__name__.replace("test_", "") in only]
            if "browser" in suites:
                for test in selected(browser_tests):
                    label = test.__name__.replace("test_", "").upper()
                    for attempt in range(2):
                        try:
                            if attempt > 0:
                                self.restart_appium_session()
                            test()
                            break
                        except Exception as error:  # noqa: BLE001
                            if attempt == 0 and self.is_session_level_error(error):
                                print(f"{label} RETRY transient session error: {error}", flush=True)
                                continue
                            self.fail_artifacts(label)
                            self.record(label, "FAIL", f"Runner error: {error}")
                            break
        finally:
            self.app.stop()
            self.write_report()

    def write_report(self) -> None:
        passed = [result for result in self.results if result.status == "PASS"]
        failed = [result for result in self.results if result.status == "FAIL"]
        skipped = [result for result in self.results if result.status == "SKIP"]
        lines = [
            "# QA Report: File Browser",
            "",
            f"**Date**: {time.strftime('%Y-%m-%d')}",
            "**Tester**: Automated via Appium + backend helpers",
            "**Device**: iPhone <qa-device> (iOS 26.4.1)",
            f"**App**: {BUNDLE_ID}",
            f"**Backend**: {BACKEND_BASE} ({CONTAINER}/{SESSION})",
            "**Plan Reference**: QA/domains/file-browser.md",
            "",
            "## Executive Summary",
            "",
            f"**{len(self.results)} test cases executed.**",
            f"**Result: {len(passed)} PASS, {len(failed)} FAIL, {len(skipped)} SKIP**",
            "",
            "## Test Results",
            "",
            "| ID | Status | Notes |",
            "|----|--------|-------|",
        ]
        for result in self.results:
            lines.append(f"| {result.case_id} | {result.status} | {result.notes} |")
        (RUN_DIR / "report.md").write_text("\n".join(lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--suite", choices=["browser"], default="browser")
    parser.add_argument("--only", help="Comma-separated test function suffixes without the test_ prefix")
    args = parser.parse_args()
    suites = [args.suite]
    only = {item.strip() for item in args.only.split(",") if item.strip()} if args.only else None
    runner = Runner()
    runner.run(suites, only=only)
    fails = [result for result in runner.results if result.status == "FAIL"]
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
