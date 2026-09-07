#!/usr/bin/env python3
"""Orchestrate one bench arm so the capture cannot miss the run.

The probe held a FIXED number of seconds and then collected the phone log with
`--last Nm`. When the driver's connect landed near the end of that guess — or
just after it — the phone tape came back without the run, and MAC-LOCAL read
n/a on a run that actually happened (measured 2026-09-07, [jaime]). A larger
guess only moves the cliff.

This removes the guess. It:

  1. arms the Mac capture and records the household snapshot + engine offset,
  2. records START,
  3. runs the driver to completion under a hard cap,
  4. records END,
  5. collects the phone log for the OBSERVED [START, END] window, not a guess,
  6. builds the transcript and hands it to the probe's own judge.

So the window is defined by what happened, and a slow arm just makes a longer
window, never a missed one. Same judge, same invariants; only the capture
boundary changes.
"""
import argparse
import datetime
import importlib.util
import json
import math
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module          # so @dataclass can resolve its module
    spec.loader.exec_module(module)
    return module


probe = _load("pairing_e2e_probe", "pairing-e2e-probe.py")


def collect_phone_window(udid: str, start: datetime.datetime,
                         end: datetime.datetime, out_dir: str) -> list[str]:
    """The phone log for exactly [start, end], not `--last <guess>`."""
    archive = os.path.join(out_dir, "iphone.logarchive")
    subprocess.run(["rm", "-rf", archive], check=False)
    minutes = max(1, math.ceil((time.time() - start.timestamp()) / 60) + 1)
    collected = subprocess.run(
        ["sudo", "-n", "/usr/bin/log", "collect", "--device-udid", udid,
         "--last", f"{minutes}m", "--output", archive],
        capture_output=True, text=True)
    if collected.returncode != 0:
        return [f"<<no phone log: {collected.stderr.strip()}>>"]
    subprocess.run(["sudo", "-n", "chown", "-R", str(os.getuid()), archive],
                   capture_output=True)
    fmt = "%Y-%m-%d %H:%M:%S"
    shown = subprocess.run(
        ["/usr/bin/log", "show", "--archive", archive, "--style", "compact",
         "--info",
         "--start", start.strftime(fmt), "--end", end.strftime(fmt),
         "--predicate", f'subsystem == "{probe.PHONE_SUBSYSTEM}"'],
        capture_output=True, text=True)
    return shown.stdout.splitlines()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenario", default="existing-house-new-phone")
    ap.add_argument("--udid", required=True)
    ap.add_argument("--mac-id", help="the Mac under test, for MAC-LOCAL subjects")
    ap.add_argument("--device-id", help="phone subject when the tape mints none")
    ap.add_argument("--phone-has-tailnet", action="store_true")
    ap.add_argument("--cap-secs", type=float, default=240,
                    help="hard cap on the driver before the window is closed")
    ap.add_argument("--find-budget", type=float, default=80)
    ap.add_argument("--mac-process", default=probe.DEV_APP_PROCESS)
    ap.add_argument("--engine-log", default=probe.DEV_ENGINE_LOG)
    ap.add_argument("--bootstrap-port", type=int, default=probe.DEV_BOOTSTRAP_PORT)
    ap.add_argument("--house-dir", default=probe.DEV_HOUSE_DIR)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--label", default="")
    args = ap.parse_args()

    probe.guard_not_production(args.bootstrap_port)
    os.makedirs(args.out_dir, exist_ok=True)
    mac_log = os.path.join(args.out_dir, "mac.log")

    devices_before = probe.household_device_count(args.bootstrap_port)
    house_before = probe.house_snapshot(args.house_dir)
    offset = probe.engine_offset(args.engine_log)
    capture = probe.start_mac_capture(mac_log, args.mac_process)
    start = datetime.datetime.now()
    print(f"[{start:%H:%M:%S}] armed; driving {args.scenario} (cap {args.cap_secs:.0f}s)")

    driver = subprocess.run(
        ["uv", "run", "python", os.path.join(HERE, "pairing-e2e-drive.py"),
         "--scenario", args.scenario, "--find-budget", str(args.find_budget)],
        env={**os.environ, "SOYEHT_E2E_IPHONE_UDID": args.udid},
        capture_output=True, text=True, timeout=args.cap_secs + 120, check=False)
    end = datetime.datetime.now()
    # A moment for the last os_log lines to flush before the window closes.
    time.sleep(3)
    end_padded = end + datetime.timedelta(seconds=3)
    print(f"[{end:%H:%M:%S}] driver done (exit {driver.returncode}); "
          f"window {start:%H:%M:%S}-{end:%H:%M:%S}")
    with open(os.path.join(args.out_dir, "drive.log"), "w") as handle:
        handle.write(driver.stdout + "\n---stderr---\n" + driver.stderr)

    capture.terminate()
    try:
        capture.wait(timeout=5)
    except subprocess.TimeoutExpired:
        capture.kill()

    engine_lines = probe.engine_tail(args.engine_log, offset)
    with open(mac_log, errors="replace") as handle:
        mac_lines = handle.read().splitlines()
    phone_lines = collect_phone_window(args.udid, start, end_padded, args.out_dir)

    transcript = probe.Transcript(
        mac=mac_lines, phone=phone_lines, engine=engine_lines,
        house_before=house_before, house_after=probe.house_snapshot(args.house_dir))
    with open(os.path.join(args.out_dir, "transcript.json"), "w") as handle:
        json.dump(probe.asdict(transcript), handle, indent=2)

    captured = (end - start).total_seconds()
    findings = probe.judge(transcript, args.phone_has_tailnet, devices_before,
                           captured_secs=captured,
                           expected_device=args.device_id,
                           expected_mac=args.mac_id)
    with open(os.path.join(args.out_dir, "run.json"), "w") as handle:
        json.dump({"label": args.label, "scenario": args.scenario,
                   "start": start.isoformat(), "end": end.isoformat(),
                   "driver_exit": driver.returncode,
                   "drove_to_the_end": "drove to the end: True" in driver.stdout,
                   "findings": [(f.name, f.verdict, f.detail) for f in findings]},
                  handle, indent=2)
    return probe.report(findings, args.label or args.scenario, args.out_dir, transcript)


if __name__ == "__main__":
    raise SystemExit(main())
