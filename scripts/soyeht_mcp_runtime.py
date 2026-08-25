from soyeht_mcp_foundation import *
from time import sleep

def with_name_styles(payload, args):
    if args.get("nameStyle"):
        payload["nameStyle"] = args.get("nameStyle")
    if args.get("paneNameStyle"):
        payload["paneNameStyle"] = args.get("paneNameStyle")
    if args.get("workspaceNameStyle"):
        payload["workspaceNameStyle"] = args.get("workspaceNameStyle")
    return payload


def with_window_target(payload, args):
    for key in ("windowID", "targetWindowID", "destinationWindowID"):
        if args.get(key):
            payload[key] = args.get(key)
    if args.get("workspaceID"):
        payload["workspaceID"] = args.get("workspaceID")
    elif args.get("workspaceIDs") and "workspaceIDs" not in payload:
        payload["workspaceIDs"] = args.get("workspaceIDs")
    return payload


def normalize_fraction(value):
    if value is None:
        return None
    try:
        numeric = float(value)
    except (TypeError, ValueError):
        raise RuntimeError(f"Invalid fraction: {value!r}")
    if numeric > 1 and numeric <= 100:
        numeric = numeric / 100
    return numeric


def first_present(*values):
    for value in values:
        if value is not None:
            return value
    return None


def normalize_prompt_mode(value):
    if value is None:
        return None
    mode = str(value).strip().lower().replace("-", "_")
    aliases = {
        "default": "auto",
        "agent": "message",
        "agent_message": "message",
        "envelope": "message",
        "enveloped": "message",
        "terminal": "raw",
        "literal": "raw",
        "input": "raw",
    }
    mode = aliases.get(mode, mode)
    if mode not in PROMPT_MODE_CHOICES:
        valid = ", ".join(PROMPT_MODE_CHOICES)
        raise RuntimeError(f"Invalid promptMode: {value!r}. Valid values: {valid}.")
    return mode


def resolved_prompt_mode(agent, prompt, explicit_mode=None):
    mode = normalize_prompt_mode(explicit_mode)
    if prompt is None or str(prompt).strip() == "":
        return mode
    if mode and mode != "auto":
        return mode
    agent_name = str(agent or "").strip().lower()
    return "raw" if agent_name == "shell" else "message"


def initial_prompt_delay_ms(agent, command=None):
    command_text = str(command or "").strip().lower()
    for name, delay in DEFAULT_INITIAL_PROMPT_DELAYS_MS.items():
        if name in command_text:
            return delay
    return DEFAULT_INITIAL_PROMPT_DELAYS_MS.get(str(agent or "").strip().lower(), 1_500)


def resolved_prompt_delay_ms(agent, command, prompt, explicit_delay_ms=None):
    if prompt is None or str(prompt).strip() == "":
        return explicit_delay_ms
    if explicit_delay_ms is not None:
        return max(int(explicit_delay_ms), 0)
    return initial_prompt_delay_ms(agent, command)


def wait_for_initial_prompt_delivery(payload, response):
    # The app now holds the create response until every requested prompt has
    # resolved against its real agent hook acknowledgement. Keep one summary
    # for compatibility, but never invent readiness from a fixed sleep.
    entries = (response.get("createdPanes") or []) + (response.get("createdWorkspaces") or [])
    statuses = [entry.get("promptDeliveryStatus") for entry in entries if entry.get("promptDeliveryStatus")]
    if statuses:
        unique = sorted(set(statuses))
        response["promptDeliveryStatus"] = unique[0] if len(unique) == 1 else "mixed"
        response["promptDeliveryStatuses"] = statuses
        failed = [
            status for status in statuses
            if status in {"handshake_timeout", "acknowledgement_timeout", "pane_unavailable"}
        ]
        if failed:
            raise RuntimeError(
                "Soyeht created pane metadata but could not verify initial prompt delivery "
                f"({', '.join(failed)}). Created targets: "
                + json.dumps({
                    "createdPanes": response.get("createdPanes") or [],
                    "createdWorkspaces": response.get("createdWorkspaces") or [],
                }, separators=(",", ":"))
            )
    return response


def creation_request_timeout(args, sessions, default=DEFAULT_BATCH_CREATE_TIMEOUT):
    """Budget for the app's real prompt acknowledgement, never a fixed sleep."""
    if args.get("timeout") is not None:
        return float(args["timeout"])
    prompt_sessions = [
        session for session in sessions
        if str(session.get("prompt") or "").strip()
        and str(session.get("agent") or "shell").strip().lower() != "shell"
    ]
    if prompt_sessions:
        total = 0.0
        for session in prompt_sessions:
            prompt = str(session.get("prompt") or "")
            explicit_delay_ms = session.get("promptDelayMs")
            settle_ms = (
                max(int(explicit_delay_ms), 1_500)
                if explicit_delay_ms is not None
                else max(initial_prompt_delay_ms(session.get("agent"), session.get("command")), 1_500)
            )
            ack_window = 20.0 if len(prompt) > 256 or "\n" in prompt else 8.0
            # 3s command admission + 90s startup handshake + settle + three
            # acknowledgement windows + two 2s Return retries + 5s IPC margin.
            total += 3.0 + 90.0 + (settle_ms / 1_000.0) + (3 * ack_window) + 4.0 + 5.0
        return max(default, total)
    return default


def with_source_context(payload, args=None):
    args = args or {}
    explicit_conversation_id = first_present(args.get("fromConversationID"), args.get("sourceConversationID"))
    explicit_handle = first_present(args.get("fromHandle"), args.get("sourceHandle"))
    if explicit_conversation_id or explicit_handle:
        from_conversation_id = explicit_conversation_id
        from_handle = explicit_handle
    else:
        source_environment = source_environment_for_context(args)
        from_conversation_id = source_environment.get("SOYEHT_CONVERSATION_ID")
        from_handle = source_environment.get("SOYEHT_HANDLE")
    if from_conversation_id:
        payload["sourceConversationID"] = from_conversation_id
    if from_handle:
        payload["sourceHandle"] = from_handle
    launch_nonce = source_environment_for_context(args).get("SOYEHT_LAUNCH_NONCE") \
        or soyeht_environment_value("SOYEHT_LAUNCH_NONCE")
    if launch_nonce:
        payload["nonce"] = launch_nonce
    if MCP_RUNTIME_AGENT and MCP_RUNTIME_INSTANCE_ID:
        payload["runtimeAgent"] = MCP_RUNTIME_AGENT
        payload["runtimeInstanceID"] = MCP_RUNTIME_INSTANCE_ID
        payload["runtimeProcessID"] = os.getpid()
    tty = current_tty()
    if tty and not from_conversation_id and not from_handle:
        payload["sourceTTY"] = tty
    return payload


def synchronize_runtime_identity(
    active=True,
    timeout=5.0,
    attempts=1,
    retry_delay=0.05,
):
    """Claim/release a manually launched CLI without changing pane style."""
    if not MCP_RUNTIME_AGENT or not MCP_RUNTIME_INSTANCE_ID:
        return None
    # The same installed MCP configuration is intentionally available when a
    # CLI runs in Terminal.app, iTerm, CI, or another host. `--runtime-agent`
    # describes the client integration; it is not proof that this particular
    # process belongs to a Soyeht pane. Only attempt the possession handshake
    # after inheriting stable pane metadata. Otherwise a harmless read such as
    # list_windows would fail before its handler merely because the external
    # terminal's TTY cannot resolve to a Soyeht pane.
    source_environment = source_environment_for_context()
    if not (
        source_environment.get("SOYEHT_CONVERSATION_ID")
        or source_environment.get("SOYEHT_HANDLE")
    ):
        return None
    payload = with_source_context({
        "runtimeAgent": MCP_RUNTIME_AGENT,
        "runtimeInstanceID": MCP_RUNTIME_INSTANCE_ID,
        "runtimeProcessID": os.getpid(),
    })
    if not (
        payload.get("sourceConversationID")
        or payload.get("sourceHandle")
        or payload.get("sourceTTY")
    ):
        return None
    request_type = "claim_agent_runtime" if active else "release_agent_runtime"
    attempt_count = max(1, int(attempts)) if active else 1
    last_error = None
    for attempt in range(attempt_count):
        try:
            return submit_request(request_type, payload, timeout=timeout)
        except Exception as exc:
            last_error = exc
            if attempt + 1 < attempt_count:
                sleep(max(0.0, float(retry_delay)))
    raise last_error


def ensure_git_worktree(repo, name, base, root, create=True):
    branch = slug(name)
    path = (root / slug(name)).expanduser().resolve()

    if path.exists():
        git_marker = path / ".git"
        if git_marker.exists():
            return {"name": name, "branch": branch, "path": str(path), "created": False}
        raise RuntimeError(f"Refusing to reuse non-git directory: {path}")

    if not create:
        raise RuntimeError(f"Worktree path does not exist and noCreate was set: {path}")

    path.parent.mkdir(parents=True, exist_ok=True)
    if branch_exists(repo, branch):
        git(repo, "worktree", "add", str(path), branch)
    else:
        git(repo, "worktree", "add", "-b", branch, str(path), base)
    return {"name": name, "branch": branch, "path": str(path), "created": True}


def require_directory(path):
    resolved = resolve_path(path)
    if not resolved.is_dir():
        raise RuntimeError(f"Directory does not exist: {resolved}")
    return resolved


def require_file(path, cwd=None):
    resolved = resolve_path(path, cwd=cwd)
    if not resolved.is_file():
        raise RuntimeError(f"File does not exist: {resolved}")
    return resolved


def ensure_safe_visible_path(path):
    resolved = Path(path).expanduser().resolve()
    for sensitive in SENSITIVE_PATHS:
        sensitive = sensitive.expanduser().resolve()
        if resolved == sensitive or sensitive in resolved.parents:
            raise RuntimeError(f"Refusing to open sensitive path in Soyeht UI: {resolved}")
    return resolved


def require_visible_directory(path):
    resolved = ensure_safe_visible_path(resolve_path(path))
    if not resolved.is_dir():
        raise RuntimeError(f"Directory does not exist: {resolved}")
    return resolved


def require_visible_file(path, cwd=None):
    resolved = ensure_safe_visible_path(resolve_path(path, cwd=cwd))
    if not resolved.is_file():
        raise RuntimeError(f"File does not exist: {resolved}")
    return resolved


def infer_editor_root(file_path):
    file_path = ensure_safe_visible_path(file_path)
    try:
        return ensure_safe_visible_path(repo_root(file_path.parent))
    except RuntimeError:
        return require_visible_directory(file_path.parent)


def matching_files(directory, patterns, max_depth):
    root = require_directory(directory)
    patterns = patterns or DEFAULT_FILE_PATTERNS
    candidates = []
    for current, dirs, files in os.walk(root):
        dirs[:] = [
            name for name in dirs
            if name not in SKIPPED_FILE_DIRS and not name.startswith(".")
        ]
        current_path = Path(current)
        rel = current_path.relative_to(root)
        depth = 0 if str(rel) == "." else len(rel.parts)
        if max_depth is not None and depth >= max_depth:
            dirs[:] = []

        for filename in files:
            if filename.startswith("."):
                continue
            file_path = current_path / filename
            rel_name = str(file_path.relative_to(root))
            if any(fnmatch.fnmatch(filename, pattern) or fnmatch.fnmatch(rel_name, pattern) for pattern in patterns):
                candidates.append(file_path)
    return sorted(candidates, key=lambda value: str(value))


def choose_file(args):
    directory = require_directory(args.get("directory") or args.get("path") or ".")
    if args.get("file"):
        return require_file(args.get("file"), cwd=directory)

    max_depth = args.get("maxDepth", 4)
    max_depth = None if max_depth is None else int(max_depth)
    patterns = args.get("patterns") or DEFAULT_FILE_PATTERNS
    files = matching_files(directory, patterns, max_depth)
    if not files:
        raise RuntimeError(f"No matching files found in {directory}.")
    return random.choice(files)


def editor_command(editor, file_path, line=None):
    line_arg = ""
    if line is not None:
        try:
            value = max(1, int(line))
            editor_name = Path(str(editor).split()[0]).name
            if editor_name in {"vi", "vim", "nvim"}:
                line_arg = f" +{value}"
        except (TypeError, ValueError):
            pass
    return f"{editor}{line_arg} {shlex.quote(str(file_path))}"


def submit_request_to_root(root, request_type, payload, timeout=DEFAULT_REQUEST_TIMEOUT, check_status=True):
    payload = dict(payload or {})
    # Persisted on agent messages by the app so behavioral E2E can
    # distinguish this contract from an older launcher targeting the same app.
    payload.setdefault("mcpClientContractVersion", MCP_CLIENT_CONTRACT_VERSION)
    payload.setdefault("mcpClientServerVersion", SERVER_VERSION)
    payload.setdefault("mcpClientProfile", MCP_CLIENT_PROFILE)
    request_id = str(uuid.uuid4())
    request = {
        "id": request_id,
        "type": request_type,
        "payload": payload,
    }
    request_file = write_request(root, request)
    response = wait_response(root, request_id, float(timeout))
    if response is None:
        raise RuntimeError(
            f"Soyeht did not respond before timeout. Make sure the Mac app is running. Request: {request_file}"
        )
    response["requestFile"] = str(request_file)
    if check_status and response.get("status") != "ok":
        raise RuntimeError(response.get("message", "Soyeht automation failed"))
    return response


def probe_request(root, request_type, payload, timeout=1.5):
    try:
        return submit_request_to_root(root, request_type, payload, timeout=timeout, check_status=False)
    except RuntimeError:
        return None


def automation_root_has_window(root, window_id):
    if not window_id:
        return False
    response = probe_request(root, "list_windows", {}, timeout=1.5)
    if not response or response.get("status") != "ok":
        return False
    for window in response.get("listedWindows") or []:
        if window.get("windowID") == window_id:
            return True
    return False


def automation_root_resolves_source(root, payload):
    source_payload = {}
    for key in ("sourceConversationID", "sourceHandle", "sourceTTY"):
        if payload.get(key):
            source_payload[key] = payload[key]
    if not source_payload:
        return False
    response = probe_request(root, "identify_agent", source_payload, timeout=1.5)
    return bool(response and response.get("status") == "ok" and response.get("sourceIdentity"))


def automation_root_has_pane_cwd(root, cwd):
    if not cwd:
        return False
    try:
        cwd_path = str(Path(cwd).expanduser().resolve())
    except OSError:
        cwd_path = str(Path(cwd).expanduser())
    response = probe_request(root, "list_panes", {}, timeout=1.5)
    if not response or response.get("status") != "ok":
        return False
    for pane in response.get("listedPanes") or []:
        try:
            pane_path = str(Path(pane.get("path") or "").expanduser().resolve())
        except OSError:
            pane_path = str(Path(pane.get("path") or "").expanduser())
        if pane_path == cwd_path:
            return True
    return False


def resolve_automation_root(automation_dir, payload):
    if automation_dir:
        return Path(automation_dir).expanduser()
    candidates = default_automation_candidates()
    target_window_id = payload.get("targetWindowID") or payload.get("windowID")
    if target_window_id:
        for root in candidates:
            if automation_root_has_window(root, target_window_id):
                return root
    if any(payload.get(key) for key in ("sourceConversationID", "sourceHandle", "sourceTTY")):
        for root in candidates:
            if automation_root_resolves_source(root, payload):
                return root
    tty = current_tty()
    if tty:
        tty_payload = {"sourceTTY": tty}
        for root in candidates:
            if automation_root_resolves_source(root, tty_payload):
                return root
    cwd = os.getcwd()
    if cwd:
        for root in candidates:
            if automation_root_has_pane_cwd(root, cwd):
                return root
    return candidates[0]


def submit_request(request_type, payload, automation_dir=None, timeout=DEFAULT_REQUEST_TIMEOUT):
    root = resolve_automation_root(automation_dir, payload)
    return submit_request_to_root(root, request_type, payload, timeout=timeout, check_status=True)


def session_spec(
    spec,
    default_agent=None,
    default_command=None,
    default_prompt=None,
    default_prompt_delay_ms=None,
    default_prompt_mode=None,
    require_name=True,
):
    name = spec.get("name")
    path = spec.get("path")
    if require_name and not name:
        raise RuntimeError("Pane spec is missing name.")
    if not path:
        raise RuntimeError("Pane spec is missing path.")

    directory = require_directory(path)
    explicit_agent = spec.get("agent")
    agent = explicit_agent or default_agent or "codex"
    # A pane-level agent override must also change the executable. Previously
    # panes=[{agent: "claude"}] inherited the top-level default command
    # (usually Codex), producing exactly the wrong-agent launch users saw.
    if spec.get("command") is not None:
        command = spec.get("command")
    elif explicit_agent and str(explicit_agent).strip().lower() != str(default_agent or "").strip().lower():
        command = default_agent_command(agent)
    else:
        command = default_command or default_agent_command(agent)
    result = {
        "path": str(directory),
        "agent": agent,
        "command": command,
    }
    if name:
        result["name"] = str(name)
    if spec.get("branch") is not None:
        result["branch"] = spec.get("branch")
    prompt = spec.get("prompt") if spec.get("prompt") is not None else default_prompt
    if prompt is not None:
        result["prompt"] = prompt
        prompt_mode = resolved_prompt_mode(
            agent,
            prompt,
            first_present(spec.get("promptMode"), spec.get("promptDelivery"), default_prompt_mode),
        )
        if prompt_mode:
            result["promptMode"] = prompt_mode
    prompt_delay = (
        spec.get("promptDelayMs")
        if spec.get("promptDelayMs") is not None
        else default_prompt_delay_ms
    )
    prompt_delay = resolved_prompt_delay_ms(agent, command, prompt, prompt_delay)
    if prompt_delay is not None:
        result["promptDelayMs"] = int(prompt_delay)
    return result
