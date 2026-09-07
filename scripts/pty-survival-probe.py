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
  - PGID and the foreground process group for job control. The macOS `sess`
    field is diagnostic only; it cannot establish session identity.
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

CURRENT SCOPE: shell identity, the long job and the TUI each with their own
pid/start/tty/pgid, a non-exported nonce, a fresh challenge after reattaching,
and numbered output released ONLY after the engine was proven gone by process
and by port.

WHAT IT STILL DOES NOT PROVE: continuous observation between OS samples, or
installed-supervisor survival before a real run. The absence gate requires all
writer DONE sentinels while every sampled PID/port check still reports absence;
replay then checks each numbered line. `--failure-mode supervisor` refuses until
a supervisor is installed. The Rust `exercise_process_survival` harness is a
reference for load and ordering; this probe inherits no proof from it.
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
DEV_SUPERVISOR_LABEL = "com.soyeht.ptyd.dev"
DEV_SUPERVISOR_PATH_FRAGMENT = "SoyehtDev/engine/soyeht-ptyd"


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
    if output.returncode == 1 and not line and not output.stderr.strip():
        return None
    if output.returncode != 0 or not line:
        raise Unqueryable("ps could not establish process identity")
    parts = line.split(None, 5)
    if len(parts) < 6:
        raise Unqueryable("ps returned an incomplete process identity")
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


class Unqueryable(RuntimeError):
    """The operating system could not be consulted.

    This exists because "I could not look" and "there is nothing there" are the
    same value in every convenient API — `ps` printing nothing, `connect_ex`
    returning a non-zero errno, `launchctl` exiting non-zero. Collapsing them
    is how a probe manufactures an absence it never observed, and an absence
    fabricated that way would be laundered straight into "your sessions kept
    writing while the engine was gone". [jaime] required this separation.
    """


def port_accepts(port: int) -> bool:
    """Does anything ACCEPT on this port right now?

    A dead process is not the same as a free port, and neither alone proves the
    engine is gone: `ps` can miss the instant between exec and exit, and a
    listening socket can outlive the process that owned it. Raises Unqueryable
    when the answer is neither "connected" nor "refused".
    """
    import errno as errno_module
    import socket
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.settimeout(0.4)
        code = probe.connect_ex(("127.0.0.1", port))
    if code == 0:
        return True
    if code == errno_module.ECONNREFUSED:
        return False
    # EMFILE, EHOSTUNREACH, a timeout — none of these mean the port is free.
    raise Unqueryable(f"port {port} answered errno {code} "
                      f"({errno_module.errorcode.get(code, '?')}), which is not a refusal")


def engine_absent(port: int) -> tuple[bool, str]:
    """True only when no engine process exists AND the port actively refuses.

    Raises Unqueryable rather than returning True when the system could not be
    asked. Callers must let that propagate: an absence is a positive
    observation, never the absence of an observation.
    """
    try:
        identity = engine_identity(DEV_ENGINE_PATH_FRAGMENT)
    except (subprocess.CalledProcessError, OSError) as error:
        raise Unqueryable(f"ps could not be consulted: {error}") from error
    listening = port_accepts(port)
    if identity is not None:
        return False, f"engine pid={identity['pid']} still present"
    if listening:
        return False, f"port {port} still accepts connections"
    return True, f"no engine process and port {port} refused"


def label_loaded(label: str) -> bool:
    """Is the launchd label still registered in this user's domain?

    Raises Unqueryable when launchctl fails for a reason other than the label
    being missing, so "the tool broke" cannot be read as "the job is gone".
    """
    result = subprocess.run(
        ["/bin/launchctl", "print", f"user/{os.getuid()}/{label}"],
        capture_output=True, text=True, check=False)
    if result.returncode == 0:
        return True
    lines = (result.stdout + result.stderr).splitlines()
    expected = f'Could not find service "{label}" in domain for uid: {os.getuid()}'
    if result.returncode == 113 and expected in [line.strip() for line in lines]:
        return False
    raise Unqueryable(f"launchctl print exited {result.returncode}: "
                      f"{(result.stderr or result.stdout).strip()[:120]!r}")


def executable_path(pid: int) -> str | None:
    """Read the executing image path from the kernel, not an argv substring."""
    import ctypes
    import errno
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    query = library.proc_pidpath
    query.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    query.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    if query(pid, buffer, len(buffer)) <= 0:
        code = ctypes.get_errno()
        if code == errno.ESRCH:
            return None
        raise Unqueryable(f"kernel executable path unavailable (errno {code})")
    return os.fsdecode(buffer.value)


def engine_identity(path_fragment: str) -> dict | None:
    """A unique launchd child executing this image, without transient fallback.

    ps command text narrows candidates only. The kernel path must match the
    binary itself: wrappers mentioning it and similarly named siblings are not
    engines. A transient --contract process cannot stand in for the daemon.
    Ambiguity or inability to inspect a candidate does not prove absence.
    """
    candidates = []
    for row in ps_rows("pid=,command="):
        if len(row) < 2 or path_fragment not in row[1]:
            continue
        pid = int(row[0])
        before = process_identity(pid)
        if before is None:
            continue
        path = executable_path(pid)
        if path is None or not path.endswith("/" + path_fragment):
            continue
        after = process_identity(pid)
        if after is None or before != after:
            raise Unqueryable("candidate changed during executable identity observation")
        candidates.append(after)
    if not candidates:
        return None
    daemons = [identity for identity in candidates if identity.get("ppid") == 1]
    if len(daemons) != 1:
        raise Unqueryable("no unique launchd-owned daemon among matching executable paths")
    return daemons[0]


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
                job_tag: str, release_path: str, done_path: str,
                session: dict | None = None) -> bool:
    """Puts the marks in the session that a re-created one could not carry.

    - the nonce lives in a variable that is NOT exported, so it exists only in
      THIS shell's memory: a replacement shell cannot inherit it and a recovery
      script cannot re-derive it;
    - `stty -echo` first, so the nonce is never echoed into the log where a
      later replay could hand it back to us;
    - a LONG-RUNNING job in the background, launched with `exec -a` so it
      carries a tag unique to this session in its argv. `ps` can then find it
      without the shell telling us its pid — the shell is the subject here,
      and a subject that names its own witnesses is a weaker witness;
    - a numbered writer that BLOCKS on a release file, and drops a DONE
      sentinel once the LAST line is out. The release file is created by the
      probe only after the engine is proven absent by process AND by port, and
      the probe then keeps the engine away until every DONE exists. Without
      that sentinel the probe released the writers inside a two-second window
      and let the remaining ~10s of output land after the engine was back,
      while still reporting the whole interval as proven. [jaime] found that:
      an earlier version started writing at arming time and proved output with
      nobody ATTACHED, and this one proved only the first fraction of it.
    """
    marker = converse(port, token, conversation_id, [
        "stty -echo\n",
        f"SOYEHT_PROBE_NONCE='{nonce}'; export -n SOYEHT_PROBE_NONCE\n",
        "printf 'ARMED:%s\\n' \"$SOYEHT_PROBE_NONCE\"\n",
        f"( exec -a {job_tag} /bin/sleep 999999 ) &\n",
        # Bounded wait: if the probe dies before releasing, this subshell must
        # not spin on this Mac forever. 900 * 0.2s = three minutes.
        f"( for w in $(seq 1 900); do [ -f '{release_path}' ] && break; sleep 0.2; done; "
        # Measured in a local PTY: 64 lines take ~11.7s wall clock, because
        # each iteration pays for a `sleep` process, not 0.05s. `writer_grace`
        # below must stay comfortably above that or the instrument fails a
        # session that was merely still writing.
        f"for n in $(seq 1 {ABSENT_LINES}); do printf 'ABSENT:%03d\\n' \"$n\"; "
        f"sleep 0.05; done; printf 'done\\n' > '{done_path}' ) &\n",
    ], collect_secs=1.5, session=session)
    return f"ARMED:{nonce}" in marker


TUI_LINES = 400


def arm_tui_session(port: int, token: str, conversation_id: str, tui_token: str,
                    session: dict | None = None) -> str | None:
    """Opens a full-screen program that OWNS the terminal, and returns its path.

    A shell with background jobs is not a TUI. What a TUI adds is a process in
    raw mode holding the tty's foreground process group — the state a user
    actually loses when a pane dies with vim open. `less` is used because it
    draws once and then stays quiet: a chatty program (`top -l 0`) would bury
    every other marker in this file under its own redraws.

    The file is written with a token unique to this run, and the last line is
    deliberately BELOW the first screen so it has never been rendered. That is
    what makes the post-failure `G` a real question: the answer is bytes the
    session could not have emitted before.
    """
    path = f"/tmp/soyeht-probe-tui-{tui_token}.txt"
    marker = converse(port, token, conversation_id, [
        "stty -echo\n",
        f"/usr/bin/seq 1 {TUI_LINES} | "
        f"/usr/bin/awk '{{ printf \"TUI:{tui_token}:%03d\\n\", $1 }}' > '{path}'\n",
        f"printf 'TUIFILE:%s\\n' '{path}'\n",
        f"/usr/bin/less -X '{path}'\n",
    ], collect_secs=2.0, session=session)
    return path if f"TUIFILE:{path}" in marker else None


def verify_session(port: int, token: str, conversation_id: str,
                   nonce: str, writer_grace: float = 25.0,
                   session: dict | None = None, released: bool = True) -> dict:
    """Reattaches and asks the session to prove it is the same one.

    Three separate questions, because each fails differently:
      absence_output — the numbered output, released only after the engine was
                  proven gone by process AND by port, each line exactly once.
                  NOT RUN when no absence could be opened: an unopened window
                  is a limit of the instrument, not a death of the session.
      nonce     — is the non-exported variable still there, and still NOT in
                  the environment? The second half is what rules out a
                  replacement shell that was handed the value.
      responds  — does the session still answer? A process can be alive and
                  wedged, and identity would call that survival.
    """
    # The writer emits one line every 0.2 s, so a short absence can end before
    # it finished. Waiting for it is honest; failing it for arriving late
    # would be the instrument blaming the product for the instrument's clock.
    deadline = time.time() + (writer_grace if released else 0.0)
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
    # When the probe never managed to prove an absence, the writers were never
    # released and there is nothing to judge. Calling that a FAILURE would
    # blame the product for a window the instrument could not open — the same
    # confusion, pointed the other way, that this file exists to prevent.
    absence_output = (
        (None, "NOT RUN — no proven engine absence, so the writer never started")
        if not released else
        (exactly_once == ABSENT_LINES and duplicated == 0,
         f"{exactly_once}/{ABSENT_LINES} lines exactly once"
         + (f", {duplicated} duplicated" if duplicated else "")))
    return {
        "absence_output": absence_output,
        "nonce": (f"AFTER:{challenge}:{nonce}" in seen and f"SOYEHT_PROBE_NONCE={nonce}" not in seen,
                  "in-memory variable survived and is still not exported"
                  if f"AFTER:{challenge}:{nonce}" in seen else "the variable is gone"),
        "responds": (f"CHALLENGE:{challenge}" in seen,
                     "answered after reattach" if f"CHALLENGE:{challenge}" in seen
                     else "no answer — alive is not the same as working"),
    }


def verify_tui_session(port: int, token: str, conversation_id: str,
                       tui_token: str, session: dict | None = None) -> dict:
    """Asks the full-screen program to render something it never rendered.

    `G` jumps to the end of the file. The last line was below the first screen
    at arming time, so its token cannot come from a replay of anything the
    session emitted earlier — the only way those bytes exist is that `less` was
    alive, still in raw mode, and still reading this terminal after the failure.

    What this does NOT prove: that the answer is unique per attempt. Repeating
    `G` produces the same bytes, so this question distinguishes "responded
    after the failure" from "was never asked", not one attempt from another.
    The per-attempt uniqueness lives in the shell challenge, and the absence
    window is evidenced separately by the release-gated numbered output.
    """
    last = f"TUI:{tui_token}:{TUI_LINES:03d}"
    seen = converse(port, token, conversation_id, ["G"],
                    collect_secs=2.5, full_replay=True, session=session)
    return {"tui_responds": (last in seen,
                             f"rendered {last} on reattach" if last in seen
                             else f"never rendered {last} — a drawn screen is not a live program")}


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
    # "shell" or "tui" — a TUI session has no shell to answer questions, so it
    # is judged on the full-screen program instead of on background marks.
    role: str = "shell"
    job_tag: str = ""
    tui_token: str = ""
    owned_by_supervisor: bool = False
    # role name -> identity from `ps`. Each of these carries its OWN pid, start,
    # tty and pgid, because "the session survived" said of the shell alone says
    # nothing about the job the person left running inside it.
    tracked: dict = field(default_factory=dict)

    def identity_key(self) -> tuple:
        """What must be identical for the session to be THE SAME one."""
        shell = self.shell or {}
        return (shell.get("pid"), shell.get("start"), self.tty)


def first_snapshot(owner_pids: list[int], conversation_id: str, tty: str,
                   nonce: str, role: str = "shell", job_tag: str = "",
                   tui_token: str = "") -> SessionSnapshot:
    """First photograph: find the shell by its OWNER and RECORD its identity.

    The owner is not always the engine. Under the supervisor backend the shell
    is forked by `soyeht-ptyd` — that is the entire point of the supervisor,
    since a shell parented to the engine dies with it. An earlier version
    matched `ppid == engine_pid` only, so against the very backend this probe
    exists to measure it would have found no shell at all, printed "no shell
    found on /dev/ttysNNN" and measured nothing. Same shape as the defect
    [jaime] found in `resnapshot`: the instrument blind exactly where the
    product is supposed to work.
    """
    snapshot = SessionSnapshot(conversation_id=conversation_id, nonce=nonce, tty=tty,
                               role=role, job_tag=job_tag, tui_token=tui_token)
    owners = set(owner_pids)
    for identity in processes_on_tty(tty):
        if identity["ppid"] in owners and snapshot.shell is None:
            snapshot.shell = identity
        elif snapshot.shell and identity["ppid"] == snapshot.shell["pid"]:
            snapshot.children.append(identity)
    snapshot.foreground_pgid = foreground_pgid(tty)
    # The OBSERVED parent, not the one that was assumed. Writing the engine's
    # pid here regardless of what `ps` said would make the later parentage
    # comparison a statement about this probe's expectations.
    snapshot.parent_pid = snapshot.shell["ppid"] if snapshot.shell else None
    snapshot.tracked = tracked_roles(tty, job_tag, tui_token)
    return snapshot


def tracked_roles(tty: str, job_tag: str, tui_token: str) -> dict:
    """The long job and the TUI, found in `ps` by what they carry in argv.

    Neither is located through the shell or through the engine's own listing:
    the tag was placed with `exec -a` and the TUI names its file on the command
    line, so both are visible to the operating system without the subject of
    the test being asked to identify its own children.
    """
    found: dict = {}
    for identity in processes_on_tty(tty):
        command = identity.get("command", "")
        if job_tag and command.startswith(job_tag) and "job" not in found:
            found["job"] = identity
        if tui_token and f"soyeht-probe-tui-{tui_token}.txt" in command and "tui" not in found:
            found["tui"] = identity
    return found


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
    snapshot.role = before.role
    snapshot.job_tag = before.job_tag
    snapshot.tui_token = before.tui_token
    snapshot.owned_by_supervisor = before.owned_by_supervisor
    # Look each tracked process up by the PID recorded before the failure, the
    # same way the shell is looked up: searching by tag again would happily
    # find a REPLACEMENT wearing the same argv.
    for name, recorded in before.tracked.items():
        current = process_identity(recorded["pid"])
        if current:
            snapshot.tracked[name] = current
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

    # The release-gated writer is a backgrounded subshell that EXITS as soon as
    # it has emitted line 064 — which `absence_output` above exists to prove it
    # did. Counting it as a lost child made the instrument contradict itself:
    # one check demanded the writer finish, the next condemned the session for
    # the writer having finished. Measured on the first real bootout, where all
    # three sessions were intact and two were reported DIED for this alone.
    #
    # Every child this probe creates on purpose is a tracked role, so the
    # untracked ones are transient by construction and are excluded here. They
    # are identified from `ps`, not from the shell naming its own children.
    tracked_pids = {identity["pid"] for identity in before.tracked.values()}
    before_children = {
        (child["command"].split()[0] if child["command"] else "?"):
            (child["pid"], child["start"]) for child in before.children
        if child["pid"] in tracked_pids
    }
    after_children = {
        (child["command"].split()[0] if child["command"] else "?"):
            (child["pid"], child["start"]) for child in after.children
        if child["pid"] in {identity["pid"] for identity in after.tracked.values()}
    }
    missing = [name for name in before_children if name not in after_children]
    changed = [name for name, identity in before_children.items()
               if name in after_children and after_children[name] != identity]
    if not before_children:
        # Zero children passing as "preserved" is an empty guard: it would stay
        # green forever because there was never anything to preserve. With no
        # fixture the result is NOT RUN, and that has to show in the report.
        checks["children_preserved"] = (
            None, "NOT RUN — no long-lived child in the fixture "
                  "(the numbered writer is expected to exit; see absence_output)")
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
        + ("(the shell was owned by the supervisor; the same owner after a swap "
           "is what continuity looks like)" if before.owned_by_supervisor else
           "(owned by the engine, so this cannot survive an engine swap; "
           "informative until the supervisor owns the session)"),
    )

    # Each tracked process is judged on its own pid, start, tty and PGID. The
    # PGID is the part that matters for a job: a process can be alive with its
    # process group dissolved, and then job control is gone even though `ps`
    # still lists it. A role that was never armed is NOT RUN, never a pass.
    for name in ("job", "tui"):
        recorded = before.tracked.get(name)
        if recorded is None:
            checks[f"{name}_preserved"] = (None, f"NOT RUN — no {name} in this fixture")
            continue
        current = after.tracked.get(name)
        if current is None:
            checks[f"{name}_preserved"] = (False, f"pid {recorded['pid']} is gone")
            continue
        same = (current["start"] == recorded["start"]
                and current["pgid"] == recorded["pgid"]
                and current["tty"] == recorded["tty"])
        checks[f"{name}_preserved"] = (
            same,
            f"pid={recorded['pid']} start={'same' if current['start'] == recorded['start'] else 'CHANGED'} "
            f"pgid={recorded['pgid']}->{current['pgid']} tty={recorded['tty']}->{current['tty']}")

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
    label = f"user/{os.getuid()}/{DEV_ENGINE_LABEL}"
    if mode == "kickstart":
        # The name says what the command IS. `kickstart -k` kills and restarts
        # in one step, so launchd may have the successor up before this probe
        # can observe any gap: it is a REPLACEMENT, never a window of absence.
        # It was once offered under the name `bootout`, which promised a
        # removal it never performed. [jaime] caught that.
        subprocess.run(["/bin/launchctl", "kickstart", "-k", label], check=False)
    elif mode == "sigkill":
        os.kill(engine["pid"], 9)
    elif mode == "bootout":
        subprocess.run(["/bin/launchctl", "bootout", label], check=False)
        # Only a command that actually removed the label may keep this name.
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                if not label_loaded(DEV_ENGINE_LABEL):
                    break
            except Unqueryable as error:
                sys.exit(f"refused to call this bootout: launchctl could not be "
                         f"consulted ({error}). Not knowing is not removal.")
            time.sleep(0.25)
        try:
            still_loaded = label_loaded(DEV_ENGINE_LABEL)
        except Unqueryable as error:
            sys.exit(f"refused to call this bootout: launchctl could not be "
                     f"consulted ({error}). Not knowing is not removal.")
        if still_loaded:
            sys.exit("refused to call this bootout: the label is still loaded "
                     f"({label}). A mode that does not remove the job must not "
                     "be reported as one that did.")
    elif mode == "supervisor":
        # Calibration, not a swap: kill the component that OWNS the sessions,
        # under the same load. If the sessions survive this too, the instrument
        # is not measuring survival — it is incapable of seeing death.
        supervisor = engine_identity(DEV_SUPERVISOR_PATH_FRAGMENT)
        if supervisor is None:
            sys.exit("refused: no Dev supervisor is running, so killing it "
                     "cannot calibrate anything. Run this mode once the "
                     "supervisor is installed.")
        os.kill(supervisor["pid"], 9)
    else:
        sys.exit(f"unknown failure mode: {mode}")


def restore_engine() -> str:
    """Puts the Dev engine back after a mode that removed it.

    A probe that leaves the owner's Dev broken has cost more than it measured.
    """
    label = f"user/{os.getuid()}/{DEV_ENGINE_LABEL}"
    plist = os.path.expanduser(f"~/Library/LaunchAgents/{DEV_ENGINE_LABEL}.plist")
    try:
        loaded = label_loaded(DEV_ENGINE_LABEL)
    except Unqueryable:
        # Bootstrapping an already-loaded job is harmless; not bootstrapping a
        # removed one is not. When in doubt, try.
        loaded = False
    if not loaded:
        if not os.path.exists(plist):
            return f"could NOT restore: {plist} is missing"
        subprocess.run(["/bin/launchctl", "bootstrap", f"user/{os.getuid()}", plist],
                       check=False, capture_output=True)
    subprocess.run(["/bin/launchctl", "kickstart", label], check=False, capture_output=True)
    deadline = time.time() + 30
    while time.time() < deadline:
        try:
            if engine_identity(DEV_ENGINE_PATH_FRAGMENT):
                return "restored"
        except (subprocess.CalledProcessError, OSError):
            pass  # keep trying; a transient ps failure is not a verdict
        time.sleep(0.5)
    return "could NOT restore: the engine did not come back within 30s"


def release_during_absence(port: int, release_path: str, done_paths: list[str],
                           budget: float, max_hold: float) -> dict:
    """Opens a REAL absence window and holds it until every writer has finished.

    The proof this function must produce is "the session emitted all 64 lines
    while nothing was serving". That requires three things, and the first
    version delivered only the first:

      1. release the writers only while the engine is provably gone;
      2. keep it gone until every writer's DONE sentinel exists;
      3. refuse the proof if the engine came back, or if the system could not
         be consulted, at ANY point in between.

    The earlier version slept a fixed two seconds and returned
    verified_absent=True even when the engine had already returned — a green
    that asserted an interval it had not watched. [jaime] found both halves.
    """
    deadline = time.time() + budget
    while time.time() < deadline:
        try:
            absent, reason = engine_absent(port)
        except Unqueryable as error:
            return {"released": False, "verified_absent": False,
                    "detail": f"refusing to call this an absence: {error}"}
        if not absent:
            time.sleep(0.2)
            continue

        with open(release_path, "w", encoding="utf-8") as handle:
            handle.write(f"{time.time()}\n")
        opened = time.time()
        hold_deadline = opened + max_hold
        # From here the engine must STAY gone. Any return, or any moment the
        # system cannot be asked, ends the proof — it does not end the run.
        while time.time() < hold_deadline:
            try:
                still, why = engine_absent(port)
            except Unqueryable as error:
                return {"released": True, "verified_absent": False,
                        "held_absent_secs": time.time() - opened,
                        "detail": f"released, then the system stopped answering: {error}"}
            if not still:
                return {"released": True, "verified_absent": False,
                        "held_absent_secs": time.time() - opened,
                        "detail": f"released, but the engine returned before every writer "
                                  f"finished ({why})"}
            missing = [path for path in done_paths if not os.path.exists(path)]
            if not missing:
                return {"released": True, "verified_absent": True,
                        "held_absent_secs": time.time() - opened,
                        "writers_finished": len(done_paths),
                        "detail": f"{reason}; every writer finished inside the absence "
                                  f"({time.time() - opened:.1f}s, {len(done_paths)} writer(s))"}
            time.sleep(0.2)
        return {"released": True, "verified_absent": False,
                "held_absent_secs": time.time() - opened,
                "detail": f"released, but {len(done_paths) - len([p for p in done_paths if os.path.exists(p)])}"
                          f" writer(s) had not finished within {max_hold:.0f}s"}
    return {"released": False, "verified_absent": False,
            "detail": "the engine was never both gone and silent on the port"}


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
    supervisor_before = engine_identity(DEV_SUPERVISOR_PATH_FRAGMENT)
    # Either process can be the shell's parent, depending on the backend under
    # test. Both are offered; which one actually appears is recorded, not assumed.
    owner_pids = [engine_pid] + ([supervisor_before["pid"]] if supervisor_before else [])
    print(f"Dev engine pid={engine_pid} start={engine_before['start']}")
    print("Dev supervisor " + (f"pid={supervisor_before['pid']}" if supervisor_before
                               else "not running (sessions will be owned by the engine)"))
    if args.failure_mode != "none":
        existing = engine._call("GET", "/api/v1/terminals/local")
        if not isinstance(existing.get("data"), list):
            sys.exit("refused: could not inventory existing Dev sessions")
        if existing["data"]:
            sys.exit("refused: restarting this Dev engine could affect terminals not created by the probe")

    created: list[tuple[str, SessionSnapshot]] = []
    armed_count = 0
    release_path = f"/tmp/soyeht-probe-release-{uuid.uuid4().hex}"
    done_paths: list[str] = []
    tui_files: list[str] = []
    # Set before attempting bootout, so the `finally` below puts the
    # engine back even if this probe raises, times out or is interrupted. A
    # measurement that leaves the owner's Dev removed has cost more than it
    # measured. [jaime]
    engine_removed_by_probe = False
    try:
        for index in range(args.sessions):
            conversation = f"ptyprobe-{uuid.uuid4()}"
            nonce = uuid.uuid4().hex
            job_tag = f"soyeht-probe-job-{uuid.uuid4().hex[:12]}"
            done_path = f"/tmp/soyeht-probe-done-{uuid.uuid4().hex}"
            response = engine.create_terminal(conversation, ["/bin/bash", "-i"])
            tty = response.get("slave_tty_path", "")
            if not tty:
                print(f"  session {index}: no TTY in the response, skipping")
                continue
            time.sleep(1.5)
            armed = arm_session(args.port, token, conversation, nonce,
                                job_tag, release_path, done_path, session=response)
            if armed:
                # Only an armed writer can ever drop its sentinel; waiting on
                # one that was never placed would hold the engine down for the
                # full budget and then blame the product for the silence.
                done_paths.append(done_path)
            # The photograph comes AFTER arming: the long job and the TUI do
            # not exist until then, and a first snapshot taken before them
            # would record a fixture with nothing to preserve — the empty
            # guard this file already had to remove once.
            time.sleep(0.8)
            snapshot = first_snapshot(owner_pids, conversation, tty, nonce,
                                      role="shell", job_tag=job_tag)
            snapshot.owned_by_supervisor = (supervisor_before is not None
                                            and snapshot.parent_pid == supervisor_before["pid"])
            if snapshot.shell is None:
                print(f"  session {index}: no shell found on {tty}")
                continue
            armed_count += 1 if armed else 0
            created.append((conversation, snapshot))
            print(f"  session {index}: pid={snapshot.shell['pid']} tty={tty}"
                  f" owner={'supervisor' if snapshot.owned_by_supervisor else 'engine'}"
                  f" job={'yes' if 'job' in snapshot.tracked else 'NO'}"
                  f" armed={'yes' if armed else 'NO'}")
            if not armed:
                print("    the marks could not be placed — this session will be "
                      "judged on identity alone, which cannot prove survival")

        if args.tui:
            conversation = f"ptyprobe-tui-{uuid.uuid4()}"
            tui_token = uuid.uuid4().hex[:12]
            response = engine.create_terminal(conversation, ["/bin/bash", "-i"])
            tty = response.get("slave_tty_path", "")
            if tty:
                time.sleep(1.5)
                path = arm_tui_session(args.port, token, conversation, tui_token,
                                       session=response)
                time.sleep(1.0)
                snapshot = first_snapshot(owner_pids, conversation, tty, "",
                                          role="tui", tui_token=tui_token)
                snapshot.owned_by_supervisor = (supervisor_before is not None
                                                and snapshot.parent_pid == supervisor_before["pid"])
                if snapshot.shell is not None and path:
                    tui_files.append(path)
                    created.append((conversation, snapshot))
                    print(f"  tui session: pid={snapshot.shell['pid']} tty={tty}"
                          f" less={'yes' if 'tui' in snapshot.tracked else 'NO'}"
                          f" fg_pgid={snapshot.foreground_pgid}")
                else:
                    print("  tui session: could not be armed — not counted")

        if not created:
            sys.exit("no session was created — nothing to measure")

        print(f"\n{len(created)} session(s) created.")

        observed = "unchanged"
        release = {"released": False, "verified_absent": False,
                   "detail": "no failure provoked, so no absence to open"}
        if args.failure_mode == "kill-shell":
            # The instrument has to be shown capable of REPORTING DEATH, and
            # the positive control cannot show that: it only proves the probe
            # does not condemn a healthy session. This mode kills nothing but
            # the shells this run created, so it needs no service restart and
            # no permission to disturb anyone's Dev.
            #
            # It is a PROXY for the supervisor calibration, not that
            # calibration: it kills the session directly instead of killing the
            # component that owns it under the same load.
            for _, snapshot in created:
                if snapshot.shell:
                    print(f"  calibration: killing probe shell pid={snapshot.shell['pid']}")
                    try:
                        os.kill(snapshot.shell["pid"], 9)
                    except OSError as error:
                        print(f"    could not kill it: {error}")
            time.sleep(2.0)
            observed = "replaced"  # nothing about the engine changed, and the
            # verdict below is about the sessions, which is what this mode asks.
        elif args.failure_mode != "none":
            # The probe provokes the failure itself and WAITS for evidence that
            # it happened. The first version asked for Enter, and run through a
            # pipe the Enter arrived instantly: I measured before the failure
            # and the "negative control" reported 100%. An instrument that
            # depends on human coordination measures the coordination, not the
            # system.
            print(f"provoking the failure: {args.failure_mode}")
            # Armed BEFORE the command, not after: provoke_failure exits when
            # a bootout did not remove the label, and an exit after a removal
            # that DID happen would skip the restore entirely.
            if args.failure_mode == "bootout":
                engine_removed_by_probe = True
            provoke_failure(args.failure_mode, engine_before)
            # The release must be attempted BEFORE the engine is put back:
            # once it is serving again there is no absence left to evidence.
            release = release_during_absence(args.port, release_path, done_paths,
                                             args.release_budget, args.absence_max_hold)
            print(f"  absence gate: {release['detail']}")
            if engine_removed_by_probe:
                restored = restore_engine()
                engine_removed_by_probe = restored != "restored"
                print(f"  restoring the Dev engine: {restored}")
            observed = wait_for_engine_change(engine_before, args.absence_budget)
            print({
                "replaced": "  failure confirmed: the engine changed identity",
                "absent": "  the engine VANISHED and did not return in time "
                          "(not the same as replaced)",
                "unchanged": "  the engine did NOT change — the failure never happened",
            }[observed])
        else:
            print("mode none: positive control, nothing is provoked")
            # With no failure there is no absence, so the writers stay blocked
            # and their check reports NOT RUN rather than a hollow pass.

        # measurement after the failure
        engine_after = engine_identity(DEV_ENGINE_PATH_FRAGMENT)
        results = []
        survivors = 0
        for conversation, before in created:
            after = resnapshot(before)
            behaviour = None
            if after is not None:
                try:
                    if before.role == "tui":
                        behaviour = verify_tui_session(
                            args.port, token, conversation, before.tui_token,
                            session=engine.created[conversation])
                    else:
                        behaviour = verify_session(
                            args.port, token, conversation, before.nonce,
                            session=engine.created[conversation],
                            released=release["released"])
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
            if args.failure_mode == "none":
                print("  positive control: engine left running")
            elif args.failure_mode in ("supervisor", "kill-shell"):
                # These modes deliberately leave the engine alone. Printing
                # "invalid control" here would condemn the run for doing
                # exactly what was asked of it.
                print("  calibration: the engine was left running on purpose"
                      + ("" if same else " — but its identity CHANGED, which this mode did not ask for"))
            else:
                print("  the engine was " + ("NOT swapped (invalid control!)" if same else "swapped ✓"))
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
        # `supervisor` is calibration: the engine is meant to stay put, so
        # "unchanged" is the CORRECT observation and the run is valid. What it
        # asserts is the opposite of the others — the sessions should die.
        if args.failure_mode in ("supervisor", "kill-shell"):
            valid = True
        if not valid:
            print(f"\nVERDICT INVALID — the failure was not provoked "
                  f"(observed: {observed}). No survival number means anything here.")
        else:
            print(f"\nsurvival: {survivors}/{len(created)} ({percentage:.0f}%)")
        measured = sorted({name for item in results
                           for name, (ok, _) in item["checks"].items()
                           if ok is not None
                           and name in ("absence_output", "nonce", "responds",
                                        "tui_responds", "job_preserved", "tui_preserved")})
        if measured:
            print("scope: identity AND behaviour — " + ", ".join(measured))
            if release.get("verified_absent"):
                print(f"       the numbered output was released inside a verified "
                      f"absence ({release['detail']})")
            else:
                print(f"       NO verified absence window: {release['detail']}. "
                      "Whatever survived here, it was not shown to have produced "
                      "output while the engine was gone.")
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
                           "scope": ("identity_and_behaviour" if measured
                                     else "identity_only"),
                           "measured_checks": measured,
                           "absence_gate": release,
                           "engine_absence_output_proven": bool(
                               release.get("verified_absent")
                               and any(item["checks"].get("absence_output", (None,))[0]
                                       for item in results)),
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
        if engine_removed_by_probe:
            # Reached when the probe threw, timed out or exited between the
            # bootout and the normal restore. The result is printed, never
            # swallowed: a silent failure here is the owner's Dev left dead.
            outcome = restore_engine()
            print(f"restoring the Dev engine after an interrupted run: {outcome}")
            if outcome != "restored":
                print("  THE DEV ENGINE IS STILL DOWN. Put it back with:\n"
                      f"  launchctl bootstrap user/{os.getuid()} "
                      f"~/Library/LaunchAgents/{DEV_ENGINE_LABEL}.plist")
        for conversation in engine.created:
            engine.delete_terminal(conversation)
        # The probe's own litter: the release gate, the DONE sentinels and the
        # TUI fixtures. The long jobs and writers die with their session's shell.
        for path in [release_path, *done_paths, *tui_files]:
            try:
                os.unlink(path)
            except OSError:
                pass


def self_test() -> int:
    """Proves the absence gate can still REFUSE. Touches no service.

    Every case here is a way this probe was already caught claiming an absence
    it had not watched. They are pinned because none of them is visible from
    using the tool normally: a run that reports "proven" looks identical
    whether or not the window was really held.
    """
    import tempfile

    original = globals()["engine_absent"]
    failures = 0
    with tempfile.TemporaryDirectory(prefix="probe-selftest-") as workdir:
        done_a = os.path.join(workdir, "a")
        done_b = os.path.join(workdir, "b")
        release = os.path.join(workdir, "release")

        def expect(name: str, condition: bool, detail: str) -> None:
            nonlocal failures
            print(f"  {'ok  ' if condition else 'CALIBRATION FAILED'} {name}: {detail[:74]}")
            failures += 0 if condition else 1

        try:
            # 1. The engine coming back before every writer finished must not
            #    be reported as a held window. This returned True regardless.
            steps = iter([(True, "gone")] * 3 + [(False, "engine pid=1 still present")] * 60)
            globals()["engine_absent"] = lambda port: next(steps)
            open(done_a, "w").write("x")
            result = release_during_absence(1, release, [done_a, done_b], 3, 5)
            expect("engine returned early", not result["verified_absent"], result["detail"])

            # 2. The positive case still has to pass, or the instrument is
            #    merely pessimistic instead of correct.
            globals()["engine_absent"] = lambda port: (True, "no engine and the port refused")
            open(done_b, "w").write("x")
            result = release_during_absence(1, release, [done_a, done_b], 3, 5)
            expect("every writer finished inside the window",
                   result["verified_absent"] and result.get("writers_finished") == 2,
                   result["detail"])

            # 3. Writers that never finish must time out, not hang the Dev.
            os.unlink(done_b)
            started = time.time()
            result = release_during_absence(1, release, [done_a, done_b], 3, 1.0)
            expect("writers never finished",
                   not result["verified_absent"] and time.time() - started < 4,
                   result["detail"])

            # 4 and 5. "I could not look" must never become "nothing is there",
            #    before the release and after it.
            def unqueryable(port):
                raise Unqueryable("simulated: the system could not be consulted")
            globals()["engine_absent"] = unqueryable
            result = release_during_absence(1, release, [done_a], 2, 2)
            expect("unqueryable before releasing",
                   not result["verified_absent"] and not result["released"], result["detail"])

            state = {"calls": 0}
            def flaky(port):
                state["calls"] += 1
                if state["calls"] == 1:
                    return (True, "gone")
                raise Unqueryable("simulated: stopped answering mid-window")
            globals()["engine_absent"] = flaky
            result = release_during_absence(1, release, [done_a, done_b], 2, 2)
            expect("unqueryable after releasing",
                   result["released"] and not result["verified_absent"], result["detail"])
        finally:
            globals()["engine_absent"] = original

    originals = {name: globals()[name] for name in ("ps_rows", "process_identity", "executable_path")}
    try:
        image = "/fixture/Library/Application Support/" + DEV_SUPERVISOR_PATH_FRAGMENT
        rows = [["1", image + " --contract"], ["2", "python mentions " + image], ["3", image + " --socket fixture"]]
        identities = {1: {"pid": 1, "ppid": 99}, 2: {"pid": 2, "ppid": 1}, 3: {"pid": 3, "ppid": 1}}
        paths = {1: image, 2: "/usr/bin/python3", 3: image}
        globals()["ps_rows"] = lambda fields: rows
        globals()["process_identity"] = lambda pid: identities.get(pid)
        globals()["executable_path"] = lambda pid: paths.get(pid)
        expect("kernel image beats argv mention and transient", engine_identity(DEV_SUPERVISOR_PATH_FRAGMENT) == identities[3], "only the actual launchd daemon qualifies")
        rows = rows[:1]
        try:
            engine_identity(DEV_SUPERVISOR_PATH_FRAGMENT)
            expect("transient alone refuses", False, "transient was adopted")
        except Unqueryable:
            expect("transient alone refuses", True, "no fallback to the first candidate")
        rows = [["2", image], ["3", image]]
        paths[2] = image
        try:
            engine_identity(DEV_SUPERVISOR_PATH_FRAGMENT)
            expect("two daemon candidates refuse", False, "ambiguous owner was selected")
        except Unqueryable:
            expect("two daemon candidates refuse", True, "ambiguity is not absence")
        rows = [["3", image + "-old"]]
        paths[3] = image + "-old"
        expect("similarly named image is different", engine_identity(DEV_SUPERVISOR_PATH_FRAGMENT) is None, "kernel path suffix must match exactly")
    finally:
        globals().update(originals)

    if failures:
        print(f"\n{failures} calibration case(s) failed. A 'proven absence' from "
              "this probe cannot be trusted until that is fixed.")
        return 1
    print("\ncalibration ok: the absence gate refuses an early return, a "
          "half-finished writer and a system it cannot consult.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sessions", type=int, default=3)
    parser.add_argument("--backend", choices=["legacy", "supervisor"], default="legacy",
                        help="explicit backend under test; never falls back after a supervisor error")
    parser.add_argument("--port", type=int, default=DEV_ADMIN_PORT)
    parser.add_argument("--state-dir", default=DEV_STATE_DIR)
    parser.add_argument("--failure-mode",
                        choices=["none", "kickstart", "sigkill", "bootout",
                                 "supervisor", "kill-shell"],
                        default="none",
                        help="how to provoke the failure; the target is verified first. "
                             "kickstart replaces without a gap; bootout removes the label "
                             "and refuses the name if it did not; supervisor is the "
                             "calibration that SHOULD kill the sessions; kill-shell "
                             "is the cheap calibration that kills only the probe's own "
                             "shells and touches no service at all")
    parser.add_argument("--tui", action="store_true",
                        help="add one session running a full-screen program that owns the tty")
    parser.add_argument("--absence-budget", type=float, default=60.0,
                        help="seconds to wait for the engine to change identity")
    parser.add_argument("--release-budget", type=float, default=15.0,
                        help="seconds to wait for a PROVEN absence before giving up on "
                             "releasing the numbered writers")
    parser.add_argument("--absence-max-hold", type=float, default=60.0,
                        help="upper bound on how long the engine is kept away after "
                             "releasing. The probe holds it until every writer's DONE "
                             "sentinel exists; this is only the ceiling, not a guess "
                             "about how long the writers take")
    parser.add_argument("--json-out")
    parser.add_argument("--self-test", action="store_true",
                        help="prove the absence gate can still refuse; touches nothing")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
