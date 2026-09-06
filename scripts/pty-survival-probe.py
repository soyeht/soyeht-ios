#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["websockets>=14"]
# ///
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

SAFETY: talks only to the Dev engine on port 8902. Deletes only its own PTYs.
Failure modes restart the verified Dev engine only after checking that it has
no pre-existing local sessions. They are explicit mutations, not read-only QA.

CURRENT SCOPE: shell identity, non-exported nonce, fresh I/O challenge and
output produced without an attached reader. This installed-Dev probe does NOT
yet prove TUI/job identity or that the output was produced during ENGINE
absence. The separate Rust process-survival harness exercises those cases.
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
    output = subprocess.run(command, capture_output=True, text=True, check=True)
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
    def __init__(self, port: int, token: str, backend: str = "legacy"):
        self.base = f"http://127.0.0.1:{port}"
        self.token = token
        self.backend = backend
        self.created: dict[str, dict] = {}

    def _call(self, method: str, path: str, body: dict | None = None, timeout=15,
              extra_headers: dict | None = None):
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(
            f"{self.base}{path}", data=data, method=method,
            headers={"Content-Type": "application/json",
                     "Authorization": f"Bearer {self.token}", **(extra_headers or {})},
        )
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}

    def create_terminal(self, conversation_id: str, argv: list[str],
                        cwd: str | None = None,
                        env: list[list[str]] | None = None) -> dict:
        body = {
            "conversation_id": conversation_id,
            "argv": argv,
            "cwd": cwd or os.getcwd(),
            "env": env or [],
            "cols": 120,
            "rows": 40,
        }
        if self.backend == "supervisor":
            issued = self._call("POST", f"/api/v1/terminals/local/{conversation_id}/intents")
            if issued.get("backend") != "supervisor" or issued.get("conversation_id") != conversation_id:
                raise RuntimeError("ticket was not issued by the expected backend")
            uuid.UUID(issued["intent_id"])
            body["intent_id"] = issued["intent_id"]
            # Keep the exact ticket even if the following CREATE response is
            # lost. Cleanup cancels this ticket, never the current conversation.
            self.created[conversation_id] = issued
        result = self._call("POST", "/api/v1/terminals/local", body)
        self.created[conversation_id] = {**self.created.get(conversation_id, {}), **result}
        if self.backend == "supervisor" and result.get("backend") != "supervisor":
            raise RuntimeError("CREATE did not use the expected supervisor")
        return result

    def delete_terminal(self, conversation_id: str) -> None:
        try:
            metadata = self.created[conversation_id]
            path = f"/api/v1/terminals/local/{conversation_id}"
            if self.backend == "supervisor":
                instance = metadata.get("session_instance_id")
                if instance:
                    self._call("DELETE", path, extra_headers={"If-Match": f'"{instance}"'})
                else:
                    self._call("POST", f"{path}/intents/{metadata['intent_id']}/cancel")
            else:
                self._call("DELETE", path)
        except urllib.error.HTTPError as error:
            if error.code != 404:
                print(f"probe cleanup refused: HTTP {error.code}", file=sys.stderr)

    def alive(self) -> bool:
        try:
            self._call("GET", "/api/v1/terminals/local", timeout=3)
            return True
        except Exception:
            return False


# ───────────────────── behaviour: the half identity cannot prove ─────────

# `\x00\x01CTL:` marks a control marker; every other binary frame is PTY output.
CTL_PREFIX = b"\x00\x01CTL:"
PTY_PREFIX = b"\x00\x02PTY:"
ABSENT_LINES = 64


def _ws_url(port: int, conversation_id: str) -> str:
    return f"ws://127.0.0.1:{port}/api/v1/terminals/local/{conversation_id}/pty"


async def _converse(port: int, token: str, conversation_id: str,
                    sends: list[str], collect_secs: float,
                    full_replay: bool = False, session: dict | None = None) -> str:
    """Attaches, sends each line, and returns everything the PTY emitted.

    Control markers are dropped: they are the transport talking about itself,
    and what this probe judges is what the SESSION produced.
    """
    import asyncio
    import websockets

    url = _ws_url(port, conversation_id)
    supervised = session is not None and session.get("backend") == "supervisor"
    if supervised:
        instance = str(uuid.UUID(session["session_instance_id"]))
        url += f"?session_instance_id={instance}&stream_protocol=1&next_offset=0"
    elif full_replay:
        url += "?full_replay=true"
    output: list[bytes] = []
    async with websockets.connect(
        url, additional_headers={"Authorization": f"Bearer {token}"},
        max_size=8 * 1024 * 1024,
    ) as socket:
        async def drain() -> None:
            cursor = 0
            async for message in socket:
                if isinstance(message, bytes):
                    if supervised:
                        if not message.startswith(PTY_PREFIX) or len(message) < len(PTY_PREFIX) + 8:
                            raise RuntimeError("invalid supervised terminal frame")
                        offset = int.from_bytes(message[len(PTY_PREFIX):len(PTY_PREFIX)+8], "big")
                        if offset != cursor:
                            raise RuntimeError("terminal replay skipped or duplicated bytes")
                        message = message[len(PTY_PREFIX)+8:]
                        cursor += len(message)
                        output.append(message)
                        continue
                    if message.startswith(CTL_PREFIX):
                        continue
                    output.append(message)
                elif supervised:
                    event = json.loads(message)
                    if event.get("type") == "attached":
                        if event.get("info", {}).get("session_instance_id") != instance:
                            raise RuntimeError("attached to a different terminal instance")
                    elif event.get("type") != "replay_end":
                        raise RuntimeError(f"terminal proof interrupted: {event.get('type')}")

        reader = asyncio.ensure_future(drain())
        for line in sends:
            await socket.send(json.dumps({"type": "input", "data": line}))
            await asyncio.sleep(0.35)
        await asyncio.sleep(collect_secs)
        reader.cancel()
        try:
            await reader
        except asyncio.CancelledError:
            pass
    return b"".join(output).decode("utf-8", "replace")


def converse(port: int, token: str, conversation_id: str, sends: list[str],
             collect_secs: float, full_replay: bool = False, session: dict | None = None) -> str:
    import asyncio
    return asyncio.run(_converse(port, token, conversation_id, sends,
                                 collect_secs, full_replay, session))


def arm_session(port: int, token: str, conversation_id: str, nonce: str,
                session: dict | None = None) -> bool:
    """Puts the marks in the session that a re-created one could not carry.

    - the nonce lives in a variable that is NOT exported, so it exists only in
      THIS shell's memory: a replacement shell cannot inherit it and a recovery
      script cannot re-derive it;
    - `stty -echo` first, so the nonce is never echoed into the log where a
      later replay could hand it back to us;
    - a numbered writer runs in the BACKGROUND, so output keeps being produced
      while nobody is attached — that is what makes the absence measurable.
    """
    marker = converse(port, token, conversation_id, [
        "stty -echo\n",
        f"SOYEHT_PROBE_NONCE='{nonce}'; export -n SOYEHT_PROBE_NONCE\n",
        "printf 'ARMED:%s\\n' \"$SOYEHT_PROBE_NONCE\"\n",
        f"( for n in $(seq 1 {ABSENT_LINES}); do printf 'ABSENT:%03d\\n' \"$n\"; "
        "sleep 0.2; done ) &\n",
    ], collect_secs=1.2, session=session)
    return f"ARMED:{nonce}" in marker


def verify_session(port: int, token: str, conversation_id: str,
                   nonce: str, writer_grace: float = 25.0,
                   session: dict | None = None) -> dict:
    """Reattaches and asks the session to prove it is the same one.

    Three separate questions, because each fails differently:
      detached_output — did the numbered output produced with nobody attached come
                  back, each line exactly once? Content AND interval, never
                  "something showed up".
      nonce     — is the non-exported variable still there, and still NOT in
                  the environment? The second half is what rules out a
                  replacement shell that was handed the value.
      responds  — does the session still answer? A process can be alive and
                  wedged, and identity would call that survival.
    """
    # The writer emits one line every 0.2 s, so a short absence can end before
    # it finished. Waiting for it is honest; failing it for arriving late
    # would be the instrument blaming the product for the instrument's clock.
    deadline = time.time() + writer_grace
    seen = ""
    while True:
        # A fresh challenge per attempt cannot be satisfied by full replay of
        # an earlier successful probe. Tie the nonce response to it as well.
        challenge = uuid.uuid4().hex
        seen = converse(port, token, conversation_id, [
            f"printf 'AFTER:{challenge}:%s\\n' \"$SOYEHT_PROBE_NONCE\"\n",
            f"env | /usr/bin/grep '^SOYEHT_PROBE_NONCE=' ; printf 'CHALLENGE:%s\\n' '{challenge}'\n",
        ], collect_secs=2.5, full_replay=True, session=session)
        if seen.count(f"ABSENT:{ABSENT_LINES:03d}") >= 1 or time.time() >= deadline:
            break
        time.sleep(1.0)

    counts = [seen.count(f"ABSENT:{n:03d}") for n in range(1, ABSENT_LINES + 1)]
    exactly_once = sum(1 for c in counts if c == 1)
    duplicated = sum(1 for c in counts if c > 1)
    return {
        "detached_output": (exactly_once == ABSENT_LINES and duplicated == 0,
                    f"{exactly_once}/{ABSENT_LINES} lines exactly once"
                    + (f", {duplicated} duplicated" if duplicated else "")),
        "nonce": (f"AFTER:{challenge}:{nonce}" in seen and f"SOYEHT_PROBE_NONCE={nonce}" not in seen,
                  "in-memory variable survived and is still not exported"
                  if f"AFTER:{challenge}:{nonce}" in seen else "the variable is gone"),
        "responds": (f"CHALLENGE:{challenge}" in seen,
                     "answered after reattach" if f"CHALLENGE:{challenge}" in seen
                     else "no answer — alive is not the same as working"),
    }



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


def compare(before: SessionSnapshot, after: SessionSnapshot | None,
            behaviour: dict | None = None) -> dict:
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

    for name, (ok, detail) in (behaviour or {}).items():
        checks[name] = (ok, detail)

    executed = [ok for ok, _ in checks.values() if ok is not None]
    survived = bool(executed) and all(executed)
    # `identity_only` was True for as long as this probe could photograph a
    # process and nothing else. Identity alone cannot tell THE SAME session
    # from one re-created convincingly — same argv, same cwd, a fresh PID that
    # happens to look right. The behaviour checks are what close that, so the
    # flag now reports whether they actually ran instead of being a constant.
    return {"survived": survived, "checks": checks,
            "identity_only": not behaviour}


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
    current = process_identity(engine["pid"])
    if (current is None or current["start"] != engine["start"]
            or DEV_ENGINE_PATH_FRAGMENT not in current.get("command", "")):
        sys.exit("refused: the Dev engine changed identity while the probe was arming")
    if mode == "kickstart":
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
    if port != DEV_ADMIN_PORT:
        sys.exit("refused: this installed-service probe accepts only Dev admin port 8902")


def run(args) -> int:
    guard_not_production(args.port)
    if os.path.realpath(args.state_dir) != os.path.realpath(DEV_STATE_DIR):
        sys.exit("refused: bootstrap credentials must come from the Dev profile")
    if not 1 <= args.sessions <= 8:
        sys.exit("refused: use between one and eight disposable probe sessions")
    token = read_token(args.state_dir)
    engine = Engine(args.port, token, args.backend)

    engine_before = engine_identity(DEV_ENGINE_PATH_FRAGMENT)
    if not engine_before:
        sys.exit("the Dev engine is not running")
    engine_pid = engine_before["pid"]
    print(f"Dev engine pid={engine_pid} start={engine_before['start']}")
    if args.failure_mode != "none":
        existing = engine._call("GET", "/api/v1/terminals/local")
        if not isinstance(existing.get("data"), list):
            sys.exit("refused: could not inventory existing Dev sessions")
        if existing["data"]:
            sys.exit("refused: restarting this Dev engine could affect terminals not created by the probe")

    created: list[tuple[str, SessionSnapshot]] = []
    armed_count = 0
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
            armed = arm_session(args.port, token, conversation, nonce, session=response)
            armed_count += 1 if armed else 0
            created.append((conversation, snapshot))
            print(f"  session {index}: pid={snapshot.shell['pid']} tty={tty}"
                  f" armed={'yes' if armed else 'NO'}")
            if not armed:
                print("    the marks could not be placed — this session will be "
                      "judged on identity alone, which cannot prove survival")

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
            behaviour = None
            if after is not None:
                try:
                    behaviour = verify_session(args.port, token, conversation,
                                               before.nonce, session=engine.created[conversation])
                except Exception as error:
                    # Not being able to ASK is not the same as a bad answer,
                    # and reporting it as survival is the exact failure this
                    # whole file exists to stop.
                    behaviour = {"responds": (False, f"could not reattach: {error}")}
            verdict = compare(before, after, behaviour)
            survivors += 1 if verdict["survived"] else 0
            results.append({"conversation_id": conversation, **verdict})

        print("\n─── RESULT ───")
        print(f"engine before: pid={engine_before['pid']} start={engine_before['start']}")
        if engine_after:
            print(f"engine after:  pid={engine_after['pid']} start={engine_after['start']}")
            same = engine_after["pid"] == engine_before["pid"]
            print("  positive control: engine left running" if args.failure_mode == "none"
                  else "  the engine was " + ("NOT swapped (invalid control!)" if same else "swapped ✓"))
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
        valid = observed == "replaced" or args.failure_mode == "none"
        if not valid:
            print(f"\nVERDICT INVALID — the failure was not provoked "
                  f"(observed: {observed}). No survival number means anything here.")
        else:
            print(f"\nsurvival: {survivors}/{len(created)} ({percentage:.0f}%)")
        measured = sorted({name for item in results
                           for name in item["checks"]
                           if name in ("detached_output", "nonce", "responds")})
        if measured:
            print("scope: identity AND behaviour — " + ", ".join(measured)
                  + ". Still not measured: a TUI and a separate long-running "
                    "process alongside the shell, or numbered output produced "
                    "specifically while the ENGINE is absent.")
        elif armed_count:
            # The marks WERE placed; there was simply nothing left to ask.
            # Saying "could not be placed" here would blame the instrument for
            # a death it measured correctly — and that sentence is what a
            # reader would use to dismiss the number.
            print(f"scope: behaviour marks were armed on {armed_count} "
                  "session(s) and none survived to answer. The 0% is a real "
                  "measurement, not a missing instrument.")
        else:
            print("scope: IDENTITY only — the behaviour marks could not be "
                  "placed, so nothing here separates the same session from "
                  "one convincingly re-created")

        if args.json_out:
            with open(args.json_out, "w", encoding="utf-8") as handle:
                json.dump({"valid": valid,
                           "failure_observed": observed,
                           "scope": "identity_and_detached_output" if measured else "identity_only",
                           "engine_absence_output_proven": False,
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
        for conversation in engine.created:
            engine.delete_terminal(conversation)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sessions", type=int, default=3)
    parser.add_argument("--backend", choices=["legacy", "supervisor"], default="legacy",
                        help="explicit backend under test; never falls back after a supervisor error")
    parser.add_argument("--port", type=int, default=DEV_ADMIN_PORT)
    parser.add_argument("--state-dir", default=DEV_STATE_DIR)
    parser.add_argument("--failure-mode", choices=["none", "kickstart", "sigkill"],
                        default="none",
                        help="how to provoke the failure; the target is verified first")
    parser.add_argument("--absence-budget", type=float, default=60.0,
                        help="seconds to wait for the engine to change identity")
    parser.add_argument("--json-out")
    return run(parser.parse_args())


if __name__ == "__main__":
    sys.exit(main())
