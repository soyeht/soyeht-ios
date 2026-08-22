from soyeht_mcp_foundation import *

TOOLS_MESSAGING = [
    {
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
    {
        "name": "message_agent",
        "description": "High-level durable tool for agent-to-agent communication in Soyeht. It never creates panes. The message is persisted before delivery and policy blocks are enforced. automatic uses semantic inbox only with an observed wake+read adapter; otherwise terminal delivery is deferred until no human draft is open. inbox guarantees zero PTY writes. Use displayReference=[name] in prose and copy only the machine-routing UUID or legacy @handle from list_agents.",
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
                "messageID": {"type": "string", "description": "Optional UUID idempotency key for retries."},
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 20.0},
            },
            "required": ["text"],
        },
    },
    {
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
    {
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
    {
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
    {
        "name": "set_agent_role",
        "description": "Assign a built-in/custom role template or inline role to panes in the caller's workspace. Use roleTemplateID=none to clear.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "conversationIDs": {"type": "array", "items": {"type": "string"}},
                "handles": {"type": "array", "items": {"type": "string"}},
                "roleTemplateID": {"type": "string", "maxLength": 128, "description": "builtin.planner, builtin.executor, builtin.reviewer, builtin.aggregator, a saved custom ID, or none."},
                "roleName": {"type": "string", "maxLength": 256},
                "roleInstructions": {"type": "string", "maxLength": 16384},
                "fromConversationID": FROM_CONVERSATION_ID_PROPERTY,
                "fromHandle": FROM_HANDLE_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 10.0},
            },
        },
    },
    {
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
    {
        "name": "configure_agent_orchestration",
        "description": "Activate a declarative workspace topology with nodes, roles, message/artifact edges and closed-by-default policy. Presets: council, planner-executor-reviewer, executor-reviewer-loop; none deactivates.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "preset": {"type": "string", "enum": ["none", "council", "planner-executor-reviewer", "executor-reviewer-loop"]},
                "ideatorCount": {"type": "integer", "minimum": 1, "maximum": 16},
                "nodeBindings": {"type": "object", "additionalProperties": {"type": "string"}, "description": "Map graph node IDs to real conversation UUIDs."},
                "fromConversationID": FROM_CONVERSATION_ID_PROPERTY,
                "fromHandle": FROM_HANDLE_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 10.0},
            },
            "required": ["preset"],
        },
    },
]
