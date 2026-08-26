from soyeht_mcp_runtime import *
from soyeht_mcp_registry import register_tool


@register_tool(
    order=1,
    definition={
        "name": "open_shell",
        "description": "Open a new Soyeht shell pane/tab in the caller/source workspace when available, otherwise the active workspace in the resolved window. Use this when the user asks for a new shell, terminal, tab, or pane in the current Soyeht workspace, optionally running a command such as vim, npm test, git status, or an agent command. Do not use Terminal.app or osascript for this intent. If prompt is provided for an AI agent, it is delivered as a Soyeht agent message with sender/reply metadata by default; set promptMode=raw only when simulating a user typing literal input.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "default": ".",
                    "description": "Working directory for the new shell pane.",
                },
                "cwd": {
                    "type": "string",
                    "description": "Alias for path.",
                },
                "name": {
                    "type": "string",
                    "description": "Pane/tab name. If omitted for a shell pane, Soyeht assigns a random unused friendly name.",
                },
                "paneName": {"type": "string"},
                "command": {
                    "type": "string",
                    "description": "Optional shell command to run after opening the pane. Leave absent for a plain interactive shell.",
                },
                "agent": {"type": "string", "default": "shell"},
                "prompt": {"type": "string"},
                "promptMode": PROMPT_MODE_PROPERTY,
                "promptDelayMs": PROMPT_DELAY_MS_PROPERTY,
                "activate": {
                    "type": "boolean",
                    "description": "Focus the newly created pane. Defaults to false for an agent and true for a plain shell.",
                },
                "fromConversationID": FROM_CONVERSATION_ID_PROPERTY,
                "fromHandle": FROM_HANDLE_PROPERTY,
                "nameStyle": {"type": "string", "enum": NAME_STYLE_CHOICES},
                "paneNameStyle": {
                    "type": "string",
                    "enum": NAME_STYLE_CHOICES,
                    "description": "Pane/tab names default to short hyphen names.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {
                    "type": "number",
                    "default": DEFAULT_AGENT_CREATE_TIMEOUT,
                    "description": "Maximum seconds to wait for process startup and the app-observed initial-prompt acknowledgement.",
                },
            },
        },
    },
)
def tool_open_shell(args):
    directory = require_directory(args.get("path") or args.get("cwd") or ".")
    agent = args.get("agent") or "shell"
    command = args.get("command")
    if command is None:
        command = default_agent_command(agent)
    name = args.get("name") or args.get("paneName")
    prompt_mode = normalize_prompt_mode(
        first_present(args.get("promptMode"), args.get("promptDelivery"))
    )
    spec = {
        "path": str(directory),
        "agent": agent,
        "command": command,
        "prompt": args.get("prompt"),
        "promptMode": prompt_mode,
        "promptDelayMs": args.get("promptDelayMs"),
    }
    if name:
        spec["name"] = name

    activate_created_pane = args.get("activate")
    if activate_created_pane is None:
        activate_created_pane = str(agent).strip().lower() == "shell"

    requested_sessions = [
        session_spec(
            spec,
            default_agent=agent,
            default_command=command,
            default_prompt=args.get("prompt"),
            default_prompt_delay_ms=args.get("promptDelayMs"),
            default_prompt_mode=prompt_mode,
            require_name=False,
        )
    ]
    payload = with_source_context(
        with_window_target(
            with_name_styles(
                {
                    "allowAutoPaneNames": True,
                    "activateCreatedPane": bool(activate_created_pane),
                    "agent": agent,
                    "command": command,
                    "promptMode": resolved_prompt_mode(
                        agent, args.get("prompt"), prompt_mode
                    ),
                    "panes": requested_sessions,
                },
                args,
            ),
            args,
        ),
        args,
    )
    return wait_for_initial_prompt_delivery(
        payload,
        submit_request(
            "create_worktree_panes",
            payload,
            automation_dir=args.get("automationDir"),
            timeout=creation_request_timeout(
                args, requested_sessions, default=DEFAULT_REQUEST_TIMEOUT
            ),
        ),
    )


@register_tool(
    order=2,
    definition={
        "name": "open_agent_pane",
        "description": (
            "Open exactly one requested coding-agent CLI in a new Soyeht pane. Use this instead of "
            "open_shell/open_panes whenever the user names Codex, Claude Code, OpenCode, Qwen, "
            "Antigravity, Pi, Droid, Kilo, Cursor, Copilot, Grok, Kimi, Devin, or Qoder. agentID is "
            "fail-closed: an unknown ID or a profile belonging to another agent is rejected, never "
            "silently replaced. Codex defaults to profile codex-yolo (codex --yolo) and OpenCode "
            "defaults to opencode-auto (opencode --auto); pass profile=base to suppress profile flags. "
            "The response returns launchContract.command and expectedArgv for audit, but always marks "
            "argvVerification as required/unverified. Acceptance requires an E2E observation of the live "
            "child process argv in Soyeht Dev; declaredAgent, pane title, and request metadata are not proof. "
            "An explicit name/paneName is preserved verbatim unless a name style is explicitly requested."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "agentID": {
                    "type": "string",
                    "enum": list(AGENT_CATALOG),
                    "description": "Exact stable agent ID. The tool rejects unknown IDs instead of choosing a fallback agent.",
                },
                "cwd": {
                    "type": "string",
                    "default": ".",
                    "description": "Existing working directory in which the exact agent process must launch.",
                },
                "path": {"type": "string", "description": "Legacy alias for cwd."},
                "workspace": {
                    "type": "string",
                    "description": "Stable destination workspace UUID; alias for workspaceID.",
                },
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "model": {
                    "type": "string",
                    "description": "Requested model, encoded as the catalogued --model argument and verified through real argv E2E.",
                },
                "args": {
                    "type": "array",
                    "items": {"type": "string"},
                    "default": [],
                    "description": "Additional literal argv entries appended after profile and model arguments.",
                },
                "profile": {
                    "type": "string",
                    "enum": ["base", *LAUNCH_PROFILES],
                    "description": "Named launch profile. Omit for per-agent defaults; base launches only the executable plus model/args.",
                },
                "name": {"type": "string", "description": "Optional pane name."},
                "paneName": {"type": "string", "description": "Alias for name."},
                "prompt": {
                    "type": "string",
                    "description": "Optional initial agent message after startup.",
                },
                "promptMode": PROMPT_MODE_PROPERTY,
                "promptDelayMs": PROMPT_DELAY_MS_PROPERTY,
                "activate": {
                    "type": "boolean",
                    "default": False,
                    "description": "Focus the newly created pane. Defaults to false so an agent opening a collaborator cannot steal the user's typing focus.",
                },
                "fromConversationID": FROM_CONVERSATION_ID_PROPERTY,
                "fromHandle": FROM_HANDLE_PROPERTY,
                "nameStyle": {"type": "string", "enum": NAME_STYLE_CHOICES},
                "paneNameStyle": {"type": "string", "enum": NAME_STYLE_CHOICES},
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {
                    "type": "number",
                    "default": DEFAULT_AGENT_CREATE_TIMEOUT,
                    "description": "Maximum seconds to wait for process startup and the app-observed initial-prompt acknowledgement.",
                },
            },
            "required": ["agentID"],
        },
    },
)
def tool_open_agent_pane(args):
    agent_id = args.get("agentID")
    if not agent_id:
        raise RuntimeError("open_agent_pane requires agentID.")

    workspace = first_present(args.get("workspaceID"), args.get("workspace"))
    if (
        args.get("workspaceID")
        and args.get("workspace")
        and args["workspaceID"] != args["workspace"]
    ):
        raise RuntimeError(
            "workspace and workspaceID must match when both are provided."
        )

    launch = build_agent_launch(
        agent_id,
        profile=args.get("profile"),
        model=args.get("model"),
        args=args.get("args"),
    )
    directory = require_directory(args.get("cwd") or args.get("path") or ".")
    prompt = args.get("prompt")
    prompt_mode = normalize_prompt_mode(
        first_present(args.get("promptMode"), args.get("promptDelivery"))
    )
    name = args.get("name") or args.get("paneName")
    spec = {
        "path": str(directory),
        "agent": launch["agentID"],
        "command": launch["command"],
        "prompt": prompt,
        "promptMode": prompt_mode,
        "promptDelayMs": args.get("promptDelayMs"),
    }
    if name:
        spec["name"] = name

    routing_args = dict(args)
    if workspace:
        routing_args["workspaceID"] = workspace
    # This dedicated launcher represents an exact agent intent. Preserve an
    # explicit pane name unless the caller deliberately selected a compact
    # naming style; otherwise a later message cannot reliably find the pane by
    # the name the user just requested.
    if (
        name
        and not routing_args.get("nameStyle")
        and not routing_args.get("paneNameStyle")
    ):
        routing_args["paneNameStyle"] = "verbatim"
    payload = with_source_context(
        with_window_target(
            with_name_styles(
                {
                    "allowAutoPaneNames": True,
                    "activateCreatedPane": bool(args.get("activate", False)),
                    "agent": launch["agentID"],
                    "command": launch["command"],
                    "promptMode": resolved_prompt_mode(
                        launch["agentID"], prompt, prompt_mode
                    ),
                    "panes": [
                        session_spec(
                            spec,
                            default_agent=launch["agentID"],
                            default_command=launch["command"],
                            default_prompt=prompt,
                            default_prompt_delay_ms=args.get("promptDelayMs"),
                            default_prompt_mode=prompt_mode,
                            require_name=False,
                        )
                    ],
                },
                routing_args,
            ),
            routing_args,
        ),
        routing_args,
    )
    result = wait_for_initial_prompt_delivery(
        payload,
        submit_request(
            "create_worktree_panes",
            payload,
            automation_dir=args.get("automationDir"),
            timeout=creation_request_timeout(
                args, [payload["panes"][0]], default=DEFAULT_AGENT_CREATE_TIMEOUT
            ),
        ),
    )
    result["launchContract"] = {
        **launch,
        "cwd": str(directory),
        "workspaceID": workspace,
    }
    result["argvVerification"] = {
        "required": True,
        "status": "unverified",
        "expectedArgv": launch["expectedArgv"],
        "acceptance": (
            "Observe the live child process argv in Soyeht Dev. declaredAgent, pane title, "
            "and command metadata are not proof that the requested agent actually launched."
        ),
    }
    return result
