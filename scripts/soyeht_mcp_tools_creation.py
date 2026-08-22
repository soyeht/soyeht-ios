from soyeht_mcp_runtime import *

def tool_open_panes(args):
    panes = args.get("panes") or []
    if not panes:
        raise RuntimeError("open_panes requires at least one pane.")

    default_agent = args.get("agent") or "codex"
    explicit_default_command = args.get("command")
    default_command = explicit_default_command or default_agent_command(default_agent)
    default_prompt_mode = normalize_prompt_mode(first_present(args.get("promptMode"), args.get("promptDelivery")))

    pane_agents = [pane.get("agent") or default_agent for pane in panes]
    activate_created_pane = args.get("activate")
    if activate_created_pane is None:
        activate_created_pane = all(str(agent).strip().lower() == "shell" for agent in pane_agents)

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
    payload = with_source_context(with_window_target(with_name_styles({
        "activateCreatedPane": bool(activate_created_pane),
        "agent": default_agent,
        "command": default_command,
        "prompt": args.get("prompt"),
        "promptMode": resolved_prompt_mode(default_agent, args.get("prompt"), default_prompt_mode),
        "promptDelayMs": resolved_prompt_delay_ms(
            default_agent,
            default_command,
            args.get("prompt"),
            args.get("promptDelayMs"),
        ),
        "panes": requested_sessions,
    }, args), args), args)
    return wait_for_initial_prompt_delivery(payload, submit_request(
        "create_worktree_panes",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=creation_request_timeout(args, requested_sessions),
    ))


def tool_open_workspace(args):
    panes = args.get("panes") or []
    if not panes:
        raise RuntimeError("open_workspace requires at least one pane.")

    default_agent = args.get("agent") or "shell"
    explicit_default_command = args.get("command")
    default_command = explicit_default_command or default_agent_command(default_agent)
    default_prompt_mode = normalize_prompt_mode(first_present(args.get("promptMode"), args.get("promptDelivery")))

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
    payload = with_source_context(with_window_target(with_name_styles({
        "workspaceName": args.get("name") or panes[0].get("name") or "Workspace",
        "workspaceBranch": args.get("branch"),
        "agent": default_agent,
        "command": default_command,
        "prompt": args.get("prompt"),
        "promptMode": resolved_prompt_mode(default_agent, args.get("prompt"), default_prompt_mode),
        "promptDelayMs": resolved_prompt_delay_ms(
            default_agent,
            default_command,
            args.get("prompt"),
            args.get("promptDelayMs"),
        ),
        "panes": requested_sessions,
    }, args), args), args)
    return wait_for_initial_prompt_delivery(payload, submit_request(
        "create_workspace_panes",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=creation_request_timeout(args, requested_sessions),
    ))


def tool_open_shell(args):
    directory = require_directory(args.get("path") or args.get("cwd") or ".")
    agent = args.get("agent") or "shell"
    command = args.get("command")
    if command is None:
        command = default_agent_command(agent)
    name = args.get("name") or args.get("paneName")
    prompt_mode = normalize_prompt_mode(first_present(args.get("promptMode"), args.get("promptDelivery")))
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
    payload = with_source_context(with_window_target(with_name_styles({
        "allowAutoPaneNames": True,
        "activateCreatedPane": bool(activate_created_pane),
        "agent": agent,
        "command": command,
        "promptMode": resolved_prompt_mode(agent, args.get("prompt"), prompt_mode),
        "panes": requested_sessions,
    }, args), args), args)
    return wait_for_initial_prompt_delivery(payload, submit_request(
        "create_worktree_panes",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=creation_request_timeout(args, requested_sessions, default=DEFAULT_REQUEST_TIMEOUT),
    ))


def tool_open_agent_pane(args):
    agent_id = args.get("agentID")
    if not agent_id:
        raise RuntimeError("open_agent_pane requires agentID.")

    workspace = first_present(args.get("workspaceID"), args.get("workspace"))
    if args.get("workspaceID") and args.get("workspace") and args["workspaceID"] != args["workspace"]:
        raise RuntimeError("workspace and workspaceID must match when both are provided.")

    launch = build_agent_launch(
        agent_id,
        profile=args.get("profile"),
        model=args.get("model"),
        args=args.get("args"),
    )
    directory = require_directory(args.get("cwd") or args.get("path") or ".")
    prompt = args.get("prompt")
    prompt_mode = normalize_prompt_mode(first_present(args.get("promptMode"), args.get("promptDelivery")))
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
    if name and not routing_args.get("nameStyle") and not routing_args.get("paneNameStyle"):
        routing_args["paneNameStyle"] = "verbatim"
    payload = with_source_context(with_window_target(with_name_styles({
        "allowAutoPaneNames": True,
        "activateCreatedPane": bool(args.get("activate", False)),
        "agent": launch["agentID"],
        "command": launch["command"],
        "promptMode": resolved_prompt_mode(launch["agentID"], prompt, prompt_mode),
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
    }, routing_args), routing_args), routing_args)
    result = wait_for_initial_prompt_delivery(payload, submit_request(
        "create_worktree_panes",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=creation_request_timeout(args, [payload["panes"][0]], default=DEFAULT_AGENT_CREATE_TIMEOUT),
    ))
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


def tool_create_worktree_panes(args):
    names = args.get("names") or []
    if not names:
        raise RuntimeError("create_worktree_panes requires at least one name.")

    repo = repo_root(args.get("repo", "."))
    root = resolve_path(args["worktreeRoot"]) if args.get("worktreeRoot") else default_worktree_root(repo)
    base = args.get("base", "HEAD")
    default_agent = args.get("agent") or "codex"
    explicit_default_command = args.get("command")
    prompt_mode = normalize_prompt_mode(first_present(args.get("promptMode"), args.get("promptDelivery")))
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
        panes.append({
            "name": wt["name"],
            "path": wt["path"],
            "branch": wt["branch"],
            "agent": default_agent,
            "command": default_command,
            "prompt": args.get("prompt"),
            "promptMode": resolved_prompt_mode(default_agent, args.get("prompt"), prompt_mode),
            "promptDelayMs": resolved_prompt_delay_ms(
                default_agent,
                default_command,
                args.get("prompt"),
                args.get("promptDelayMs"),
            ),
        })

    request_type = "create_workspace_panes" if new_workspace else "create_worktree_panes"
    payload = with_source_context(with_window_target(with_name_styles({
        "repoPath": str(repo),
        "workspaceName": args.get("workspaceName"),
        "agent": default_agent,
        "command": default_command,
        "prompt": args.get("prompt"),
        "promptMode": resolved_prompt_mode(default_agent, args.get("prompt"), prompt_mode),
        "promptDelayMs": resolved_prompt_delay_ms(
            default_agent,
            default_command,
            args.get("prompt"),
            args.get("promptDelayMs"),
        ),
        "panes": panes,
    }, args), args), args)
    return wait_for_initial_prompt_delivery(payload, submit_request(
        request_type,
        payload,
        automation_dir=args.get("automationDir"),
        timeout=creation_request_timeout(args, panes),
    ))


def tool_agent_race_panes(args):
    repo = repo_root(args.get("repo", "."))
    root = resolve_path(args["worktreeRoot"]) if args.get("worktreeRoot") else default_worktree_root(repo)
    base = args.get("base", "HEAD")
    agents = args.get("agents") or ["codex", "claude", "opencode"]
    prefix = args.get("prefix", "bug")
    no_create = bool(args.get("noCreate", False))
    new_workspace = bool(args.get("newWorkspace", False))
    prompt_mode = normalize_prompt_mode(first_present(args.get("promptMode"), args.get("promptDelivery")))

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
        panes.append({
            "name": wt["name"],
            "path": wt["path"],
            "branch": wt["branch"],
            "agent": agent,
            "command": default_agent_command(agent),
            "prompt": args.get("prompt"),
            "promptMode": resolved_prompt_mode(agent, args.get("prompt"), prompt_mode),
            "promptDelayMs": resolved_prompt_delay_ms(
                agent,
                default_agent_command(agent),
                args.get("prompt"),
                args.get("promptDelayMs"),
            ),
        })

    request_type = "create_workspace_panes" if new_workspace else "create_worktree_panes"
    payload = with_source_context(with_window_target(with_name_styles({
        "repoPath": str(repo),
        "workspaceName": args.get("workspaceName"),
        "prompt": args.get("prompt"),
        "promptMode": resolved_prompt_mode(agents[0] if agents else "codex", args.get("prompt"), prompt_mode),
        "promptDelayMs": resolved_prompt_delay_ms(
            agents[0] if agents else "codex",
            default_agent_command(agents[0]) if agents else default_agent_command("codex"),
            args.get("prompt"),
            args.get("promptDelayMs"),
        ),
        "panes": panes,
    }, args), args), args)
    return wait_for_initial_prompt_delivery(payload, submit_request(
        request_type,
        payload,
        automation_dir=args.get("automationDir"),
        timeout=creation_request_timeout(args, panes),
    ))


