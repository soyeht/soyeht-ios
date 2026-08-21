#!/usr/bin/env python3
"""Behavioral security-boundary probes against a running Soyeht Dev app."""

from __future__ import annotations

import argparse
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
from time import monotonic, sleep, time


def load_mcp(repo_root: Path):
    module_path = repo_root / "scripts" / "soyeht-mcp"
    loader = importlib.machinery.SourceFileLoader("soyeht_mcp2_security_module", str(module_path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


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


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def expect_runtime_rejection(case, expected_fragment, action):
    try:
        action()
    except RuntimeError as error:
        message = str(error)
        require(
            expected_fragment in message,
            f"{case} returned an unexpected rejection: {message}",
        )
        return {
            "case": case,
            "expected": "rejected",
            "result": "rejected",
            "message": message,
        }
    raise RuntimeError(f"{case} unexpectedly succeeded.")


def signed_team_id(app_path: Path) -> str:
    completed = subprocess.run(
        ["/usr/bin/codesign", "-dvv", str(app_path)],
        check=True,
        capture_output=True,
        text=True,
    )
    for line in completed.stderr.splitlines():
        if line.startswith("TeamIdentifier="):
            return line.split("=", 1)[1]
    return ""


def persisted_launch_nonce(snapshot_path: Path, conversation_id: str, timeout: float) -> str:
    deadline = monotonic() + timeout
    while monotonic() < deadline:
        try:
            snapshot = json.loads(snapshot_path.read_text())
            conversation = next(
                item
                for item in snapshot.get("conversations", [])
                if item.get("id") == conversation_id
            )
            nonce = conversation.get("agentLaunchOwnershipNonce")
            if nonce:
                return nonce
        except (FileNotFoundError, json.JSONDecodeError, StopIteration):
            pass
        sleep(0.2)
    raise RuntimeError(
        f"Persistent snapshot never recorded a launch nonce for {conversation_id}."
    )


def policy_request(root, mcp, pane, nonce, window_id, timeout, **policy):
    return mcp.submit_request_to_root(
        root,
        "set_agent_communication_policy",
        {
            "targetWindowID": window_id,
            "sourceConversationID": pane["conversationID"],
            "sourceHandle": pane["handle"],
            "nonce": nonce,
            "mcpClientContractVersion": 2,
            "mcpClientServerVersion": "2.0.0-security-probe",
            **policy,
        },
        timeout=timeout,
        check_status=False,
    )


def restart_dev_and_wait(mcp, automation_dir, timeout):
    subprocess.run(
        ["/usr/bin/osascript", "-e", 'tell application id "com.soyeht.mac.dev" to quit'],
        check=False,
        capture_output=True,
        text=True,
    )
    sleep(1.0)
    subprocess.run(["/usr/bin/open", "-na", "/Applications/Soyeht Dev.app"], check=True)
    deadline = monotonic() + timeout
    latest_error = None
    while monotonic() < deadline:
        try:
            windows = mcp.tool_list_windows({
                "automationDir": automation_dir,
                "timeout": min(timeout, 5.0),
            })
            if windows.get("listedWindows"):
                return windows
        except RuntimeError as error:
            latest_error = error
        sleep(0.25)
    raise RuntimeError(f"Soyeht Dev did not resume automation after restart: {latest_error}")


def wait_for_restored_ownership(root, mcp, pane, nonce, window_id, timeout):
    deadline = monotonic() + timeout
    latest = None
    while monotonic() < deadline:
        latest = policy_request(
            root,
            mcp,
            pane,
            nonce,
            window_id,
            min(timeout, 5.0),
            outgoingEnabled=True,
        )
        if latest.get("status") == "ok":
            return latest
        sleep(0.25)
    return latest or {"status": "error", "message": "No ownership response."}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--automation-dir", required=True)
    parser.add_argument(
        "--workspace-snapshot",
        default=str(Path.home() / "Library/Application Support/SoyehtDev/workspaces.json"),
    )
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--output")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    automation_dir = str(Path(args.automation_dir).expanduser().resolve())
    require(
        "Soyeht/Automation" not in automation_dir,
        "Refusing to probe the release Soyeht automation directory.",
    )
    mcp = load_mcp(repo_root)
    detach_external_observer_identity()
    root = Path(automation_dir)
    snapshot_path = Path(args.workspace_snapshot).expanduser().resolve()
    unique = str(int(time()))
    workspace_id = None

    windows = mcp.tool_list_windows({
        "automationDir": automation_dir,
        "timeout": args.timeout,
    })
    require(windows.get("listedWindows"), "Soyeht Dev automation is not responding.")
    window_id = windows["listedWindows"][0]["windowID"]

    try:
        workspace = mcp.tool_open_workspace({
            "automationDir": automation_dir,
            "timeout": args.timeout,
            "targetWindowID": window_id,
            "name": f"mcp2-security-{unique}",
            "agent": "shell",
            "panes": [{
                "name": f"mcp2-security-shell-{unique}",
                "path": str(repo_root),
                "agent": "shell",
                "command": "/bin/cat",
            }],
        })
        shell = workspace["createdPanes"][0]
        workspace_id = shell["workspaceID"]

        opened = {}
        for agent_id in ("codex", "opencode"):
            response = mcp.tool_open_agent_pane({
                "automationDir": automation_dir,
                "timeout": args.timeout,
                "targetWindowID": window_id,
                "workspaceID": workspace_id,
                "agentID": agent_id,
                "cwd": str(repo_root),
                "name": f"mcp2-security-{agent_id}-{unique}",
            })
            require(response.get("createdPanes"), f"Could not create {agent_id} probe pane.")
            opened[agent_id] = response["createdPanes"][0]

        codex = opened["codex"]
        opencode = opened["opencode"]
        codex_nonce = persisted_launch_nonce(snapshot_path, codex["conversationID"], args.timeout)
        opencode_nonce = persisted_launch_nonce(snapshot_path, opencode["conversationID"], args.timeout)
        cases = [
            expect_runtime_rejection(
                "legacy-agent-write",
                "Low-level send_pane_input cannot write to agent pane",
                lambda: mcp.tool_send_pane_input({
                    "automationDir": automation_dir,
                    "timeout": args.timeout,
                    "targetWindowID": window_id,
                    "conversationIDs": [opencode["conversationID"]],
                    "text": "MCP2_LEGACY_WRITE_MUST_NOT_APPEAR",
                    "lineEnding": "none",
                }),
            ),
            expect_runtime_rejection(
                "spoof-policy-without-launch-nonce",
                "SOYEHT_LAUNCH_NONCE",
                lambda: mcp.tool_set_agent_communication_policy({
                    "automationDir": automation_dir,
                    "timeout": args.timeout,
                    "targetWindowID": window_id,
                    "sourceConversationID": codex["conversationID"],
                    "sourceHandle": codex["handle"],
                    "incomingEnabled": False,
                }),
            ),
        ]

        valid_ownership = policy_request(
            root,
            mcp,
            codex,
            codex_nonce,
            window_id,
            args.timeout,
            incomingEnabled=True,
        )
        require(valid_ownership.get("status") == "ok", "The owning pane's valid nonce was rejected.")
        cases.append({
            "case": "owning-pane-valid-launch-nonce",
            "expected": "accepted",
            "result": "accepted",
        })

        unsubmitted_message = mcp.submit_request_to_root(
            root,
            "send_agent_message",
            {
                "targetWindowID": window_id,
                "sourceConversationID": codex["conversationID"],
                "sourceHandle": codex["handle"],
                "nonce": codex_nonce,
                "conversationIDs": [opencode["conversationID"]],
                "text": "MCP2_UNSUBMITTED_AGENT_MESSAGE_MUST_NOT_APPEAR",
                "lineEnding": "none",
                "deliveryPreference": "automatic",
                "mcpClientContractVersion": 2,
                "mcpClientServerVersion": "2.0.0-security-probe",
            },
            timeout=args.timeout,
            check_status=False,
        )
        require(
            unsubmitted_message.get("status") == "error",
            "An unsubmitted durable agent message was accepted.",
        )
        require(
            "lineEnding=enter" in unsubmitted_message.get("message", ""),
            "Unsubmitted agent message returned the wrong error.",
        )
        cases.append({
            "case": "agent-message-cannot-use-line-ending-none",
            "expected": "rejected",
            "result": "rejected",
            "message": unsubmitted_message["message"],
        })

        wrong_owner = policy_request(
            root,
            mcp,
            codex,
            opencode_nonce,
            window_id,
            args.timeout,
            incomingEnabled=False,
        )
        require(wrong_owner.get("status") == "error", "A valid nonce from another pane was accepted.")
        require(
            "SOYEHT_LAUNCH_NONCE" in wrong_owner.get("message", ""),
            "Cross-pane nonce rejection returned the wrong error.",
        )
        cases.append({
            "case": "valid-other-pane-nonce-cannot-spoof-owner",
            "expected": "rejected",
            "result": "rejected",
            "message": wrong_owner["message"],
        })

        old_contract = mcp.submit_request_to_root(
            root,
            "set_agent_communication_policy",
            {
                "targetWindowID": window_id,
                "sourceConversationID": codex["conversationID"],
                "sourceHandle": codex["handle"],
                "incomingEnabled": False,
                "mcpClientContractVersion": 1,
                "mcpClientServerVersion": "1.x-probe",
            },
            timeout=args.timeout,
            check_status=False,
        )
        require(old_contract.get("status") == "error", "Old MCP contract unexpectedly succeeded.")
        require("contract 1" in old_contract.get("message", ""), "Old contract returned the wrong error.")
        cases.append({
            "case": "old-contract-sensitive-write",
            "expected": "rejected",
            "result": "rejected",
            "message": old_contract["message"],
        })

        resumed_windows = restart_dev_and_wait(mcp, automation_dir, args.timeout)
        resumed_window_ids = {item["windowID"] for item in resumed_windows["listedWindows"]}
        require(window_id in resumed_window_ids, "The persistent test window did not restore.")
        restored_ownership = wait_for_restored_ownership(
            root,
            mcp,
            codex,
            codex_nonce,
            window_id,
            args.timeout,
        )
        require(
            restored_ownership.get("status") == "ok",
            f"Restored pane lost its launch ownership: {restored_ownership.get('message')}",
        )
        cases.append({
            "case": "launch-ownership-survives-app-restart",
            "expected": "accepted",
            "result": "accepted",
        })

        app_path = Path("/Applications/Soyeht Dev.app")
        commit = subprocess.run(
            ["/usr/bin/git", "rev-parse", "--short=8", "HEAD"],
            cwd=repo_root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        evidence = {
            "status": "passed",
            "app": {
                "bundleID": "com.soyeht.mac.dev",
                "commit": commit,
                "installation": str(app_path),
                "signedTeamID": signed_team_id(app_path),
            },
            "cases": cases,
            "createdAgents": {
                agent_id: {
                    "conversationID": pane["conversationID"],
                    "handle": pane["handle"],
                }
                for agent_id, pane in opened.items()
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
