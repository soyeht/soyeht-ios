from soyeht_mcp_runtime import *
from soyeht_mcp_registry import register_tool


@register_tool(
    order=28,
    definition={
        "name": "list_windows",
        "description": "List open Soyeht macOS windows with stable windowID, active workspace, nested workspaces, and pane counts. Use this before cross-window routing.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 10.0},
            },
        },
    },
)
def tool_list_windows(args):
    return submit_request(
        "list_windows",
        {},
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )


@register_tool(
    order=29,
    definition={
        "name": "list_workspaces",
        "description": "List Soyeht workspaces with IDs, names, pane counts, isActive flag, activePaneID, and windowID. By default this returns workspaces from every open Soyeht macOS window; pass windowID/targetWindowID to scope to one window.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "windowID": WINDOW_ID_PROPERTY,
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 10.0},
            },
        },
    },
)
def tool_list_workspaces(args):
    return submit_request(
        "list_workspaces",
        with_window_target({}, args),
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )


@register_tool(
    order=30,
    definition={
        "name": "list_panes",
        "description": "List Soyeht panes with conversationIDs, handles, paths, declaredAgent (pane launch metadata, not runtime process identity), and per-pane isActive (focused pane in its workspace) and isActiveWorkspace flags. Do not use declaredAgent to decide whether a pane can respond as an AI agent. The result also carries an activeContext block for the resolved target window/workspace; when called from a Soyeht pane, that is the caller/source workspace unless targetWindowID points elsewhere. Optionally filter to a single workspace; an invalid or unknown workspaceID returns an error instead of falling back to listing everything.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "workspaceID": {
                    "type": "string",
                    "description": "If provided, only panes in this workspace are returned. Must be a known UUID.",
                },
                "windowID": WINDOW_ID_PROPERTY,
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 10.0},
            },
        },
    },
)
def tool_list_panes(args):
    payload = with_source_context(with_window_target({}, args), args)
    if args.get("workspaceID"):
        payload["workspaceIDs"] = [args["workspaceID"]]
    return submit_request(
        "list_panes",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )


@register_tool(
    order=31,
    definition={
        "name": "identify_agent",
        "description": "Identify the Soyeht pane that is calling this MCP server. Use this before replying to another agent when you do not know your own handle/conversationID. It resolves fromHandle/fromConversationID first, then SOYEHT_CONVERSATION_ID/SOYEHT_HANDLE exported by the pane, then the calling terminal TTY. The response includes sourceIdentity plus a replyTarget other agents can use to message you.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "fromConversationID": {
                    "type": "string",
                    "description": "Explicit source conversationID. Optional; normally omitted so Soyeht infers the calling pane.",
                },
                "fromHandle": {
                    "type": "string",
                    "description": "Explicit source handle. Optional; normally omitted so Soyeht infers the calling pane.",
                },
                "windowID": WINDOW_ID_PROPERTY,
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 5.0},
            },
        },
    },
)
def tool_identify_agent(args):
    payload = with_source_context(with_window_target({}, args), args)
    return submit_request(
        "identify_agent",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 5.0),
    )


@register_tool(
    order=32,
    definition={
        "name": "list_agents",
        "description": "List the global Soyeht agent/pane directory and resolve existing named Soyeht pane agents before communicating with them. For a communication request (talk, send, ping, ask, or wait for replies) containing target names, call this tool BEFORE choosing a delegation mechanism. Match normalized names against the returned panes: matched names go to message_agent and must never be replaced by newly spawned internal harness subagents; unmatched names must be reported to the user, not silently created. Also call this tool when the user mentions Soyeht, a workspace, or panes without listing names. This does not forbid internal subagents when the user explicitly asks the harness to create or delegate to new subagents. In this contract, a Soyeht agent is a live named pane identity such as [ilia] or [marcia] — NOT a harness/CLI product such as Codex, Claude Code, OpenCode, Qwen Code, or Droid. When the user asks which Soyeht agents are in a workspace, return the pane displayReference names from this result; never substitute the harness catalog. By default all workspaces remain visible, grouped in workspaceGroups with the caller's current workspace first. canReceiveMessage is a hard contract: true means message_agent accepts the pane now; false includes messagingAvailability and unavailableReason such as mcp_not_connected, agent_not_running, or not_live. Pass workspaceID only for an intentional filter. Each agent includes displayReference=[name] for prose, while legacy @handles and conversation UUIDs remain machine-routing inputs in messageTarget. Use displayReference in commits, PRs, comments, and prose so GitHub accounts are not mentioned. Never create a new pane in Soyeht or start a process without explicit user confirmation.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "workspaceID": {
                    "type": "string",
                    "description": "If provided, only agents/panes in this workspace are returned.",
                },
                "fromConversationID": {
                    "type": "string",
                    "description": "Explicit source conversationID used to prefill messageTarget.fromConversationID.",
                },
                "fromHandle": {
                    "type": "string",
                    "description": "Explicit source handle used to prefill messageTarget.fromHandle.",
                },
                "windowID": WINDOW_ID_PROPERTY,
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 10.0},
            },
        },
    },
)
def tool_list_agents(args):
    payload = with_source_context(with_window_target({}, args), args)
    if args.get("workspaceID"):
        payload["workspaceIDs"] = [args["workspaceID"]]
    response = submit_request(
        "list_agents",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )
    return decorate_agent_directory(
        response, filtered_workspace_id=args.get("workspaceID")
    )


@register_tool(
    order=34,
    definition={
        "name": "close_pane",
        "description": "Close (kill) one or more Soyeht panes by conversationID or handle. Cannot close the last pane in a workspace — use close_workspace instead.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "conversationIDs": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "UUIDs of panes to close.",
                },
                "handles": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Handles of panes to close, e.g. @claude or @fix-auth.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 20.0},
            },
        },
    },
)
def tool_close_pane(args):
    cids = args.get("conversationIDs") or []
    handles = args.get("handles") or []
    if not cids and not handles:
        raise RuntimeError("close_pane requires conversationIDs or handles.")
    payload = with_source_context(
        with_window_target({"conversationIDs": cids, "handles": handles}, args), args
    )
    return submit_request(
        "close_pane",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


@register_tool(
    order=35,
    definition={
        "name": "close_workspace",
        "description": "Close a Soyeht workspace (and all its panes) by workspaceID or name. Cannot close the last workspace.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "workspaceIDs": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "UUIDs of workspaces to close.",
                },
                "workspaceNames": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Names of workspaces to close.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 20.0},
            },
        },
    },
)
def tool_close_workspace(args):
    wids = args.get("workspaceIDs") or []
    wnames = args.get("workspaceNames") or []
    if not wids and not wnames:
        raise RuntimeError("close_workspace requires workspaceIDs or workspaceNames.")
    payload = with_source_context(
        with_window_target({"workspaceIDs": wids, "workspaceNames": wnames}, args), args
    )
    return submit_request(
        "close_workspace",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


@register_tool(
    order=36,
    definition={
        "name": "move_pane",
        "description": "Move one or more Soyeht panes/tabs from their current workspace to a different workspace, identified by workspaceID or name. Supports natural-language requests like moving a tab/pane to another workspace; use destinationWindowID for a workspace in another Soyeht window.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "conversationIDs": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "UUIDs of panes to move.",
                },
                "handles": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Handles of panes to move, e.g. @claude.",
                },
                "destinationWorkspaceID": {
                    "type": "string",
                    "description": "UUID of the destination workspace.",
                },
                "destinationWorkspaceName": {
                    "type": "string",
                    "description": "Name of the destination workspace (used if destinationWorkspaceID is not provided).",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "destinationWindowID": DESTINATION_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 20.0},
            },
        },
    },
)
def tool_move_pane(args):
    cids = args.get("conversationIDs") or []
    handles = args.get("handles") or []
    if not cids and not handles:
        raise RuntimeError("move_pane requires conversationIDs or handles.")
    dest_id = args.get("destinationWorkspaceID")
    dest_name = args.get("destinationWorkspaceName")
    if not dest_id and not dest_name:
        raise RuntimeError(
            "move_pane requires destinationWorkspaceID or destinationWorkspaceName."
        )
    payload = with_source_context(
        with_window_target(
            {
                "conversationIDs": cids,
                "handles": handles,
                "destinationWorkspaceID": dest_id,
                "destinationWorkspaceName": dest_name,
            },
            args,
        ),
        args,
    )
    return submit_request(
        "move_pane",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


@register_tool(
    order=39,
    definition={
        "name": "get_pane_status",
        "description": (
            "Return the current status of one or more Soyeht panes. "
            "Status values: 'active' (running, recent output), 'idle' (running, no output >5min), "
            "'dead' (process exited), 'mirror' (remote tmux mirror), 'not_live' (conversation exists but no live view). "
            "Omit conversationIDs and handles to return all live panes. "
            "Use this to monitor fan-out agent runs: open N panes, poll until all are 'dead', then notify the user."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "conversationIDs": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "UUIDs of panes to query. Omit to return all live panes.",
                },
                "handles": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Handles of panes to query, e.g. ['@claude', '@codex']. Omit to return all live panes.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 15.0},
            },
        },
    },
)
def tool_get_pane_status(args):
    payload = with_source_context(
        with_window_target(
            {
                "conversationIDs": args.get("conversationIDs") or [],
                "handles": args.get("handles") or [],
            },
            args,
        ),
        args,
    )
    return submit_request(
        "get_pane_status",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 15.0),
    )


@register_tool(
    order=37,
    definition={
        "name": "get_conversation_context",
        "description": (
            "Read canonical user and assistant messages for the calling Soyeht pane without terminal scraping. "
            "Call this when a SOYEHT_AGENT_HANDOFF_MCP_V1 bootstrap asks you to continue another agent's conversation. "
            "If hasMore is true, call again with afterSequence=nextCursor. After the final page, acknowledge throughSequence."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "afterSequence": {
                    "type": "integer",
                    "minimum": 0,
                    "description": "Sequence cursor returned as nextCursor by the previous page. Omit on the first call.",
                },
                "maxEvents": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 50,
                    "default": 20,
                    "description": "Maximum canonical messages in one page.",
                },
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 15.0},
            },
        },
    },
)
def tool_get_conversation_context(args):
    payload = with_source_context(
        {
            "afterSequence": args.get("afterSequence"),
            "maxEvents": args.get("maxEvents", 20),
        },
        args,
    )
    return submit_request(
        "get_conversation_context",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 15.0),
    )


@register_tool(
    order=38,
    definition={
        "name": "ack_conversation_context",
        "description": (
            "Acknowledge canonical Soyeht conversation context after all pages were read successfully. "
            "Use the throughSequence returned by the final get_conversation_context page."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "throughSequence": {
                    "type": "integer",
                    "minimum": 0,
                    "description": "Final throughSequence returned by get_conversation_context.",
                },
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 15.0},
            },
            "required": ["throughSequence"],
        },
    },
)
def tool_ack_conversation_context(args):
    through_sequence = args.get("throughSequence")
    if through_sequence is None:
        raise RuntimeError("ack_conversation_context requires throughSequence.")
    payload = with_source_context(
        {
            "throughSequence": through_sequence,
        },
        args,
    )
    return submit_request(
        "ack_conversation_context",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 15.0),
    )


@register_tool(
    order=33,
    definition={
        "name": "get_active_context",
        "description": "Return the resolved Soyeht context: activeContext = { windowID, workspaceID, workspaceName, paneID, paneHandle } plus sourceIdentity when called by a live Soyeht pane. In that case activeContext identifies the caller pane, not whichever sibling pane happens to be focused; otherwise it falls back to the user's active window/workspace. Use sourceIdentity for fromConversationID/fromHandle and activeContext.workspaceID when the user says 'open a pane here' / 'in this workspace'.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "windowID": WINDOW_ID_PROPERTY,
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 5.0},
            },
        },
    },
)
def tool_get_active_context(args):
    return submit_request(
        "get_active_context",
        with_source_context(with_window_target({}, args), args),
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 5.0),
    )
