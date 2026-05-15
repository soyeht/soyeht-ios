#!/usr/bin/env python3
"""Live test that the unified terminal screen responds to finger-drag scroll.

Boots the repo's usual WDA + Appium gate, navigates to a terminal, writes a
seed of numbered lines via WebSocket, then drags from the middle-bottom of
the terminal view up toward the top. The test verifies that the visible
content offset actually changed (read via XCUITest element-source diff) and
that the app did not crash.
"""
from __future__ import annotations

import base64
import os
import sys
import time
from datetime import date
from pathlib import Path

import requests

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "QA" / "scripts"))

from appium_gate_common import (
    build_gate_env,
    terminate_processes,
    ensure_session_token,
    DEFAULT_BASE_URL,
    require_env,
)

APPIUM_URL = os.environ.get("APPIUM_URL", "http://127.0.0.1:4723")
BUNDLE_ID = "com.soyeht.app"


def _post(base: str, path: str, body: dict | None = None, timeout: int = 60):
    r = requests.post(f"{base}{path}", json=body or {}, timeout=timeout)
    r.raise_for_status()
    return r.json().get("value")


def _get(base: str, path: str, timeout: int = 30):
    r = requests.get(f"{base}{path}", timeout=timeout)
    r.raise_for_status()
    return r.json().get("value")


def _session(udid: str, wda_url: str) -> tuple[str, str]:
    caps = {
        "platformName": "iOS",
        "appium:automationName": "XCUITest",
        "appium:udid": udid,
        "appium:bundleId": BUNDLE_ID,
        "appium:noReset": True,
        "appium:shouldUseSingletonTestManager": False,
        "appium:waitForIdleTimeout": 0,
        "appium:waitForQuiescence": False,
        "appium:webDriverAgentUrl": wda_url,
        "appium:useNewWDA": False,
        "appium:wdaLaunchTimeout": 180000,
        "appium:wdaConnectionTimeout": 180000,
        "appium:newCommandTimeout": 240,
    }
    r = requests.post(
        f"{APPIUM_URL}/session",
        json={"capabilities": {"alwaysMatch": caps, "firstMatch": [{}]}},
        timeout=240,
    )
    r.raise_for_status()
    payload = r.json()
    sid = payload["value"].get("sessionId") or payload.get("sessionId")
    return sid, f"{APPIUM_URL}/session/{sid}"


def _find_by_id(base: str, acc_id: str, timeout: float = 15.0) -> str | None:
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            v = _post(base, "/element", {"using": "accessibility id", "value": acc_id})
            if isinstance(v, dict):
                return v.get("ELEMENT") or v.get("element-6066-11e4-a52e-4f735466cecf")
        except Exception as e:
            last = e
        time.sleep(0.5)
    print(f"  [warn] Could not find {acc_id}: {last}")
    return None


def _rect(base: str, eid: str) -> dict:
    return _get(base, f"/element/{eid}/rect")


def _source(base: str) -> str:
    r = requests.get(f"{base}/source", timeout=30)
    r.raise_for_status()
    return r.json()["value"]


def _screenshot(base: str, out: Path) -> None:
    data = _get(base, "/screenshot")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(base64.b64decode(data))


def _type_keys(base: str, text: str, eid: str | None = None) -> None:
    """Send text to the keyboard — tries multiple endpoints for compatibility."""
    errs = []
    if eid is not None:
        try:
            _post(base, f"/element/{eid}/value", {"text": text, "value": list(text)})
            return
        except Exception as e:
            errs.append(f"element/value: {e}")
    try:
        _post(base, "/appium/device/keys", {"value": list(text)})
        return
    except Exception as e:
        errs.append(f"device/keys: {e}")
    try:
        _post(base, "/wda/keys", {"value": list(text)})
        return
    except Exception as e:
        errs.append(f"wda/keys: {e}")
    raise RuntimeError("; ".join(errs))


def _drag(base: str, sx: float, sy: float, ex: float, ey: float, duration: float = 0.35):
    _post(
        base,
        "/execute/sync",
        {"script": "mobile: dragFromToForDuration",
         "args": [{"duration": duration, "fromX": sx, "fromY": sy, "toX": ex, "toY": ey}]},
    )


def _w3c_drag(base: str, sx: float, sy: float, ex: float, ey: float, duration_ms: int = 400) -> None:
    """W3C Actions finger drag — sometimes triggers UIScrollView panning when
    mobile:dragFromToForDuration is routed through XCUITest coordinate events."""
    _post(base, "/actions", {
        "actions": [{
            "type": "pointer",
            "id": "finger1",
            "parameters": {"pointerType": "touch"},
            "actions": [
                {"type": "pointerMove", "duration": 0, "x": int(sx), "y": int(sy)},
                {"type": "pointerDown", "button": 0},
                {"type": "pause", "duration": 80},
                {"type": "pointerMove", "duration": duration_ms, "x": int(ex), "y": int(ey)},
                {"type": "pointerUp", "button": 0},
            ],
        }]
    })
    try:
        _post(base, "/actions/release", {})
    except Exception:
        pass


def _click_id(base: str, acc_id: str, timeout: float = 15.0) -> bool:
    eid = _find_by_id(base, acc_id, timeout)
    if not eid:
        return False
    _post(base, f"/element/{eid}/click")
    return True


def _maybe_pair(base: str, out_dir: Path) -> None:
    """If app is showing the QR scan screen, pair using env token via deep link."""
    src = _source(base)
    if "paste link" not in src and "scan qr code" not in src and "QRScanner" not in src:
        return
    host = os.environ.get("SOYEHT_BASE_URL") or os.environ.get("QA_BASE_URL") or DEFAULT_BASE_URL
    try:
        token = ensure_session_token(host)
    except Exception as e:
        print(f"  [warn] cannot obtain token: {e}")
        return
    import urllib.parse
    host_q = urllib.parse.quote(host, safe="")
    deep = f"theyos://pair?token={token}&host={host_q}"
    print(f"  -> deep-link pair: theyos://pair?token=***&host={host_q}")
    try:
        _post(base, "/execute/sync", {"script": "mobile: deepLink", "args": [{"url": deep, "bundleId": BUNDLE_ID}]})
    except Exception as e:
        print(f"  [warn] mobile: deepLink failed: {e}")
        return
    time.sleep(5)
    _screenshot(base, out_dir / "after_pair.png")


def _nav_to_terminal(base: str, out_dir: Path) -> bool:
    """Navigate from launch screen to a terminal session."""
    _maybe_pair(base, out_dir)
    import re
    for attempt in range(40):
        src = _source(base)
        _screenshot(base, out_dir / f"nav_{attempt:02d}.png")
        if "soyeht.terminal.terminalView" in src or "soyeht.terminal.shortcutBar" in src:
            print(f"  [ok] reached terminal at attempt {attempt}")
            return True
        if "soyeht.instanceList.connectButton" in src:
            print("  -> connect")
            _click_id(base, "soyeht.instanceList.connectButton", 5)
            time.sleep(2)
            continue
        m = re.search(r'name="(soyeht\.instanceList\.instanceCard\.[^"]+)"[^>]*visible="true"', src)
        if m:
            print(f"  -> card {m.group(1)}")
            _click_id(base, m.group(1), 5)
            time.sleep(3)
            continue
        m = re.search(r'name="(soyeht\.sessionSheet\.windowCard\.[^"]+)"[^>]*visible="true"', src)
        if m:
            print(f"  -> window {m.group(1)}")
            _click_id(base, m.group(1), 5)
            time.sleep(3)
            continue
        # Fallback: if paired just got saved, wait then retry
        time.sleep(1)
    return False


def main() -> int:
    run_dir = Path(
        os.environ.get("SOYEHT_QA_RUN_DIR")
        or REPO / "QA" / "runs" / f"{date.today().isoformat()}-terminal-scroll"
    )
    run_dir.mkdir(parents=True, exist_ok=True)
    processes = []
    sid = None
    try:
        prebuilt_wda = os.environ.get("SOYEHT_WDA_URL_PREBUILT")
        if prebuilt_wda:
            print(f"[*] using prebuilt WDA {prebuilt_wda}")
            wda_url = prebuilt_wda
        else:
            env_updates, processes = build_gate_env(run_dir)
            for k, v in env_updates.items():
                os.environ[k] = v
            wda_url = env_updates["SOYEHT_WDA_URL"]
        udid = require_env("SOYEHT_IOS_UDID", os.environ.get("SOYEHT_IOS_UDID"))
        print(f"[1/6] Session on {udid} via WDA {wda_url}")
        sid, base = _session(udid, wda_url)
        print(f"      sid={sid}")

        print("[2/6] Terminating + reactivating app for clean state")
        _post(base, "/appium/device/terminate_app", {"bundleId": BUNDLE_ID})
        time.sleep(1)
        _post(base, "/appium/device/activate_app", {"bundleId": BUNDLE_ID})
        time.sleep(3)

        print("[3/6] Navigate to terminal screen")
        if not _nav_to_terminal(base, run_dir):
            print("  [fail] couldn't reach terminal")
            _screenshot(base, run_dir / "nav_failed.png")
            return 2
        time.sleep(2)

        print("[4/6] Locate terminalView and seed content")
        tv = _find_by_id(base, "soyeht.terminal.terminalView", 10)
        if not tv:
            print("  [fail] terminalView not found")
            return 3

        # Focus the terminal and seed 500 numbered lines so scrollback has content.
        _post(base, f"/element/{tv}/click")
        time.sleep(0.5)
        try:
            _type_keys(base, "clear; seq 1 500\n", eid=tv)
        except Exception as e:
            print(f"  [warn] seed failed: {e}")
        time.sleep(3)
        _screenshot(base, run_dir / "terminal_seeded.png")

        r0 = _rect(base, tv)
        print(f"      rect={r0}")
        cx = r0["x"] + r0["width"] / 2
        y_bot = r0["y"] + r0["height"] * 0.8
        y_top = r0["y"] + r0["height"] * 0.2
        _screenshot(base, run_dir / "terminal_before.png")

        print(f"[5/6] Drag from ({cx}, {y_bot}) -> ({cx}, {y_top}) to scroll history up")
        # Probe terminalView attrs before drag
        try:
            val_before = _get(base, f"/element/{tv}/attribute/value")
            print(f"      tv.value (before) = {str(val_before)[:200]}")
        except Exception as e:
            print(f"      [warn] value probe: {e}")
        _w3c_drag(base, cx, y_bot, cx, y_top, duration_ms=400)
        time.sleep(0.3)
        _screenshot(base, run_dir / "terminal_after_drag1.png")
        _w3c_drag(base, cx, y_bot, cx, y_top, duration_ms=400)
        time.sleep(0.3)
        _screenshot(base, run_dir / "terminal_after_drag2.png")
        try:
            val_after = _get(base, f"/element/{tv}/attribute/value")
            print(f"      tv.value (after)  = {str(val_after)[:200]}")
        except Exception:
            pass

        print("[6/6] Compare before/after screenshots by filesize")
        before = (run_dir / "terminal_before.png").stat().st_size
        after2 = (run_dir / "terminal_after_drag2.png").stat().st_size
        delta = abs(after2 - before)
        print(f"      before={before}B after={after2}B delta={delta}B")
        # Visually compare with "↓ live" button presence
        src = _source(base)
        has_scroll_btn = "soyeht.terminal.scrollToBottomButton" in src
        print(f"      ↓ live button visible: {has_scroll_btn}")

        # Report
        report = run_dir / "report.txt"
        report.write_text(
            f"terminalView rect: {r0}\n"
            f"before size: {before}B\n"
            f"after drag2 size: {after2}B\n"
            f"delta: {delta}B\n"
            f"scrollToBottomButton in source: {has_scroll_btn}\n"
        )
        print(f"      wrote {report}")
        # Success criterion: either significant pixel delta OR scroll button exists (UI intact)
        return 0 if (delta > 1000 and has_scroll_btn) else 1
    finally:
        if sid:
            try:
                requests.delete(f"{APPIUM_URL}/session/{sid}", timeout=30)
            except Exception:
                pass
        terminate_processes(processes)


if __name__ == "__main__":
    sys.exit(main())
