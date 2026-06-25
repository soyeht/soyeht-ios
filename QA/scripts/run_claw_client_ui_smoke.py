#!/usr/bin/env python3
"""Non-destructive iOS Claw Store UI smoke for the Dev app.

This script is intentionally opt-in. Without SOYEHT_F3_RUN_LIVE=1 and
SOYEHT_F3_RUN_CLIENT_UI=1 it writes a SKIP report and exits before Appium,
WebDriverAgent, or the app process are touched.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any

import requests

from appium_gate_common import DEFAULT_APPIUM_URL, build_gate_env, terminate_processes
from env_loader import load_repo_env


LIVE_ENV = "SOYEHT_F3_RUN_LIVE"
CLIENT_UI_ENV = "SOYEHT_F3_RUN_CLIENT_UI"
RAW_ARTIFACTS_ENV = "SOYEHT_F3_SAVE_RAW_UI_ARTIFACTS"
BUILD_INSTALL_ENV = "SOYEHT_F3_CLIENT_UI_BUILD_INSTALL"
DEFAULT_BUNDLE_ID = "com.soyeht.app.dev"
SHIPPING_BUNDLE_ID = "com.soyeht.app"
UI_TEST_LAUNCH_ARGUMENT = "-SoyehtUITest"
E2E_LAUNCH_ARGUMENT = "-SoyehtClawStoreE2E"
RELAY_FFI_PATH = Path("Native/RelayStreamGuestFFI/RelayStreamGuestFFI.xcframework")
RELAY_FFI_LEGACY_PATH = Path("Native/RelayStreamGuestFFI/RelayStreamGuestFFIBinary.xcframework")
W3C_ELEMENT = "element-6066-11e4-a52e-4f735466cecf"


@dataclass
class SmokeResult:
    case_id: str
    status: str
    notes: str
    artifacts: list[str] = field(default_factory=list)


class Redactor:
    def __init__(self, repo_root: Path) -> None:
        env_keys = [
            "APPIUM_URL",
            "QA_BASE_URL",
            "SOYEHT_BASE_URL",
            "SOYEHT_F3_BASE_URL",
            "SOYEHT_IOS_UDID",
            "SOYEHT_TOKEN",
            "TOKEN",
            "SOYEHT_SSH_HOST",
            "SOYEHT_WDA_URL",
        ]
        replacements = [(str(repo_root), "<soyeht-ios>")]
        for key in env_keys:
            value = os.environ.get(key, "")
            if value:
                replacements.append((value, f"<{key.lower()}-redacted>"))
        self.replacements = replacements

    def text(self, value: str) -> str:
        redacted = value
        for old, new in self.replacements:
            redacted = redacted.replace(old, new)
        patterns = [
            (r"Bearer\s+[A-Za-z0-9._~+/=-]+", "Bearer <redacted>"),
            (r"(?i)(token|secret|password|authorization)(=|:)\s*[^,\s\"']+", r"\1\2 <redacted>"),
            (r"https?://[^\s\"')>]+", "<url-redacted>"),
            (r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "192.0.2.10"),
            (r"/Users/[^/\s]+", "/Users/<user>"),
        ]
        for pattern, replacement in patterns:
            redacted = re.sub(pattern, replacement, redacted)
        return redacted

    def xml(self, value: str) -> str:
        redacted = self.text(value)
        redacted = re.sub(
            r"(soyeht\.clawStore\.serverPickerRow\.)[^\"<\s]+",
            r"\1<server-id>",
            redacted,
        )
        redacted = re.sub(
            r"(soyeht\.instanceList\.macCard\.)[^\"<\s]+",
            r"\1<server-id>",
            redacted,
        )

        def redact_user_text(match: re.Match[str]) -> str:
            attr = match.group(1)
            value = match.group(2)
            if value.startswith("soyeht."):
                return f'{attr}="{value}"'
            return f'{attr}="<redacted-text>"'

        return re.sub(r'\b(name|label|value)="([^"]*)"', redact_user_text, redacted)


class AppiumSession:
    def __init__(self, bundle_id: str, appium_url: str = DEFAULT_APPIUM_URL) -> None:
        self.bundle_id = bundle_id
        self.appium_url = appium_url.rstrip("/")
        self.session_id: str | None = None
        self.base: str | None = None

    def start(self) -> None:
        wda_url = os.environ.get("SOYEHT_WDA_URL", "").strip()
        caps: dict[str, Any] = {
            "platformName": "iOS",
            "appium:automationName": "XCUITest",
            "appium:udid": os.environ.get("SOYEHT_IOS_UDID", "").strip(),
            "appium:bundleId": self.bundle_id,
            "appium:processArguments": {
                "args": [UI_TEST_LAUNCH_ARGUMENT, E2E_LAUNCH_ARGUMENT],
                "env": {"SOYEHT_UI_TEST": "1"},
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
        if wda_url:
            caps["appium:webDriverAgentUrl"] = wda_url
            caps["appium:useNewWDA"] = False
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
            raise RuntimeError("Appium session response did not include a session id")
        self.base = f"{self.appium_url}/session/{self.session_id}"

    def stop(self) -> None:
        if not self.base:
            return
        try:
            requests.delete(self.base, timeout=120)
        finally:
            self.base = None
            self.session_id = None

    def post(self, path: str, payload: dict[str, Any] | None = None, timeout: int = 120) -> Any:
        assert self.base
        response = requests.post(f"{self.base}{path}", json=payload or {}, timeout=timeout)
        response.raise_for_status()
        return response.json()["value"]

    def get_text(self, path: str, timeout: int = 120) -> str:
        assert self.base
        response = requests.get(f"{self.base}{path}", timeout=timeout)
        response.raise_for_status()
        return response.json()["value"]

    def source(self) -> str:
        return self.get_text("/source")

    def screenshot(self) -> bytes:
        return base64.b64decode(self.get_text("/screenshot"))

    def element_id(self, value: Any) -> str:
        if isinstance(value, list):
            if not value:
                raise LookupError("No element returned")
            value = value[0]
        if W3C_ELEMENT in value:
            return value[W3C_ELEMENT]
        return value["ELEMENT"]

    def find(self, using: str, value: str, timeout: float = 8.0) -> str:
        deadline = time.time() + timeout
        last_error: Exception | None = None
        while time.time() < deadline:
            try:
                payload = self.post("/element", {"using": using, "value": value})
                return self.element_id(payload)
            except Exception as error:  # noqa: BLE001
                last_error = error
                time.sleep(0.5)
        raise LookupError(f"Unable to find {using}={value}: {last_error}")

    def click_id(self, accessibility_id: str, timeout: float = 8.0) -> None:
        self.post(f"/element/{self.find('accessibility id', accessibility_id, timeout=timeout)}/click")

    def back(self) -> None:
        self.post("/back")


class SmokeRunner:
    def __init__(self, run_dir: Path, repo_root: Path, bundle_id: str) -> None:
        self.run_dir = run_dir
        self.repo_root = repo_root
        self.bundle_id = bundle_id
        self.redactor = Redactor(repo_root)
        self.results: list[SmokeResult] = []
        self.raw_artifacts = os.environ.get(RAW_ARTIFACTS_ENV) == "1"
        self.app = AppiumSession(bundle_id)

    def record(self, case_id: str, status: str, notes: str, artifacts: list[str] | None = None) -> None:
        self.results.append(SmokeResult(case_id, status, self.redactor.text(notes), artifacts or []))
        print(f"{case_id} {status} {self.redactor.text(notes)}", flush=True)

    def save_source_artifact(self, label: str) -> list[str]:
        artifacts: list[str] = []
        self.run_dir.mkdir(parents=True, exist_ok=True)
        source = self.app.source()
        redacted_path = self.run_dir / f"{label}.redacted.xml"
        redacted_path.write_text(self.redactor.xml(source), encoding="utf-8")
        artifacts.append(redacted_path.name)
        if self.raw_artifacts:
            raw_path = self.run_dir / f"{label}.raw.xml"
            raw_path.write_text(source, encoding="utf-8")
            artifacts.append(raw_path.name)
            screenshot_path = self.run_dir / f"{label}.raw.png"
            screenshot_path.write_bytes(self.app.screenshot())
            artifacts.append(screenshot_path.name)
        return artifacts

    def wait_for_any(self, tokens: list[str], timeout: float = 20.0) -> tuple[str, str]:
        deadline = time.time() + timeout
        last_source = ""
        while time.time() < deadline:
            last_source = self.app.source()
            for token in tokens:
                if token in last_source:
                    return token, last_source
            time.sleep(0.75)
        raise LookupError(f"Timed out waiting for one of: {', '.join(tokens)}")

    def visible_ids(self, source: str, prefix: str) -> list[str]:
        ids: list[str] = []
        for match in re.finditer(r'\b(?:name|label|value)="([^"]+)"', source):
            identifier = match.group(1)
            if identifier.startswith(prefix) and identifier not in ids:
                ids.append(identifier)
        return ids

    def run(self) -> int:
        self.app.start()
        try:
            self.app.click_id("soyeht.instanceList.clawStoreButton", timeout=30)
            token, source = self.wait_for_any([
                "soyeht.clawStore.serverPickerList",
                "soyeht.clawStore.loadingState",
                "soyeht.clawStore.clawCard.",
                "soyeht.clawStore.guestImageGate",
                "soyeht.clawStore.macUnavailableState",
                "soyeht.clawStore.errorState",
            ])
            if token == "soyeht.clawStore.serverPickerList":
                rows = self.visible_ids(source, "soyeht.clawStore.serverPickerRow.")
                if not rows:
                    self.record(
                        "ST-Q-CLAW-001",
                        "FAIL",
                        "Server picker opened but no selectable rows were exposed.",
                        self.save_source_artifact("server-picker-empty"),
                    )
                    return 1
                self.app.click_id(rows[0], timeout=8)
                token, source = self.wait_for_any([
                    "soyeht.clawStore.loadingState",
                    "soyeht.clawStore.clawCard.",
                    "soyeht.clawStore.guestImageGate",
                    "soyeht.clawStore.macUnavailableState",
                    "soyeht.clawStore.errorState",
                ])
                self.record("ST-Q-CLAW-001", "PASS", "Claw Store route reached through server picker.")
            else:
                self.record("ST-Q-CLAW-001", "PASS", "Claw Store route reached directly from the Dev app home.")

            _, source = self.wait_for_any([
                "soyeht.clawStore.clawCard.",
                "soyeht.clawStore.guestImageGate",
                "soyeht.clawStore.macUnavailableState",
                "soyeht.clawStore.errorState",
            ], timeout=30)
            store_has_gate = "soyeht.clawStore.guestImageGate" in source
            store_unavailable = "soyeht.clawStore.macUnavailableState" in source
            cards = self.visible_ids(source, "soyeht.clawStore.clawCard.")
            cards = [card for card in cards if ".progress" not in card and ".unavailable" not in card]
            if store_unavailable and not cards:
                self.record(
                    "ST-Q-CLAW-003",
                    "SKIP",
                    "Target route is explicitly unavailable; no card can be opened non-destructively.",
                    self.save_source_artifact("store-unavailable"),
                )
                return 0
            if not cards:
                self.record(
                    "ST-Q-CLAW-002",
                    "FAIL",
                    "Store opened but no claw card was exposed for the detail smoke.",
                    self.save_source_artifact("store-no-card"),
                )
                return 1
            self.record(
                "ST-Q-CLAW-002",
                "PASS",
                "Store rendered at least one claw card; readiness gate visible: "
                + ("yes" if store_has_gate else "no"),
            )

            self.app.click_id(cards[0], timeout=8)
            _, detail_source = self.wait_for_any([
                "soyeht.clawDetail.statusLabel",
                "soyeht.clawDetail.guestImageGate",
                "soyeht.clawDetail.unavailableCard",
            ], timeout=20)

            has_status = "soyeht.clawDetail.statusLabel" in detail_source
            action_ids = [
                "soyeht.clawDetail.deployButton",
                "soyeht.clawDetail.installButton",
                "soyeht.clawDetail.uninstallButton",
            ]
            has_action = any(identifier in detail_source for identifier in action_ids)
            has_gate = "soyeht.clawDetail.guestImageGate" in detail_source
            has_unavailable = "soyeht.clawDetail.unavailableCard" in detail_source
            categories = [has_action, has_gate, has_unavailable]
            if not has_status or sum(1 for value in categories if value) != 1:
                self.record(
                    "ST-Q-CLAW-003",
                    "FAIL",
                    "Detail did not expose status plus exactly one action/gate/unavailable category.",
                    self.save_source_artifact("detail-invalid-category"),
                )
                return 1
            if has_gate:
                detail_notes = "Detail rendered readiness gate path."
            elif has_unavailable:
                detail_notes = "Detail rendered unavailable path."
            else:
                detail_notes = "Detail rendered non-destructive action path."
            self.record(
                "ST-Q-CLAW-003",
                "PASS",
                detail_notes,
                self.save_source_artifact("detail-final"),
            )
            return 0
        finally:
            self.app.stop()

    def write_report(self, started_at: str, finished_at: str, top_status: str | None = None) -> None:
        self.run_dir.mkdir(parents=True, exist_ok=True)
        counts = {"PASS": 0, "FAIL": 0, "SKIP": 0}
        for result in self.results:
            counts[result.status] = counts.get(result.status, 0) + 1
        if not self.results and top_status:
            counts[top_status] = counts.get(top_status, 0) + 1

        payload = {
            "suite": "claw-client-ui-smoke",
            "started_at": started_at,
            "finished_at": finished_at,
            "bundle": DEFAULT_BUNDLE_ID,
            "summary": counts,
            "raw_ui_artifacts": self.raw_artifacts,
            "results": [asdict(result) for result in self.results],
        }
        (self.run_dir / "report.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        lines = [
            "# Claw Client UI Smoke",
            "",
            f"- Started: {started_at}",
            f"- Finished: {finished_at}",
            f"- App: {DEFAULT_BUNDLE_ID}",
            "- Device: device-alpha",
            "- Backend: backend-alpha",
            f"- Raw UI artifacts: {'enabled' if self.raw_artifacts else 'disabled'}",
            "",
            "Raw XML/screenshots may contain local device or server data and are disabled by default.",
            "",
            "| Case | Status | Notes | Artifacts |",
            "|------|--------|-------|-----------|",
        ]
        if self.results:
            for result in self.results:
                artifacts = ", ".join(f"`{item}`" for item in result.artifacts) if result.artifacts else ""
                lines.append(f"| {result.case_id} | {result.status} | {result.notes} | {artifacts} |")
        else:
            lines.append(f"| client-ui-ios-dev-smoke | {top_status or 'SKIP'} | No smoke steps executed. | |")
        lines.append("")
        (self.run_dir / "report.md").write_text("\n".join(lines), encoding="utf-8")


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the non-destructive iOS Claw Store Dev app smoke.")
    parser.add_argument("--output-dir", help="Report directory. Defaults to QA/runs/<date>-claw-client-ui-smoke.")
    return parser.parse_args()


def relay_framework_present(repo_root: Path) -> bool:
    return (repo_root / RELAY_FFI_PATH).is_dir() or (repo_root / RELAY_FFI_LEGACY_PATH).is_dir()


def write_top_level_report(run_dir: Path, repo_root: Path, status: str, reason: str) -> None:
    runner = SmokeRunner(run_dir, repo_root, DEFAULT_BUNDLE_ID)
    runner.record("client-ui-ios-dev-smoke", status, reason)
    now = utc_now()
    runner.write_report(now, now, top_status=status)


def main() -> int:
    load_repo_env()
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[2]
    run_dir = Path(args.output_dir).expanduser() if args.output_dir else repo_root / "QA" / "runs" / f"{date.today().isoformat()}-claw-client-ui-smoke"
    if not run_dir.is_absolute():
        run_dir = repo_root / run_dir

    if os.environ.get(LIVE_ENV) != "1" or os.environ.get(CLIENT_UI_ENV) != "1":
        write_top_level_report(
            run_dir,
            repo_root,
            "SKIP",
            f"default SKIP; set {LIVE_ENV}=1 and {CLIENT_UI_ENV}=1 to run the Dev app UI smoke",
        )
        print(f"Report: {run_dir / 'report.md'}")
        return 0

    bundle_id = os.environ.get("SOYEHT_BUNDLE_ID", DEFAULT_BUNDLE_ID).strip() or DEFAULT_BUNDLE_ID
    if bundle_id == SHIPPING_BUNDLE_ID:
        write_top_level_report(
            run_dir,
            repo_root,
            "FAIL",
            "refused shipping iOS bundle; use com.soyeht.app.dev for this smoke",
        )
        print(f"Report: {run_dir / 'report.md'}")
        return 1
    if bundle_id != DEFAULT_BUNDLE_ID:
        write_top_level_report(
            run_dir,
            repo_root,
            "FAIL",
            "unsupported bundle for this smoke; use com.soyeht.app.dev",
        )
        print(f"Report: {run_dir / 'report.md'}")
        return 1

    if os.environ.get(BUILD_INSTALL_ENV) == "1" and not relay_framework_present(repo_root):
        write_top_level_report(
            run_dir,
            repo_root,
            "SKIP",
            "relay_stream_guest_ffi_missing; run scripts/bootstrap-relay-stream-guest-ffi.sh before any Xcode build/install path",
        )
        print(f"Report: {run_dir / 'report.md'}")
        return 0

    started_at = utc_now()
    processes = []
    runner = SmokeRunner(run_dir, repo_root, bundle_id)
    try:
        env_updates, processes = build_gate_env(run_dir)
        os.environ.update(env_updates)
        exit_code = runner.run()
        return exit_code
    except Exception as error:  # noqa: BLE001
        runner.record("client-ui-ios-dev-smoke", "FAIL", f"smoke failed: {error}")
        return 1
    finally:
        terminate_processes(processes)
        runner.write_report(started_at, utc_now())
        print(f"Report: {run_dir / 'report.md'}")


if __name__ == "__main__":
    sys.exit(main())
