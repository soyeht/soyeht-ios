#!/usr/bin/env python3
"""Smoke test Soyeht MCP agent-directory and agent-to-agent messaging.

This script expects a running Soyeht macOS app with automation enabled. Pass
--automation-dir when testing an isolated Soyeht Dev instance.
"""

import argparse
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
from time import sleep, time


def load_mcp(repo_root: Path):
    module_path = repo_root / "scripts" / "soyeht-mcp"
    loader = importlib.machinery.SourceFileLoader("soyeht_mcp", str(module_path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def default_automation_dir() -> str:
    return os.environ.get(
        "SOYEHT_AUTOMATION_DIR",
        str(Path.home() / "Library" / "Application Support" / "Soyeht" / "Automation"),
    )


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--automation-dir", default=default_automation_dir())
    parser.add_argument("--workspace-name", default="qa-mcp-agent-messaging")
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument("--keep", action="store_true", help="Do not close the created workspace.")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    mcp = load_mcp(repo_root)
    automation_dir = args.automation_dir
    unique = str(int(time()))
    created_workspace_id = None
    evidence = {}

    try:
        windows = mcp.tool_list_windows({"automationDir": automation_dir, "timeout": args.timeout})
        require(windows.get("listedWindows") is not None, "Soyeht automation did not return listedWindows.")
        evidence["windowCountBefore"] = len(windows.get("listedWindows", []))

        created = mcp.tool_open_workspace({
            "automationDir": automation_dir,
            "timeout": args.timeout,
            "name": f"{args.workspace_name}-{unique}",
            "agent": "shell",
            "panes": [
                {"name": f"qa mcp source {unique}", "path": str(repo_root), "agent": "shell", "command": "/bin/bash"},
                {"name": f"qa mcp target {unique}", "path": str(repo_root), "agent": "shell", "command": "/bin/bash"},
            ],
        })
        panes = created.get("createdPanes", [])
        require(len(panes) >= 2, "open_workspace did not create two panes.")
        source = panes[0]
        target = panes[1]
        created_workspace_id = source["workspaceID"]
        evidence["source"] = source
        evidence["target"] = target

        sleep(1)

        identity = mcp.tool_identify_agent({
            "automationDir": automation_dir,
            "timeout": args.timeout,
            "fromHandle": source["handle"],
        })
        source_identity = identity.get("sourceIdentity")
        require(source_identity, "identify_agent did not return sourceIdentity.")
        require(source_identity["handle"] == source["handle"], "identify_agent returned the wrong source handle.")
        evidence["sourceIdentity"] = source_identity

        directory = mcp.tool_list_agents({
            "automationDir": automation_dir,
            "timeout": args.timeout,
            "fromHandle": source["handle"],
            "targetWindowID": target.get("windowID"),
        })
        entries = directory.get("listedAgents", [])
        target_entry = next((entry for entry in entries if entry["handle"] == target["handle"]), None)
        require(target_entry, "list_agents did not include the target pane.")
        require(target_entry["canReceiveMessage"], "Target pane is not messageable.")
        require(target_entry["messageTarget"]["fromHandle"] == source["handle"], "messageTarget did not preserve sender handle.")
        evidence["targetDirectoryEntry"] = target_entry

        message_args = dict(target_entry["messageTarget"])
        message_args["automationDir"] = automation_dir
        message_args["timeout"] = args.timeout
        message_args["text"] = f"MCP_AGENT_DIRECTORY_SMOKE_{unique}"
        sent = mcp.tool_message_agent(message_args)
        sent_panes = sent.get("sentPanes", [])
        require(sent_panes and sent_panes[0].get("envelopeApplied"), "message_agent did not apply an envelope.")
        require(sent_panes[0].get("sourceHandle") == source["handle"], "message_agent returned the wrong source handle.")
        evidence["sent"] = sent_panes[0]

        sleep(1)
        capture = mcp.tool_capture_pane_range({
            "automationDir": automation_dir,
            "timeout": args.timeout,
            "handles": [target["handle"]],
            "fromEnd": True,
            "lineCount": 80,
        })
        text = "\n".join(item.get("text", "") for item in capture.get("capturedPanes", []))
        require(f"From: {source['handle']}" in text, "Captured target pane is missing From metadata.")
        require("Reply via Soyeht MCP" in text, "Captured target pane is missing reply instructions.")
        require(f"MCP_AGENT_DIRECTORY_SMOKE_{unique}" in text, "Captured target pane is missing request text.")
        evidence["captureMatched"] = True

        print(json.dumps({"status": "ok", "evidence": evidence}, indent=2))
        return 0
    finally:
        if created_workspace_id and not args.keep:
            try:
                mcp.tool_close_workspace({
                    "automationDir": automation_dir,
                    "timeout": args.timeout,
                    "workspaceIDs": [created_workspace_id],
                })
            except Exception as exc:
                print(json.dumps({"cleanupWarning": str(exc), "workspaceID": created_workspace_id}), flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
