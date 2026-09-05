#!/usr/bin/env python3
"""F0 — measures whether a terminal session SURVIVED an engine swap.

Without this, "it survived" is an opinion. That opinion is how eleven of the
owner's panes died on 2026-09-05: I had read one guard, convinced myself, and
said so out loud.

WHAT IT MEASURES, AND WHY EACH PART

Identity (necessary, not sufficient):
  - PID plus start time of the shell. The start time is what stops a recycled
    PID from passing itself off as the original process within one boot.
  - TTY. Not enough on its own: the name can be reused.

Behaviour (what separates "the same session" from "a session convincingly
re-created" — criteria proposed by [jaime]):
  - a nonce in a NON-exported variable, assigned only just before the failure.
    `X=1` would be weak: a recovery script could re-run it and "prove"
    something that never happened.
  - PID plus start time of the long-running process and of the TUI, not just of
    the shell.
  - PGID/SID and the foreground process group — that is what proves job control.
  - an I/O challenge AFTER reattaching: a process can be alive and wedged.
  - numbered, deterministic output during the absence, checked by content and
    by interval — not "something showed up".
  - PID plus start time of the engine, and the supervisor's identity: proof
    that I killed the component I meant to and that it stayed away for a known
    length of time.

EVERYTHING IS TAKEN FROM THE OPERATING SYSTEM, never from the `list` of the
service under test — otherwise it testifies about itself.

SAFETY: talks only to the Dev engine (port 8902 by default). Refuses to run
against production. Never kills anything it did not create.
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
import uuid
from dataclasses import dataclass, field

DEV_ADMIN_PORT = 8902
PROD_ADMIN_PORT = 8892
DEV_STATE_DIR = os.path.expanduser("~/Library/Application Support/SoyehtDev")
DEV_ENGINE_LABEL = "com.soyeht.engine.dev"
DEV_ENGINE_PATH_FRAGMENT = "SoyehtDev/engine/theyos-engine"


# ─────────────────────────── what the OS says ───────────────────────────


def ps_rows(fields: str, extra: list[str] | None = None) -> list[list[str]]:
    """Raw `ps`. The source of truth about processes — not the service on trial."""
    command = ["/bin/ps", "-Ao", fields]
    if extra:
        command = ["/bin/ps", *extra, "-o", fields]
    output = subprocess.run(command, capture_output=True, text=True, check=False)
    rows = []
    # `pid=` (with the `=`) suppresses the header, so dropping the first line
    # ate a process — possibly the very one I was looking for. [jaime]
    for line in output.stdout.splitlines():
        parts = line.split(None, len(fields.split(",")) - 1)
        if parts:
            rows.append(parts)
    return rows


def normalize_tty(tty: str) -> str:
    """`ps -o tty=` answers `ttys003`; the API returns `/dev/ttys003`.

    Comparing the two forms reported FAILURE on an intact session. An
    instrument that fails the good case is as useless as one that passes the
    bad one.
    """
    if not tty or tty == "??":
        return ""
    return tty if tty.startswith("/dev/") else f"/dev/{tty}"


def process_identity(pid: int) -> dict | None:
    """PID, start time, TTY, PGID and SID, straight from `ps`.

    `lstart` is the discriminator that matters: within one boot, two processes
    never share both a PID and a start instant.
    """
    output = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "pid=,ppid=,pgid=,sess=,tty=,lstart=,command="],
        capture_output=True, text=True, check=False,
    )
    line = output.stdout.strip()
    if not line:
        return None
    parts = line.split(None, 5)
    if len(parts) < 6:
        return None
    pid_text, ppid_text, pgid_text, sess_text, tty_text, rest = parts
    # lstart is five fields ("Fri Sep  5 14:23:45 2026"); the command follows.
    rest_parts = rest.split(None, 5)
    lstart = " ".join(rest_parts[:5]) if len(rest_parts) >= 5 else ""
    command = rest_parts[5] if len(rest_parts) > 5 else ""
    return {
        "pid": int(pid_text),
        "ppid": int(ppid_text),
        "pgid": int(pgid_text),
        "sess": sess_text,
        "tty": normalize_tty(tty_text),
        "start": lstart,
        "command": command[:120],
    }


def pids_under(parent_pid: int) -> list[int]:
    result = []
    for row in ps_rows("pid=,ppid="):
        if len(row) >= 2 and row[1].isdigit() and int(row[1]) == parent_pid:
            result.append(int(row[0]))
    return result


def foreground_pgid(tty: str) -> int | None:
    """The TTY's foreground process group — the evidence of job control."""
    if not tty or tty == "??":
        return None
    device = tty if tty.startswith("/dev/") else f"/dev/{tty}"
    output = subprocess.run(
        ["/bin/ps", "-t", device.replace("/dev/", ""), "-o", "pgid=,stat="],
        capture_output=True, text=True, check=False,
    )
    for line in output.stdout.splitlines():
        parts = line.split()
        # the '+' in STAT marks the foreground group
        if len(parts) >= 2 and "+" in parts[1]:
            return int(parts[0])
    return None


def engine_identity(path_fragment: str) -> dict | None:
    for row in ps_rows("pid=,command="):
        if len(row) >= 2 and path_fragment in row[1]:
            return process_identity(int(row[0]))
    return None


# ─────────────────────────── talking to the engine ───────────────────────


class Engine:
    def __init__(self, port: int, token: str):
        self.base = f"http://127.0.0.1:{port}"
        self.token = token

    def _call(self, method: str, path: str, body: dict | None = None, timeout=15):
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(
            f"{self.base}{path}", data=data, method=method,
            headers={"Content-Type": "application/json",
                     "Authorization": f"Bearer {self.token}"},
        )
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}

    def create_terminal(self, conversation_id: str, argv: list[str],
                        cwd: str | None = None,
                        env: list[list[str]] | None = None) -> dict:
        return self._call("POST", "/api/v1/terminals/local", {
            "conversation_id": conversation_id,
            "argv": argv,
            "cwd": cwd,
            "env": env or [],
            "cols": 120,
            "rows": 40,
        })

    def delete_terminal(self, conversation_id: str) -> None:
        try:
            self._call("DELETE", f"/api/v1/terminals/local/{conversation_id}")
        except urllib.error.HTTPError:
            pass

    def alive(self) -> bool:
        try:
            self._call("GET", "/api/v1/terminals/local", timeout=3)
            return True
        except Exception:
            return False


# ─────────────────────────── one session under test ───────────────────────


@dataclass
class SessionSnapshot:
    conversation_id: str
    nonce: str
    shell: dict | None = None
    children: list[dict] = field(default_factory=list)
    tty: str = ""
    foreground_pgid: int | None = None
    parent_pid: int | None = None

    def identity_key(self) -> tuple:
        """What must be identical for the session to be THE SAME one."""
        shell = self.shell or {}
        return (shell.get("pid"), shell.get("start"), self.tty)


def first_snapshot(engine_pid: int, conversation_id: str, tty: str,
                   nonce: str) -> SessionSnapshot:
    """First photograph: find the shell by its parent (the engine) and RECORD
    its identity."""
    snapshot = SessionSnapshot(conversation_id=conversation_id, nonce=nonce, tty=tty)
    for identity in processes_on_tty(tty):
        if identity["ppid"] == engine_pid and snapshot.shell is None:
            snapshot.shell = identity
        elif snapshot.shell and identity["ppid"] == snapshot.shell["pid"]:
            snapshot.children.append(identity)
    snapshot.foreground_pgid = foreground_pgid(tty)
    snapshot.parent_pid = engine_pid
    return snapshot


def resnapshot(before: SessionSnapshot) -> SessionSnapshot:
    """Second photograph: look for THAT shell by the identity I recorded.

    THE DEFECT THIS FIXES — found by [jaime], reproduced with mocks. The first
    version looked the shell up by PPID and, on the later measurement, passed
    the NEW engine's pid. A shell that SURVIVED would have the supervisor as
    its parent, not the new engine: it would come back "not found", and the
    probe would declare it dead.

    In other words, the instrument would condemn path A precisely when path A
    worked. A test that fails the correct solution is worse than no test.

    Identity first; parentage becomes a SEPARATE assertion, against the parent
    expected after the swap.
    """
    snapshot = SessionSnapshot(conversation_id=before.conversation_id,
                               nonce=before.nonce, tty=before.tty)
    if before.shell is None:
        return snapshot
    target = process_identity(before.shell["pid"])
    # The same PID is not enough: the start time is what separates the original
    # process from a recycled PID.
    if target and target["start"] == before.shell["start"]:
        snapshot.shell = target
        snapshot.tty = target["tty"] or before.tty
        snapshot.parent_pid = target["ppid"]
        for identity in processes_on_tty(snapshot.tty):
            if identity["ppid"] == target["pid"]:
                snapshot.children.append(identity)
        snapshot.foreground_pgid = foreground_pgid(snapshot.tty)
    return snapshot


def processes_on_tty(tty: str) -> list[dict]:
    tty_name = tty.replace("/dev/", "")
    output = subprocess.run(["/bin/ps", "-t", tty_name, "-o", "pid="],
                            capture_output=True, text=True, check=False)
    result = []
    for line in output.stdout.splitlines():
        line = line.strip()
        if line.isdigit():
            identity = process_identity(int(line))
            if identity:
                result.append(identity)
    return result


# ─────────────────────────── the verdict ───────────────────────────


def compare(before: SessionSnapshot, after: SessionSnapshot | None) -> dict:
    """Checks identity AND behaviour. Both, or it is not the same session."""
    checks: dict[str, tuple[bool | None, str]] = {}

    if after is None or after.shell is None:
        return {"survived": False,
                "checks": {"shell_alive": (False, "the shell no longer exists")}}

    old, new = before.shell or {}, after.shell
    checks["same_pid"] = (old.get("pid") == new.get("pid"),
                          f'{old.get("pid")} -> {new.get("pid")}')
    checks["same_start_time"] = (old.get("start") == new.get("start"),
                                 f'{old.get("start")!r} -> {new.get("start")!r}')
    # The TTY comes from the NEW observation of the process (`after.tty` is
    # re-read from `ps`), not from the field copied out of the first photograph
    # — comparing a value with itself is an empty guard. [jaime]
    checks["same_tty"] = (before.tty == after.tty, f"{before.tty} -> {after.tty}")
    checks["same_pgid"] = (old.get("pgid") == new.get("pgid"),
                           f'{old.get("pgid")} -> {new.get("pgid")}')
    # `ps -o sess=` answers 0 for EVERY process on this macOS — measured. A
    # check that always passes is worse than no check: it hands out false
    # confidence. What really proves job control is the TTY's foreground group.
    checks["foreground_pgid"] = (
        before.foreground_pgid is not None
        and before.foreground_pgid == after.foreground_pgid,
        f"{before.foreground_pgid} -> {after.foreground_pgid}",
    )

    before_children = {
        (child["command"].split()[0] if child["command"] else "?"):
            (child["pid"], child["start"]) for child in before.children
    }
    after_children = {
        (child["command"].split()[0] if child["command"] else "?"):
            (child["pid"], child["start"]) for child in after.children
    }
    missing = [name for name in before_children if name not in after_children]
    changed = [name for name, identity in before_children.items()
               if name in after_children and after_children[name] != identity]
    if not before_children:
        # Zero children passing as "preserved" is an empty guard: it would stay
        # green forever because there was never anything to preserve. With no
        # fixture the result is NOT RUN, and that has to show in the report.
        checks["children_preserved"] = (None, "NOT RUN — no child in the fixture")
    else:
        checks["children_preserved"] = (
            not missing and not changed,
            f"gone={missing} changed={changed}" if (missing or changed) else
            f"{len(before_children)} process(es) with the same pid+start",
        )

    # Parentage is an assertion of its OWN, not the means of finding the shell
    # — and it is INFORMATIVE until a supervisor exists: today, without one,
    # the parent staying put is normal. Marking it a failure failed an intact
    # session. Once the supervisor exists it becomes decisive, against the
    # EXPECTED parent.
    checks["observed_parent"] = (
        None,
        f"{before.parent_pid} -> {after.parent_pid} "
        f"(informative until F2; then the expected parent is the supervisor)",
    )

    executed = [ok for ok, _ in checks.values() if ok is not None]
    survived = bool(executed) and all(executed)
    return {"survived": survived, "checks": checks,
            "identity_only": True}  # nonce/TUI/IO still pending — see F0 above


def wait_for_engine_change(before: dict, budget: float) -> str:
    """Waits for evidence of the failure. Returns what was ACTUALLY observed.

    Three distinct outcomes, because conflating them is the same as lying:
      "replaced"  — an engine with a different identity appeared. That is proof.
      "absent"    — the engine vanished and did not return within the budget.
                    Not the same thing: it may be a service that died and
                    never came back.
      "unchanged" — nothing happened. The failure command did nothing.

    The first version returned True for "absent" and the caller printed
    "identity changed" — asserting what it had not seen. [jaime]
    """
    deadline = time.time() + budget
    saw_absence = False
    while time.time() < deadline:
        current = engine_identity(DEV_ENGINE_PATH_FRAGMENT)
        if current is None:
            saw_absence = True
        elif current["pid"] != before["pid"] or current["start"] != before["start"]:
            return "replaced"
        time.sleep(0.5)
    return "absent" if saw_absence else "unchanged"


def provoke_failure(mode: str, engine: dict) -> None:
    """Provokes the failure by TYPED MODE, against a verified target.

    The first version accepted `--failure-command` with arbitrary shell, and
    the only guard was the port. That did not hold up the promise in the header
    ("Dev only, never kills what it did not create"): anything could go in
    there, and the action restarts a Dev engine that may hold someone else's
    panes. [jaime]

    Each mode checks the target before acting.
    """
    if mode == "none":
        return
    if DEV_ENGINE_PATH_FRAGMENT not in engine.get("command", ""):
        sys.exit("refused: the target is not the Dev engine "
                 f"(command={engine.get('command','')[:60]!r})")
    if mode == "bootout":
        label = f"user/{os.getuid()}/{DEV_ENGINE_LABEL}"
        subprocess.run(["/bin/launchctl", "kickstart", "-k", label], check=False)
    elif mode == "sigkill":
        os.kill(engine["pid"], 9)
    else:
        sys.exit(f"unknown failure mode: {mode}")


# ─────────────────────────── the run ───────────────────────────


def read_token(state_dir: str) -> str:
    path = os.path.join(state_dir, "bootstrap-token")
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read().strip()


def guard_not_production(port: int) -> None:
    if port == PROD_ADMIN_PORT:
        sys.exit("refused: this probe never talks to the production engine (8892). "
                 "It creates and kills sessions.")


def run(args) -> int:
    guard_not_production(args.port)
    token = read_token(args.state_dir)
    engine = Engine(args.port, token)

    engine_before = engine_identity(DEV_ENGINE_PATH_FRAGMENT)
    if not engine_before:
        sys.exit("the Dev engine is not running")
    engine_pid = engine_before["pid"]
    print(f"Dev engine pid={engine_pid} start={engine_before['start']}")

    created: list[tuple[str, SessionSnapshot]] = []
    try:
        for index in range(args.sessions):
            conversation = f"ptyprobe-{uuid.uuid4()}"
            nonce = uuid.uuid4().hex
            response = engine.create_terminal(conversation, ["/bin/bash", "-i"])
            tty = response.get("slave_tty_path", "")
            if not tty:
                print(f"  session {index}: no TTY in the response, skipping")
                continue
            time.sleep(1.5)
            snapshot = first_snapshot(engine_pid, conversation, tty, nonce)
            if snapshot.shell is None:
                print(f"  session {index}: no shell found on {tty}")
                continue
            created.append((conversation, snapshot))
            print(f"  session {index}: pid={snapshot.shell['pid']} tty={tty}")

        if not created:
            sys.exit("no session was created — nothing to measure")

        print(f"\n{len(created)} session(s) created.")

        observed = "unchanged"
        if args.failure_mode != "none":
            # The probe provokes the failure itself and WAITS for evidence that
            # it happened. The first version asked for Enter, and run through a
            # pipe the Enter arrived instantly: I measured before the failure
            # and the "negative control" reported 100%. An instrument that
            # depends on human coordination measures the coordination, not the
            # system.
            print(f"provoking the failure: {args.failure_mode}")
            provoke_failure(args.failure_mode, engine_before)
            observed = wait_for_engine_change(engine_before, args.absence_budget)
            print({
                "replaced": "  failure confirmed: the engine changed identity",
                "absent": "  the engine VANISHED and did not return in time "
                          "(not the same as replaced)",
                "unchanged": "  the engine did NOT change — the failure never happened",
            }[observed])
        else:
            print("mode none: positive control, nothing is provoked")

        # measurement after the failure
        engine_after = engine_identity(DEV_ENGINE_PATH_FRAGMENT)
        results = []
        survivors = 0
        for conversation, before in created:
            after = resnapshot(before)
            verdict = compare(before, after)
            survivors += 1 if verdict["survived"] else 0
            results.append({"conversation_id": conversation, **verdict})

        print("\n─── RESULT ───")
        print(f"engine before: pid={engine_before['pid']} start={engine_before['start']}")
        if engine_after:
            print(f"engine after:  pid={engine_after['pid']} start={engine_after['start']}")
            same = engine_after["pid"] == engine_before["pid"]
            print("  the engine was "
                  + ("NOT swapped (invalid control!)" if same else "swapped ✓"))
        else:
            print("engine after:  ABSENT")

        for item in results:
            headline = "SURVIVED" if item["survived"] else "DIED"
            print(f"\n{headline}  {item['conversation_id'][:24]}…")
            for name, (ok, detail) in item["checks"].items():
                mark = "n/a " if ok is None else ("ok  " if ok else "FAIL")
                print(f"    {mark} {name}: {detail}")

        percentage = 100.0 * survivors / len(created)

        # If the failure was not provoked, there IS no survival verdict. The
        # first version printed 100% and returned 0 with a warning beside it —
        # exactly the shape of the mistake that cost the eleven panes: a green
        # that does not measure what it claims to. [jaime] reproduced this
        # with mocks.
        valid = observed == "replaced"
        if not valid:
            print(f"\nVERDICT INVALID — the failure was not provoked "
                  f"(observed: {observed}). No survival number means anything here.")
        else:
            print(f"\nsurvival: {survivors}/{len(created)} ({percentage:.0f}%)")
        print("scope: IDENTITY only — nonce, TUI, long-running process, I/O "
              "challenge and output during the absence are not measured yet")

        if args.json_out:
            with open(args.json_out, "w", encoding="utf-8") as handle:
                json.dump({"valid": valid,
                           "failure_observed": observed,
                           "scope": "identity_only",
                           "engine_before": engine_before,
                           "engine_after": engine_after,
                           "results": results,
                           "survival_pct": percentage if valid else None},
                          handle, indent=2)
            print(f"report: {args.json_out}")

        if not valid:
            return 2  # invalid gets its own code: never confuse it with failure
        return 0 if survivors == len(created) else 1
    finally:
        for conversation, _ in created:
            engine.delete_terminal(conversation)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sessions", type=int, default=3)
    parser.add_argument("--port", type=int, default=DEV_ADMIN_PORT)
    parser.add_argument("--state-dir", default=DEV_STATE_DIR)
    parser.add_argument("--failure-mode", choices=["none", "bootout", "sigkill"],
                        default="none",
                        help="how to provoke the failure; the target is verified first")
    parser.add_argument("--absence-budget", type=float, default=60.0,
                        help="seconds to wait for the engine to change identity")
    parser.add_argument("--json-out")
    return run(parser.parse_args())


if __name__ == "__main__":
    sys.exit(main())
