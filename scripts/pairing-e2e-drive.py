#!/usr/bin/env python3
"""Drives one pairing run on the Dev pair, with nobody touching anything.

DELIBERATELY SEPARATE FROM THE PROBE. This file ACTS; `pairing-e2e-probe.py`
JUDGES. A driver that also judged could bias its own verdict — it would only
have to declare success when it managed to press the button. The two halves
share no state: the probe reads the system's logs, not what this script
believed happened.

WHY THIS HAS TO EXIST

Without a driver, "validate on the device" means the owner repeating taps by
hand. That is how the seven runs of 2026-09-05 produced no diagnosis: each was
slightly different, none was repeatable, and the negative control never
happened at all. A scenario you cannot repeat cannot separate a fix from a
coincidence.

WHAT IT DRIVES

  Test iPhone   through WebDriverAgent over HTTP (an `iproxy` tunnel), using
                the app's real accessibility ids — `soyeht.onboarding.*`.
  Soyeht Dev    through the macOS accessibility API, opening Add iPhone.

SAFETY

  - Only the dedicated test iPhone, named by SOYEHT_E2E_IPHONE_UDID. Any other
    device is refused, the owner's personal phone included: that one is in real
    daily use and is not a lab animal.
  - Only `Soyeht Dev`. It refuses to drive the production app.
  - It never invokes "Leave this household" on production, and never erases a
    household it did not create during this run.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

# The test device, from the environment rather than the file: this repository
# is public and a UDID is hardware identity tied to someone's account. The
# guard stays whole — with no value set, the script does not run.
UDID_ENV = "SOYEHT_E2E_IPHONE_UDID"
TEST_IPHONE_UDID = os.environ.get(UDID_ENV, "")

DEV_APP_PROCESS = "Soyeht Dev"
PROD_APP_PROCESS = "Soyeht"
DEV_BUNDLE_ID = "com.soyeht.app.dev"

# The ids the app actually publishes today (`AwaitingMacView.swift`).
ID_LOOKING = "soyeht.onboarding.looking.status"
ID_CARD = "soyeht.onboarding.isThisYourMac.card"
ID_CONFIRM = "soyeht.onboarding.isThisYourMac.confirm"
ID_REJECT = "soyeht.onboarding.isThisYourMac.reject"
ID_KEEP_LOOKING = "soyeht.onboarding.notFound.keepLooking"
# The words the phone shows while it waits for an owner to approve it. They are
# derived from request_id + d_pub through one shared type in SoyehtCore, so the
# approving Mac must show the SAME six. Reading them here is the only way an
# automated run can tell "both ends agree" from "both ends show six words".
ID_APPROVAL_WORDS = "soyeht.onboarding.approval.requestWords"

# Leaving the household is how a phone returns to the state where it publishes
# a setup invitation again. Without it a phone that already belongs to a home
# simply never advertises, the Mac logs `candidates count=0` forever, and a
# scenario called "from scratch" measures a phone that was never from scratch.
# Measured 2026-09-05: that is exactly what the first real rehearsal did.
LEAVE_HOUSEHOLD_LABEL = "Leave this household"
LEAVE_CONFIRM_LABEL = "Leave"


class DriveError(RuntimeError):
    """A failure to DRIVE. Never a verdict about the product — the probe
    judges. Confusing the two would turn "I could not press it" into "pairing
    failed"."""


# ──────────────────────────────── guards ────────────────────────────────


def guard_device(udid: str) -> None:
    if not TEST_IPHONE_UDID:
        raise SystemExit(
            f"refused: set {UDID_ENV} to the dedicated test iPhone's UDID.\n"
            "It is not hard-coded because this repository is public.")
    if udid != TEST_IPHONE_UDID:
        raise SystemExit(
            "refused: this script only drives the dedicated test iPhone.\n"
            f"  asked for: {udid}\n"
            f"  {UDID_ENV}: {TEST_IPHONE_UDID}\n"
            "The owner's personal phone is not a lab animal.")


def guard_mac_app(process: str) -> None:
    if process == PROD_APP_PROCESS:
        raise SystemExit(
            "refused: this script never drives the production Soyeht. "
            f"The disposable target is '{DEV_APP_PROCESS}'.")


# ────────────────────────── the phone, via WDA ──────────────────────────


class Phone:
    """The minimum of WebDriverAgent this flow needs, and nothing more.

    A general-purpose client would invite the probe to ask the app what it
    thinks of its own state — which is exactly the testimony that does not
    count.
    """

    def __init__(self, port: int, timeout: float = 20):
        self.base = f"http://127.0.0.1:{port}"
        self.timeout = timeout
        self.session: str | None = None

    def _call(self, method: str, path: str, body: dict | None = None) -> dict:
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(
            self.base + path, data=data, method=method,
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return json.loads(response.read() or b"{}")
        except urllib.error.HTTPError as error:
            raise DriveError(f"{method} {path} -> {error.code} {error.read()[:200]!r}") from error
        except Exception as error:
            raise DriveError(f"{method} {path} -> {error}") from error

    def reachable(self) -> bool:
        try:
            return self._call("GET", "/status").get("value") is not None
        except DriveError:
            return False

    @classmethod
    def discover(cls, udid: str, preferred: int | None = None) -> "Phone | None":
        """Finds the tunnel that actually answers.

        WebDriverAgent picks a fresh port on the device every time the runner
        starts (52590 on one run, something else on the next), and each stale
        `iproxy` stays open pointing at a dead one. Hard-coding a number makes
        preflight reject a harness that is standing — that cost us a round.
        """
        candidates = ([preferred] if preferred else []) + [
            port for port in cls._iproxy_local_ports(udid) if port != preferred
        ]
        for port in candidates:
            phone = cls(port=port)
            if phone.reachable():
                return phone
        return None

    @staticmethod
    def _iproxy_local_ports(udid: str) -> list[int]:
        """Local ports of the live tunnels for this device, in listed order."""
        listed = subprocess.run(["/usr/bin/pgrep", "-fl", "iproxy"],
                                capture_output=True, text=True).stdout
        ports: list[int] = []
        for line in listed.splitlines():
            if udid not in line:
                continue  # another device's tunnel is none of our business
            for token in line.split():
                local, _, remote = token.partition(":")
                if local.isdigit() and remote.isdigit():
                    ports.append(int(local))
        return ports

    def open_app(self, bundle_id: str = DEV_BUNDLE_ID) -> None:
        response = self._call("POST", "/session", {
            "capabilities": {"alwaysMatch": {
                "bundleId": bundle_id,
                "shouldWaitForQuiescence": False,
            }}
        })
        self.session = (response.get("sessionId")
                        or response.get("value", {}).get("sessionId"))
        if not self.session:
            raise DriveError(f"no session in the response: {response}")

    def find(self, accessibility_id: str) -> str | None:
        """The element, or None. Absence is a legitimate answer here — the
        "looking" screen and the "found it" screen are different states of the
        same flow."""
        try:
            response = self._call("POST", f"/session/{self.session}/element",
                                  {"using": "accessibility id",
                                   "value": accessibility_id})
        except DriveError:
            return None
        value = response.get("value") or {}
        return value.get("ELEMENT") or value.get("element-6066-11e4-a52e-4f735466cecf")

    def tap(self, accessibility_id: str) -> bool:
        element = self.find(accessibility_id)
        if element is None:
            return False
        self._call("POST", f"/session/{self.session}/element/{element}/click", {})
        return True

    def find_by_label(self, label: str) -> str | None:
        """By visible name. Settings has no accessibility ids on these rows."""
        try:
            response = self._call("POST", f"/session/{self.session}/element",
                                  {"using": "link text", "value": f"label={label}"})
        except DriveError:
            return None
        value = response.get("value") or {}
        return value.get("ELEMENT") or value.get("element-6066-11e4-a52e-4f735466cecf")

    def click(self, element: str) -> None:
        self._call("POST", f"/session/{self.session}/element/{element}/click", {})

    def text_of(self, accessibility_id: str) -> str | None:
        element = self.find(accessibility_id)
        if element is None:
            return None
        return (self._call("GET", f"/session/{self.session}/element/{element}/text")
                .get("value"))

    def wait_for(self, accessibility_id: str, budget: float) -> bool:
        """Waits WITH a deadline. An unbounded wait is the defect we are
        hunting; I will not reproduce it inside the driver."""
        deadline = time.monotonic() + budget
        while time.monotonic() < deadline:
            if self.find(accessibility_id) is not None:
                return True
            time.sleep(1)
        return False


# ─────────────────────────── the Mac, via AX ───────────────────────────


def osascript(script: str) -> str:
    result = subprocess.run(["/usr/bin/osascript", "-e", script],
                            capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise DriveError(f"osascript: {result.stderr.strip()}")
    return result.stdout.strip()


def app_menu_title(process: str) -> str:
    """The app's own menu title, asked for rather than guessed.

    Guessing it as the first word of the process name worked for "Soyeht" and
    failed for "Soyeht Dev", whose menu is titled "Soyeht Dev". The rehearsal
    caught it; a real run would have wasted a whole measurement window.
    """
    titles = osascript(
        f'tell application "System Events" to tell process "{process}" to '
        'name of menu bar items of menu bar 1'
    ).split(", ")
    # The app menu is the one right after Apple's.
    for title in titles[1:]:
        if title.strip():
            return title.strip()
    raise DriveError(f"{process} exposes no application menu")


def open_add_iphone(process: str = DEV_APP_PROCESS) -> None:
    guard_mac_app(process)
    menu = app_menu_title(process)
    osascript(f'tell application "System Events" to tell process "{process}" to '
              'click menu item "Devices…" of menu 1 of menu bar item '
              f'"{menu}" of menu bar 1')
    time.sleep(2)
    # The button comes from the accessibility API, not from a coordinate: the
    # sheet re-lays out as its state changes (measured 2026-09-05, the text
    # changed mid-run) and a click by pixel lands somewhere else without saying so.
    #
    # The window is bound to a variable first. Written as one expression,
    # AppleScript folded the two `whose` clauses into a single filter on the
    # window and asked for a Preferences window that was also named "Add
    # iPhone" — a window that cannot exist. The rehearsal caught it.
    # The buttons are not direct children of the window: the window holds one
    # AXGroup and the buttons live inside it. Asking the window for them
    # returns only the traffic lights, whose names are all "missing value" —
    # which reads as "the button is not there" rather than "you looked in the
    # wrong place". The rehearsal caught both this and the `whose` clause
    # below, which AppleScript had been folding into a single window filter.
    osascript(
        'tell application "System Events" to tell process "%s"\n'
        '  set prefsWindow to first window whose name is "Preferences"\n'
        '  set content to first UI element of prefsWindow\n'
        '  click (first button of content whose name is "Add iPhone")\n'
        'end tell' % process
    )


def mac_app_running(process: str) -> bool:
    return bool(subprocess.run(["/usr/bin/pgrep", "-f",
                                f"{process}.app/Contents/MacOS"],
                               capture_output=True).stdout.strip())


# ─────────────────────────────── scenarios ───────────────────────────────


def leave_household(phone: Phone) -> bool:
    """Puts the phone back to publishing an invitation, by its own Settings.

    Deliberately NOT silent and NOT the default: this erases the phone's
    membership, and a driver that wipes state nobody asked it to wipe is how a
    harness stops being trustworthy. The caller opts in with --reset-phone.
    """
    for label in (LEAVE_HOUSEHOLD_LABEL, LEAVE_CONFIRM_LABEL):
        element = phone.find_by_label(label)
        if element is None:
            return False
        phone.click(element)
        time.sleep(2)
    time.sleep(4)  # the app restarts itself into the welcome carousel
    return True


def scenario_from_scratch(phone: Phone, mac_process: str, budget: float,
                          reset_phone: bool = False) -> dict:
    """Pairing from scratch: the Mac offers, the phone checks the words and accepts.

    Returns what the DRIVER observed — steps taken and deadlines blown. None of
    it is a verdict; the probe judges from the logs.
    """
    steps: list[dict] = []

    def note(what: str, ok: bool, detail: str = "") -> None:
        steps.append({"step": what, "ok": ok, "detail": detail})

    phone.open_app()
    note("opened the app on the phone", True)

    if reset_phone:
        left = leave_household(phone)
        note("phone left its household so it advertises again", left,
             "" if left else "could not find the Settings control")
        if not left:
            return {"scenario": "from scratch", "steps": steps,
                    "drove_to_the_end": False}
        phone.open_app()
    else:
        note("phone NOT reset", True,
             "a phone that already belongs to a home never advertises; "
             "pass --reset-phone for a true from-scratch run")

    open_add_iphone(mac_process)
    note("opened Add iPhone on the Mac", True)

    found = phone.wait_for(ID_CARD, budget)
    note("the phone found the Mac", found,
         "" if found else f"nothing within {budget:.0f}s — this is the spinner symptom")
    if not found:
        return {"scenario": "from scratch", "steps": steps, "drove_to_the_end": False}

    words = [phone.text_of(f"soyeht.onboarding.isThisYourMac.word.{index}")
             for index in range(1, 7)]
    note("read the six words", all(words), " ".join(w or "?" for w in words))

    tapped = phone.tap(ID_CONFIRM)
    note("confirmed on the phone", tapped)

    # If the run continues into owner approval, capture the request words the
    # phone displays. Comparing them against the Mac's is the point of the
    # ceremony: six words on each screen prove nothing until they are the same
    # six, and only a machine reading both ends can say that without a person
    # squinting at two displays.
    approval = phone.text_of(ID_APPROVAL_WORDS)
    if approval:
        note("phone shows request words for the approver", True, approval)

    return {"scenario": "from scratch", "steps": steps,
            "phone_approval_words": approval, "drove_to_the_end": tapped}


SCENARIOS = {"from-scratch": scenario_from_scratch}


def preflight(phone: Phone | None, mac_process: str) -> list[str]:
    """What is missing before a run can happen. Said up front, not mid-run."""
    missing = []
    if phone is None:
        missing.append(
            "WebDriverAgent answers on no live tunnel for this device. Start the "
            "runner (`xcodebuild test-without-building` on WebDriverAgentRunner) "
            "and an `iproxy <local>:<the port the runner announces> -u <udid>`.")
    if not mac_app_running(mac_process):
        missing.append(f"'{mac_process}' is not running.")
    return missing


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--scenario", choices=sorted(SCENARIOS), default="from-scratch")
    parser.add_argument("--udid", default=TEST_IPHONE_UDID)
    parser.add_argument("--mac-process", default=DEV_APP_PROCESS)
    parser.add_argument("--wda-port", type=int,
                        help="force one tunnel; without it I discover which answers")
    parser.add_argument("--find-budget", type=float, default=90,
                        help="how long the phone gets to find the Mac before I "
                             "call it a spinner")
    parser.add_argument("--reset-phone", action="store_true",
                        help="make the phone leave its household first, so it "
                             "advertises again; without this a 'from scratch' "
                             "run measures a phone that is not from scratch")
    parser.add_argument("--preflight", action="store_true",
                        help="only report whether a run is possible, then exit")
    args = parser.parse_args()

    guard_device(args.udid)
    guard_mac_app(args.mac_process)

    phone = Phone.discover(args.udid, preferred=args.wda_port)
    missing = preflight(phone, args.mac_process)
    if args.preflight:
        if missing:
            print("not ready to run:")
            for item in missing:
                print(f"  – {item}")
            return 1
        print(f"ready: WebDriverAgent answers at {phone.base} and "
              f"{args.mac_process} is running.")
        return 0
    if missing:
        for item in missing:
            print(f"missing: {item}", file=sys.stderr)
        return 1

    try:
        result = SCENARIOS[args.scenario](phone, args.mac_process,
                                          args.find_budget, args.reset_phone)
    except DriveError as error:
        print(f"could not drive: {error}", file=sys.stderr)
        print("this is NOT a verdict about pairing — the script itself failed.",
              file=sys.stderr)
        return 2

    for step in result["steps"]:
        print(f"  {'ok  ' if step['ok'] else 'NO  '} {step['step']}"
              + (f"  — {step['detail']}" if step["detail"] else ""))
    print(f"\ndrove to the end: {result['drove_to_the_end']}")
    print("now run the probe for the verdict: scripts/pairing-e2e-probe.py")
    return 0 if result["drove_to_the_end"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
