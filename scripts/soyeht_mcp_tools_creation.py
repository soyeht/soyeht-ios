from soyeht_mcp_runtime import *
from soyeht_mcp_registry import register_tool


@register_tool(
    order=8,
    definition={
        "name": "open_workspace",
        "description": (
            "Create a brand-new Soyeht workspace and open multiple panes inside it. "
            "Each pane uses an existing directory path — no git worktree creation is done here. "
            "Use this when you already have directories ready, or when the user asks to open a new workspace. "
            "To create git worktrees AND open them in a new workspace in one call, use agent_race_panes with newWorkspace=true instead. "
            "If prompt is provided for an AI agent, it is delivered as a Soyeht agent message with sender/reply metadata by default; set promptMode=raw only for literal terminal input."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string"},
                "branch": {"type": "string"},
                "panes": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "name": {"type": "string"},
                            "path": {"type": "string"},
                            "agent": {"type": "string"},
                            "command": {"type": "string"},
                            "prompt": {"type": "string"},
                            "promptMode": PROMPT_MODE_PROPERTY,
                            "promptDelayMs": PROMPT_DELAY_MS_PROPERTY,
                        },
                        "required": ["name", "path"],
                    },
                },
                "agent": {"type": "string", "default": "shell"},
                "command": {"type": "string"},
                "prompt": {"type": "string"},
                "promptMode": PROMPT_MODE_PROPERTY,
                "promptDelayMs": PROMPT_DELAY_MS_PROPERTY,
                "fromConversationID": FROM_CONVERSATION_ID_PROPERTY,
                "fromHandle": FROM_HANDLE_PROPERTY,
                "nameStyle": {"type": "string", "enum": NAME_STYLE_CHOICES},
                "paneNameStyle": {
                    "type": "string",
                    "enum": NAME_STYLE_CHOICES,
                    "description": "Pane/tab names default to short hyphen names.",
                },
                "workspaceNameStyle": {
                    "type": "string",
                    "enum": NAME_STYLE_CHOICES,
                    "description": "Workspace names default to short space names, ideally one or two words. Use verbatim when the user asks for an exact name.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": DEFAULT_BATCH_CREATE_TIMEOUT},
            },
            "required": ["panes"],
        },
    },
)
def tool_open_workspace(args):
    panes = args.get("panes") or []
    if not panes:
        raise RuntimeError("open_workspace requires at least one pane.")

    default_agent = args.get("agent") or "shell"
    explicit_default_command = args.get("command")
    default_command = explicit_default_command or default_agent_command(default_agent)
    default_prompt_mode = normalize_prompt_mode(
        first_present(args.get("promptMode"), args.get("promptDelivery"))
    )

    requested_sessions = [
        session_spec(
            pane,
            default_agent=default_agent,
            default_command=default_command,
            default_prompt=args.get("prompt"),
            default_prompt_delay_ms=args.get("promptDelayMs"),
            default_prompt_mode=default_prompt_mode,
        )
        for pane in panes
    ]
    payload = with_source_context(
        with_window_target(
            with_name_styles(
                {
                    "workspaceName": args.get("name")
                    or panes[0].get("name")
                    or "Workspace",
                    "workspaceBranch": args.get("branch"),
                    "agent": default_agent,
                    "command": default_command,
                    "prompt": args.get("prompt"),
                    "promptMode": resolved_prompt_mode(
                        default_agent, args.get("prompt"), default_prompt_mode
                    ),
                    "promptDelayMs": resolved_prompt_delay_ms(
                        default_agent,
                        default_command,
                        args.get("prompt"),
                        args.get("promptDelayMs"),
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
            "create_workspace_panes",
            payload,
            automation_dir=args.get("automationDir"),
            timeout=creation_request_timeout(args, requested_sessions),
        ),
    )


@register_tool(
    order=7,
    definition={
        "name": "create_worktree_panes",
        "description": (
            "Create one or more git worktrees and open each as a new Soyeht tab/pane. "
            "All panes run the same single agent (default: codex). "
            "To open different agents per pane (e.g. claude + opencode + codex), use agent_race_panes instead. "
            "By default panes are added to the caller/source workspace when available, otherwise the active workspace in the resolved window. "
            "Set newWorkspace=true to open them in a brand-new workspace instead. "
            "Pass prompt to send an initial message to each agent — Enter is pressed automatically so the agent starts immediately."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "repo": {"type": "string", "default": "."},
                "names": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "One name per worktree/pane to create.",
                },
                "base": {"type": "string", "default": "HEAD"},
                "worktreeRoot": {"type": "string"},
                "agent": {
                    "type": "string",
                    "default": "codex",
                    "description": (
                        "Legacy multi-pane agent selector. All 14 catalog IDs plus shell are supported; "
                        "custom agent names must also provide command. For an exact single-agent launch "
                        "with profiles/model/argv audit, prefer open_agent_pane."
                    ),
                },
                "command": {"type": "string"},
                "prompt": {
                    "type": "string",
                    "description": "Initial prompt sent to every agent after startup. For AI agents this is a Soyeht agent message with sender/reply metadata by default. Enter is pressed automatically.",
                },
                "promptMode": PROMPT_MODE_PROPERTY,
                "promptDelayMs": PROMPT_DELAY_MS_PROPERTY,
                "fromConversationID": FROM_CONVERSATION_ID_PROPERTY,
                "fromHandle": FROM_HANDLE_PROPERTY,
                "noCreate": {"type": "boolean", "default": False},
                "newWorkspace": {
                    "type": "boolean",
                    "default": False,
                    "description": "When true, open all panes in a brand-new workspace instead of the active one.",
                },
                "workspaceName": {
                    "type": "string",
                    "description": "Name for the new workspace when newWorkspace=true.",
                },
                "nameStyle": {"type": "string", "enum": NAME_STYLE_CHOICES},
                "paneNameStyle": {
                    "type": "string",
                    "enum": NAME_STYLE_CHOICES,
                    "description": "Pane/tab names default to short hyphen names, e.g. 'Fix Login Bug' becomes @fix-login.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": DEFAULT_BATCH_CREATE_TIMEOUT},
            },
            "required": ["names"],
        },
    },
)
def tool_create_worktree_panes(args):
    names = args.get("names") or []
    if not names:
        raise RuntimeError("create_worktree_panes requires at least one name.")

    repo = repo_root(args.get("repo", "."))
    root = (
        resolve_path(args["worktreeRoot"])
        if args.get("worktreeRoot")
        else default_worktree_root(repo)
    )
    base = args.get("base", "HEAD")
    default_agent = args.get("agent") or "codex"
    explicit_default_command = args.get("command")
    prompt_mode = normalize_prompt_mode(
        first_present(args.get("promptMode"), args.get("promptDelivery"))
    )
    if default_agent not in KNOWN_AGENTS and not explicit_default_command:
        valid = ", ".join(sorted(KNOWN_AGENTS))
        raise RuntimeError(
            f"Unknown agent: {default_agent}. Valid agents: {valid}. "
            "Provide command when using a custom agent name."
        )
    default_command = explicit_default_command or default_agent_command(default_agent)
    no_create = bool(args.get("noCreate", False))
    new_workspace = bool(args.get("newWorkspace", False))

    panes = []
    for name in names:
        wt = ensure_git_worktree(repo, name, base, root, create=not no_create)
        panes.append(
            {
                "name": wt["name"],
                "path": wt["path"],
                "branch": wt["branch"],
                "agent": default_agent,
                "command": default_command,
                "prompt": args.get("prompt"),
                "promptMode": resolved_prompt_mode(
                    default_agent, args.get("prompt"), prompt_mode
                ),
                "promptDelayMs": resolved_prompt_delay_ms(
                    default_agent,
                    default_command,
                    args.get("prompt"),
                    args.get("promptDelayMs"),
                ),
            }
        )

    request_type = (
        "create_workspace_panes" if new_workspace else "create_worktree_panes"
    )
    payload = with_source_context(
        with_window_target(
            with_name_styles(
                {
                    "repoPath": str(repo),
                    "workspaceName": args.get("workspaceName"),
                    "agent": default_agent,
                    "command": default_command,
                    "prompt": args.get("prompt"),
                    "promptMode": resolved_prompt_mode(
                        default_agent, args.get("prompt"), prompt_mode
                    ),
                    "promptDelayMs": resolved_prompt_delay_ms(
                        default_agent,
                        default_command,
                        args.get("prompt"),
                        args.get("promptDelayMs"),
                    ),
                    "panes": panes,
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
            request_type,
            payload,
            automation_dir=args.get("automationDir"),
            timeout=creation_request_timeout(args, panes),
        ),
    )


@register_tool(
    order=9,
    definition={
        "name": "agent_race_panes",
        "description": (
            "Create one git worktree per AI agent and open each in its own Soyeht tab/pane. "
            "Default agents are codex, claude (Claude Code), and opencode — one worktree each. "
            "Use this whenever the user asks to start multiple AI agents side by side, "
            "'create 3 worktrees with different agents', or 'open claude + opencode + codex'. "
            "Pass prompt to send an initial message to every agent — Enter is pressed automatically so they start working immediately. "
            "By default panes are added to the caller/source workspace when available, otherwise the active workspace in the resolved window. "
            "Set newWorkspace=true to open all agent panes in a brand-new workspace instead."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "repo": {"type": "string", "default": "."},
                "agents": {
                    "type": "array",
                    "items": {"type": "string"},
                    "default": ["codex", "claude", "opencode"],
                    "description": "Catalog agent IDs to launch. Each gets its own worktree and tab; all 14 IDs in open_agent_pane are accepted.",
                },
                "prefix": {
                    "type": "string",
                    "default": "bug",
                    "description": "Branch/worktree name prefix. Each worktree is named <prefix>-<agent>.",
                },
                "base": {"type": "string", "default": "HEAD"},
                "worktreeRoot": {"type": "string"},
                "prompt": {
                    "type": "string",
                    "description": "Initial prompt sent to every agent after startup. For AI agents this is a Soyeht agent message with sender/reply metadata by default. Enter is pressed automatically so the agent starts executing immediately.",
                },
                "promptMode": PROMPT_MODE_PROPERTY,
                "promptDelayMs": PROMPT_DELAY_MS_PROPERTY,
                "fromConversationID": FROM_CONVERSATION_ID_PROPERTY,
                "fromHandle": FROM_HANDLE_PROPERTY,
                "noCreate": {"type": "boolean", "default": False},
                "newWorkspace": {
                    "type": "boolean",
                    "default": False,
                    "description": "When true, open the agent panes in a brand-new workspace instead of adding them to the active workspace.",
                },
                "workspaceName": {
                    "type": "string",
                    "description": "Name for the new workspace when newWorkspace=true. Defaults to a short generated name.",
                },
                "nameStyle": {"type": "string", "enum": NAME_STYLE_CHOICES},
                "paneNameStyle": {
                    "type": "string",
                    "enum": NAME_STYLE_CHOICES,
                    "description": "Pane/tab names default to short hyphen names.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": DEFAULT_BATCH_CREATE_TIMEOUT},
            },
        },
    },
)
def tool_agent_race_panes(args):
    repo = repo_root(args.get("repo", "."))
    root = (
        resolve_path(args["worktreeRoot"])
        if args.get("worktreeRoot")
        else default_worktree_root(repo)
    )
    base = args.get("base", "HEAD")
    agents = args.get("agents") or ["codex", "claude", "opencode"]
    prefix = args.get("prefix", "bug")
    no_create = bool(args.get("noCreate", False))
    new_workspace = bool(args.get("newWorkspace", False))
    prompt_mode = normalize_prompt_mode(
        first_present(args.get("promptMode"), args.get("promptDelivery"))
    )

    unknown = [a for a in agents if a not in KNOWN_AGENTS]
    if unknown:
        valid = ", ".join(sorted(KNOWN_AGENTS - {"shell"}))
        raise RuntimeError(f"Unknown agent(s): {unknown}. Valid agents: {valid}")

    # Build per-agent frequency so repeated agents get a counter suffix
    agent_freq = {}
    for a in agents:
        agent_freq[a] = agent_freq.get(a, 0) + 1
    agent_counter = {}

    panes = []
    for agent in agents:
        agent_counter[agent] = agent_counter.get(agent, 0) + 1
        suffix = f"-{agent_counter[agent]}" if agent_freq[agent] > 1 else ""
        name = f"{prefix}-{agent}{suffix}" if prefix else f"{agent}{suffix}"
        wt = ensure_git_worktree(repo, name, base, root, create=not no_create)
        panes.append(
            {
                "name": wt["name"],
                "path": wt["path"],
                "branch": wt["branch"],
                "agent": agent,
                "command": default_agent_command(agent),
                "prompt": args.get("prompt"),
                "promptMode": resolved_prompt_mode(
                    agent, args.get("prompt"), prompt_mode
                ),
                "promptDelayMs": resolved_prompt_delay_ms(
                    agent,
                    default_agent_command(agent),
                    args.get("prompt"),
                    args.get("promptDelayMs"),
                ),
            }
        )

    request_type = (
        "create_workspace_panes" if new_workspace else "create_worktree_panes"
    )
    payload = with_source_context(
        with_window_target(
            with_name_styles(
                {
                    "repoPath": str(repo),
                    "workspaceName": args.get("workspaceName"),
                    "prompt": args.get("prompt"),
                    "promptMode": resolved_prompt_mode(
                        agents[0] if agents else "codex",
                        args.get("prompt"),
                        prompt_mode,
                    ),
                    "promptDelayMs": resolved_prompt_delay_ms(
                        agents[0] if agents else "codex",
                        (
                            default_agent_command(agents[0])
                            if agents
                            else default_agent_command("codex")
                        ),
                        args.get("prompt"),
                        args.get("promptDelayMs"),
                    ),
                    "panes": panes,
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
            request_type,
            payload,
            automation_dir=args.get("automationDir"),
            timeout=creation_request_timeout(args, panes),
        ),
    )
