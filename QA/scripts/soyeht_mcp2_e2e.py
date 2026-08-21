#!/usr/bin/env python3
"""End-to-end acceptance for the MCP 2.0 agent collaboration contract.

The test drives a running Soyeht Dev.app through its real file automation
transport. It creates temporary workspaces, proves durable/no-PTY and deferred
delivery, exercises policy and graph denials, and observes the real processes
spawned for every installed CLI in the MCP agent catalog.

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
from time import monotonic, sleep, time


def load_mcp(repo_root: Path):
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


def capture_text(mcp, pane, automation_dir, timeout):
    response = mcp.tool_capture_pane_range({
        "automationDir": automation_dir,
        "timeout": timeout,
        "conversationIDs": [pane["conversationID"]],
        "targetWindowID": pane.get("windowID"),
        "fromEnd": True,
        "lineCount": 160,
    })
    return "\n".join(item.get("text", "") for item in response.get("capturedPanes", []))\
        .replace("\x00", "")


def wait_for_text(mcp, pane, token, automation_dir, timeout):
    deadline = monotonic() + timeout
    latest = ""
    while monotonic() < deadline:
        latest = capture_text(mcp, pane, automation_dir, timeout)
        if token in latest.replace("\r", "").replace("\n", ""):
            return latest
        sleep(0.2)
    raise RuntimeError(f"Timed out waiting for {token!r} in {pane['handle']}. Last capture: {latest[-500:]!r}")


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


def close_workspace(mcp, pane, workspace_id, automation_dir, timeout, **extra):
    return mcp.tool_close_workspace({
        **source_args(pane, automation_dir, timeout),
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
                {"name": f"mcp2-executor-{unique}", "path": str(repo_root), "agent": "shell", "command": "/bin/cat"},
                {"name": f"mcp2-reviewer-{unique}", "path": str(repo_root), "agent": "shell", "command": "/bin/cat"},
            ],
        })
        panes = primary.get("createdPanes", [])
        require(len(panes) == 3, "Primary workspace did not create three panes.")
        source, executor, reviewer = panes
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

        custom = mcp.tool_save_agent_role_template({
            **source_args(source, automation_dir, args.timeout),
            "templateID": "custom.e2e-skeptic",
            "roleName": "E2E Skeptic",
            "roleInstructions": "Challenge assumptions and require observable evidence.",
        })
        require(custom.get("agentOrchestrations"), "Custom role template was not saved.")
        role_calls = [
            (source, "builtin.planner"),
            (executor, "builtin.executor"),
            (reviewer, "builtin.reviewer"),
        ]
        for pane, template_id in role_calls:
            assigned = mcp.tool_set_agent_role({
                **source_args(source, automation_dir, args.timeout),
                "conversationIDs": [pane["conversationID"]],
                "roleTemplateID": template_id,
            })
            require(assigned.get("agentRoles", [{}])[0].get("templateID") == template_id, f"Role {template_id} was not assigned.")
        graph = mcp.tool_configure_agent_orchestration({
            **source_args(source, automation_dir, args.timeout),
            "preset": "planner-executor-reviewer",
            "nodeBindings": {
                "planner": source["conversationID"],
                "executor": executor["conversationID"],
                "reviewer": reviewer["conversationID"],
            },
        })
        active_graph = graph.get("agentOrchestrations", [{}])[0].get("activeGraph")
        require(active_graph and active_graph.get("preset") == "plannerExecutorReviewer", "Graph preset was not activated.")
        role_directory = mcp.tool_list_agents({
            **source_args(source, automation_dir, args.timeout),
            "workspaceID": primary_workspace_id,
        })
        roles = {item["conversationID"]: item.get("roleName") for item in role_directory.get("listedAgents", [])}
        require(roles.get(source["conversationID"]) == "Planner", "Planner role missing from directory.")
        require(roles.get(executor["conversationID"]) == "Executor", "Executor role missing from directory.")
        evidence["checks"]["rolesAndGraph"] = {
            "status": "passed",
            "customTemplateSaved": True,
            "preset": active_graph.get("preset"),
            "nodeCount": len(active_graph.get("nodes", [])),
            "edgeCount": len(active_graph.get("edges", [])),
        }

        semantic_token = f"MCP2_SEMANTIC_NO_PTY_{unique}"
        before_semantic = capture_text(mcp, executor, automation_dir, args.timeout)
        semantic = mcp.tool_message_agent({
            **source_args(source, automation_dir, args.timeout),
            "conversationIDs": [executor["conversationID"]],
            "text": semantic_token,
            "deliveryPreference": "semanticInboxOnly",
        })
        semantic_delivery = semantic.get("agentMessageDeliveries", [{}])[0]
        require(semantic_delivery.get("writesToPTY") is False, "Semantic inbox wrote to the PTY.")
        require(semantic_delivery.get("status") == "stored_but_adapter_cannot_wake", "Semantic fail-closed status changed.")
        sleep(1.0)
        after_semantic = capture_text(mcp, executor, automation_dir, args.timeout)
        require(semantic_token not in after_semantic, "Semantic inbox token leaked into terminal output.")
        require(len(after_semantic) >= len(before_semantic), "Terminal capture unexpectedly shrank.")
        inbox = mcp.tool_list_agent_messages({
            **source_args(executor, automation_dir, args.timeout),
            "unreadOnly": True,
            "markRead": True,
        })
        stored = next((item for item in inbox.get("agentInboxMessages", []) if item.get("body") == semantic_token), None)
        require(stored, "Semantic inbox message was not durably readable.")
        acknowledged = mcp.tool_ack_agent_messages({
            **source_args(executor, automation_dir, args.timeout),
            "messageIDs": [stored["messageID"]],
        })
        require(acknowledged.get("agentInboxMessages", [{}])[0].get("acknowledgedAt"), "Inbox ack was not persisted.")
        evidence["checks"]["semanticInbox"] = {
            "status": "passed",
            "writesToPTY": False,
            "deliveryStatus": semantic_delivery.get("status"),
            "readAndAcknowledged": True,
        }

        deferred_token = f"MCP2_DEFERRED_TERMINAL_{unique}"
        deferred = mcp.tool_message_agent({
            **source_args(source, automation_dir, args.timeout),
            "conversationIDs": [executor["conversationID"]],
            "text": deferred_token,
            "deliveryPreference": "automatic",
        })
        deferred_delivery = deferred.get("agentMessageDeliveries", [{}])[0]
        require(deferred_delivery.get("writesToPTY") is True, "Universal fallback did not select deferred terminal.")
        require(deferred_delivery.get("status") == "queued_until_human_input_is_clear", "Message was not queued behind the typing gate.")
        terminal_text = wait_for_text(mcp, executor, deferred_token, automation_dir, args.timeout)
        source_reference = f"[{source['handle'].lstrip('@')}]"
        require(source_reference in terminal_text, "Deferred envelope did not use the safe bracketed sender reference.")
        evidence["checks"]["deferredTerminal"] = {
            "status": "passed",
            "queuedFirst": True,
            "safeSenderReference": source_reference,
            "terminalFallback": True,
        }

        human_draft_token = f"MCP2_HUMAN_DRAFT_{unique}"
        held_message_token = f"MCP2_HELD_BEHIND_DRAFT_{unique}"
        mcp.tool_send_pane_input({
            **source_args(source, automation_dir, args.timeout),
            "conversationIDs": [executor["conversationID"]],
            "text": human_draft_token,
            "lineEnding": "none",
        })
        wait_for_text(mcp, executor, human_draft_token, automation_dir, args.timeout)
        held = mcp.tool_message_agent({
            **source_args(source, automation_dir, args.timeout),
            "conversationIDs": [executor["conversationID"]],
            "text": held_message_token,
            "deliveryPreference": "automatic",
        })
        require(
            held.get("agentMessageDeliveries", [{}])[0].get("status")
            == "queued_until_human_input_is_clear",
            "Draft-gated message was not queued.",
        )
        sleep(1.5)
        held_capture = capture_text(mcp, executor, automation_dir, args.timeout)
        require(human_draft_token in held_capture, "Unfinished draft was not visible in the pane.")
        require(held_message_token not in held_capture, "Agent message interrupted an unfinished draft.")
        mcp.tool_send_pane_input({
            **source_args(source, automation_dir, args.timeout),
            "conversationIDs": [executor["conversationID"]],
            "text": "\r",
            "lineEnding": "none",
        })
        wait_for_text(mcp, executor, held_message_token, automation_dir, args.timeout)
        evidence["checks"]["typingDraftGate"] = {
            "status": "passed",
            "inputPath": "send_pane_input and onUserInputData share AgentMessageDraftGate",
            "heldWhileDraftOpen": True,
            "releasedAfterEnter": True,
        }

        blocked_token = f"MCP2_BLOCKED_{unique}"
        policy = mcp.tool_set_agent_communication_policy({
            **source_args(executor, automation_dir, args.timeout),
            "blockedPaneIDs": [source["conversationID"]],
        })
        require(policy.get("agentCommunicationPolicies", [{}])[0].get("blockedPaneIDs") == [source["conversationID"]], "Pane block was not saved.")
        blocked = mcp.tool_message_agent({
            **source_args(source, automation_dir, args.timeout),
            "conversationIDs": [executor["conversationID"]],
            "text": blocked_token,
        })
        blocked_delivery = blocked.get("agentMessageDeliveries", [{}])[0]
        require(blocked_delivery.get("status") == "blocked", "Blocked pane accepted a message.")
        require(blocked_delivery.get("writesToPTY") is False, "Blocked message wrote to PTY.")

        remote_policy = mcp.tool_set_agent_communication_policy({
            **source_args(remote, automation_dir, args.timeout),
            "incomingAllowsCrossWorkspace": False,
        })
        require(remote_policy.get("agentCommunicationPolicies"), "Cross-workspace policy was not saved.")
        remote_blocked = mcp.tool_message_agent({
            **source_args(source, automation_dir, args.timeout),
            "conversationIDs": [remote["conversationID"]],
            "text": f"MCP2_CROSS_WORKSPACE_BLOCK_{unique}",
        })
        require(remote_blocked.get("agentMessageDeliveries", [{}])[0].get("status") == "blocked", "Cross-workspace deny was not enforced.")
        evidence["checks"]["denyDominantPolicy"] = {
            "status": "passed",
            "paneBlock": blocked_delivery.get("policyDenials"),
            "crossWorkspaceBlock": remote_blocked.get("agentMessageDeliveries", [{}])[0].get("policyDenials"),
        }

        graph_denied = mcp.tool_message_agent({
            **source_args(reviewer, automation_dir, args.timeout),
            "conversationIDs": [source["conversationID"]],
            "text": f"MCP2_GRAPH_DENIED_{unique}",
        })
        graph_delivery = graph_denied.get("agentMessageDeliveries", [{}])[0]
        require(graph_delivery.get("status") == "orchestration_denied", "Undeclared graph edge was not denied.")
        require(graph_delivery.get("writesToPTY") is False, "Denied graph edge wrote to PTY.")
        evidence["checks"]["graphPolicy"] = {
            "status": "passed",
            "deniedUndeclaredEdge": "reviewer -> planner",
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
            source,
            remote_workspace_id,
            automation_dir,
            args.timeout,
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
                    close_workspace(mcp, source, workspace_id, automation_dir, args.timeout)
                except Exception as exc:
                    print(json.dumps({
                        "cleanupWarning": str(exc),
                        "workspaceID": workspace_id,
                    }), flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
