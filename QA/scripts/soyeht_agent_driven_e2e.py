#!/usr/bin/env python3
"""Behavioral E2E for real coding agents collaborating through Soyeht MCP.

Unlike the protocol E2E, this runner does not open the child panes itself. It
starts real parent agents, asks each parent in natural language to open a named
collaborator in an exact directory, and waits for a round-trip MCP reply. The
runner independently observes pane identity, live process argv and cwd; launch
metadata alone is never accepted as proof.

The default ring is Codex -> OpenCode -> Claude -> Codex. Run only against
Soyeht Dev.app because the test creates live paid-agent sessions.
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
    loader = importlib.machinery.SourceFileLoader("soyeht_agent_driven_e2e_module", str(module_path))
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
        "fromConversationID": pane["conversationID"],
        "fromHandle": pane["handle"],
        "targetWindowID": pane["windowID"],
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


def command_matches(command: str, expected_argv):
    try:
        tokens = shlex.split(command)
    except ValueError:
        tokens = command.split()
    executable = Path(expected_argv[0]).name.lower()
    observed_executables = {
        Path(token).name.lower()
        for token in tokens
        if token and not token.startswith("-")
    }
    expected_flags = [token for token in expected_argv[1:] if token.startswith("-")]
    return executable in observed_executables and all(flag in tokens for flag in expected_flags)


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


def capture_text(mcp, pane, automation_dir, timeout):
    response = mcp.tool_capture_pane({
        "automationDir": automation_dir,
        "timeout": timeout,
        "conversationIDs": [pane["conversationID"]],
        "targetWindowID": pane["windowID"],
        "mode": "all",
        "maxLines": 220,
    })
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
        response = mcp.tool_list_agent_messages({
            "automationDir": automation_dir,
            "timeout": timeout,
            "fromConversationID": child["conversationID"],
            "fromHandle": child["handle"],
            "unreadOnly": False,
            "markRead": False,
        })
        latest_inbox = response.get("agentInboxMessages", [])
        request = next((
            message for message in latest_inbox
            if token in message.get("body", "")
            and message.get("senderConversationID") == parent["conversationID"]
            and message.get("mcpClientContractVersion") == 2
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
        response = mcp.tool_list_agent_messages({
            "automationDir": automation_dir,
            "timeout": timeout,
            "fromConversationID": parent["conversationID"],
            "fromHandle": parent["handle"],
            "unreadOnly": False,
            "markRead": False,
        })
        latest_inbox = response.get("agentInboxMessages", [])
        reply = next((
            message for message in latest_inbox
            if token in message.get("body", "")
            and message.get("senderConversationID") == child["conversationID"]
            and message.get("mcpClientContractVersion") == 2
        ), None)
        if reply:
            return reply
        sleep(0.5)
    raise RuntimeError(
        f"No durable MCP reply {token!r} from {child['handle']} to {parent['handle']}. "
        f"Inbox provenance: "
        f"{[(item.get('body'), item.get('mcpClientContractVersion'), item.get('mcpClientServerVersion')) for item in latest_inbox]!r}"
    )


def wait_for_parent_completion(mcp, parent, marker, automation_dir, timeout):
    deadline = monotonic() + timeout
    latest = ""
    while monotonic() < deadline:
        latest = capture_text(mcp, parent, automation_dir, timeout)
        normalized = " ".join(latest.split())
        if marker in normalized:
            return latest
        sleep(0.5)
    raise RuntimeError(
        f"Parent {parent['handle']} did not produce completion {marker!r} after "
        f"receiving the durable child reply. Last capture: {latest[-1200:]!r}"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--automation-dir", required=True)
    parser.add_argument("--timeout", type=float, default=240.0)
    parser.add_argument("--keep", action="store_true")
    parser.add_argument("--output")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    automation_dir = str(Path(args.automation_dir).expanduser().resolve())
    require("SoyehtDev/Automation" in automation_dir, "Refusing to run paid-agent E2E outside Soyeht Dev automation.")
    mcp = load_mcp(repo_root)
    run_id = str(int(time()))
    evidence = {
        "runID": run_id,
        "kind": "real-agent-behavioral-ring",
        "automationDir": automation_dir,
        "flows": [],
    }
    workspace_id = None
    observer = None

    flows = [
        {"parent": "codex", "child": "opencode", "directory": repo_root / "QA"},
        {"parent": "opencode", "child": "claude", "directory": repo_root / "docs"},
        {"parent": "claude", "child": "codex", "directory": repo_root / "TerminalApp"},
    ]

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
            token = f"E2E_REPLY_{run_id}_{index}"
            completion_prefix = f"E2E_FLOW_OK_{run_id}_{index}"
            marker = f"{completion_prefix} {token}"
            prompt = (
                f"Teste E2E de comportamento, sem alterar arquivos. Abra uma nova pane do agente "
                f"{flow['child']} neste mesmo workspace, no diretório exato {flow['directory']}, "
                f"com o nome exato {child_name}. Use especificamente a integração MCP nova "
                f"soyeht-dev para abrir a pane; não use a integração soyeht antiga, não abra um "
                f"agente diferente e não use Terminal.app. Depois envie uma mensagem ao agente filho "
                f"pela integração soyeht-dev pedindo que ele responda a você, também pela integração "
                f"soyeht-dev, com exatamente "
                f"o token {token}. Espere receber a resposta real. Só então conclua escrevendo o prefixo "
                f"{completion_prefix}, um espaço e depois repetindo o token recebido."
            )
            opened = mcp.tool_open_agent_pane({
                **source_args(observer, automation_dir, args.timeout),
                "agentID": flow["parent"],
                "cwd": str(repo_root),
                "workspaceID": workspace_id,
                "name": parent_name,
                "prompt": prompt,
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
            })

        for record in parent_records:
            parent = record["parentPane"]
            parent_process = observe_process(
                global_baseline,
                record["parentContract"]["expectedArgv"],
                repo_root,
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
            })

        evidence["status"] = "passed"
        output = Path(args.output).resolve() if args.output else repo_root / "QA" / "runs" / f"agent-driven-e2e-{run_id}.json"
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(json.dumps({"status": "passed", "report": str(output), "evidence": evidence}, indent=2, sort_keys=True))
        return 0
    finally:
        if not args.keep and observer is not None and workspace_id is not None:
            try:
                mcp.tool_close_workspace({
                    **source_args(observer, automation_dir, args.timeout),
                    "workspaceIDs": [workspace_id],
                })
            except Exception as exc:
                print(json.dumps({"cleanupWarning": str(exc), "workspaceID": workspace_id}), flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
