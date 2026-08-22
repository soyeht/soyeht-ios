#!/usr/bin/env python3
"""Deterministic E2E for human input replayed between two agent relays.

The sources and recipient are real catalog agents, while the harness uses
their persisted test credentials to control message timing precisely. Natural
language tool selection is covered separately by soyeht_agent_driven_e2e.py.
"""

from __future__ import annotations

import argparse
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import sys
from time import monotonic, sleep, time
import uuid

import soyeht_agent_driven_e2e as physical


def load_mcp(module_path: Path):
    loader = importlib.machinery.SourceFileLoader("soyeht_mcp2_broker_queue_module", str(module_path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def detach_external_observer_identity():
    for key in (
        "SOYEHT_AGENT_NAME",
        "SOYEHT_CONVERSATION_ID",
        "SOYEHT_HANDLE",
        "SOYEHT_LAUNCH_NONCE",
    ):
        os.environ.pop(key, None)
    foundation = sys.modules.get("soyeht_mcp_foundation")
    if foundation is not None:
        foundation._PARENT_PROCESS_ENVIRONMENT = {}


def snapshot_conversation(snapshot_path: Path, conversation_id: str):
    snapshot = json.loads(snapshot_path.read_text())
    return next(
        item
        for item in snapshot.get("conversations", [])
        if item.get("id") == conversation_id
    )


def wait_for_nonce(snapshot_path: Path, conversation_id: str, timeout: float) -> str:
    deadline = monotonic() + timeout
    while monotonic() < deadline:
        try:
            nonce = snapshot_conversation(snapshot_path, conversation_id).get(
                "agentLaunchOwnershipNonce"
            )
            if nonce:
                return nonce
        except (FileNotFoundError, json.JSONDecodeError, StopIteration):
            pass
        sleep(0.1)
    raise RuntimeError(f"No persisted launch nonce for {conversation_id}.")


def snapshot_message(snapshot_path: Path, conversation_id: str, message_id: str):
    try:
        conversation = snapshot_conversation(snapshot_path, conversation_id)
    except (FileNotFoundError, json.JSONDecodeError, StopIteration):
        return None
    inbox = conversation.get("agentMessageInbox") or {}
    return next(
        (
            item
            for item in inbox.get("messages", [])
            if str(item.get("id", "")).casefold() == message_id.casefold()
        ),
        None,
    )


def wait_for_message_state(snapshot_path, conversation_id, message_id, predicate, timeout):
    deadline = monotonic() + timeout
    latest = None
    while monotonic() < deadline:
        latest = snapshot_message(snapshot_path, conversation_id, message_id)
        if latest and predicate(latest):
            return latest
        sleep(0.1)
    raise RuntimeError(
        f"Message {message_id} did not reach the expected state. Latest: {latest!r}"
    )


def send_authenticated_message(
    mcp,
    automation_root,
    window_id,
    sender,
    sender_nonce,
    recipient,
    message_id,
    body,
    timeout,
):
    response = mcp.submit_request_to_root(
        automation_root,
        "send_agent_message",
        {
            "targetWindowID": window_id,
            "sourceConversationID": sender["conversationID"],
            "sourceHandle": sender["handle"],
            "nonce": sender_nonce,
            "conversationIDs": [recipient["conversationID"]],
            "text": body,
            "lineEnding": "enter",
            "deliveryPreference": "automatic",
            "requestAttention": False,
            "messageIDs": [message_id],
            "mcpClientContractVersion": 2,
            "mcpClientServerVersion": "2.0.0-broker-queue-e2e",
        },
        timeout=timeout,
        check_status=False,
    )
    require(response.get("status") == "ok", f"Agent message failed: {response}")
    delivery = response.get("agentMessageDeliveries", [{}])[0]
    require(
        delivery.get("status") == "queued_until_human_input_is_clear",
        f"Unexpected delivery plan: {delivery}",
    )
    return delivery


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--mcp-script",
        default="/Applications/Soyeht Dev.app/Contents/Resources/soyeht-mcp",
    )
    parser.add_argument("--automation-dir", required=True)
    parser.add_argument(
        "--workspace-snapshot",
        default=str(Path.home() / "Library/Application Support/SoyehtDev/workspaces.json"),
    )
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--timeout", type=float, default=90.0)
    parser.add_argument("--output")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    automation_dir = str(Path(args.automation_dir).expanduser().resolve())
    automation_root = Path(automation_dir)
    snapshot_path = Path(args.workspace_snapshot).expanduser().resolve()
    mcp = load_mcp(Path(args.mcp_script).resolve())
    detach_external_observer_identity()
    physical.require_accessibility_keyboard_control()

    windows = mcp.tool_list_windows({"automationDir": automation_dir, "timeout": args.timeout})
    require(windows.get("listedWindows"), "Soyeht Dev automation is not responding.")
    window_id = windows["listedWindows"][0]["windowID"]
    run_id = str(int(time()))
    workspace_id = None

    try:
        workspace = mcp.tool_open_workspace({
            "automationDir": automation_dir,
            "timeout": args.timeout,
            "targetWindowID": window_id,
            "name": f"mcp2-broker-queue-{run_id}",
            "agent": "shell",
            "panes": [{
                "name": f"mcp2-broker-observer-{run_id}",
                "path": str(repo_root),
                "agent": "shell",
                "command": "/bin/cat",
            }],
        })
        observer = workspace["createdPanes"][0]
        workspace_id = observer["workspaceID"]

        agents = {}
        for agent_id in ("codex", "claude", "opencode"):
            opened = mcp.tool_open_agent_pane({
                "automationDir": automation_dir,
                "timeout": args.timeout,
                "targetWindowID": window_id,
                "workspaceID": workspace_id,
                "agentID": agent_id,
                "cwd": str(repo_root),
                "name": f"mcp2-broker-{agent_id}-{run_id}",
                "activate": False,
            })
            require(opened.get("createdPanes"), f"Could not create {agent_id} pane.")
            agents[agent_id] = opened["createdPanes"][0]

        codex = agents["codex"]
        claude = agents["claude"]
        recipient = agents["opencode"]
        codex_nonce = wait_for_nonce(snapshot_path, codex["conversationID"], args.timeout)
        claude_nonce = wait_for_nonce(snapshot_path, claude["conversationID"], args.timeout)
        sleep(4.0)

        mcp.tool_emphasize_pane({
            "automationDir": automation_dir,
            "timeout": args.timeout,
            "targetWindowID": window_id,
            "conversationIDs": [recipient["conversationID"]],
            "mode": "zoom",
        })
        # Zoom rebuilds the rendered pane subtree. Let AppKit install the new
        # terminal view before clicking it; otherwise a valid window-level
        # keystroke can still target the responder from the previous pane.
        sleep(1.0)
        physical.raise_soyeht_dev_window(window_id)
        physical.click_soyeht_dev_pane(window_id, recipient["handle"])

        first_id = str(uuid.uuid4())
        second_id = str(uuid.uuid4())
        first_token = f"BROKER_FIRST_{run_id}"
        second_token = f"BROKER_SECOND_{run_id}"
        draft_token = f"HUMAN_DRAFT_{run_id}"
        first_delivery = send_authenticated_message(
            mcp,
            automation_root,
            window_id,
            codex,
            codex_nonce,
            recipient,
            first_id,
            f"{first_token} Não responda; este é um teste de fila. " + ("x" * 900),
            args.timeout,
        )

        # The delivery grace is 0.75s and a long broker paste waits 2s before
        # Return. Type in the middle of that transaction so these bytes are
        # replayed immediately before the first completion callback.
        sleep(1.0)
        physical.type_through_macos_keyboard(draft_token, window_id, submit_with_return=False)
        second_delivery = send_authenticated_message(
            mcp,
            automation_root,
            window_id,
            claude,
            claude_nonce,
            recipient,
            second_id,
            f"{second_token} Não responda; aguarde o rascunho humano.",
            args.timeout,
        )

        first_message = wait_for_message_state(
            snapshot_path,
            recipient["conversationID"],
            first_id,
            lambda item: item.get("deferredTerminalDeliveredAt") is not None,
            args.timeout,
        )
        sleep(2.75)
        held_second = snapshot_message(snapshot_path, recipient["conversationID"], second_id)
        require(held_second is not None, "Second message was not persisted.")
        require(
            held_second.get("deferredTerminalDeliveredAt") is None,
            "Second relay bypassed the human draft after the first broker transaction.",
        )

        physical.release_physical_draft("return", len(draft_token), window_id)
        delivered_second = wait_for_message_state(
            snapshot_path,
            recipient["conversationID"],
            second_id,
            lambda item: item.get("deferredTerminalDeliveredAt") is not None,
            args.timeout,
        )

        # Exercise the other producer that used to bypass the pane arbiter.
        # Raw send_pane_input simulates an unfinished terminal draft while an
        # agent relay owns the broker; a later complete send_pane_input must be
        # held until a raw Return releases that draft. The first half of this
        # test already covers actual physical typing/Return with agent TUIs.
        mcp.tool_emphasize_pane({
            "automationDir": automation_dir,
            "timeout": args.timeout,
            "targetWindowID": window_id,
            "conversationIDs": [observer["conversationID"]],
            "mode": "zoom",
        })
        shell_message_id = str(uuid.uuid4())
        shell_relay_token = f"BROKER_SHELL_RELAY_{run_id}"
        shell_draft_token = f"SHELL_HUMAN_DRAFT_{run_id}"
        shell_automation_token = f"SHELL_AUTOMATION_{run_id}"
        shell_delivery = send_authenticated_message(
            mcp,
            automation_root,
            window_id,
            codex,
            codex_nonce,
            observer,
            shell_message_id,
            f"{shell_relay_token} Não responda; este é um teste de arbitragem. "
            + ("y" * 900),
            args.timeout,
        )
        sleep(1.0)
        raw_draft_response = mcp.tool_send_pane_input({
            "automationDir": automation_dir,
            "timeout": args.timeout,
            "targetWindowID": window_id,
            "conversationIDs": [observer["conversationID"]],
            "text": shell_draft_token,
            "lineEnding": "none",
        })
        automation_response = mcp.tool_send_pane_input({
            "automationDir": automation_dir,
            "timeout": args.timeout,
            "targetWindowID": window_id,
            "conversationIDs": [observer["conversationID"]],
            "text": shell_automation_token,
            "lineEnding": "enter",
        })
        shell_relay = wait_for_message_state(
            snapshot_path,
            observer["conversationID"],
            shell_message_id,
            lambda item: item.get("deferredTerminalDeliveredAt") is not None,
            args.timeout,
        )
        draft_capture = physical.wait_for_transcript_token(
            mcp,
            observer,
            shell_draft_token,
            automation_dir,
            args.timeout,
        )
        sleep(2.75)
        held_capture = physical.capture_text(
            mcp,
            observer,
            automation_dir,
            args.timeout,
        )
        require(
            shell_automation_token not in held_capture,
            "send_pane_input bypassed the replayed human draft.",
        )
        raw_release_response = mcp.tool_send_pane_input({
            "automationDir": automation_dir,
            "timeout": args.timeout,
            "targetWindowID": window_id,
            "conversationIDs": [observer["conversationID"]],
            "text": "\r",
            "lineEnding": "none",
        })
        released_capture = physical.wait_for_transcript_token(
            mcp,
            observer,
            shell_automation_token,
            automation_dir,
            args.timeout,
        )

        evidence = {
            "status": "passed",
            "runID": run_id,
            "agents": {
                "firstSender": "codex",
                "secondSender": "claude",
                "recipient": "opencode",
            },
            "deliveryPlans": [first_delivery, second_delivery],
            "firstDeliveredAt": first_message.get("deferredTerminalDeliveredAt"),
            "secondDeliveredBeforeHumanReturn": False,
            "secondDeliveredAfterHumanReturnAt": delivered_second.get(
                "deferredTerminalDeliveredAt"
            ),
            "physicalDraftLength": len(draft_token),
            "rawAutomationArbitration": {
                "agentRelayPlan": shell_delivery,
                "agentRelayDeliveredAt": shell_relay.get(
                    "deferredTerminalDeliveredAt"
                ),
                "rawDraftStatus": raw_draft_response.get("status"),
                "sendPaneInputStatus": automation_response.get("status"),
                "rawReleaseStatus": raw_release_response.get("status"),
                "automationVisibleBeforeHumanReturn": False,
                "automationVisibleAfterHumanReturn": shell_automation_token
                in released_capture,
                "humanDraftVisibleBeforeReturn": shell_draft_token in draft_capture,
                "physicalDraftLength": len(shell_draft_token),
            },
        }
        rendered = json.dumps(evidence, indent=2, sort_keys=True) + "\n"
        if args.output:
            output = Path(args.output)
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(rendered)
        print(rendered, end="")
        return 0
    finally:
        if workspace_id:
            try:
                mcp.tool_close_workspace({
                    "automationDir": automation_dir,
                    "timeout": args.timeout,
                    "targetWindowID": window_id,
                    "workspaceIDs": [workspace_id],
                })
            except Exception as error:
                print(json.dumps({"cleanupWarning": str(error)}))


if __name__ == "__main__":
    raise SystemExit(main())
