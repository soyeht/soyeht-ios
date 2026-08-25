#!/usr/bin/env python3
"""Physical E2E for agents typed into ordinary Soyeht split panes.

This runner deliberately does *not* use open_agent_pane. It creates three
ordinary panes through the visible Split button, types the CLI commands through
macOS Accessibility, and proves that the resulting panes remain declared
``shell`` while acquiring an authenticated runtime identity. Real Codex,
Claude Code, and OpenCode instances then collaborate from natural-language
user requests. The disposable workspace is the only workspace the runner
closes.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
from time import monotonic, sleep, time

import soyeht_agent_driven_e2e as common
from soyeht_dev_ui_cleanup import close_workspace_through_ui


FORBIDDEN_PROMPT_TERMS = (
    "message_agent",
    "send_pane_input",
    "open_agent_pane",
    "soyeht-dev",
    "mcp",
    "nome da ferramenta",
    "nome da função",
)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def natural_prompt(text):
    folded = text.casefold()
    leaked = [
        term for term in FORBIDDEN_PROMPT_TERMS
        if (
            re.search(r"(?<!\w)mcp(?!\w)", folded)
            if term == "mcp"
            else term.casefold() in folded
        )
    ]
    require(not leaked, f"User prompt leaked implementation vocabulary: {leaked}")
    return text


def observer_args(observer, automation_dir, timeout):
    return {
        "automationDir": automation_dir,
        "timeout": timeout,
        "targetWindowID": observer["windowID"],
    }


def list_workspace_panes(mcp, observer, workspace_id, automation_dir, timeout):
    return mcp.tool_list_panes({
        **observer_args(observer, automation_dir, timeout),
        "workspaceID": workspace_id,
    }).get("listedPanes", [])


def wait_for_new_split_pane(
    mcp, observer, workspace_id, previous_ids, automation_dir, timeout
):
    deadline = monotonic() + timeout
    latest = []
    while monotonic() < deadline:
        latest = list_workspace_panes(
            mcp, observer, workspace_id, automation_dir, timeout
        )
        additions = [
            pane for pane in latest
            if pane.get("conversationID") not in previous_ids
        ]
        if len(additions) == 1:
            return additions[0]
        if len(additions) > 1:
            raise RuntimeError(
                "A single Split-button press created multiple panes: "
                f"{[item.get('conversationID') for item in additions]}"
            )
        sleep(0.2)
    raise RuntimeError(
        "The visible Split pane button did not create exactly one pane. "
        f"Latest inventory: {latest!r}"
    )


def press_header_button(window_id, pane_label, button_description):
    """Press the requested button closest to an exact visible pane label."""
    expected_identifier = f"com.soyeht.mac.mainwindow.{window_id}"
    visible_label = str(pane_label).removeprefix("@")
    script = r'''
on run argv
  set expectedIdentifier to item 1 of argv
  set expectedLabel to item 2 of argv
  set expectedDescription to item 3 of argv
  tell application id "com.soyeht.mac.dev" to activate
  delay 0.25
  tell application "System Events" to tell process "Soyeht Dev"
    repeat 40 times
      try
        set targetWindow to first window whose value of attribute "AXIdentifier" is expectedIdentifier
        perform action "AXRaise" of targetWindow
        -- Raising or reconciling a split can invalidate the AXUIElement proxy
        -- while keeping the same stable window identifier. Always reacquire it.
        delay 0.1
        set targetWindow to first window whose value of attribute "AXIdentifier" is expectedIdentifier
        set elements to entire contents of targetWindow
        set labelCenterY to missing value
        repeat with elementRef in elements
          try
            if role of elementRef is "AXStaticText" and (value of elementRef as text) is expectedLabel then
              set {labelX, labelY} to position of elementRef
              set {labelW, labelH} to size of elementRef
              set labelCenterX to labelX + (labelW / 2)
              set labelCenterY to labelY + (labelH / 2)
              exit repeat
            end if
          end try
        end repeat

        if labelCenterY is not missing value then
          set bestButton to missing value
          set bestDistanceY to 1000000
          set bestDistanceX to 1000000
          repeat with elementRef in elements
            try
              set candidateRole to role of elementRef
              if candidateRole is "AXButton" or candidateRole is "AXCheckBox" then
                set candidateDescription to value of attribute "AXDescription" of elementRef as text
                if candidateDescription is expectedDescription then
                  set {buttonX, buttonY} to position of elementRef
                  set {buttonW, buttonH} to size of elementRef
                  set distanceX to (buttonX + (buttonW / 2)) - labelCenterX
                  set distanceY to (buttonY + (buttonH / 2)) - labelCenterY
                  if distanceY < 0 then set distanceY to -distanceY
                  -- Header actions live to the right of their own label. In a
                  -- side-by-side grid, the previous pane's button can be
                  -- closer in absolute X; excluding negative distance keeps
                  -- the action inside the requested pane's header row.
                  if distanceX >= 0 and (distanceY < bestDistanceY or (distanceY = bestDistanceY and distanceX < bestDistanceX)) then
                    set bestDistanceY to distanceY
                    set bestDistanceX to distanceX
                    set bestButton to elementRef
                  end if
                end if
              end if
            end try
          end repeat
          if bestButton is not missing value and bestDistanceY <= 32 then
            perform action "AXPress" of bestButton
            return "pressed"
          end if
        end if
      end try
      delay 0.1
    end repeat
    error "Pane header action did not become available: " & expectedLabel & " / " & expectedDescription
  end tell
end run
'''
    completed = subprocess.run(
        [
            "/usr/bin/osascript", "-e", script,
            expected_identifier, visible_label, button_description,
        ],
        capture_output=True,
        text=True,
    )
    require(
        completed.returncode == 0,
        f"Could not press {button_description!r} for {visible_label!r}: "
        f"{completed.stderr.strip() or completed.stdout.strip()}",
    )
    return completed.stdout.strip()


def start_shell_in_visible_empty_pane(window_id):
    """Complete the ordinary Split-button flow through its session picker."""
    expected_identifier = f"com.soyeht.mac.mainwindow.{window_id}"
    script = r'''
on run argv
  set expectedIdentifier to item 1 of argv
  tell application id "com.soyeht.mac.dev" to activate
  delay 0.25
  tell application "System Events" to tell process "Soyeht Dev"
    set targetWindow to first window whose value of attribute "AXIdentifier" is expectedIdentifier
    perform action "AXRaise" of targetWindow
    delay 0.15
    repeat 40 times
      set targetWindow to first window whose value of attribute "AXIdentifier" is expectedIdentifier
      set matches to {}
      set elements to entire contents of targetWindow
      repeat with elementRef in elements
        try
          if role of elementRef is "AXButton" and description of elementRef is "Start bash session" then
            set end of matches to elementRef
          end if
        end try
      end repeat
      if (count of matches) is 1 then
        perform action "AXPress" of item 1 of matches
        return "started"
      end if
      if (count of matches) > 1 then error "More than one empty-pane shell action is visible"
      delay 0.1
    end repeat
    error "The empty-pane shell action did not appear"
  end tell
end run
'''
    completed = subprocess.run(
        ["/usr/bin/osascript", "-e", script, expected_identifier],
        capture_output=True,
        text=True,
    )
    require(
        completed.returncode == 0,
        "Could not start the ordinary shell selected after Split: "
        f"{completed.stderr.strip() or completed.stdout.strip()}",
    )


def rename_pane(mcp, observer, pane, new_name, automation_dir, timeout):
    mcp.tool_rename_panes({
        **observer_args(observer, automation_dir, timeout),
        "conversationIDs": [pane["conversationID"]],
        "newName": new_name,
        "paneNameStyle": "verbatim",
    })
    deadline = monotonic() + timeout
    while monotonic() < deadline:
        latest = list_workspace_panes(
            mcp, observer, pane["workspaceID"], automation_dir, timeout
        )
        renamed = next(
            (item for item in latest if item.get("conversationID") == pane["conversationID"]),
            None,
        )
        if renamed and renamed.get("handle") in {new_name, f"@{new_name}"}:
            return renamed
        sleep(0.2)
    raise RuntimeError(f"Pane {pane['conversationID']} was not renamed to {new_name}.")


def wait_for_active_pane(
    mcp, observer, workspace_id, pane_id, automation_dir, timeout
):
    deadline = monotonic() + min(timeout, 10.0)
    while monotonic() < deadline:
        panes = list_workspace_panes(
            mcp, observer, workspace_id, automation_dir, timeout
        )
        target = next(
            (item for item in panes if item.get("conversationID") == pane_id),
            None,
        )
        if target and target.get("isActive") is True:
            return
        sleep(0.1)
    raise RuntimeError(f"Physical click did not focus split pane {pane_id}.")


def capture_pane_input_point(window_id, pane_label):
    """Capture a stable composer point before a CLI changes its pane title."""
    expected_identifier = f"com.soyeht.mac.mainwindow.{window_id}"
    visible_label = str(pane_label).removeprefix("@")
    script = r'''
on run argv
  set expectedIdentifier to item 1 of argv
  set expectedLabel to item 2 of argv
  tell application id "com.soyeht.mac.dev" to activate
  delay 0.25
  tell application "System Events" to tell process "Soyeht Dev"
    repeat 40 times
      try
        set targetWindow to first window whose value of attribute "AXIdentifier" is expectedIdentifier
        perform action "AXRaise" of targetWindow
        delay 0.1
        set targetWindow to first window whose value of attribute "AXIdentifier" is expectedIdentifier
        set {windowX, windowY} to position of targetWindow
        set {windowWidth, windowHeight} to size of targetWindow
        set elements to entire contents of targetWindow
        repeat with elementRef in elements
          try
            if role of elementRef is "AXStaticText" and (value of elementRef as text) is expectedLabel then
              set {elementX, elementY} to position of elementRef
              set {elementWidth, elementHeight} to size of elementRef
              -- Clicking just below the header can activate a TUI message
              -- action through real mouse reporting. Target the lower
              -- composer area, like a user clicking before typing.
              return ((elementX + 100) as text) & "," & ((windowY + windowHeight - 130) as text)
            end if
          end try
        end repeat
      end try
      delay 0.1
    end repeat
    error "Visible pane label was not found: " & expectedLabel
  end tell
end run
'''
    completed = subprocess.run(
        ["/usr/bin/osascript", "-e", script, expected_identifier, visible_label],
        capture_output=True,
        text=True,
    )
    require(
        completed.returncode == 0,
        f"Could not capture terminal point for {visible_label!r}: "
        f"{completed.stderr.strip() or completed.stdout.strip()}",
    )
    try:
        return tuple(float(value) for value in completed.stdout.strip().split(","))
    except (TypeError, ValueError) as exc:
        raise RuntimeError(
            f"Invalid terminal point for {visible_label!r}: {completed.stdout!r}"
        ) from exc


def click_pane_input_point(window_id, point):
    """Focus an ordinary split without relying on a mutable agent title."""
    try:
        import Quartz
    except ImportError as exc:
        raise RuntimeError("PyObjC Quartz is required for physical input.") from exc

    common.raise_soyeht_dev_window(window_id)
    for event_type in (Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp):
        event = Quartz.CGEventCreateMouseEvent(
            None, event_type, point, Quartz.kCGMouseButtonLeft
        )
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
        sleep(0.05)
    sleep(0.15)


def focus_pane_for_physical_input(
    mcp, observer, workspace_id, pane, window_id, input_point,
    automation_dir, timeout,
):
    click_pane_input_point(window_id, input_point)
    try:
        wait_for_active_pane(
            mcp,
            observer,
            workspace_id,
            pane["conversationID"],
            automation_dir,
            min(timeout, 2.0),
        )
    except RuntimeError:
        # Four narrow columns make a lower-composer coordinate vulnerable to
        # transient layout reconciliation in Accessibility. Focusing the same
        # ordinary split through pane chrome keeps the assertion deterministic;
        # all actual CLI input below still arrives as macOS keyboard events,
        # and mouse/wheel behavior has its own physical smoke later in the run.
        focus_pane_without_terminal_mouse(
            mcp,
            observer,
            workspace_id,
            pane,
            automation_dir,
            timeout,
        )


def focus_pane_without_terminal_mouse(
    mcp, observer, workspace_id, pane, automation_dir, timeout
):
    """Focus a composer without sending a TUI mouse-reporting packet.

    Mouse reporting is deliberately preserved in ordinary shell panes. A
    physical click inside OpenCode may therefore move or activate its TUI and
    must conservatively make the draft gate uncertain. For the specific
    letter-by-letter abandonment scenario, focus through pane chrome state and
    keep the only terminal input under test to printable keys + Backspaces.
    """
    mcp.tool_emphasize_pane({
        **observer_args(observer, automation_dir, timeout),
        "conversationIDs": [pane["conversationID"]],
        "mode": "unzoom",
    })
    wait_for_active_pane(
        mcp,
        observer,
        workspace_id,
        pane["conversationID"],
        automation_dir,
        timeout,
    )


def launch_cli_physically(
    mcp, observer, workspace_id, pane, command, cwd, window_id,
    automation_dir, timeout, input_point,
):
    focus_pane_for_physical_input(
        mcp,
        observer,
        workspace_id,
        pane,
        window_id,
        input_point,
        automation_dir,
        timeout,
    )
    shell_line = f"cd {shlex.quote(str(cwd))} && {command}"
    common.type_through_macos_keyboard(
        shell_line,
        window_id,
        submit_with_return=True,
    )
    return shell_line


def wait_for_runtime_agent(
    mcp, observer, workspace_id, pane_id, expected_agent, automation_dir, timeout
):
    deadline = monotonic() + timeout
    latest = None
    while monotonic() < deadline:
        response = mcp.tool_list_agents({
            **observer_args(observer, automation_dir, timeout),
            "workspaceID": workspace_id,
        })
        latest = next(
            (
                item for item in response.get("listedAgents", [])
                if item.get("conversationID") == pane_id
            ),
            None,
        )
        if (
            latest
            and latest.get("declaredAgent") == "shell"
            and latest.get("activeRuntimeAgent") == expected_agent
            and latest.get("canReceiveMessage") is True
        ):
            return latest
        sleep(0.5)
    raise RuntimeError(
        f"Split pane {pane_id} did not claim {expected_agent!r} while remaining shell. "
        f"Latest directory row: {latest!r}"
    )


def confirm_startup_gate_if_runtime_is_pending(
    mcp, observer, workspace_id, pane, window_id, input_point,
    automation_dir, timeout,
):
    """Act like a user accepting a CLI's first-run directory prompt.

    Codex, Claude and other CLIs may stop before MCP initialization to ask
    whether the current checkout is trusted. Seeing the foreground process is
    therefore not enough to assert that its integrations have started. If the
    runtime is still absent after a short settling period, focus the exact pane
    and press one physical Return. On an already-ready composer this is only an
    empty submission; on a trust screen it is the required human confirmation.
    """
    sleep(1.0)
    response = mcp.tool_list_agents({
        **observer_args(observer, automation_dir, timeout),
        "workspaceID": workspace_id,
    })
    row = next(
        (
            item for item in response.get("listedAgents", [])
            if item.get("conversationID") == pane["conversationID"]
        ),
        None,
    )
    if row and row.get("activeRuntimeAgent"):
        return {"physicalReturnPosted": False, "reason": "runtime_already_ready"}
    focus_pane_for_physical_input(
        mcp,
        observer,
        workspace_id,
        pane,
        window_id,
        input_point,
        automation_dir,
        timeout,
    )
    common.type_through_macos_keyboard(
        "",
        window_id,
        submit_with_return=True,
    )
    return {"physicalReturnPosted": True, "reason": "runtime_identity_pending"}


def wait_for_agent_idle(mcp, observer, pane_id, automation_dir, timeout):
    """Start the collision scenario from a real, settled TUI composer."""
    deadline = monotonic() + timeout
    latest = None
    while monotonic() < deadline:
        response = mcp.tool_get_pane_status({
            **observer_args(observer, automation_dir, timeout),
            "conversationIDs": [pane_id],
        })
        latest = next(iter(response.get("paneStatuses", [])), None)
        if latest and latest.get("agentState") == "idle":
            return latest
        sleep(0.25)
    raise RuntimeError(
        f"Agent pane {pane_id} did not become idle before physical typing: {latest!r}"
    )


def observed_cli_process(pane_id, agent_name, expected_cwd, timeout):
    """Prove a real CLI process without persisting its environment/secrets."""
    deadline = monotonic() + timeout
    expected_cwd = str(Path(expected_cwd).resolve())
    while monotonic() < deadline:
        rows = subprocess.run(
            ["/bin/ps", "eww", "-axo", "pid=,command="],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.splitlines()
        for row in rows:
            if f"SOYEHT_CONVERSATION_ID={pane_id}" not in row:
                continue
            head = row.strip().split(None, 1)
            if len(head) != 2 or not head[0].isdigit():
                continue
            pid = int(head[0])
            command_prefix = head[1].split(" SOYEHT_", 1)[0]
            if "soyeht" in command_prefix.casefold() or agent_name not in command_prefix.casefold():
                continue
            cwd = common.process_cwd(pid)
            if cwd == expected_cwd:
                environment_keys = {
                    token.split("=", 1)[0]
                    for token in head[1].split()
                    if "=" in token
                }
                return {
                    "pid": pid,
                    "cwd": cwd,
                    "agentCommandObserved": agent_name,
                    "launchNoncePresent": "SOYEHT_LAUNCH_NONCE" in environment_keys,
                    "claudeChildSessionPresent": (
                        "CLAUDE_CODE_CHILD_SESSION" in environment_keys
                    ),
                    "environmentRedacted": True,
                }
        sleep(0.4)
    raise RuntimeError(
        f"No real {agent_name} process was observed for split pane {pane_id} in {expected_cwd}."
    )


def inbox_messages(recipient):
    return common.persisted_inbox_messages(recipient)


def wait_for_message(recipient, sender, token, timeout):
    deadline = monotonic() + timeout
    latest = []
    while monotonic() < deadline:
        latest = inbox_messages(recipient)
        found = next(
            (
                message for message in latest
                if token in message.get("body", "")
                and message.get("senderConversationID") == sender["conversationID"]
                and message.get("mcpClientContractVersion") == 3
            ),
            None,
        )
        if found:
            return found
        sleep(0.5)
    raise RuntimeError(
        f"No contract-3 message {token!r} from {sender['handle']} to "
        f"{recipient['handle']}."
    )


def send_natural_request(
    mcp, observer, workspace_id, pane, window_id, prompt, input_point,
    automation_dir, timeout,
):
    natural_prompt(prompt)
    focus_pane_for_physical_input(
        mcp,
        observer,
        workspace_id,
        pane,
        window_id,
        input_point,
        automation_dir,
        timeout,
    )
    common.type_through_macos_keyboard(prompt, window_id, submit_with_return=True)


def wait_for_delivery(recipient, message_id, delivered, timeout):
    deadline = monotonic() + timeout
    latest = None
    while monotonic() < deadline:
        latest = next(
            (
                item for item in inbox_messages(recipient)
                if item.get("messageID") == message_id
            ),
            None,
        )
        is_delivered = bool(latest and latest.get("deferredTerminalDeliveredAt"))
        if latest is not None and is_delivered == delivered:
            return latest
        sleep(0.25)
    raise RuntimeError(
        f"Message {message_id} delivery state did not become {delivered}: {latest!r}"
    )


def physical_tui_input_smoke(
    mcp, observer, workspace_id, window_id, pane, input_point,
    automation_dir, timeout,
):
    """Send mouse, wheel, and navigation keys through the macOS event path."""
    try:
        import Quartz
    except ImportError as exc:
        raise RuntimeError("PyObjC Quartz is required for physical input smoke.") from exc

    focus_pane_for_physical_input(
        mcp,
        observer,
        workspace_id,
        pane,
        window_id,
        input_point,
        automation_dir,
        timeout,
    )
    point = input_point
    for event_type in (Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp):
        event = Quartz.CGEventCreateMouseEvent(
            None, event_type, point, Quartz.kCGMouseButtonLeft
        )
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
    wheel = Quartz.CGEventCreateScrollWheelEvent(
        None, Quartz.kCGScrollEventUnitLine, 1, -4
    )
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, wheel)

    script = r'''
tell application "System Events"
  key code 123
  key code 124
  key code 125
  key code 126
  key code 48
  key code 53
end tell
'''
    subprocess.run(
        ["/usr/bin/osascript", "-e", script],
        check=True,
        capture_output=True,
        text=True,
    )
    return {
        "mouseClickPosted": True,
        "scrollWheelPosted": True,
        "arrowKeysPosted": ["left", "right", "down", "up"],
        "tabAndEscapePosted": True,
    }


def snapshot_document():
    return json.loads(common.WORKSPACE_SNAPSHOT_PATH.read_text(encoding="utf-8"))


def workspace_manager_ids(workspace_id):
    document = snapshot_document()
    workspace = next(
        item for item in document.get("workspaces", []) if item.get("id") == workspace_id
    )
    return set(
        workspace.get("orchestration", {}).get("authorizedManagerPaneIDs", [])
    )


def wait_for_manager_state(workspace_id, pane_id, expected, timeout):
    deadline = monotonic() + timeout
    while monotonic() < deadline:
        observed = pane_id in workspace_manager_ids(workspace_id)
        if observed == expected:
            return observed
        sleep(0.2)
    raise RuntimeError(
        f"Orchestrator privilege for {pane_id} did not become {expected}."
    )


def safe_mcp_config_evidence(profile_key):
    """Read only the owned command/args; never serialize unrelated config."""
    home = Path.home()
    evidence = {}
    claude = json.loads((home / ".claude.json").read_text())
    claude_entry = claude.get("mcpServers", {}).get(profile_key, {})
    evidence["claude"] = {
        "commandBasename": Path(claude_entry.get("command", "")).name,
        "args": claude_entry.get("args"),
    }
    opencode = json.loads(
        (home / ".config/opencode/opencode.json").read_text()
    )
    opencode_command = opencode.get("mcp", {}).get(profile_key, {}).get("command", [])
    evidence["opencode"] = {
        "commandBasename": Path(opencode_command[0]).name if opencode_command else "",
        "args": opencode_command[1:],
    }
    codex_text = (home / ".codex/config.toml").read_text()
    match = re.search(
        rf"(?ms)^\[mcp_servers\.{re.escape(profile_key)}\]\s*$"
        rf"(?P<body>.*?)(?=^\[|\Z)",
        codex_text,
    )
    require(match is not None, f"Codex entry {profile_key!r} is absent.")
    args_match = re.search(r"(?m)^args\s*=\s*(\[[^\n]*\])", match.group("body"))
    evidence["codex"] = {
        "commandBasename": "soyeht-dev-mcp",
        "argsLiteral": args_match.group(1) if args_match else None,
    }
    return evidence


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument(
        "--automation-dir",
        default=str(Path.home() / "Library/Application Support/SoyehtDev/Automation"),
    )
    parser.add_argument(
        "--workspace-snapshot",
        default=str(Path.home() / "Library/Application Support/SoyehtDev/workspaces.json"),
    )
    parser.add_argument("--expected-commit", required=True)
    parser.add_argument("--timeout", type=float, default=300.0)
    parser.add_argument("--output", required=True)
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    automation_dir = str(Path(args.automation_dir).expanduser().resolve())
    require("SoyehtDev/Automation" in automation_dir, "Runner is Dev-only.")
    common.require_accessibility_keyboard_control()
    mcp_path = Path("/Applications/Soyeht Dev.app/Contents/Resources/soyeht-mcp")
    mcp = common.load_mcp(mcp_path)
    common.detach_external_observer_identity()
    common.WORKSPACE_SNAPSHOT_PATH = Path(args.workspace_snapshot).expanduser().resolve()

    provenance = common.installed_app_provenance(Path("/Applications/Soyeht Dev.app"))
    require(provenance["commit"] == args.expected_commit, "Installed commit mismatch.")
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
    require(repo_commit == args.expected_commit, "Checkout commit mismatch.")
    require(not repo_dirty, "Runner requires a clean checkout.")

    run_id = str(int(time()))
    output = Path(args.output).resolve()
    evidence = {
        "kind": "manual-split-agent-mcp-e2e",
        "runID": run_id,
        "installedApp": provenance,
        "status": "running",
        "panes": [],
        "collaboration": [],
    }
    workspace_id = None
    observer = None

    try:
        workspace = mcp.tool_open_workspace({
            "automationDir": automation_dir,
            "timeout": args.timeout,
            "name": f"manual-split-agent-e2e-{run_id}",
            "agent": "shell",
            "panes": [{
                "name": f"split-source-{run_id}",
                "path": str(repo_root),
                "agent": "shell",
                "command": "/bin/zsh -l",
            }],
        })
        observer = workspace["createdPanes"][0]
        workspace_id = observer["workspaceID"]
        window_id = observer["windowID"]
        sleep(1.5)

        agent_specs = [
            ("codex", "codex --yolo"),
            ("claude", "claude"),
            ("opencode", "opencode --auto"),
        ]
        manual_panes = {}
        known_ids = {observer["conversationID"]}
        for agent_name, _ in agent_specs:
            press_header_button(
                window_id,
                observer["handle"],
                "Split pane vertically",
            )
            start_shell_in_visible_empty_pane(window_id)
            pane = wait_for_new_split_pane(
                mcp,
                observer,
                workspace_id,
                known_ids,
                automation_dir,
                args.timeout,
            )
            known_ids.add(pane["conversationID"])
            pane = rename_pane(
                mcp,
                observer,
                pane,
                f"manual-{agent_name}-{run_id}",
                automation_dir,
                args.timeout,
            )
            require(pane.get("declaredAgent") == "shell", "Split pane was not a shell.")
            manual_panes[agent_name] = pane

        input_points = {
            agent_name: capture_pane_input_point(window_id, pane["handle"])
            for agent_name, pane in manual_panes.items()
        }

        for agent_name, command in agent_specs:
            pane = manual_panes[agent_name]
            typed = launch_cli_physically(
                mcp,
                observer,
                workspace_id,
                pane,
                command,
                repo_root,
                window_id,
                automation_dir,
                args.timeout,
                input_points[agent_name],
            )
            process = observed_cli_process(
                pane["conversationID"], agent_name, repo_root, args.timeout
            )
            startup_confirmation = confirm_startup_gate_if_runtime_is_pending(
                mcp,
                observer,
                workspace_id,
                pane,
                window_id,
                input_points[agent_name],
                automation_dir,
                args.timeout,
            )
            try:
                directory_row = wait_for_runtime_agent(
                    mcp,
                    observer,
                    workspace_id,
                    pane["conversationID"],
                    agent_name,
                    automation_dir,
                    args.timeout,
                )
            except Exception as exc:
                raise RuntimeError(
                    f"{exc} The CLI process was already observed with "
                    f"pid={process['pid']}, cwd={process['cwd']!r}, and "
                    f"launchNoncePresent={process['launchNoncePresent']}."
                ) from exc
            require(
                process["launchNoncePresent"],
                f"Manual {agent_name} did not inherit SOYEHT_LAUNCH_NONCE.",
            )
            if agent_name == "claude":
                require(
                    not process["claudeChildSessionPresent"],
                    "Manual Claude inherited CLAUDE_CODE_CHILD_SESSION and "
                    "disabled transcript saving.",
                )
            evidence["panes"].append({
                "agent": agent_name,
                "createdBy": "visible Split pane vertically button",
                "launchInput": typed,
                "pane": pane,
                "directoryRow": directory_row,
                "process": process,
                "startupConfirmation": startup_confirmation,
                "declaredPaneStylePreserved": directory_row.get("declaredAgent") == "shell",
            })
            sleep(2.0)

        evidence["mcpConfig"] = safe_mcp_config_evidence("soyeht-dev")

        # User-owned privilege: on -> usable, then off again. The UI state is
        # persisted, so the oracle is independent of the button's paint.
        codex = manual_panes["codex"]
        press_header_button(
            window_id,
            codex["handle"],
            "Toggle agent orchestrator privilege",
        )
        wait_for_manager_state(workspace_id, codex["conversationID"], True, args.timeout)
        evidence["orchestratorToggle"] = {
            "enabledThroughVisibleButton": True,
            "managerPaneID": codex["conversationID"],
        }

        ring = [
            ("codex", "claude"),
            ("claude", "opencode"),
            ("opencode", "codex"),
        ]
        for index, (sender_name, recipient_name) in enumerate(ring, start=1):
            sender = manual_panes[sender_name]
            recipient = manual_panes[recipient_name]
            token = f"SPLIT-E2E-{run_id}-{index}"
            # Inbox persistence can prove that the previous reply exists a
            # fraction of a second before the sender TUI finishes rendering
            # its final answer and returns to the composer. A real user waits
            # for that transition before typing the next instruction; make the
            # physical test preserve the same boundary.
            wait_for_agent_idle(
                mcp,
                observer,
                sender["conversationID"],
                automation_dir,
                args.timeout,
            )
            prompt = natural_prompt(
                "Sem alterar arquivos e sem criar agentes, subagentes ou panes, "
                f"envie uma mensagem para o agente [{recipient['handle'].removeprefix('@')}] "
                "que ja esta aberto em uma pane visivel deste mesmo workspace do Soyeht. "
                f"Peca que ele responda a voce com exatamente {token}. "
                "Aguarde a resposta que vier dessa pane antes de encerrar esta tarefa."
            )
            send_natural_request(
                mcp,
                observer,
                workspace_id,
                sender,
                window_id,
                prompt,
                input_points[sender_name],
                automation_dir,
                args.timeout,
            )
            request = wait_for_message(recipient, sender, token, args.timeout)
            reply = wait_for_message(sender, recipient, token, args.timeout)
            evidence["collaboration"].append({
                "status": "passed",
                "senderAgent": sender_name,
                "recipientAgent": recipient_name,
                "userPrompt": prompt,
                "requestMessageID": request.get("messageID"),
                "replyMessageID": reply.get("messageID"),
                "requestContract": request.get("mcpClientContractVersion"),
                "replyContract": reply.get("mcpClientContractVersion"),
            })

        # Real unfinished user input in OpenCode must hold a Codex relay.
        recipient = manual_panes["opencode"]
        sender = manual_panes["codex"]
        settled_recipient = wait_for_agent_idle(
            mcp,
            observer,
            recipient["conversationID"],
            automation_dir,
            args.timeout,
        )
        draft = f"RASCUNHO-{run_id}-NAO-ENVIADO"
        focus_pane_without_terminal_mouse(
            mcp,
            observer,
            workspace_id,
            recipient,
            automation_dir,
            args.timeout,
        )
        # Activating a pane through automation does not necessarily make the
        # containing macOS window frontmost. Re-raise and verify the exact
        # disposable window immediately before physical typing so another app
        # cannot turn this safety check into a flaky false failure.
        common.raise_soyeht_dev_window(window_id)
        common.type_through_macos_keyboard(draft, window_id, submit_with_return=False)
        relay_token = f"SPLIT-COLLISION-{run_id}"
        collision_prompt = natural_prompt(
            "Sem criar agentes, subagentes ou panes, envie uma mensagem para o agente "
            f"[{recipient['handle'].removeprefix('@')}] que ja esta aberto em uma pane "
            "visivel deste mesmo workspace do Soyeht. "
            f"Peca que ele responda exatamente {relay_token} e aguarde a resposta dessa pane."
        )
        send_natural_request(
            mcp,
            observer,
            workspace_id,
            sender,
            window_id,
            collision_prompt,
            input_points["codex"],
            automation_dir,
            args.timeout,
        )
        request = wait_for_message(recipient, sender, relay_token, args.timeout)
        held = wait_for_delivery(recipient, request["messageID"], False, args.timeout)
        require(
            held.get("channel") == "deferredTerminal",
            "A client without proven wake capability suppressed terminal fallback.",
        )
        focus_pane_without_terminal_mouse(
            mcp,
            observer,
            workspace_id,
            recipient,
            automation_dir,
            args.timeout,
        )
        common.release_physical_draft("backspace", len(draft), window_id)
        delivered = wait_for_delivery(
            recipient, request["messageID"], True, args.timeout
        )
        reply = wait_for_message(sender, recipient, relay_token, args.timeout)
        evidence["typingCollision"] = {
            "status": "passed",
            "senderAgent": "codex",
            "recipientAgent": "opencode",
            "channel": delivered.get("channel"),
            "physicalDraft": draft,
            "heldBeforeBackspace": held.get("deferredTerminalDeliveredAt") is None,
            "terminalBytesInjected": bool(
                delivered.get("deferredTerminalDeliveredAt")
            ),
            "expectedTerminalDelivery": True,
            "replyMessageID": reply.get("messageID"),
            "recipientStateBeforeDraft": settled_recipient.get("agentState"),
            "focusAvoidedTerminalMousePacket": True,
        }

        # Exercise the native event path after authentication. The pane is
        # still declared shell, which is the product invariant that retains
        # normal terminal mouse reporting and scroll behavior.
        evidence["normalPaneInputSmoke"] = physical_tui_input_smoke(
            mcp,
            observer,
            workspace_id,
            window_id,
            manual_panes["opencode"],
            input_points["opencode"],
            automation_dir,
            args.timeout,
        )
        final_row = wait_for_runtime_agent(
            mcp,
            observer,
            workspace_id,
            manual_panes["opencode"]["conversationID"],
            "opencode",
            automation_dir,
            args.timeout,
        )
        evidence["normalPaneInputSmoke"]["runtimeStillHealthy"] = True
        evidence["normalPaneInputSmoke"]["declaredAgentAfterInput"] = final_row.get(
            "declaredAgent"
        )

        press_header_button(
            window_id,
            codex["handle"],
            "Toggle agent orchestrator privilege",
        )
        wait_for_manager_state(workspace_id, codex["conversationID"], False, args.timeout)
        evidence["orchestratorToggle"]["disabledThroughVisibleButton"] = True

        cleanup = close_workspace_through_ui(
            snapshot_path=common.WORKSPACE_SNAPSHOT_PATH,
            workspace_id=workspace_id,
            window_id=window_id,
            timeout=min(args.timeout, 30.0),
        )
        evidence["cleanup"] = cleanup
        workspace_id = None
        observer = None
        evidence["status"] = "passed"
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
        print(json.dumps({"status": "passed", "report": str(output)}, indent=2))
        return 0
    except Exception as exc:
        evidence["status"] = "failed"
        evidence["error"] = {"type": type(exc).__name__, "message": str(exc)}
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
        raise
    finally:
        if not args.keep and observer is not None and workspace_id is not None:
            try:
                close_workspace_through_ui(
                    snapshot_path=common.WORKSPACE_SNAPSHOT_PATH,
                    workspace_id=workspace_id,
                    window_id=observer["windowID"],
                    timeout=min(args.timeout, 30.0),
                )
            except Exception as cleanup_error:
                print(
                    json.dumps({
                        "cleanupFailure": str(cleanup_error),
                        "workspaceID": workspace_id,
                    }),
                    file=sys.stderr,
                )


if __name__ == "__main__":
    raise SystemExit(main())
