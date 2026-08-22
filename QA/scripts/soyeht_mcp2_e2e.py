#!/usr/bin/env python3
"""External-controller acceptance for the MCP 2.0 automation contract.

The test drives a running Soyeht Dev.app through its real file automation
transport. It creates temporary workspaces, checks the grouped directory,
observes the real processes spawned for installed CLIs, and pins workspace
cleanup. It deliberately does not claim an authenticated agent identity:
messaging, inbox, policy, role, and graph behavior belong to the agent-driven
runner and security probes, where a real launched pane owns the nonce.

Never point this test at the release Automation directory.
"""

from __future__ import annotations

import argparse
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
import sys
from time import monotonic, sleep, time


def load_mcp(repo_root: Path):
    sys.dont_write_bytecode = True
    module_path = repo_root / "scripts" / "soyeht-mcp"
    loader = importlib.machinery.SourceFileLoader("soyeht_mcp2_e2e_module", str(module_path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def source_args(pane, automation_dir, timeout):
    return {
        "automationDir": automation_dir,
        "timeout": timeout,
        "sourceConversationID": pane["conversationID"],
        "sourceHandle": pane["handle"],
        "targetWindowID": pane.get("windowID"),
    }


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


def observed_launch_process(before, expected_argv, timeout=10.0):
    expected_executable = Path(expected_argv[0]).name.lower()
    expected_flags = [value for value in expected_argv[1:] if value.startswith("-")]
    deadline = monotonic() + timeout
    candidates = []
    while monotonic() < deadline:
        after = process_snapshot()
        candidates = [
            {"pid": pid, **item}
            for pid, item in after.items()
            if pid not in before
        ]
        for candidate in candidates:
            command = candidate["command"]
            try:
                command_tokens = shlex.split(command)
            except ValueError:
                command_tokens = command.split()
            observed_executables = {
                Path(token).name.lower()
                for token in command_tokens
                if token and not token.startswith("-")
            }
            if expected_executable not in observed_executables:
                continue
            if not all(flag in command_tokens for flag in expected_flags):
                continue
            return candidate
        sleep(0.1)
    rendered = [item["command"] for item in candidates[-12:]]
    raise RuntimeError(
        f"No new live process matched argv {expected_argv!r}. Newest candidates: {rendered!r}"
    )


def close_workspace(mcp, workspace_id, automation_dir, timeout, target_window_id=None, **extra):
    return mcp.tool_close_workspace({
        "automationDir": automation_dir,
        "timeout": timeout,
        "targetWindowID": target_window_id,
        "workspaceIDs": [workspace_id],
        **extra,
    })


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--automation-dir", required=True)
    parser.add_argument("--timeout", type=float, default=25.0)
    parser.add_argument("--keep", action="store_true")
    parser.add_argument(
        "--agents",
        default="all",
        help="Comma-separated agent IDs to launch, or 'all' for the complete catalog.",
    )
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    automation_dir = str(Path(args.automation_dir).expanduser().resolve())
    require("Soyeht/Automation" not in automation_dir, "Refusing to test against release Soyeht automation.")
    mcp = load_mcp(repo_root)
    unique = str(int(time()))
    evidence = {"runID": unique, "automationDir": automation_dir, "checks": {}}
    created_workspace_ids = []
    source = None

    windows = mcp.tool_list_windows({"automationDir": automation_dir, "timeout": args.timeout})
    require(windows.get("listedWindows"), "Soyeht Dev automation is not responding.")
    evidence["checks"]["devAutomation"] = {
        "status": "passed",
        "windowCount": len(windows["listedWindows"]),
    }

    try:
        primary = mcp.tool_open_workspace({
            "automationDir": automation_dir,
            "timeout": args.timeout,
            "name": f"mcp2-e2e-primary-{unique}",
            "agent": "shell",
            "panes": [
                {"name": f"mcp2-source-{unique}", "path": str(repo_root), "agent": "shell", "command": "/bin/cat"},
            ],
        })
        panes = primary.get("createdPanes", [])
        require(len(panes) == 1, "Primary workspace did not create its controller pane.")
        source = panes[0]
        primary_workspace_id = source["workspaceID"]
        created_workspace_ids.append(primary_workspace_id)

        remote_response = mcp.tool_open_workspace({
            "automationDir": automation_dir,
            "timeout": args.timeout,
            "name": f"mcp2-e2e-remote-{unique}",
            "agent": "shell",
            "panes": [
                {"name": f"mcp2-remote-{unique}", "path": str(repo_root), "agent": "shell", "command": "/bin/cat"},
            ],
        })
        remote = remote_response["createdPanes"][0]
        remote_workspace_id = remote["workspaceID"]
        created_workspace_ids.append(remote_workspace_id)

        # Initial commands are deliberately started asynchronously by the app.
        sleep(4.0)

        directory = mcp.tool_list_agents({
            **source_args(source, automation_dir, args.timeout),
        })
        groups = directory.get("workspaceGroups", [])
        require(directory.get("directoryScope") == "global", "Agent directory is not global.")
        require(groups and groups[0].get("sameWorkspace"), "Caller's workspace is not the first group.")
        require(groups[0].get("workspaceID") == primary_workspace_id, "Wrong workspace was highlighted.")
        require(any(group.get("workspaceID") == remote_workspace_id for group in groups), "Remote workspace is absent.")
        own_entries = [
            item for item in directory.get("listedAgents", [])
            if item.get("workspaceID") == primary_workspace_id
        ]
        require(all(item.get("displayReference", "").startswith("[") for item in own_entries), "Unsafe display reference found.")
        evidence["checks"]["globalGroupedDirectory"] = {
            "status": "passed",
            "groupCount": len(groups),
            "sourceWorkspaceFirst": True,
            "displayReferenceFormat": directory.get("displayReferenceFormat"),
        }

        evidence["checks"]["authenticatedAgentBoundary"] = {
            "status": "delegated",
            "reason": "This controller owns no pane launch nonce and must not impersonate an agent.",
            "coveredBy": [
                "QA/scripts/soyeht_agent_driven_e2e.py",
                "QA/scripts/soyeht_mcp2_security_probes.py",
            ],
        }

        if args.agents == "all":
            requested_agents = list(mcp.AGENT_CATALOG)
        else:
            requested_agents = [item.strip() for item in args.agents.split(",") if item.strip()]
        launch_evidence = []
        for agent_id in requested_agents:
            require(agent_id in mcp.AGENT_CATALOG, f"Unknown requested E2E agent: {agent_id}")
            executable = mcp.AGENT_CATALOG[agent_id]["executable"]
            if not mcp.shutil.which(executable):
                launch_evidence.append({"agentID": agent_id, "status": "not-installed"})
                continue
            before = process_snapshot()
            opened = mcp.tool_open_agent_pane({
                "automationDir": automation_dir,
                "timeout": args.timeout,
                "agentID": agent_id,
                "cwd": str(repo_root),
                "workspaceID": primary_workspace_id,
                "name": f"mcp2-launch-{agent_id}-{unique}",
                "targetWindowID": source.get("windowID"),
            })
            created = opened.get("createdPanes", [])
            require(created, f"open_agent_pane did not create {agent_id}.")
            contract = opened.get("launchContract", {})
            expected_argv = contract.get("expectedArgv", [])
            require(expected_argv, f"{agent_id} returned no expected argv contract.")
            observed = observed_launch_process(before, expected_argv)
            if agent_id == "codex":
                require("--yolo" in observed["command"], "Codex process is missing --yolo.")
            if agent_id == "opencode":
                require("--auto" in observed["command"], "OpenCode process is missing --auto.")
            launch_evidence.append({
                "agentID": agent_id,
                "status": "observed-live",
                "profile": contract.get("profile"),
                "expectedArgv": expected_argv,
                "observedProcess": observed,
                "conversationID": created[0]["conversationID"],
            })
            mcp.tool_close_pane({
                "automationDir": automation_dir,
                "timeout": args.timeout,
                "conversationIDs": [created[0]["conversationID"]],
                "targetWindowID": source.get("windowID"),
            })
        missing = [item for item in launch_evidence if item["status"] != "observed-live"]
        require(not missing, f"Some catalog agents were not observed live: {missing!r}")
        evidence["checks"]["exactAgentLaunch"] = {
            "status": "passed",
            "agentCount": len(launch_evidence),
            "agents": launch_evidence,
        }

        # Regression requested after two stale test panes could not be closed.
        # Supplying the unrelated destination field must neither be required
        # nor make close_workspace reject a valid workspace ID.
        closed_remote = close_workspace(
            mcp,
            remote_workspace_id,
            automation_dir,
            args.timeout,
            target_window_id=source.get("windowID"),
            destinationWorkspaceID=primary_workspace_id,
        )
        require(
            any(item.get("workspaceID") == remote_workspace_id for item in closed_remote.get("closedWorkspaces", [])),
            "close_workspace rejected a valid workspace while destinationWorkspaceID was present.",
        )
        created_workspace_ids.remove(remote_workspace_id)
        evidence["checks"]["closeWorkspaceRegression"] = {
            "status": "passed",
            "destinationFieldIgnored": True,
            "closedWorkspaceID": remote_workspace_id,
        }

        print(json.dumps({"status": "passed", "evidence": evidence}, indent=2, sort_keys=True))
        return 0
    finally:
        if not args.keep and source is not None:
            for workspace_id in list(reversed(created_workspace_ids)):
                try:
                    close_workspace(
                        mcp,
                        workspace_id,
                        automation_dir,
                        args.timeout,
                        target_window_id=source.get("windowID"),
                    )
                except Exception as exc:
                    print(json.dumps({
                        "cleanupWarning": str(exc),
                        "workspaceID": workspace_id,
                    }), flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
