#!/usr/bin/env python3
"""Behavioral security-boundary probes against a running Soyeht Dev app."""

from __future__ import annotations

import argparse
import hashlib
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from time import monotonic, sleep, time


def load_mcp(module_path: Path):
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


def process_launch_nonce(conversation_id: str, timeout: float) -> str:
    deadline = monotonic() + timeout
    while monotonic() < deadline:
        processes = subprocess.run(
            ["/bin/ps", "eww", "-ax", "-o", "command="],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        for command in processes.splitlines():
            if f"SOYEHT_CONVERSATION_ID={conversation_id}" not in command:
                continue
            match = re.search(r"(?:^|\s)SOYEHT_LAUNCH_NONCE=([^\s]+)", command)
            if match:
                return match.group(1)
        sleep(0.2)
    raise RuntimeError(
        f"The owning process never exposed a launch nonce for {conversation_id}."
    )


def require_persistent_engine_owner(snapshot_path: Path, conversation_id: str):
    snapshot = json.loads(snapshot_path.read_text())
    conversation = next(
        item
        for item in snapshot.get("conversations", [])
        if item.get("id") == conversation_id
    )
    require(
        not conversation.get("agentLaunchOwnershipNonce"),
        "The workspace snapshot must not contain a launch bearer.",
    )
    require(
        "engineLocal" in (conversation.get("commander") or {}),
        "Restart ownership requires an engineLocal pane; the local engine "
        f"fell back to a non-persistent PTY for {conversation_id}.",
    )


def bundle_provenance(app_path: Path) -> dict:
    subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app_path)],
        check=True,
        capture_output=True,
        text=True,
    )
    team_id = signed_team_id(app_path)
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


def policy_request(root, mcp, pane, nonce, window_id, timeout, **policy):
    return mcp.submit_request_to_root(
        root,
        "set_agent_communication_policy",
        {
            "targetWindowID": window_id,
            "sourceConversationID": pane["conversationID"],
            "sourceHandle": pane["handle"],
            "nonce": nonce,
            "mcpClientContractVersion": 3,
            "mcpClientProfile": "dev",
            "mcpClientServerVersion": "2.0.0-security-probe",
            **policy,
        },
        timeout=timeout,
        check_status=False,
    )


def restart_dev_and_wait(mcp, automation_dir, timeout):
    original_pids = {
        int(line)
        for line in subprocess.run(
            ["/usr/bin/pgrep", "-x", "Soyeht Dev"],
            check=False,
            capture_output=True,
            text=True,
        ).stdout.splitlines()
        if line.strip()
    }
    subprocess.run(
        ["/usr/bin/osascript", "-e", 'tell application id "com.soyeht.mac.dev" to quit'],
        check=False,
        capture_output=True,
        text=True,
    )
    quit_deadline = monotonic() + timeout
    while monotonic() < quit_deadline:
        running = {
            int(line)
            for line in subprocess.run(
                ["/usr/bin/pgrep", "-x", "Soyeht Dev"],
                check=False,
                capture_output=True,
                text=True,
            ).stdout.splitlines()
            if line.strip()
        }
        if not original_pids.intersection(running):
            break
        sleep(0.1)
    else:
        raise RuntimeError("Soyeht Dev did not terminate before the restart probe.")
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
    parser.add_argument(
        "--mcp-script",
        default="/Applications/Soyeht Dev.app/Contents/Resources/soyeht-mcp",
        help="Exact installed MCP server exercised by the external observer.",
    )
    parser.add_argument("--expected-commit", required=True)
    parser.add_argument("--output")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    automation_dir = str(Path(args.automation_dir).expanduser().resolve())
    require(
        "Soyeht/Automation" not in automation_dir,
        "Refusing to probe the release Soyeht automation directory.",
    )
    mcp_script = Path(args.mcp_script).expanduser().resolve()
    require(mcp_script.is_file(), f"Installed MCP script does not exist: {mcp_script}")
    expected_mcp_script = Path("/Applications/Soyeht Dev.app/Contents/Resources/soyeht-mcp").resolve()
    require(
        mcp_script == expected_mcp_script,
        f"Security probes must exercise the installed MCP bundle, not {mcp_script}.",
    )
    mcp = load_mcp(mcp_script)
    require(
        re.fullmatch(r"[0-9a-f]{40}", args.expected_commit) is not None,
        "--expected-commit must be the full 40-character Git commit.",
    )
    detach_external_observer_identity()
    root = Path(automation_dir)
    snapshot_path = Path(args.workspace_snapshot).expanduser().resolve()
    unique = str(int(time()))
    workspace_id = None
    parking_workspace_id = None

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
        codex_nonce = process_launch_nonce(codex["conversationID"], args.timeout)
        opencode_nonce = process_launch_nonce(opencode["conversationID"], args.timeout)
        require_persistent_engine_owner(snapshot_path, codex["conversationID"])
        require_persistent_engine_owner(snapshot_path, opencode["conversationID"])
        require(snapshot_path.stat().st_mode & 0o777 == 0o600, "workspaces.json is not mode 0600")
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

        # Every endpoint that reads or mutates pane-owned collaboration state
        # must bind the public conversation ID to that pane's possession
        # credential. A valid nonce from another pane is still a spoof.
        pane_owned_requests = [
            ("get_conversation_context", {}),
            ("ack_conversation_context", {"throughSequence": 0}),
            ("report_agent_state", {"state": "idle", "reportSource": "self_report"}),
            ("report_agent_conversation", {"role": "assistant", "text": "MUST_NOT_BE_RECORDED"}),
            ("request_attention", {"attentionKind": "done", "message": "MUST_NOT_NOTIFY"}),
        ]
        for request_type, fields in pane_owned_requests:
            spoof = mcp.submit_request_to_root(
                root,
                request_type,
                {
                    "targetWindowID": window_id,
                    "sourceConversationID": opencode["conversationID"],
                    "sourceHandle": opencode["handle"],
                    "nonce": codex_nonce,
                    "mcpClientContractVersion": 3,
                    "mcpClientProfile": "dev",
                    **fields,
                },
                timeout=args.timeout,
                check_status=False,
            )
            require(
                spoof.get("status") == "error"
                and "does not belong to that pane" in spoof.get("message", ""),
                f"{request_type} accepted another pane's nonce: {spoof}",
            )
            cases.append({
                "case": f"cross-pane-nonce-{request_type}",
                "expected": "rejected",
                "result": "rejected",
                "message": spoof["message"],
            })

        context_control = mcp.submit_request_to_root(
            root,
            "get_conversation_context",
            {
                "targetWindowID": window_id,
                "sourceConversationID": opencode["conversationID"],
                "sourceHandle": opencode["handle"],
                "nonce": opencode_nonce,
                "mcpClientContractVersion": 3,
                "mcpClientProfile": "dev",
            },
            timeout=args.timeout,
            check_status=False,
        )
        require(context_control.get("status") == "ok", f"Valid context owner was rejected: {context_control}")
        cases.append({
            "case": "owning-pane-context-read",
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
                "mcpClientContractVersion": 3,
                "mcpClientProfile": "dev",
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
                "mcpClientContractVersion": 2,
                "mcpClientServerVersion": "2.0.0-pre-profile-probe",
            },
            timeout=args.timeout,
            check_status=False,
        )
        require(old_contract.get("status") == "error", "Old MCP contract unexpectedly succeeded.")
        require("contract 3" in old_contract.get("message", ""), "Old contract returned the wrong error.")
        cases.append({
            "case": "old-contract-sensitive-write",
            "expected": "rejected",
            "result": "rejected",
            "message": old_contract["message"],
        })

        omitted_agent_old_contract = mcp.submit_request_to_root(
            root,
            "create_worktree_panes",
            {
                "targetWindowID": window_id,
                "repo": "/definitely/not/a/repository",
                "names": ["must-not-create"],
                # No agent field: this route defaults to Codex and therefore
                # must still be classified as an agent launch.
                "mcpClientContractVersion": 2,
                "mcpClientServerVersion": "2.0.0-pre-profile-omitted-agent-probe",
            },
            timeout=args.timeout,
            check_status=False,
        )
        require(
            omitted_agent_old_contract.get("status") == "error"
            and "contract 3" in omitted_agent_old_contract.get("message", ""),
            f"Omitted-agent creation bypassed the contract gate: {omitted_agent_old_contract}",
        )
        cases.append({
            "case": "omitted-agent-default-codex-still-requires-current-contract",
            "expected": "rejected",
            "result": "rejected",
            "message": omitted_agent_old_contract["message"],
        })

        wrong_profile = mcp.submit_request_to_root(
            root,
            "set_agent_communication_policy",
            {
                "targetWindowID": window_id,
                "sourceConversationID": codex["conversationID"],
                "sourceHandle": codex["handle"],
                "nonce": codex_nonce,
                "incomingEnabled": False,
                "mcpClientContractVersion": 3,
                "mcpClientProfile": "release",
                "mcpClientServerVersion": "2.0.0-wrong-profile-probe",
            },
            timeout=args.timeout,
            check_status=False,
        )
        require(wrong_profile.get("status") == "error", "Wrong MCP profile unexpectedly succeeded.")
        require("profile release" in wrong_profile.get("message", ""), "Wrong profile returned the wrong error.")
        cases.append({
            "case": "wrong-profile-sensitive-write",
            "expected": "rejected",
            "result": "rejected",
            "message": wrong_profile["message"],
        })

        # Leave the owning agent in an inactive workspace before relaunch.
        # This distinguishes store-level credential rehydration from the lazy
        # PaneViewController restore path, which only runs after a human visits
        # the workspace.
        parking_workspace = mcp.tool_open_workspace({
            "automationDir": automation_dir,
            "timeout": args.timeout,
            "targetWindowID": window_id,
            "name": f"mcp2-security-parking-{unique}",
            "agent": "shell",
            "panes": [{
                "name": f"mcp2-security-parking-shell-{unique}",
                "path": str(repo_root),
                "agent": "shell",
                "command": "/bin/cat",
            }],
        })
        parking_workspace_id = parking_workspace["createdPanes"][0]["workspaceID"]
        active_before_restart = mcp.tool_get_active_context({
            "automationDir": automation_dir,
            "timeout": args.timeout,
            "targetWindowID": window_id,
        })
        require(
            active_before_restart.get("activeContext", {}).get("workspaceID")
            == parking_workspace_id,
            "The parking workspace did not become active before restart.",
        )

        resumed_windows = restart_dev_and_wait(mcp, automation_dir, args.timeout)
        resumed_window_ids = {item["windowID"] for item in resumed_windows["listedWindows"]}
        require(window_id in resumed_window_ids, "The persistent test window did not restore.")
        active_after_restart = mcp.tool_get_active_context({
            "automationDir": automation_dir,
            "timeout": args.timeout,
            "targetWindowID": window_id,
        })
        require(
            active_after_restart.get("activeContext", {}).get("workspaceID")
            == parking_workspace_id,
            "The original agent workspace was materialized during restart.",
        )
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
            "case": "inactive-workspace-launch-ownership-survives-app-restart",
            "expected": "accepted",
            "result": "accepted",
            "activeWorkspaceID": parking_workspace_id,
            "agentWorkspaceID": workspace_id,
        })

        app_path = Path("/Applications/Soyeht Dev.app")
        provenance = bundle_provenance(app_path)
        require(
            provenance["commit"] == args.expected_commit,
            f"Installed app commit {provenance['commit']} != expected {args.expected_commit}.",
        )
        evidence = {
            "status": "passed",
            "app": {
                "bundleID": "com.soyeht.mac.dev",
                **provenance,
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
        if parking_workspace_id:
            try:
                mcp.tool_close_workspace({
                    "automationDir": automation_dir,
                    "timeout": args.timeout,
                    "targetWindowID": window_id,
                    "workspaceIDs": [parking_workspace_id],
                })
            except Exception as error:
                print(json.dumps({"cleanupWarning": str(error)}))
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
