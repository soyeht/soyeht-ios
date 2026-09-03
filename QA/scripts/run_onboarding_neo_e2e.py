#!/usr/bin/env python3
"""Drive the iPhone half of the neo onboarding, from zero to a terminal.

    uv run QA/scripts/run_onboarding_neo_e2e.py
    uv run QA/scripts/run_onboarding_neo_e2e.py --keep-state   # no reset first

What it does: resets both devices, waits at each point where the Mac needs a
click, drives every phone screen over WDA, and saves a screenshot of each one
into QA/runs/<date>-onboarding-neo/screenshots/.

What it does NOT do: click the Mac. Those two buttons ("Set up this Mac",
"Continue") are SwiftUI, and System Events cannot press them — a click has to
come from `native-devtools`, which is an agent tool rather than something a
script can call. So the script stops and asks, and the operator (or an agent
holding native-devtools) clicks. Everything else is automatic.

Read QA/domains/ios-onboarding-neo.md for what each screen must show. This
script proves the path exists; the eye on the screenshots is what proves it is
right.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

# The Dev engine's own port. 8091 is the release engine and 8100/8101 are the
# WDA and household ports — proxying onto 8101 collides with the engine and
# takes the Mac down with it.
DEV_ENGINE = "http://127.0.0.1:8101"
WDA = "http://127.0.0.1:8210"

DEV_APP = "/Applications/Soyeht Dev.app"
DEV_BUNDLE = "com.soyeht.mac.dev"
PHONE_BUNDLE = "com.soyeht.app.dev"

# Taps are in WDA points: the screenshot is 3× that. Each is the centre of the
# screen's primary button, which is pinned to the bottom by OnboardingScaffold.
TAP_I1_GET_STARTED = 724
TAP_I2_YES = 626
TAP_I4_CONNECT = 610
TAP_I5_OPEN_TERMINAL = 724
TAP_HOME_NEW_SESSION = 382


def run(*args: str, check: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True, check=check)


def device_udid() -> str:
    """The devicectl identifier, from the environment rather than a literal —
    a UDID in a public repository is a personal identifier."""
    import os

    udid = os.environ.get("SOYEHT_IOS_DEVICE_UDID")
    if not udid:
        sys.exit(
            "set SOYEHT_IOS_DEVICE_UDID to the devicectl identifier of the Dev iPhone\n"
            "(xcrun devicectl list devices)"
        )
    return udid


def engine_state() -> str | None:
    try:
        with urllib.request.urlopen(f"{DEV_ENGINE}/bootstrap/status", timeout=2) as response:
            return json.load(response).get("state")
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
        return None


def wait_for_state(*wanted: str, timeout: float = 300) -> str:
    deadline = time.time() + timeout
    while time.time() < deadline:
        state = engine_state()
        if state in wanted:
            return state
        time.sleep(2)
    sys.exit(f"engine never reached {' or '.join(wanted)} (last: {engine_state()})")


def wda(path: str, body: dict | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(
        f"{WDA}{path}", data=data, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def new_session() -> str:
    payload = {
        "capabilities": {
            "alwaysMatch": {"bundleId": PHONE_BUNDLE, "shouldWaitForQuiescence": False}
        }
    }
    session = wda("/session", payload).get("sessionId")
    if not session:
        sys.exit("WDA refused a session — is `iproxy 8210:8100 -u <udid>` running?")
    return session


def tap(session: str, y: int, x: int = 187) -> None:
    wda(
        f"/session/{session}/actions",
        {
            "actions": [
                {
                    "type": "pointer",
                    "id": "finger1",
                    "parameters": {"pointerType": "touch"},
                    "actions": [
                        {"type": "pointerMove", "duration": 0, "x": x, "y": y},
                        {"type": "pointerDown", "button": 0},
                        {"type": "pause", "duration": 80},
                        {"type": "pointerUp", "button": 0},
                    ],
                }
            ]
        },
    )


def wait_for_text(session: str, needle: str, timeout: float = 120) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if needle in wda(f"/session/{session}/source").get("value", ""):
            return
        time.sleep(1)
    sys.exit(f"the phone never showed {needle!r}")


def shoot(into: Path, name: str) -> Path:
    into.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(f"{WDA}/screenshot", timeout=20) as response:
        image = base64.b64decode(json.load(response)["value"])
    path = into / f"{name}.png"
    path.write_bytes(image)
    print(f"    saved {path.relative_to(REPO)}")
    return path


def ask_mac(prompt: str) -> None:
    print(f"\n  >>> ON THE MAC: {prompt}")
    input("      press Return once you have done it — ")


def reset_everything(udid: str) -> None:
    print("resetting the Mac Dev app…")
    run("osascript", "-e", f'quit app id "{DEV_BUNDLE}"')
    time.sleep(3)
    subprocess.run(
        [f"{DEV_APP}/Contents/MacOS/Soyeht Dev", "--reset-local-state-for-qa"],
        env={"SOYEHT_RUN_DEV_LOCAL_STATE_RESET": "1", "PATH": "/usr/bin:/bin"},
        capture_output=True,
        text=True,
    )
    print("resetting the iPhone…")
    run(
        "xcrun", "devicectl", "device", "process", "launch", "--device", udid,
        "--payload-url", "soyeht://debug/reset-local-state", PHONE_BUNDLE,
    )
    time.sleep(6)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--keep-state", action="store_true", help="skip the reset; walk what is already there")
    args = parser.parse_args()

    udid = device_udid()
    run_dir = REPO / "QA" / "runs" / f"{dt.date.today():%Y-%m-%d}-onboarding-neo" / "screenshots"

    if not args.keep_state:
        reset_everything(udid)

    run("open", "-a", DEV_APP)
    ask_mac('click "Set up this Mac"')
    print("  waiting for the Dev engine…")
    wait_for_state("uninitialized", "ready_for_naming", "named_awaiting_pair", "ready")

    ask_mac('name the home and click "Continue"')
    wait_for_state("named_awaiting_pair")
    print("  the Mac is offering; M4 should be showing six words.")

    run("xcrun", "devicectl", "device", "process", "launch", "--device", udid,
        "--terminate-existing", PHONE_BUNDLE)
    session = new_session()

    print("\nI1 — welcome")
    wait_for_text(session, "Get started")
    shoot(run_dir, "01-i1-welcome")
    tap(session, TAP_I1_GET_STARTED)

    print("I2 — is Soyeht already on your Mac?")
    wait_for_text(session, "Is Soyeht already on your Mac?")
    shoot(run_dir, "02-i2-question")
    tap(session, TAP_I2_YES)

    print("I3 — the radar, then I4 with the six words")
    time.sleep(3)
    shoot(run_dir, "03-i3-radar")
    wait_for_text(session, "Connect this iPhone", timeout=180)
    shoot(run_dir, "04-i4-six-words")
    print("    >>> compare these six words with the Mac before continuing.")
    tap(session, TAP_I4_CONNECT)

    print("waiting for the engine to accept the pairing…")
    wait_for_state("ready")

    print("I5 — the celebration")
    wait_for_text(session, "Open a terminal", timeout=120)
    shoot(run_dir, "05-i5-celebration")
    tap(session, TAP_I5_OPEN_TERMINAL)

    print("home")
    wait_for_text(session, "New session", timeout=120)
    shoot(run_dir, "06-home")
    tap(session, TAP_HOME_NEW_SESSION)

    print("the terminal")
    time.sleep(10)
    shoot(run_dir, "07-terminal")

    print(f"\ndone — screenshots in {run_dir.relative_to(REPO)}")
    print("they are gitignored: a device screenshot carries the machine name and")
    print("its tailnet address, and this repository is public.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
