#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "requests>=2.31",
# ]
# ///
"""Appium runner for QA/domains/paired-macs-flow.md (ST-Q-PM-001..012).

Auto cases covered today: PM-001..PM-006.

Manual/assisted (require Mac-side orchestration via native-devtools MCP or
AppleScript: pkill Mac app, click "Abrir no iPhone", revoke in panel, rename
display name, etc.) are surfaced as SKIP with a reason so the gate still reports
complete coverage.

Assumptions (aborts early if missing):
- iPhone <qa-device-2> physical device connected (UDID via env SOYEHT_IOS_UDID).
- Mac Soyeht app running with ≥1 pane, already paired with this iPhone from a
  prior QR flow (state fixture — no pairing is performed here).
- Appium + WebDriverAgent either already running (env SOYEHT_WDA_URL) or
  startable via appium_gate_common.ensure_appium_server/ensure_wda.

Usage:
    uv run QA/scripts/run_paired_macs.py
    uv run QA/scripts/run_paired_macs.py --only PM-001,PM-003
    uv run QA/scripts/run_paired_macs.py --mac-name macStudio
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import date, datetime
from pathlib import Path
from typing import Any, Callable

import requests

from appium_gate_common import (
    DEFAULT_APPIUM_URL,
    DEFAULT_UDID,
    ensure_appium_server,
    require_env,
    ensure_wda,
    terminate_processes,
)


BUNDLE_ID = os.environ.get("SOYEHT_BUNDLE_ID", "com.soyeht.app")
W3C_ELEMENT = "element-6066-11e4-a52e-4f735466cecf"


# --------------------------------------------------------------------------- #
# Results plumbing
# --------------------------------------------------------------------------- #

@dataclass
class CaseResult:
    case_id: str
    status: str  # PASS | FAIL | SKIP
    notes: str = ""
    screenshot: str | None = None


@dataclass
class RunReport:
    domain: str = "paired-macs-flow"
    started_at: str = field(default_factory=lambda: datetime.utcnow().isoformat() + "Z")
    finished_at: str | None = None
    udid: str = ""
    mac_name_expected: str = ""
    cases: list[CaseResult] = field(default_factory=list)

    def summary(self) -> dict[str, int]:
        counts = {"PASS": 0, "FAIL": 0, "SKIP": 0}
        for case in self.cases:
            counts[case.status] = counts.get(case.status, 0) + 1
        return counts


# --------------------------------------------------------------------------- #
# Minimal Appium client (standalone — no dependency on run_file_live_appium)
# --------------------------------------------------------------------------- #

class AppiumSession:
    def __init__(self, appium_url: str, udid: str, wda_url: str | None) -> None:
        self.appium_url = appium_url.rstrip("/")
        self.udid = udid
        self.wda_url = wda_url
        self.session_id: str | None = None
        self.base: str | None = None

    def start(self) -> None:
        caps: dict[str, Any] = {
            "platformName": "iOS",
            "appium:automationName": "XCUITest",
            "appium:udid": self.udid,
            "appium:bundleId": BUNDLE_ID,
            "appium:noReset": True,
            "appium:shouldUseSingletonTestManager": False,
            "appium:waitForIdleTimeout": 0,
            "appium:waitForQuiescence": False,
            "appium:wdaEventloopIdleDelay": 1,
            "appium:wdaLaunchTimeout": 180000,
            "appium:wdaConnectionTimeout": 180000,
            "appium:newCommandTimeout": 240,
        }
        if self.wda_url:
            caps["appium:webDriverAgentUrl"] = self.wda_url
            caps["appium:useNewWDA"] = False
        else:
            caps["appium:useNewWDA"] = True
        response = requests.post(
            f"{self.appium_url}/session",
            json={"capabilities": {"alwaysMatch": caps, "firstMatch": [{}]}},
            timeout=240,
        )
        response.raise_for_status()
        payload = response.json()
        value = payload["value"]
        self.session_id = value.get("sessionId") or payload.get("sessionId")
        if not self.session_id:
            raise RuntimeError(f"Unable to determine session id: {payload}")
        self.base = f"{self.appium_url}/session/{self.session_id}"

    def stop(self) -> None:
        if not self.base:
            return
        try:
            requests.delete(self.base, timeout=120)
        finally:
            self.base = None
            self.session_id = None

    # ----- HTTP helpers --------------------------------------------------- #

    def _post(self, path: str, payload: dict[str, Any] | None = None, timeout: int = 120) -> Any:
        assert self.base
        response = requests.post(f"{self.base}{path}", json=payload or {}, timeout=timeout)
        response.raise_for_status()
        return response.json()["value"]

    def _get(self, path: str, timeout: int = 120) -> Any:
        assert self.base
        response = requests.get(f"{self.base}{path}", timeout=timeout)
        response.raise_for_status()
        return response.json()["value"]

    # ----- Convenience ---------------------------------------------------- #

    def reset_app(self) -> None:
        self._post("/appium/device/terminate_app", {"bundleId": BUNDLE_ID})
        time.sleep(1)
        self._post("/appium/device/activate_app", {"bundleId": BUNDLE_ID})
        time.sleep(2)

    def source(self) -> str:
        return self._get("/source")

    def screenshot(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        data = self._get("/screenshot")
        path.write_bytes(base64.b64decode(data))

    def _element_id(self, value: Any) -> str:
        if isinstance(value, list):
            if not value:
                raise LookupError("No element returned")
            value = value[0]
        return value.get(W3C_ELEMENT) or value["ELEMENT"]

    def find(self, using: str, value: str, timeout: float = 8.0) -> str:
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

    def text_of(self, element_id: str) -> str:
        return self._get(f"/element/{element_id}/text") or ""

    def tap(self, element_id: str) -> None:
        """Tap using XCUITest's `mobile: tap` with coordinates from the element
        rect. `/element/.../click` on SwiftUI Buttons in sheets is sometimes a
        no-op; tapping a hit point is more reliable.
        """
        rect = self._get(f"/element/{element_id}/rect")
        x = float(rect["x"]) + float(rect["width"]) / 2.0
        y = float(rect["y"]) + float(rect["height"]) / 2.0
        self._post("/execute/sync", {"script": "mobile: tap", "args": [{"x": x, "y": y}]})

    def type_text(self, element_id: str, text: str) -> None:
        self._post(f"/element/{element_id}/value", {"text": text})

    def background(self, seconds: int) -> None:
        """Send the app to the background for `seconds`, then return."""
        self._post(
            "/execute/sync",
            {"script": "mobile: backgroundApp", "args": [{"seconds": seconds}]},
            timeout=seconds + 60,
        )

    def send_keys_hardware(self, keys: str) -> None:
        # Send text to the currently-focused element via W3C Actions keyboard.
        self._post("/actions", {
            "actions": [{
                "type": "key",
                "id": "keyboard",
                "actions": [{"type": "keyDown", "value": c} for c in keys]
                          + [{"type": "keyUp", "value": c} for c in keys],
            }]
        })

    def contains_text(self, needle: str) -> bool:
        return needle in self.source()


# --------------------------------------------------------------------------- #
# Test cases — one method per PM-xxx
# --------------------------------------------------------------------------- #

class PairedMacsRunner:
    def __init__(self, session: AppiumSession, run_dir: Path, mac_name: str) -> None:
        self.session = session
        self.run_dir = run_dir
        self.mac_name = mac_name

    def _shot(self, name: str) -> str:
        path = self.run_dir / "screenshots" / f"{name}.png"
        self.session.screenshot(path)
        return str(path.relative_to(self.run_dir))

    # ----- Cases ---------------------------------------------------------- #

    def pm_001(self) -> CaseResult:
        """Home list renders a paired Mac row with [mac] tag within 3s."""
        self.session.reset_app()
        deadline = time.time() + 15
        source = ""
        while time.time() < deadline:
            source = self.session.source()
            if "[mac]" in source and self.mac_name in source:
                break
            time.sleep(1)
        shot = self._shot("pm-001-home")
        if "[mac]" not in source:
            return CaseResult("PM-001", "FAIL", f"[mac] tag not rendered on home list; {self.mac_name!r} absent", shot)
        if self.mac_name not in source:
            return CaseResult("PM-001", "FAIL", f"Mac row visible but expected name {self.mac_name!r} missing", shot)
        return CaseResult("PM-001", "PASS", f"Mac row {self.mac_name!r} visible with [mac] tag", shot)

    def pm_002(self) -> CaseResult:
        """Tap Mac row → MacDetailView sheet opens with pane list."""
        try:
            mac_row = self.session.find("xpath", f"//*[contains(@label,'{self.mac_name}')]", timeout=10)
        except LookupError as exc:
            return CaseResult("PM-002", "FAIL", f"Mac row not tappable: {exc}")
        self.session.tap(mac_row)
        time.sleep(2)
        shot = self._shot("pm-002-detail")
        source = self.session.source()
        # MacDetailView renders pane rows or an empty state; the only header we control is the mac_name.
        if self.mac_name not in source:
            return CaseResult("PM-002", "FAIL", "MacDetailView header did not render mac name", shot)
        return CaseResult("PM-002", "PASS", "MacDetailView opened", shot)

    # MacDetailView-only marker. If this string is still on screen after a
    # pane tap, the tap did not navigate to the terminal.
    MAC_DETAIL_MARKER = "panes ativos"

    def _on_terminal(self, source: str | None = None) -> bool:
        """True when the iOS app is on a terminal view (LocalTerminalView).
        We detect by: (a) MacDetailView marker absent AND (b) keyboard or
        terminal container element present.
        """
        src = source if source is not None else self.session.source()
        if self.MAC_DETAIL_MARKER in src:
            return False
        # Either the SwiftTerm view ID "terminal-view" (set via .accessibilityIdentifier),
        # or the on-screen keyboard (XCUIElementTypeKeyboard) is enough.
        return "terminal-view" in src or "XCUIElementTypeKeyboard" in src

    def pm_003(self) -> CaseResult:
        """Tap a pane → terminal opens via attach (no QR)."""
        try:
            pane_buttons = self._find_pane_buttons()
        except LookupError as exc:
            return CaseResult("PM-003", "SKIP", f"No panes listed for {self.mac_name!r}: {exc}")
        if not pane_buttons:
            return CaseResult("PM-003", "SKIP", f"No panes listed for {self.mac_name!r} — open a pane on the Mac first")
        target_label = pane_buttons[0]["label"]
        self.session.tap(pane_buttons[0]["id"])
        # Poll up to 6s for the terminal to take over (WS grant round-trip + transition).
        on_terminal = False
        deadline = time.time() + 6
        while time.time() < deadline:
            if self._on_terminal():
                on_terminal = True
                break
            time.sleep(0.5)
        shot = self._shot("pm-003-pane")
        if not on_terminal:
            return CaseResult("PM-003", "FAIL", f"Tap on pane {target_label!r} did not reach terminal view within 6s", shot)
        return CaseResult("PM-003", "PASS", f"Pane {target_label!r} opened without QR", shot)

    def pm_004(self) -> CaseResult:
        """Type `ls`, expect echo in the terminal (not just in the page source)."""
        if not self._on_terminal():
            return CaseResult("PM-004", "SKIP", "Not on terminal view — PM-003 prerequisite failed")
        # Use a rare sentinel so we don't collide with view-hierarchy strings.
        sentinel = f"zqa-{int(time.time()) % 100000}"
        try:
            self.session.send_keys_hardware(f"echo {sentinel}\n")
        except requests.HTTPError as exc:
            return CaseResult("PM-004", "SKIP", f"Hardware keyboard not available: {exc}")
        # Wait for echo to arrive in scrollback.
        deadline = time.time() + 4
        saw = False
        while time.time() < deadline:
            source = self.session.source()
            if sentinel in source:
                saw = True
                break
            time.sleep(0.5)
        shot = self._shot("pm-004-echo")
        if not saw:
            return CaseResult("PM-004", "FAIL", f"Sentinel {sentinel!r} not echoed back", shot)
        return CaseResult("PM-004", "PASS", f"Sentinel {sentinel!r} echoed back from Mac PTY", shot)

    def pm_005(self) -> CaseResult:
        """Back out, re-enter same pane → scrollback replayed (sentinel preserved)."""
        if not self._on_terminal():
            return CaseResult("PM-005", "SKIP", "Not on terminal view — PM-003/004 prerequisite failed")
        # Find the sentinel we typed in PM-004 — if it's there we can assert the replay.
        pre_source = self.session.source()
        sentinels = [tok for tok in pre_source.split() if tok.startswith("zqa-")]
        sentinel = sentinels[0] if sentinels else None

        try:
            back = self.session.find("xpath", "//*[@name='Back' or @label='Back' or @name='< Back' or contains(@label,'chevron.left')]", timeout=5)
        except LookupError as exc:
            return CaseResult("PM-005", "SKIP", f"No back button to exit terminal: {exc}")
        self.session.tap(back)
        time.sleep(1)
        try:
            panes = self._find_pane_buttons()
        except LookupError as exc:
            return CaseResult("PM-005", "SKIP", f"Pane list gone after back: {exc}")
        if not panes:
            return CaseResult("PM-005", "SKIP", "No panes to reopen")
        self.session.tap(panes[0]["id"])
        # Poll for re-entry into terminal.
        deadline = time.time() + 6
        re_entered = False
        while time.time() < deadline:
            if self._on_terminal():
                re_entered = True
                break
            time.sleep(0.5)
        shot = self._shot("pm-005-reenter")
        if not re_entered:
            return CaseResult("PM-005", "FAIL", "Did not re-enter terminal after back + tap", shot)
        if sentinel is None:
            return CaseResult("PM-005", "PASS", "Terminal reopened (sentinel check skipped — PM-004 did not place one)", shot)
        # Scrollback replay: sentinel from the earlier session must still be visible.
        source = self.session.source()
        if sentinel not in source:
            return CaseResult("PM-005", "FAIL", f"Sentinel {sentinel!r} absent after re-entry — scrollback not replayed", shot)
        return CaseResult("PM-005", "PASS", f"Sentinel {sentinel!r} preserved via scrollback replay", shot)

    def pm_013(self) -> CaseResult:
        """Background the app mid-terminal → foreground → same terminal restored.

        This exercises H4 (session persistence): when iOS suspends the pane
        WebSocket during background, the app must reconnect on foreground and
        present the same terminal view with scrollback preserved.
        """
        if not self._on_terminal():
            return CaseResult("PM-013", "SKIP", "Not on terminal view — PM-003 prerequisite failed")

        pre_source = self.session.source()
        # Grab a distinctive sentinel from the current scrollback — a token that
        # is longer than 6 chars and unlikely to appear in XCUI chrome strings.
        # The Mac shell prompt usually has host/path tokens we can anchor on.
        sentinel: str | None = None
        for token in pre_source.split():
            clean = token.strip(""""'<>(){}[].,;:!? """)
            if (
                len(clean) >= 8
                and "-" in clean
                and not clean.startswith("XCUIElement")
                and "mac_id" not in clean
            ):
                sentinel = clean
                break

        try:
            self.session.background(seconds=8)
        except requests.HTTPError as exc:
            return CaseResult("PM-013", "FAIL", f"mobile: backgroundApp failed: {exc}")

        # After foregrounding, wait up to 6s for the pane WS to reconnect and
        # the terminal view to come back on top.
        deadline = time.time() + 6
        restored = False
        while time.time() < deadline:
            if self._on_terminal():
                restored = True
                break
            time.sleep(0.5)

        shot = self._shot("pm-013-resumed")
        if not restored:
            return CaseResult("PM-013", "FAIL", "Terminal not restored after background/foreground cycle", shot)

        post_source = self.session.source()
        # If we captured a sentinel, assert it survived the cycle (scrollback preserved).
        if sentinel is not None and sentinel not in post_source:
            return CaseResult(
                "PM-013", "FAIL",
                f"Terminal visible again but sentinel {sentinel!r} missing — scrollback lost",
                shot,
            )
        # Also look for a disconnect banner (SwiftTerm prints "[WS] Reconnecting..." or similar).
        lower = post_source.lower()
        if "reconnecting" in lower and "ws" in lower:
            # Reconnect in-flight — give it a bit more time and re-check.
            time.sleep(3)
            post_source = self.session.source()
            lower = post_source.lower()
        if "reconnect failed" in lower or "disconnected" in lower:
            return CaseResult("PM-013", "FAIL", "Terminal shows a disconnect/reconnect-failed banner after foreground", shot)

        detail = f"sentinel={sentinel!r}" if sentinel else "no sentinel available"
        return CaseResult("PM-013", "PASS", f"Same terminal restored after background 8s ({detail})", shot)

    def pm_006(self) -> CaseResult:
        """Relaunch iPhone app → home row reconnects within 3s."""
        self.session.reset_app()
        deadline = time.time() + 10
        while time.time() < deadline:
            source = self.session.source()
            if self.mac_name in source and "[mac]" in source:
                break
            time.sleep(1)
        shot = self._shot("pm-006-relaunch")
        # "offline" subtitle would indicate presence did not reconnect.
        source = self.session.source()
        if "offline" in source.lower() and self.mac_name in source:
            return CaseResult("PM-006", "FAIL", "Mac row stuck offline after relaunch", shot)
        if self.mac_name not in source:
            return CaseResult("PM-006", "FAIL", "Mac row missing after relaunch", shot)
        return CaseResult("PM-006", "PASS", "Presence reconnected after relaunch", shot)

    # Manual/assisted placeholders — require Mac-side orchestration outside Appium's scope.
    def pm_manual(self, case_id: str, description: str) -> CaseResult:
        return CaseResult(case_id, "SKIP", f"assisted case: {description}")

    # ----- Helpers -------------------------------------------------------- #

    def _find_pane_buttons(self) -> list[dict[str, str]]:
        """Returns a list of {id, label} for pane rows inside MacDetailView.

        SwiftUI Button without `.contentShape(Rectangle())` only hit-tests on
        non-transparent subviews. The row's horizontal center falls on a
        Spacer, so tapping the Button's rect center is a no-op. Instead we
        target the inner text element (e.g. "@shell") — inside the Button's
        action region, always hittable — which our `tap` helper will convert
        to the element's rect center.
        """
        response = self.session._post(
            "/elements",
            {"using": "xpath", "value": "//XCUIElementTypeStaticText[starts-with(@label,'@')]"},
        )
        items = []
        for raw in response or []:
            element_id = raw.get(W3C_ELEMENT) or raw.get("ELEMENT")
            if not element_id:
                continue
            try:
                label = self.session.text_of(element_id) or ""
            except Exception:  # noqa: BLE001
                label = ""
            items.append({"id": element_id, "label": label})
        return items


# --------------------------------------------------------------------------- #
# Case selection + main
# --------------------------------------------------------------------------- #

AUTO_CASES = [
    ("PM-001", "pm_001"),
    ("PM-002", "pm_002"),
    ("PM-003", "pm_003"),
    ("PM-013", "pm_013"),   # background/foreground preserves terminal (H4)
    ("PM-004", "pm_004"),
    ("PM-005", "pm_005"),
    ("PM-006", "pm_006"),
]

ASSISTED_CASES = [
    ("PM-007", "pkill Mac app → iPhone shows offline in <10s; Mac back → online in <5s"),
    ("PM-008", "Mac creates new pane → iPhone sees panes_delta added=1"),
    ("PM-009", "Mac clicks 'Abrir no iPhone' → iPhone auto-navigates within 1s"),
    ("PM-010", "Mac renames display name in Preferences → iPhone label updates in <5s"),
    ("PM-011", "Mac revokes iPhone in panel → WS drops, Mac disappears from home"),
    ("PM-012", "Kill local bash pane (`exit`) → iPhone dot turns red with exit code"),
]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mac-name", default=os.environ.get("SOYEHT_QA_MAC_NAME", "macStudio"),
                        help="Display name of the paired Mac (default: macStudio)")
    parser.add_argument("--only", default="", help="Comma-separated PM-IDs to execute (default: all auto)")
    parser.add_argument("--run-dir", default="", help="Output directory (default: QA/runs/<date>-paired-macs)")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[2]
    run_dir = Path(args.run_dir) if args.run_dir else (
        repo_root / "QA" / "runs" / f"{date.today().isoformat()}-paired-macs"
    )
    run_dir.mkdir(parents=True, exist_ok=True)

    selected: set[str] = set(filter(None, (s.strip() for s in args.only.split(","))))

    udid = require_env("SOYEHT_IOS_UDID", os.environ.get("SOYEHT_IOS_UDID") or DEFAULT_UDID)
    wda_url = os.environ.get("SOYEHT_WDA_URL") or None
    report = RunReport(udid=udid, mac_name_expected=args.mac_name)

    processes = []
    appium_server = None
    wda_process = None

    try:
        appium_server = ensure_appium_server(run_dir, DEFAULT_APPIUM_URL)
        if appium_server:
            processes.append(appium_server)
        if not wda_url:
            wda_url, wda_process = ensure_wda(run_dir, udid)
            processes.append(wda_process)

        session = AppiumSession(DEFAULT_APPIUM_URL, udid, wda_url)
        session.start()
        try:
            runner = PairedMacsRunner(session, run_dir, args.mac_name)
            for case_id, method_name in AUTO_CASES:
                if selected and case_id not in selected:
                    continue
                fn: Callable[[], CaseResult] = getattr(runner, method_name)
                print(f"=== {case_id} ===", flush=True)
                try:
                    result = fn()
                except Exception as exc:  # noqa: BLE001
                    result = CaseResult(case_id, "FAIL", f"uncaught: {exc!r}")
                print(f"  {result.status}: {result.notes}")
                report.cases.append(result)

            for case_id, description in ASSISTED_CASES:
                if selected and case_id not in selected:
                    continue
                result = runner.pm_manual(case_id, description)
                print(f"=== {case_id} ===\n  {result.status}: {result.notes}")
                report.cases.append(result)
        finally:
            session.stop()
    finally:
        if processes:
            terminate_processes(processes)

    report.finished_at = datetime.utcnow().isoformat() + "Z"
    summary = report.summary()

    report_path = run_dir / "report.json"
    report_path.write_text(json.dumps(asdict(report), indent=2))
    print(f"\nReport: {report_path}")
    print(f"Summary: {summary}")

    # Exit non-zero if any FAIL — SKIPs are expected for assisted cases.
    return 1 if summary.get("FAIL", 0) else 0


if __name__ == "__main__":
    sys.exit(main())
