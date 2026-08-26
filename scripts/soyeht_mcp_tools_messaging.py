from soyeht_mcp_runtime import *
from soyeht_mcp_registry import register_tool


@register_tool(
    order=10,
    definition={
        "name": "send_pane_input",
        "description": "Send text directly to live Soyeht panes by conversation id or pane handle. Use this for low-level terminal input. If you intend to talk to another agent, prefer message_agent: it requires an identifiable sender and wraps the message with reply instructions. Before sending by handle, call list_panes if there is any doubt; do not create a new pane when the user asked you to message an existing one. send_pane_input can include fromHandle/fromConversationID to identify the sender, otherwise Soyeht tries to infer the sender from the calling terminal TTY. The response reports whether an agent envelope was applied.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "conversationIDs": {"type": "array", "items": {"type": "string"}},
                "handles": {"type": "array", "items": {"type": "string"}},
                "text": {"type": "string", "maxLength": 65536},
                "fromConversationID": {
                    "type": "string",
                    "description": "Explicit sender conversationID. Use this when relaying a message from a known Soyeht pane; it is more reliable than TTY inference.",
                },
                "fromHandle": {
                    "type": "string",
                    "description": "Explicit sender pane handle, such as @codex. Use this when the recipient should know who sent the message and where to reply.",
                },
                "lineEnding": {
                    "type": "string",
                    "enum": ["enter", "newline", "crlf", "none"],
                    "default": "enter",
                    "description": "Terminator to append. enter sends the terminal Return key; newline sends LF; crlf sends CRLF; none sends only the text.",
                },
                "appendNewline": {
                    "type": "boolean",
                    "default": True,
                    "description": "Legacy boolean. false maps to lineEnding=none.",
                },
                "forceAgentEnvelope": {
                    "type": "boolean",
                    "default": False,
                    "description": "Wrap the text with Soyeht From/To/Reply metadata when a sender can be resolved. Prefer message_agent instead of setting this manually.",
                },
                "requireAgentEnvelope": {
                    "type": "boolean",
                    "default": False,
                    "description": "Fail instead of delivering raw text if Soyeht cannot resolve a sender and apply the agent message envelope.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 20.0},
            },
            "required": ["text"],
        },
    },
)
def tool_send_pane_input(args):
    text = args.get("text")
    if text is None or text == "":
        raise RuntimeError("send_pane_input requires text.")
    line_ending = args.get("lineEnding")
    if line_ending is None:
        line_ending = "enter" if args.get("appendNewline", True) else "none"
    payload = with_source_context(
        with_window_target(
            {
                "conversationIDs": args.get("conversationIDs") or [],
                "handles": args.get("handles") or [],
                "text": text,
                "appendNewline": line_ending != "none",
                "lineEnding": line_ending,
                "forceAgentEnvelope": bool(args.get("forceAgentEnvelope", False)),
                "requireAgentEnvelope": bool(args.get("requireAgentEnvelope", False)),
            },
            args,
        ),
        args,
    )
    return submit_request(
        "send_pane_input",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


@register_tool(
    order=11,
    definition={
        "name": "message_agent",
        "description": "Use this for communication requests (talk, send, ping, ask, or wait for replies) whose target names match existing named Soyeht agent panes, or when the user mentions Soyeht, a workspace, or panes. For named targets, list_agents must be called before choosing a delegation mechanism; normalized matches route here, while unmatched names are reported rather than silently created. Never spawn internal harness subagents as substitutes for matched panes. Internal subagents remain valid when the user explicitly asks the harness to create or delegate to new subagents. This is the high-level durable Soyeht pane-to-pane agent-to-agent communication tool and it never creates panes or starts processes. Each existing target returns its own delivered, queued, blocked, mcp_not_connected, agent_not_running, or not_live result; one unavailable target does not cancel the others. Never claim a reply merely because delivery succeeded: wait for a real Soyeht reply or verify pane output. Messages are persisted only for eligible targets before delivery, and policy blocks are enforced. automatic uses semantic inbox only with an observed wake+read adapter; otherwise terminal delivery is deferred until no human draft is open. If a target has no connected MCP client, report that fact and ask the user whether they want to start or restart an agent there; never type a launch command without explicit confirmation. inbox guarantees zero PTY writes. Use displayReference=[name] in prose and copy only the machine-routing UUID or legacy @handle from list_agents.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "conversationIDs": {"type": "array", "items": {"type": "string"}},
                "handles": {"type": "array", "items": {"type": "string"}},
                "text": {"type": "string", "maxLength": 65536},
                "fromConversationID": {
                    "type": "string",
                    "description": "Explicit sender conversationID. Strongly recommended when you know your own Soyeht pane.",
                },
                "fromHandle": {
                    "type": "string",
                    "description": "Explicit sender handle. Strongly recommended so the recipient knows where to reply.",
                },
                "lineEnding": {
                    "type": "string",
                    "enum": ["enter"],
                    "default": "enter",
                    "description": "Agent messages are complete submissions and always use the terminal Return key. Use send_pane_input for intentional raw input.",
                },
                "deliveryPreference": {
                    "type": "string",
                    "enum": ["automatic", "inbox", "deferred_terminal"],
                    "default": "automatic",
                    "description": "automatic uses semantic inbox only when a wake+read adapter is observed; otherwise it queues terminal delivery until the human draft is clear. inbox never writes to PTY.",
                },
                "requestAttention": {"type": "boolean", "default": True},
                "messageID": {
                    "type": "string",
                    "description": "Optional UUID idempotency key for retries.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 20.0},
            },
            "required": ["text"],
        },
    },
)
def tool_message_agent(args):
    text = args.get("text")
    if text is None or text == "":
        raise RuntimeError("message_agent requires text.")
    conversation_ids = args.get("conversationIDs") or []
    handles = args.get("handles") or []
    if not conversation_ids and not handles:
        raise RuntimeError(
            "message_agent requires handles or conversationIDs. Use list_panes first; do not create a new pane when you intend to message an existing agent."
        )
    line_ending = (args.get("lineEnding") or "enter").strip().lower()
    if line_ending != "enter":
        raise RuntimeError(
            "message_agent always submits a complete message with lineEnding=enter. "
            "Use send_pane_input only when you intentionally need raw terminal input."
        )
    payload = with_source_context(
        with_window_target(
            {
                "conversationIDs": conversation_ids,
                "handles": handles,
                "text": text,
                "lineEnding": line_ending,
                "deliveryPreference": args.get("deliveryPreference")
                or args.get("deliveryMode")
                or "automatic",
                "requestAttention": bool(args.get("requestAttention", True)),
                "messageIDs": [args["messageID"]] if args.get("messageID") else [],
            },
            args,
        ),
        args,
    )
    return submit_request(
        "send_agent_message",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


@register_tool(
    order=12,
    definition={
        "name": "list_agent_messages",
        "description": "Read this calling agent's durable semantic inbox. Reading and acknowledgement are separate; call ack_agent_messages after accepting responsibility for a message.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "unreadOnly": {"type": "boolean", "default": False},
                "markRead": {"type": "boolean", "default": True},
                "afterMessageID": {
                    "type": "string",
                    "description": "Cursor from agentInboxPage.nextCursor. Omit for the first page.",
                },
                "messageLimit": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 50,
                    "default": 20,
                    "description": "Maximum messages in this bounded response page.",
                },
                "fromConversationID": FROM_CONVERSATION_ID_PROPERTY,
                "fromHandle": FROM_HANDLE_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 10.0},
            },
        },
    },
)
def tool_list_agent_messages(args):
    payload = with_source_context(
        {
            "unreadOnly": bool(args.get("unreadOnly", False)),
            "markRead": bool(args.get("markRead", True)),
            "afterMessageID": args.get("afterMessageID"),
            "messageLimit": int(args.get("messageLimit", 20)),
        },
        args,
    )
    return submit_request(
        "list_agent_messages",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )


@register_tool(
    order=13,
    definition={
        "name": "ack_agent_messages",
        "description": "Acknowledge durable inbox messages after this agent has read and accepted them.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "messageIDs": {
                    "type": "array",
                    "items": {"type": "string"},
                    "maxItems": 500,
                },
                "fromConversationID": FROM_CONVERSATION_ID_PROPERTY,
                "fromHandle": FROM_HANDLE_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 10.0},
            },
            "required": ["messageIDs"],
        },
    },
)
def tool_ack_agent_messages(args):
    message_ids = args.get("messageIDs") or []
    if not message_ids:
        raise RuntimeError("ack_agent_messages requires messageIDs.")
    payload = with_source_context({"messageIDs": message_ids}, args)
    return submit_request(
        "ack_agent_messages",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )


@register_tool(
    order=14,
    definition={
        "name": "set_agent_communication_policy",
        "description": "Update the calling pane's incoming/outgoing messaging policy. Blocks route by stable pane/workspace UUID and deny always wins.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "incomingEnabled": {"type": "boolean"},
                "incomingAllowsCrossWorkspace": {"type": "boolean"},
                "outgoingEnabled": {"type": "boolean"},
                "outgoingAllowsCrossWorkspace": {"type": "boolean"},
                "blockedPaneIDs": {"type": "array", "items": {"type": "string"}},
                "blockedWorkspaceIDs": {"type": "array", "items": {"type": "string"}},
                "fromConversationID": FROM_CONVERSATION_ID_PROPERTY,
                "fromHandle": FROM_HANDLE_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 10.0},
            },
        },
    },
)
def tool_set_agent_communication_policy(args):
    payload = with_source_context(
        {
            "incomingEnabled": args.get("incomingEnabled"),
            "incomingAllowsCrossWorkspace": args.get("incomingAllowsCrossWorkspace"),
            "outgoingEnabled": args.get("outgoingEnabled"),
            "outgoingAllowsCrossWorkspace": args.get("outgoingAllowsCrossWorkspace"),
            "blockedPaneIDs": args.get("blockedPaneIDs"),
            "blockedWorkspaceIDs": args.get("blockedWorkspaceIDs"),
        },
        args,
    )
    return submit_request(
        "set_agent_communication_policy",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )


@register_tool(
    order=15,
    definition={
        "name": "set_agent_role",
        "description": "Assign a built-in/custom role template or inline role to panes in the caller's workspace. Use roleTemplateID=none to clear.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "conversationIDs": {"type": "array", "items": {"type": "string"}},
                "handles": {"type": "array", "items": {"type": "string"}},
                "roleTemplateID": {
                    "type": "string",
                    "maxLength": 128,
                    "description": "builtin.planner, builtin.executor, builtin.reviewer, builtin.aggregator, a saved custom ID, or none.",
                },
                "roleName": {"type": "string", "maxLength": 256},
                "roleInstructions": {"type": "string", "maxLength": 16384},
                "fromConversationID": FROM_CONVERSATION_ID_PROPERTY,
                "fromHandle": FROM_HANDLE_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 10.0},
            },
        },
    },
)
def tool_set_agent_role(args):
    payload = with_source_context(
        {
            "conversationIDs": args.get("conversationIDs") or [],
            "handles": args.get("handles") or [],
            "roleTemplateID": args.get("roleTemplateID"),
            "roleName": args.get("roleName"),
            "roleInstructions": args.get("roleInstructions"),
        },
        args,
    )
    return submit_request(
        "set_agent_role",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )


@register_tool(
    order=16,
    definition={
        "name": "save_agent_role_template",
        "description": "Create or update a reusable custom agent-role template in the caller's workspace.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "templateID": {"type": "string", "maxLength": 128},
                "roleName": {"type": "string", "maxLength": 256},
                "roleInstructions": {"type": "string", "maxLength": 16384},
                "fromConversationID": FROM_CONVERSATION_ID_PROPERTY,
                "fromHandle": FROM_HANDLE_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 10.0},
            },
            "required": ["roleName", "roleInstructions"],
        },
    },
)
def tool_save_agent_role_template(args):
    if (
        not str(args.get("roleName") or "").strip()
        or not str(args.get("roleInstructions") or "").strip()
    ):
        raise RuntimeError(
            "save_agent_role_template requires roleName and roleInstructions."
        )
    payload = with_source_context(
        {
            "templateID": args.get("templateID"),
            "roleName": args.get("roleName"),
            "roleInstructions": args.get("roleInstructions"),
        },
        args,
    )
    return submit_request(
        "save_agent_role_template",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )


@register_tool(
    order=17,
    definition={
        "name": "configure_agent_orchestration",
        "description": "Activate a declarative workspace topology with nodes, roles, message/artifact edges and closed-by-default policy. Presets: council, planner-executor-reviewer, executor-reviewer-loop; none deactivates.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "preset": {
                    "type": "string",
                    "enum": [
                        "none",
                        "council",
                        "planner-executor-reviewer",
                        "executor-reviewer-loop",
                    ],
                },
                "ideatorCount": {"type": "integer", "minimum": 1, "maximum": 16},
                "nodeBindings": {
                    "type": "object",
                    "additionalProperties": {"type": "string"},
                    "description": "Map graph node IDs to real conversation UUIDs.",
                },
                "fromConversationID": FROM_CONVERSATION_ID_PROPERTY,
                "fromHandle": FROM_HANDLE_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 10.0},
            },
            "required": ["preset"],
        },
    },
)
def tool_configure_agent_orchestration(args):
    payload = with_source_context(
        {
            "preset": args.get("preset"),
            "ideatorCount": args.get("ideatorCount"),
            "nodeBindings": args.get("nodeBindings") or {},
        },
        args,
    )
    return submit_request(
        "configure_agent_orchestration",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )
