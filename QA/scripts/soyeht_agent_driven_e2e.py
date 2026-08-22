#!/usr/bin/env python3
"""Behavioral E2E for real coding agents collaborating through Soyeht MCP.

Unlike the protocol E2E, this runner does not open the child panes itself. It
starts real parent agents with raw user prompts, asks each parent in natural
language to open a named collaborator in an exact directory, and waits for a
round-trip MCP reply. The runner never impersonates a pane: read-only UI
automation uses explicit targets, while durable message evidence is read from
the persisted workspace snapshot. It independently observes pane identity,
live process argv and cwd; launch metadata alone is never accepted as proof.

The default ring is Codex -> OpenCode -> Claude -> Codex. Run only against
Soyeht Dev.app because the test creates live paid-agent sessions.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
from time import monotonic, sleep, time


WORKSPACE_SNAPSHOT_PATH = None

# These terms describe implementation, not user intent. Agent-facing E2E
# prompts must never contain them: the point of this runner is to prove that a
# real agent discovers the right capability from ordinary language.
FORBIDDEN_AGENT_PROMPT_FRAGMENTS = (
    "message_agent",
    "open_agent_pane",
    "send_pane_input",
    "soyeht-dev",
    "mcp",
    "nome da função",
    "nome da ferramenta",
)


def require_natural_user_prompt(prompt: str):
    normalized = prompt.casefold()
    leaked = [
        fragment
        for fragment in FORBIDDEN_AGENT_PROMPT_FRAGMENTS
        if (
            re.search(r"(?<!\w)mcp(?!\w)", normalized)
            if fragment == "mcp"
            else fragment.casefold() in normalized
        )
    ]
    require(
        not leaked,
        f"Agent-facing prompt leaked implementation vocabulary: {leaked!r}",
    )


def natural_collaboration_prompt(child_agent, child_name, directory, token, completion_prefix):
    prompt = (
        f"Sem alterar arquivos, primeiro abra uma nova pane com {child_agent} neste mesmo "
        f"workspace, no diretório exato {directory}, e dê a ela o nome {child_name}. "
        "Abra a pane sem dar uma tarefa inicial e confirme que ela apareceu. "
        f"Depois que ela já estiver aberta, em uma segunda ação separada, fale com esse "
        f"agente e peça que ele responda a você com exatamente {token}. "
        f"Aguarde a resposta dele. Só então responda aqui com exatamente "
        f"{completion_prefix} {token}."
    )
    require_natural_user_prompt(prompt)
    return prompt


def natural_collision_setup_prompt(
    recipient_agent,
    recipient_name,
    recipient_directory,
    recipient_ready_token,
    ready_token,
    relay_token,
    completion_prefix,
):
    prompt = (
        f"Sem alterar arquivos, abra uma nova pane com {recipient_agent} neste mesmo workspace, "
        f"no diretório exato {recipient_directory}, e dê a ela o nome {recipient_name}. "
        f"Ao abrir a pane, peça ao novo agente que responda somente {recipient_ready_token} e aguarde. "
        f"Quando a pane estiver pronta, diga aqui {ready_token} sem encerrar seu trabalho. "
        "Em seguida aguarde 15 segundos sem trazer outra pane para a frente. "
        f"Depois desse intervalo, fale com o agente {recipient_name} e peça que ele responda "
        f"a você com exatamente {relay_token}. Aguarde a resposta dele e então diga aqui "
        f"exatamente {completion_prefix} {relay_token}."
    )
    require_natural_user_prompt(prompt)
    return prompt


def load_mcp(module_path: Path):
    # Never invalidate a signed app bundle merely by loading its MCP resources.
    sys.dont_write_bytecode = True
    loader = importlib.machinery.SourceFileLoader("soyeht_agent_driven_e2e_module", str(module_path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def detach_external_observer_identity():
    """Prevent the harness from inheriting an unauthenticated pane claim."""
    for key in (
        "SOYEHT_AGENT_NAME",
        "SOYEHT_CONVERSATION_ID",
        "SOYEHT_HANDLE",
        "SOYEHT_LAUNCH_NONCE",
    ):
        os.environ.pop(key, None)
    foundation = sys.modules.get("soyeht_mcp_foundation")
    if foundation is not None:
        # The installed server intentionally inspects parent environments for
        # real CLI subprocesses. This runner is an external observer, so its
        # parent-pane metadata is not an identity claim and must be ignored.
        foundation._PARENT_PROCESS_ENVIRONMENT = {}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def installed_app_provenance(app_path: Path) -> dict:
    subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app_path)],
        check=True,
        capture_output=True,
        text=True,
    )
    signature = subprocess.run(
        ["/usr/bin/codesign", "-dvv", str(app_path)],
        check=True,
        capture_output=True,
        text=True,
    ).stderr
    team_id = next(
        (line.split("=", 1)[1] for line in signature.splitlines() if line.startswith("TeamIdentifier=")),
        "",
    )
    require(team_id not in {"", "not set"}, "Installed Soyeht Dev is ad-hoc signed.")
    plist = app_path / "Contents" / "Info.plist"
    executable = app_path / "Contents" / "MacOS" / "Soyeht Dev"
    commit = subprocess.run(
        ["/usr/libexec/PlistBuddy", "-c", "Print :SoyehtBuildGitCommit", str(plist)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    binary_sha = subprocess.run(
        ["/usr/bin/shasum", "-a", "256", str(executable)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.split()[0]
    resources = app_path / "Contents" / "Resources"
    mcp_files = sorted(
        [resources / "soyeht-mcp", resources / "LocalAgentCatalog.json"]
        + list(resources.glob("soyeht_mcp_*.py")),
        key=lambda item: item.name,
    )
    require(all(item.is_file() for item in mcp_files), "Installed MCP resource set is incomplete.")
    digest = hashlib.sha256()
    for item in mcp_files:
        digest.update(item.name.encode("utf-8") + b"\0")
        digest.update(item.read_bytes())
    return {
        "commit": commit,
        "teamID": team_id,
        "binarySHA256": binary_sha,
        "mcpBundleSHA256": digest.hexdigest(),
        "mcpFiles": [item.name for item in mcp_files],
    }


def require_accessibility_keyboard_control():
    completed = subprocess.run(
        [
            "/usr/bin/osascript",
            "-e",
            'tell application "System Events" to return UI elements enabled',
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    require(
        completed.stdout.strip().lower() == "true",
        "macOS Accessibility keyboard control is not enabled for this runner.",
    )


def raise_soyeht_dev_window(window_id):
    expected_identifier = f"com.soyeht.mac.mainwindow.{window_id}"
    script = r'''
on run argv
  set expectedIdentifier to item 1 of argv
  tell application id "com.soyeht.mac.dev" to activate
  delay 0.35
  tell application "System Events" to tell process "Soyeht Dev"
    set targetWindow to first window whose value of attribute "AXIdentifier" is expectedIdentifier
    perform action "AXRaise" of targetWindow
    try
      set value of attribute "AXMain" of targetWindow to true
    end try
    delay 0.15
    if value of attribute "AXIdentifier" of front window is not expectedIdentifier then
      error "The requested Soyeht Dev window did not become frontmost"
    end if
  end tell
end run
'''
    latest_error = ""
    for _ in range(8):
        completed = subprocess.run(
            ["/usr/bin/osascript", "-e", script, expected_identifier],
            capture_output=True,
            text=True,
        )
        if completed.returncode == 0:
            return
        latest_error = completed.stderr.strip()
        sleep(0.25)
    raise RuntimeError(
        f"Could not raise exact Soyeht Dev window {window_id}: {latest_error}"
    )


def type_through_macos_keyboard(text, expected_window_id, submit_with_return=False):
    expected_identifier = f"com.soyeht.mac.mainwindow.{expected_window_id}"
    script = r'''
on run argv
  set payload to item 1 of argv
  set shouldSubmit to item 2 of argv
  set expectedIdentifier to item 3 of argv
  tell application "System Events"
    set frontApp to name of first application process whose frontmost is true
    if frontApp is not "Soyeht Dev" then error "Soyeht Dev did not become frontmost"
    tell process "Soyeht Dev"
      if value of attribute "AXIdentifier" of front window is not expectedIdentifier then
        error "Physical input would target the wrong Soyeht Dev window"
      end if
    end tell
    if length of payload is greater than 0 then
      keystroke payload
    end if
    if shouldSubmit is "true" then
      delay 0.25
      key code 36
    end if
  end tell
end run
'''
    subprocess.run(
        [
            "/usr/bin/osascript",
            "-e",
            script,
            text,
            "true" if submit_with_return else "false",
            expected_identifier,
        ],
        check=True,
        capture_output=True,
        text=True,
    )


def release_physical_draft(action, draft_length, expected_window_id):
    expected_identifier = f"com.soyeht.mac.mainwindow.{expected_window_id}"
    script = r'''
on run argv
  set releaseAction to item 1 of argv
  set draftLength to (item 2 of argv) as integer
  set expectedIdentifier to item 3 of argv
  tell application "System Events"
    set frontApp to name of first application process whose frontmost is true
    if frontApp is not "Soyeht Dev" then error "Soyeht Dev did not become frontmost"
    tell process "Soyeht Dev"
      if value of attribute "AXIdentifier" of front window is not expectedIdentifier then
        error "Physical clear would target the wrong Soyeht Dev window"
      end if
    end tell
    if releaseAction is "return" then
      key code 36
    else if releaseAction is "backspace" then
      repeat draftLength times
        key code 51
      end repeat
    else if releaseAction is "ctrl-u" then
      keystroke "u" using {control down}
    else if releaseAction is "ctrl-c" then
      keystroke "c" using {control down}
    else
      error "Unsupported physical draft release: " & releaseAction
    end if
  end tell
end run
'''
    subprocess.run(
        [
            "/usr/bin/osascript",
            "-e",
            script,
            action,
            str(draft_length),
            expected_identifier,
        ],
        check=True,
        capture_output=True,
        text=True,
    )


def click_soyeht_dev_target(expected_window_id):
    try:
        import Quartz
    except ImportError as exc:
        raise RuntimeError(
            "--physical-keyboard-only requires macOS PyObjC Quartz bindings."
        ) from exc

    expected_identifier = f"com.soyeht.mac.mainwindow.{expected_window_id}"
    script = r'''
on run argv
  set expectedIdentifier to item 1 of argv
  tell application "System Events" to tell process "Soyeht Dev"
    if frontmost is not true then error "Soyeht Dev is not frontmost"
    set targetWindow to first window whose value of attribute "AXIdentifier" is expectedIdentifier
    set {windowX, windowY} to position of targetWindow
    set {windowWidth, windowHeight} to size of targetWindow
    return (windowX as text) & "," & (windowY as text) & "," & (windowWidth as text) & "," & (windowHeight as text)
  end tell
end run
'''
    latest_error = ""
    for _ in range(8):
        raise_soyeht_dev_window(expected_window_id)
        completed = subprocess.run(
            ["/usr/bin/osascript", "-e", script, expected_identifier],
            capture_output=True,
            text=True,
        )
        if completed.returncode == 0:
            try:
                window_x, window_y, window_width, window_height = [
                    float(value.strip()) for value in completed.stdout.strip().split(",")
                ]
            except (TypeError, ValueError) as exc:
                latest_error = f"invalid AX window bounds: {completed.stdout!r} ({exc})"
                sleep(0.25)
                continue
            point = (
                window_x + window_width * 0.50,
                window_y + window_height * 0.60,
            )
            mouse_down = Quartz.CGEventCreateMouseEvent(
                None,
                Quartz.kCGEventLeftMouseDown,
                point,
                Quartz.kCGMouseButtonLeft,
            )
            mouse_up = Quartz.CGEventCreateMouseEvent(
                None,
                Quartz.kCGEventLeftMouseUp,
                point,
                Quartz.kCGMouseButtonLeft,
            )
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, mouse_down)
            sleep(0.05)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, mouse_up)
            sleep(0.15)
            return
        latest_error = completed.stderr.strip()
        sleep(0.25)
    raise RuntimeError(
        f"Could not click exact Soyeht Dev window {expected_window_id}: {latest_error}"
    )


def click_soyeht_dev_pane(expected_window_id, pane_label):
    """Click terminal content below an exact, visible pane-header label."""
    try:
        import Quartz
    except ImportError as exc:
        raise RuntimeError(
            "--physical-keyboard-only requires macOS PyObjC Quartz bindings."
        ) from exc

    expected_identifier = f"com.soyeht.mac.mainwindow.{expected_window_id}"
    visible_label = str(pane_label).removeprefix("@")
    script = r'''
on run argv
  set expectedIdentifier to item 1 of argv
  set expectedLabel to item 2 of argv
  tell application "System Events" to tell process "Soyeht Dev"
    if frontmost is not true then error "Soyeht Dev is not frontmost"
    set targetWindow to first window whose value of attribute "AXIdentifier" is expectedIdentifier
    set elements to entire contents of targetWindow
    repeat with elementRef in elements
      try
        if role of elementRef is "AXStaticText" then
          if (value of elementRef as text) is expectedLabel then
            set {elementX, elementY} to position of elementRef
            set {elementWidth, elementHeight} to size of elementRef
            return (elementX as text) & "," & (elementY as text) & "," & (elementWidth as text) & "," & (elementHeight as text)
          end if
        end if
      end try
    end repeat
    error "Visible pane label was not found: " & expectedLabel
  end tell
end run
'''
    latest_error = ""
    for _ in range(8):
        raise_soyeht_dev_window(expected_window_id)
        completed = subprocess.run(
            [
                "/usr/bin/osascript",
                "-e",
                script,
                expected_identifier,
                visible_label,
            ],
            capture_output=True,
            text=True,
        )
        if completed.returncode == 0:
            try:
                element_x, element_y, element_width, element_height = [
                    float(value.strip())
                    for value in completed.stdout.strip().split(",")
                ]
            except (TypeError, ValueError) as exc:
                latest_error = f"invalid pane-label bounds: {completed.stdout!r} ({exc})"
                sleep(0.25)
                continue
            point = (
                element_x + element_width * 0.5,
                element_y + element_height * 0.5,
            )
            mouse_down = Quartz.CGEventCreateMouseEvent(
                None,
                Quartz.kCGEventLeftMouseDown,
                point,
                Quartz.kCGMouseButtonLeft,
            )
            mouse_up = Quartz.CGEventCreateMouseEvent(
                None,
                Quartz.kCGEventLeftMouseUp,
                point,
                Quartz.kCGMouseButtonLeft,
            )
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, mouse_down)
            sleep(0.05)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, mouse_up)
            sleep(0.15)
            return
        latest_error = completed.stderr.strip()
        sleep(0.25)
    raise RuntimeError(
        f"Could not click pane {visible_label!r} in Soyeht Dev window "
        f"{expected_window_id}: {latest_error}"
    )


def source_args(pane, automation_dir, timeout):
    # This process is an external test observer, not the pane. Never attach a
    # fromConversationID/fromHandle claim or a stolen launch nonce.
    return {
        "automationDir": automation_dir,
        "timeout": timeout,
        "targetWindowID": pane["windowID"],
    }


def persisted_inbox_messages(recipient):
    require(WORKSPACE_SNAPSHOT_PATH is not None, "Workspace snapshot path is not configured.")
    latest_error = None
    for _ in range(20):
        try:
            document = json.loads(WORKSPACE_SNAPSHOT_PATH.read_text(encoding="utf-8"))
            conversation = next((
                item for item in document.get("conversations", [])
                if item.get("id") == recipient["conversationID"]
            ), None)
            if conversation is not None:
                return [
                    {
                        **message,
                        "messageID": message.get("id"),
                        "senderConversationID": message.get("sender", {}).get("paneID"),
                        "senderWorkspaceID": message.get("sender", {}).get("workspaceID"),
                        "senderReference": message.get("sender", {}).get("handle"),
                        "recipientConversationID": message.get("recipient", {}).get("paneID"),
                        "recipientWorkspaceID": message.get("recipient", {}).get("workspaceID"),
                        "recipientReference": message.get("recipient", {}).get("handle"),
                    }
                    for message in conversation.get("agentMessageInbox", {}).get("messages", [])
                ]
        except (OSError, json.JSONDecodeError) as exc:
            latest_error = exc
        sleep(0.05)
    raise RuntimeError(
        f"Could not read durable inbox for {recipient['conversationID']} from "
        f"{WORKSPACE_SNAPSHOT_PATH}: {latest_error}"
    )


def process_snapshot():
    completed = subprocess.run(
        ["/bin/ps", "-axo", "pid=,ppid=,command="],
        check=True,
        capture_output=True,
        text=True,
    )
    result = {}
    for line in completed.stdout.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3:
            continue
        try:
            result[int(fields[0])] = {"ppid": int(fields[1]), "command": fields[2]}
        except ValueError:
            continue
    return result


def process_cwd(pid: int):
    completed = subprocess.run(
        ["/usr/sbin/lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
        capture_output=True,
        text=True,
    )
    for line in completed.stdout.splitlines():
        if line.startswith("n"):
            return str(Path(line[1:]).resolve())
    return None


def process_launch_nonce(pid: int, conversation_id: str, timeout: float) -> str:
    """Read the just-observed agent's QA credential without persisting it."""
    deadline = monotonic() + timeout
    while monotonic() < deadline:
        command = subprocess.run(
            ["/bin/ps", "eww", "-p", str(pid), "-o", "command="],
            check=False,
            capture_output=True,
            text=True,
        ).stdout
        if f"SOYEHT_CONVERSATION_ID={conversation_id}" in command:
            match = re.search(r"(?:^|\s)SOYEHT_LAUNCH_NONCE=([^\s]+)", command)
            if match:
                return match.group(1)
        sleep(0.2)
    raise RuntimeError(
        f"Observed agent process {pid} never exposed the launch credential for "
        f"{conversation_id}."
    )


def command_matches(command: str, expected_argv):
    try:
        tokens = shlex.split(command)
    except ValueError:
        tokens = command.split()
    if len(tokens) != len(expected_argv) or not tokens:
        return False
    if Path(tokens[0]).name.lower() != Path(expected_argv[0]).name.lower():
        return False
    return tokens[1:] == list(expected_argv[1:])


def observe_process(baseline, expected_argv, expected_cwd: Path, timeout):
    expected_cwd = str(expected_cwd.resolve())
    deadline = monotonic() + timeout
    newest = []
    while monotonic() < deadline:
        newest = [
            {"pid": pid, **item}
            for pid, item in process_snapshot().items()
            if pid not in baseline
        ]
        for candidate in newest:
            if not command_matches(candidate["command"], expected_argv):
                continue
            cwd = process_cwd(candidate["pid"])
            if cwd != expected_cwd:
                continue
            return {**candidate, "cwd": cwd}
        sleep(0.25)
    raise RuntimeError(
        f"No new process matched argv={expected_argv!r}, cwd={expected_cwd!r}. "
        f"Newest commands: {[item['command'] for item in newest[-12:]]!r}"
    )


def capture_text(mcp, pane, nonce, automation_dir, timeout):
    # capture_pane is intentionally self-only. The white-box harness uses the
    # nonce of the exact PID whose argv/cwd it already proved; the secret is
    # never written to the evidence document.
    response = mcp.submit_request_to_root(
        Path(automation_dir),
        "capture_pane",
        {
            "targetWindowID": pane["windowID"],
            "sourceConversationID": pane["conversationID"],
            "sourceHandle": pane["handle"],
            "nonce": nonce,
            "conversationIDs": [pane["conversationID"]],
            "mode": "all",
            "maxLines": 220,
            "mcpClientContractVersion": 3,
            "mcpClientProfile": "dev",
            "mcpClientServerVersion": "2.0.0-agent-driven-e2e",
        },
        timeout=timeout,
        check_status=True,
    )
    return "\n".join(item.get("text", "") for item in response.get("capturedPanes", [])).replace("\x00", "")


def wait_for_child_pane(mcp, observer, workspace_id, expected_name, automation_dir, timeout):
    deadline = monotonic() + timeout
    expected_handles = {expected_name, f"@{expected_name}"}
    latest = []
    while monotonic() < deadline:
        response = mcp.tool_list_panes({
            **source_args(observer, automation_dir, timeout),
            "workspaceID": workspace_id,
        })
        latest = response.get("listedPanes", [])
        for pane in latest:
            if pane.get("handle") in expected_handles:
                return pane, latest
        sleep(0.5)
    raise RuntimeError(
        f"Agent did not create exact pane {expected_name!r}. "
        f"Observed handles: {[pane.get('handle') for pane in latest]!r}"
    )


def wait_for_parent_request(mcp, parent, child, token, automation_dir, timeout):
    deadline = monotonic() + timeout
    latest_inbox = []
    while monotonic() < deadline:
        latest_inbox = persisted_inbox_messages(child)
        request = next((
            message for message in latest_inbox
            if token in message.get("body", "")
            and message.get("senderConversationID") == parent["conversationID"]
            and message.get("mcpClientContractVersion") == 3
        ), None)
        if request:
            return request
        sleep(0.5)
    raise RuntimeError(
        f"No durable MCP v2 request containing {token!r} from {parent['handle']} "
        f"to {child['handle']}. Inbox provenance: "
        f"{[(item.get('body'), item.get('mcpClientContractVersion'), item.get('mcpClientServerVersion')) for item in latest_inbox]!r}"
    )


def wait_for_reply(mcp, parent, child, token, automation_dir, timeout):
    deadline = monotonic() + timeout
    latest_inbox = []
    while monotonic() < deadline:
        latest_inbox = persisted_inbox_messages(parent)
        reply = next((
            message for message in latest_inbox
            if token in message.get("body", "")
            and message.get("senderConversationID") == child["conversationID"]
            and message.get("mcpClientContractVersion") == 3
        ), None)
        if reply:
            return reply
        sleep(0.5)
    raise RuntimeError(
        f"No durable MCP reply {token!r} from {child['handle']} to {parent['handle']}. "
        f"Inbox provenance: "
        f"{[(item.get('body'), item.get('mcpClientContractVersion'), item.get('mcpClientServerVersion')) for item in latest_inbox]!r}"
    )


def inbox_message(mcp, recipient, message_id, automation_dir, timeout):
    return next((
        message for message in persisted_inbox_messages(recipient)
        if message.get("id") == message_id or message.get("messageID") == message_id
    ), None)


def wait_for_deferred_terminal_delivery(mcp, recipient, message_id, automation_dir, timeout):
    deadline = monotonic() + timeout
    latest = None
    while monotonic() < deadline:
        latest = inbox_message(mcp, recipient, message_id, automation_dir, timeout)
        if latest and latest.get("deferredTerminalDeliveredAt") is not None:
            return latest
        sleep(0.5)
    raise RuntimeError(
        f"Deferred message {message_id} was not marked terminal-delivered for "
        f"{recipient['handle']}. Last inbox record: {latest!r}"
    )


def wait_for_parent_completion(mcp, parent, nonce, marker, automation_dir, timeout):
    deadline = monotonic() + timeout
    latest = ""
    while monotonic() < deadline:
        latest = capture_text(mcp, parent, nonce, automation_dir, timeout)
        normalized = " ".join(latest.split())
        if marker in normalized:
            return latest
        sleep(0.5)
    raise RuntimeError(
        f"Parent {parent['handle']} did not produce completion {marker!r} after "
        f"receiving the durable child reply. Last capture: {latest[-1200:]!r}"
    )


def wait_for_transcript_token(mcp, pane, nonce, token, automation_dir, timeout):
    deadline = monotonic() + timeout
    latest = ""
    while monotonic() < deadline:
        latest = capture_text(mcp, pane, nonce, automation_dir, timeout)
        if token in latest:
            return latest
        sleep(0.5)
    raise RuntimeError(
        f"Pane {pane['handle']} did not show transcript token {token!r}. "
        f"Last capture: {latest[-1200:]!r}"
    )


def wait_for_transcript_token_count(
    mcp,
    pane,
    nonce,
    token,
    minimum_count,
    automation_dir,
    timeout,
):
    deadline = monotonic() + timeout
    latest = ""
    while monotonic() < deadline:
        latest = capture_text(mcp, pane, nonce, automation_dir, timeout)
        if latest.count(token) >= minimum_count:
            return latest
        sleep(0.5)
    raise RuntimeError(
        f"Pane {pane['handle']} showed {token!r} only {latest.count(token)} time(s); "
        f"expected at least {minimum_count}. Last capture: {latest[-1200:]!r}"
    )


def run_typing_collision(
    mcp,
    observer,
    workspace_id,
    repo_root,
    automation_dir,
    timeout,
    run_id,
    index,
    sender_agent,
    recipient_agent,
    recipient_directory,
    input_mode,
    draft_release_action,
    release_timeout,
):
    collision_baseline = process_snapshot()
    sender_name = f"e2e-draft-sender-{sender_agent}-{run_id}-{index}"
    recipient_name = f"e2e-draft-target-{recipient_agent}-{run_id}-{index}"
    ready_token = f"E2E_DRAFT_CHILD_READY_{run_id}_{index}"
    recipient_ready_token = f"E2E_DRAFT_RECIPIENT_READY_{run_id}_{index}"
    draft_token = f"E2E_DRAFT_{run_id}_{index}"
    relay_token = f"E2E_DEFERRED_REAL_AGENT_REPLY_{run_id}_{index}"
    # Hyphens survive Markdown/TUI rendering. The MCP reply token itself stays
    # underscore-exact and is validated from the durable inbox separately.
    completion_prefix = f"E2E-DRAFT-COLLISION-OK-{run_id}-{index}"
    sender_prompt = natural_collision_setup_prompt(
        recipient_agent=recipient_agent,
        recipient_name=recipient_name,
        recipient_directory=recipient_directory,
        recipient_ready_token=recipient_ready_token,
        ready_token=ready_token,
        relay_token=relay_token,
        completion_prefix=completion_prefix,
    )
    sender_opened = mcp.tool_open_agent_pane({
        "automationDir": automation_dir,
        "timeout": timeout,
        "targetWindowID": observer["windowID"],
        "agentID": sender_agent,
        "cwd": str(repo_root),
        "workspaceID": workspace_id,
        "name": sender_name,
        "prompt": sender_prompt,
        "promptMode": "raw",
        "activate": False,
    })
    sender = sender_opened.get("createdPanes", [])[0]
    sender_process = observe_process(
        collision_baseline,
        sender_opened["launchContract"]["expectedArgv"],
        repo_root,
        timeout,
    )
    sender_nonce = process_launch_nonce(
        sender_process["pid"],
        sender["conversationID"],
        timeout,
    )
    recipient, _ = wait_for_child_pane(
        mcp,
        observer,
        workspace_id,
        recipient_name,
        automation_dir,
        timeout,
    )
    recipient_contract = mcp.build_agent_launch(recipient_agent)
    recipient_process = observe_process(
        collision_baseline,
        recipient_contract["expectedArgv"],
        recipient_directory,
        timeout,
    )
    recipient_nonce = process_launch_nonce(
        recipient_process["pid"],
        recipient["conversationID"],
        timeout,
    )
    wait_for_transcript_token(
        mcp,
        sender,
        sender_nonce,
        ready_token,
        automation_dir,
        timeout,
    )
    # The launch prompt itself contains the token once. Requiring a second
    # occurrence proves that the real agent answered and returned from a full
    # turn instead of merely echoing broker input during startup.
    wait_for_transcript_token_count(
        mcp,
        recipient,
        recipient_nonce,
        recipient_ready_token,
        2,
        automation_dir,
        timeout,
    )
    # The marker can become visible one render before the TUI restores its
    # input editor. Give the completed frame a short settle interval so the
    # physical draft cannot be erased by the final alternate-screen redraw.
    sleep(3.0)

    # Put the real recipient in the same focused state as a pane where the
    # user is actively composing. The text then enters without Enter through
    # the same onUserInputData path used by keyboard input.
    if input_mode == "physicalKeyboard":
        # Pane focus inside a background window is not enough: macOS sends
        # physical keys to the key window. Raise the exact AX-identified
        # Soyeht window first, then let emphasize_pane claim the terminal as
        # first responder while that window is active.
        raise_soyeht_dev_window(recipient["windowID"])
    mcp.tool_emphasize_pane({
        **source_args(observer, automation_dir, timeout),
        "conversationIDs": [recipient["conversationID"]],
        "mode": "zoom" if input_mode == "physicalKeyboard" else "spotlight",
        "ratio": None if input_mode == "physicalKeyboard" else 0.72,
    })
    focused_inventory = mcp.tool_list_panes({
        **source_args(observer, automation_dir, timeout),
        "workspaceID": workspace_id,
    }).get("listedPanes", [])
    require(
        any(
            pane.get("conversationID") == recipient["conversationID"] and pane.get("isActive")
            for pane in focused_inventory
        ),
        f"Real {recipient_agent} recipient was not focused before simulating human typing.",
    )
    if input_mode == "physicalKeyboard":
        # Model focus and AppKit first-responder focus are separate. Zoom makes
        # the target deterministic regardless of accumulated pane geometry;
        # a real Quartz click then reproduces how a person focuses its editor.
        click_soyeht_dev_target(recipient["windowID"])

    # pt-BR multibyte characters reproduce the original byte-vs-character
    # DraftGate defect while Backspace clears one visible character per key.
    unfinished_draft = f"{draft_token} café ação reply only OK"
    if input_mode == "physicalKeyboard":
        # Generate ordinary keyboard events, not bracketed paste. The scenario
        # under test is a person typing and then deleting the draft one key at
        # a time while the sender continues independently in the background.
        type_through_macos_keyboard(
            unfinished_draft,
            recipient["windowID"],
            submit_with_return=False,
        )
    else:
        draft_input = mcp.tool_send_pane_input({
            **source_args(observer, automation_dir, timeout),
            "conversationIDs": [recipient["conversationID"]],
            "text": unfinished_draft,
            "lineEnding": "none",
        })
        require(
            any(
                pane.get("conversationID") == recipient["conversationID"]
                for pane in draft_input.get("sentPanes", [])
            ),
            f"Synthetic human draft was not accepted by the real {recipient_agent} pane.",
        )
    sleep(0.75)
    initial_draft_capture = capture_text(
        mcp,
        recipient,
        recipient_nonce,
        automation_dir,
        timeout,
    )
    require(
        draft_token in initial_draft_capture,
        f"{input_mode} input did not reach the focused {recipient_agent} pane. "
        "Refusing to treat app activation alone as proof of user input.",
    )
    if input_mode == "physicalKeyboard":
        # Zoom temporarily removes siblings from the rendered tree. Restore
        # them before asking the sender to continue so its pane is live.
        mcp.tool_emphasize_pane({
            **source_args(observer, automation_dir, timeout),
            "conversationIDs": [recipient["conversationID"]],
            "mode": "unzoom",
        })

    if input_mode != "physicalKeyboard":
        raise RuntimeError(
            "MCP 2.0 intentionally rejects external send_pane_input writes to agent panes; "
            "run collision tests with --physical-keyboard-only."
        )
    parent_request = wait_for_parent_request(
        mcp,
        sender,
        recipient,
        relay_token,
        automation_dir,
        timeout,
    )
    sleep(1.5)
    held_capture = capture_text(
        mcp,
        recipient,
        recipient_nonce,
        automation_dir,
        timeout,
    )
    require(
        relay_token not in held_capture,
        f"MCP relay spliced into a real {recipient_agent} agent's unfinished draft.",
    )
    held_message = inbox_message(
        mcp,
        recipient,
        parent_request["messageID"],
        automation_dir,
        timeout,
    )
    require(held_message is not None, "Durable real-agent relay disappeared from the inbox.")
    require(
        held_message.get("channel") == "deferredTerminal",
        "Real-agent relay did not select deferred-terminal delivery.",
    )
    require(
        held_message.get("deferredTerminalDeliveredAt") is None,
        f"Real {recipient_agent} relay was marked terminal-delivered before the user's draft release.",
    )

    if input_mode == "physicalKeyboard":
        # The sender continued independently and never took focus from the
        # composing recipient, matching the real user scenario.
        release_physical_draft(
            draft_release_action,
            len(unfinished_draft),
            recipient["windowID"],
        )
    else:
        mcp.tool_send_pane_input({
            **source_args(observer, automation_dir, timeout),
            "conversationIDs": [recipient["conversationID"]],
            "text": " ENVIAR_AGORA",
            "lineEnding": "enter",
        })
    try:
        released_capture = wait_for_transcript_token(
            mcp,
            recipient,
            recipient_nonce,
            relay_token,
            automation_dir,
            release_timeout,
        )
    except RuntimeError as exc:
        post_release_capture = capture_text(
            mcp,
            recipient,
            recipient_nonce,
            automation_dir,
            timeout,
        )
        post_release_message = inbox_message(
            mcp,
            recipient,
            parent_request["messageID"],
            automation_dir,
            timeout,
        )
        raise RuntimeError(
            f"Physical {draft_release_action} did not release the queued relay for "
            f"{recipient_agent} within {release_timeout}s; "
            f"draftTokenVisible={draft_token in post_release_capture}, "
            f"deliveredAt={post_release_message.get('deferredTerminalDeliveredAt') if post_release_message else None}. "
            f"Underlying wait: {exc}"
        ) from exc
    delivered_message = wait_for_deferred_terminal_delivery(
        mcp,
        recipient,
        parent_request["messageID"],
        automation_dir,
        timeout,
    )
    reply = wait_for_reply(
        mcp,
        sender,
        recipient,
        relay_token,
        automation_dir,
        timeout,
    )
    wait_for_transcript_token(
        mcp,
        sender,
        sender_nonce,
        completion_prefix,
        automation_dir,
        timeout,
    )
    result = {
        "status": "passed",
        "senderAgent": sender_agent,
        "recipientAgent": recipient_agent,
        "senderPane": sender,
        "recipientPane": recipient,
        "senderProcess": sender_process,
        "recipientProcess": recipient_process,
        "inputSimulation": (
            f"macOS Accessibility typing plus physical {draft_release_action}"
            if input_mode == "physicalKeyboard"
            else "send_pane_input without Enter through the shared onUserInputData draft gate"
        ),
        "draftReleaseAction": draft_release_action,
        "recipientFocusedForHumanSimulation": True,
        "unfinishedDraftInputAccepted": True,
        "unfinishedDraftVisibleInDynamicCapture": draft_token in initial_draft_capture,
        "relayAbsentBeforeRelease": relay_token not in held_capture,
        "deliveryTimestampBeforeRelease": held_message.get("deferredTerminalDeliveredAt"),
        "relayObservedAfterRelease": relay_token in released_capture,
        "deliveryTimestampAfterRelease": delivered_message.get("deferredTerminalDeliveredAt"),
        "requestContractVersion": parent_request.get("mcpClientContractVersion"),
        "requestServerVersion": parent_request.get("mcpClientServerVersion"),
        "replyContractVersion": reply.get("mcpClientContractVersion"),
        "replyServerVersion": reply.get("mcpClientServerVersion"),
        "completionObservedInSenderTranscript": True,
        "userPrompts": {
            "setup": sender_prompt,
            "message": follow_up,
        },
        "promptVocabularyAudit": {
            "status": "passed",
            "forbiddenFragments": list(FORBIDDEN_AGENT_PROMPT_FRAGMENTS),
        },
    }
    if draft_release_action == "return":
        result.update({
            "relayAbsentBeforeEnter": relay_token not in held_capture,
            "deliveryTimestampBeforeEnter": held_message.get("deferredTerminalDeliveredAt"),
            "relayObservedAfterEnter": relay_token in released_capture,
            "deliveryTimestampAfterEnter": delivered_message.get("deferredTerminalDeliveredAt"),
        })
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument(
        "--mcp-script",
        default="/Applications/Soyeht Dev.app/Contents/Resources/soyeht-mcp",
        help="Exact MCP server implementation used by the external observer.",
    )
    parser.add_argument(
        "--workspace-snapshot",
        default=str(Path.home() / "Library/Application Support/SoyehtDev/workspaces.json"),
        help="Durable app snapshot used as a read-only inbox oracle without pane impersonation.",
    )
    parser.add_argument("--automation-dir", required=True)
    parser.add_argument("--timeout", type=float, default=240.0)
    parser.add_argument("--expected-commit", required=True)
    parser.add_argument("--keep", action="store_true")
    parser.add_argument(
        "--typing-collision-only",
        action="store_true",
        help="Run only the real-agent unfinished-draft collision scenario.",
    )
    parser.add_argument(
        "--collaboration-only",
        action="store_true",
        help="Run only the natural-language open-and-message collaboration ring.",
    )
    parser.add_argument(
        "--physical-keyboard-only",
        action="store_true",
        help="Run the collision ring using macOS Accessibility keystrokes instead of send_pane_input.",
    )
    parser.add_argument(
        "--draft-release-action",
        choices=("return", "backspace", "ctrl-u", "ctrl-c"),
        default="return",
        help="Physical action that clears/submits the unfinished draft before queued delivery.",
    )
    parser.add_argument(
        "--release-timeout",
        type=float,
        default=20.0,
        help="Maximum wait for a queued relay after the physical draft-release action.",
    )
    parser.add_argument(
        "--collision-route",
        choices=("all", "codex-opencode", "opencode-claude", "claude-codex"),
        default="all",
        help="Limit the typing-collision ring to one sender-recipient route.",
    )
    parser.add_argument("--output")
    args = parser.parse_args()

    if args.typing_collision_only:
        # A collision-only run exists specifically to model a human composing
        # in the pane. Never silently substitute automation input for actual
        # macOS Accessibility keyboard events.
        args.physical_keyboard_only = True

    repo_root = Path(args.repo_root).resolve()
    automation_dir = str(Path(args.automation_dir).expanduser().resolve())
    require("SoyehtDev/Automation" in automation_dir, "Refusing to run paid-agent E2E outside Soyeht Dev automation.")
    mcp_script = Path(args.mcp_script).expanduser().resolve()
    require(mcp_script.is_file(), f"Installed MCP script does not exist: {mcp_script}")
    expected_mcp_script = Path("/Applications/Soyeht Dev.app/Contents/Resources/soyeht-mcp").resolve()
    require(
        mcp_script == expected_mcp_script,
        f"E2E must exercise the installed MCP bundle, not an override: {mcp_script}",
    )
    mcp = load_mcp(mcp_script)
    detach_external_observer_identity()
    global WORKSPACE_SNAPSHOT_PATH
    WORKSPACE_SNAPSHOT_PATH = Path(args.workspace_snapshot).expanduser().resolve()
    run_id = str(int(time()))
    app_provenance = installed_app_provenance(Path("/Applications/Soyeht Dev.app"))
    require(
        re.fullmatch(r"[0-9a-f]{40}", args.expected_commit) is not None,
        "--expected-commit must be the full 40-character Git commit.",
    )
    require(
        app_provenance["commit"] == args.expected_commit,
        f"Installed app commit {app_provenance['commit']} != expected {args.expected_commit}.",
    )
    repo_commit = subprocess.run(
        ["/usr/bin/git", "-C", str(repo_root), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    repo_dirty = subprocess.run(
        ["/usr/bin/git", "-C", str(repo_root), "status", "--porcelain"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    require(repo_commit == args.expected_commit, "E2E repo checkout is not the expected commit.")
    require(not repo_dirty, "E2E repo checkout must be clean before launching paid agents.")
    evidence = {
        "runID": run_id,
        "kind": "real-agent-behavioral-ring",
        "automationDir": automation_dir,
        "installedApp": app_provenance,
        "flows": [],
    }
    output = (
        Path(args.output).resolve()
        if args.output
        else repo_root / "QA" / "runs" / f"agent-driven-e2e-{run_id}.json"
    )
    workspace_id = None
    observer = None

    flows = [
        {"parent": "codex", "child": "opencode", "directory": repo_root / "QA"},
        {"parent": "opencode", "child": "claude", "directory": repo_root / "docs"},
        {"parent": "claude", "child": "codex", "directory": repo_root / "TerminalApp"},
    ]
    if args.typing_collision_only or args.physical_keyboard_only:
        flows = []
    require(
        not (args.collaboration_only and (args.typing_collision_only or args.physical_keyboard_only)),
        "--collaboration-only cannot be combined with a collision-only mode.",
    )
    if args.physical_keyboard_only:
        require_accessibility_keyboard_control()
    require(
        args.physical_keyboard_only or args.draft_release_action == "return",
        "--draft-release-action requires --physical-keyboard-only.",
    )

    try:
        workspace = mcp.tool_open_workspace({
            "automationDir": automation_dir,
            "timeout": args.timeout,
            "name": f"agent-driven-e2e-{run_id}",
            "agent": "shell",
            "panes": [{
                "name": f"agent-driven-observer-{run_id}",
                "path": str(repo_root),
                "agent": "shell",
                "command": "/bin/cat",
            }],
        })
        observer = workspace["createdPanes"][0]
        workspace_id = observer["workspaceID"]
        sleep(2.0)

        parent_records = []
        global_baseline = process_snapshot()
        for index, flow in enumerate(flows, start=1):
            parent_name = f"e2e-parent-{flow['parent']}-{run_id}"
            child_name = f"e2e-child-{flow['child']}-{run_id}-{index}"
            # Hyphens survive all three alternate-screen renderers. OpenCode
            # visually strips some underscores even when the model emitted
            # and the durable inbox preserved them.
            token = f"E2E-REPLY-{run_id}-{index}"
            completion_prefix = f"E2E-FLOW-OK-{run_id}-{index}"
            marker = f"{completion_prefix} {token}"
            prompt = natural_collaboration_prompt(
                child_agent=flow["child"],
                child_name=child_name,
                directory=flow["directory"],
                token=token,
                completion_prefix=completion_prefix,
            )
            opened = mcp.tool_open_agent_pane({
                "automationDir": automation_dir,
                "timeout": args.timeout,
                "targetWindowID": observer["windowID"],
                "agentID": flow["parent"],
                "cwd": str(repo_root),
                "workspaceID": workspace_id,
                "name": parent_name,
                "prompt": prompt,
                "promptMode": "raw",
                "activate": False,
            })
            parent = opened.get("createdPanes", [])[0]
            parent_records.append({
                **flow,
                "parentPane": parent,
                "parentContract": opened["launchContract"],
                "childName": child_name,
                "token": token,
                "marker": marker,
                "userPrompt": prompt,
            })

        for record in parent_records:
            parent = record["parentPane"]
            parent_process = observe_process(
                global_baseline,
                record["parentContract"]["expectedArgv"],
                repo_root,
                args.timeout,
            )
            parent_nonce = process_launch_nonce(
                parent_process["pid"],
                parent["conversationID"],
                args.timeout,
            )
            child, pane_inventory = wait_for_child_pane(
                mcp,
                observer,
                workspace_id,
                record["childName"],
                automation_dir,
                args.timeout,
            )
            child_contract = mcp.build_agent_launch(record["child"])
            child_process = observe_process(
                global_baseline,
                child_contract["expectedArgv"],
                record["directory"],
                args.timeout,
            )
            parent_request = wait_for_parent_request(
                mcp,
                parent,
                child,
                record["token"],
                automation_dir,
                args.timeout,
            )
            reply = wait_for_reply(
                mcp,
                parent,
                child,
                record["token"],
                automation_dir,
                args.timeout,
            )
            completion = wait_for_parent_completion(
                mcp,
                parent,
                parent_nonce,
                record["marker"],
                automation_dir,
                args.timeout,
            )
            transcript = completion
            active_panes = [pane.get("handle") for pane in pane_inventory if pane.get("isActive")]
            require(
                child.get("handle") not in active_panes,
                f"Child {child['handle']} stole workspace focus during an agent-launched collaboration.",
            )
            evidence["flows"].append({
                "status": "passed",
                "parentAgent": record["parent"],
                "childAgent": record["child"],
                "requestedDirectory": str(record["directory"]),
                "parentPane": parent,
                "childPane": child,
                "parentProcess": parent_process,
                "childProcess": child_process,
                "parentRequest": parent_request,
                "reply": reply,
                "completionObservedInParentTranscript": True,
                "completionMarker": record["marker"],
                "parentTranscriptTail": transcript[-1800:],
                "childStoleFocus": False,
                "userPrompt": record["userPrompt"],
                "promptVocabularyAudit": {
                    "status": "passed",
                    "forbiddenFragments": list(FORBIDDEN_AGENT_PROMPT_FRAGMENTS),
                },
            })

        # Exercise the unfinished-draft guarantee with every primary CLI as a
        # sender and as a recipient, preserving the same ring as launch tests.
        collision_flows = [
            ("codex", "opencode", repo_root / "QA"),
            ("opencode", "claude", repo_root / "docs"),
            ("claude", "codex", repo_root / "TerminalApp"),
        ]
        if args.collaboration_only:
            collision_flows = []
        if args.collision_route != "all":
            requested_sender, requested_recipient = args.collision_route.split("-", 1)
            collision_flows = [
                flow for flow in collision_flows
                if flow[0] == requested_sender and flow[1] == requested_recipient
            ]
        evidence["typingCollisions"] = []
        for index, (sender_agent, recipient_agent, recipient_directory) in enumerate(
            collision_flows,
            start=1,
        ):
            evidence["typingCollisions"].append(run_typing_collision(
                mcp=mcp,
                observer=observer,
                workspace_id=workspace_id,
                repo_root=repo_root,
                automation_dir=automation_dir,
                timeout=args.timeout,
                run_id=run_id,
                index=index,
                sender_agent=sender_agent,
                recipient_agent=recipient_agent,
                recipient_directory=recipient_directory,
                input_mode="physicalKeyboard" if args.physical_keyboard_only else "automationInput",
                draft_release_action=args.draft_release_action,
                release_timeout=args.release_timeout,
            ))

        evidence["status"] = "passed"
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(json.dumps({"status": "passed", "report": str(output), "evidence": evidence}, indent=2, sort_keys=True))
        return 0
    except Exception as exc:
        evidence["status"] = "failed"
        evidence["error"] = {
            "type": type(exc).__name__,
            "message": str(exc),
        }
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(
            json.dumps(evidence, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        raise
    finally:
        if not args.keep and observer is not None and workspace_id is not None:
            try:
                mcp.tool_close_workspace({
                    "automationDir": automation_dir,
                    "timeout": args.timeout,
                    "targetWindowID": observer["windowID"],
                    "workspaceIDs": [workspace_id],
                })
            except Exception as exc:
                print(json.dumps({"cleanupWarning": str(exc), "workspaceID": workspace_id}), flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
