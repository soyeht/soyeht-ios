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
from time import time


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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--automation-dir", required=True)
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
