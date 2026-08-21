import json
import fnmatch
import os
import random
import re
import shlex
import shutil
import signal
import subprocess
import sys
import uuid
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from soyeht_mcp_catalog import load_agent_catalog
from soyeht_mcp_ipc import wait_response, write_request


SERVER_NAME = "soyeht-automation"
SERVER_VERSION = "2.0.0"
MCP_CLIENT_CONTRACT_VERSION = 2
NAME_STYLE_CHOICES = ["default", "short", "hyphen", "space", "full-hyphen", "full-space", "verbatim"]
PANE_LAYOUT_CHOICES = ["stack", "row", "grid"]
PANE_EMPHASIS_MODE_CHOICES = ["spotlight", "zoom", "unzoom"]
AGENT_CATALOG, LAUNCH_PROFILES = load_agent_catalog(__file__)
KNOWN_AGENTS = set(AGENT_CATALOG) | {"shell"}
DEFAULT_AGENT_PROFILES = {
    agent_id: entry["defaultProfile"]
    for agent_id, entry in AGENT_CATALOG.items()
    if entry.get("defaultProfile")
}
PROMPT_MODE_CHOICES = ["auto", "message", "raw"]
DEFAULT_INITIAL_PROMPT_DELAYS_MS = {
    "codex": 8_000,
    "claude": 15_000,
}
INITIAL_COMMAND_START_DELAY_MS = 3_000
PANE_EMPHASIS_POSITION_CHOICES = ["left", "right", "top", "bottom"]
PANE_CAPTURE_MODE_CHOICES = ["all", "visible", "scrollback"]
PANE_SCROLL_MODE_CHOICES = ["up", "down", "page_up", "page_down", "top", "bottom", "position", "row"]
WINDOW_ID_PROPERTY = {
    "type": "string",
    "description": "Stable Soyeht macOS windowID. Discover with list_windows. When omitted, Soyeht uses explicit pane/source context before falling back to the active/key window.",
}
TARGET_WINDOW_ID_PROPERTY = {
    "type": "string",
    "description": "Stable Soyeht macOS windowID to run this operation in. Discover with list_windows. When omitted, Soyeht uses explicit pane/source context before falling back to the active/key window.",
}
WORKSPACE_ID_PROPERTY = {
    "type": "string",
    "description": "Stable Soyeht workspaceID. When omitted, Soyeht uses the caller/source pane workspace when available, otherwise the active workspace in the resolved window.",
}
DESTINATION_WINDOW_ID_PROPERTY = {
    "type": "string",
    "description": "Stable Soyeht macOS windowID that owns the destination workspace for cross-window moves.",
}
PROMPT_DELAY_MS_PROPERTY = {
    "type": "integer",
    "description": "Milliseconds to wait after launching a command before sending the initial prompt. If omitted, Soyeht uses a startup-aware default: longer for known agent TUIs such as Codex/Claude, short for plain shells.",
}
PROMPT_MODE_PROPERTY = {
    "type": "string",
    "enum": PROMPT_MODE_CHOICES,
    "default": "auto",
    "description": "How to deliver an initial prompt after opening a pane. auto sends a Soyeht agent message with From/To/Reply metadata for AI agents and raw terminal input for shell panes. Use raw only for literal terminal/menu input.",
}
FROM_CONVERSATION_ID_PROPERTY = {
    "type": "string",
    "description": "Explicit sender conversationID for initial agent prompts. Usually omitted because Soyeht infers it from the calling pane.",
}
FROM_HANDLE_PROPERTY = {
    "type": "string",
    "description": "Explicit sender pane handle for initial agent prompts. Usually omitted because Soyeht infers it from the calling pane.",
}
DEFAULT_REQUEST_TIMEOUT = 20.0
DEFAULT_BATCH_CREATE_TIMEOUT = 60.0
DEFAULT_AGENT_CREATE_TIMEOUT = 120.0
DEFAULT_FILE_PATTERNS = [
    "*.swift",
    "*.md",
    "*.py",
    "*.ts",
    "*.tsx",
    "*.js",
    "*.jsx",
    "*.json",
    "*.yml",
    "*.yaml",
    "*.sh",
    "*.txt",
]
SKIPPED_FILE_DIRS = {
    ".build",
    ".git",
    ".next",
    ".swiftpm",
    "__pycache__",
    "DerivedData",
    "node_modules",
}
SENSITIVE_PATHS = [
    Path.home() / ".ssh",
    Path.home() / ".gnupg",
    Path.home() / ".soyeht",
    Path.home() / "Library" / "Keychains",
]
SOYEHT_ENV_KEYS = {
    "SOYEHT_AUTOMATION_DIR",
    "SOYEHT_CONVERSATION_ID",
    "SOYEHT_HANDLE",
    "SOYEHT_LAUNCH_NONCE",
}
_PARENT_PROCESS_ENVIRONMENT = None


def run(cmd, cwd=None, check=True):
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and proc.returncode != 0:
        joined = " ".join(cmd)
        raise RuntimeError(f"{joined}\n{proc.stderr.strip()}")
    return proc


def concrete_tty_path(value):
    tty = str(value or "").strip()
    if not tty or tty in {"??", "tty", "/dev/tty"}:
        return None
    return tty if tty.startswith("/dev/") else f"/dev/{tty}"


def current_tty():
    for fd in (0, 1, 2):
        try:
            tty = concrete_tty_path(os.ttyname(fd))
            if tty:
                return tty
        except OSError:
            pass
    try:
        fd = os.open("/dev/tty", os.O_RDONLY)
    except OSError:
        fd = None
    if fd is not None:
        try:
            tty = concrete_tty_path(os.ttyname(fd))
            if tty:
                return tty
        except OSError:
            pass
        finally:
            os.close(fd)
    try:
        proc = run(["ps", "-o", "tty=", "-p", str(os.getpid())], check=False)
    except OSError:
        return None
    return concrete_tty_path(proc.stdout)


def git(repo, *args, check=True):
    return run(["git", "-C", str(repo), *args], check=check)


def resolve_path(path, cwd=None):
    value = Path(path).expanduser()
    if not value.is_absolute():
        value = Path(cwd or os.getcwd()) / value
    return value.resolve()


def repo_root(path):
    proc = run(["git", "-C", str(resolve_path(path)), "rev-parse", "--show-toplevel"])
    return Path(proc.stdout.strip()).resolve()


def branch_exists(repo, branch):
    proc = git(repo, "show-ref", "--verify", "--quiet", f"refs/heads/{branch}", check=False)
    return proc.returncode == 0


def slug(value):
    value = str(value).strip()
    value = re.sub(r"\s+", "-", value)
    value = re.sub(r"[^A-Za-z0-9._/-]+", "-", value)
    value = value.strip("-/")
    return value or "worktree"


def default_worktree_root(repo):
    return Path.home() / "soyeht-worktrees" / slug(repo.name)


def default_automation_root():
    override = soyeht_environment_value("SOYEHT_AUTOMATION_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / "Soyeht" / "Automation"


def default_automation_candidates():
    override = soyeht_environment_value("SOYEHT_AUTOMATION_DIR")
    if override:
        return [Path(override).expanduser()]
    app_support = Path.home() / "Library" / "Application Support"
    # Release remains first for normal user launches. Dev is listed so MCP
    # subprocesses from agents that do not inherit SOYEHT_AUTOMATION_DIR
    # (notably Codex) can still route back to the Soyeht Dev pane that spawned
    # them by probing targetWindowID/sourceTTY.
    roots = [
        app_support / "Soyeht" / "Automation",
        app_support / "SoyehtDev" / "Automation",
        app_support / "Soyeht Dev" / "Automation",
    ]
    result = []
    seen = set()
    for root in roots:
        key = str(root.expanduser())
        if key in seen:
            continue
        seen.add(key)
        result.append(root)
    return result


def soyeht_environment_value(key):
    return os.environ.get(key) or parent_process_environment().get(key)


def equivalent_automation_dir(left, right):
    if not left or not right:
        return False
    try:
        left_path = Path(left).expanduser().resolve(strict=False)
        right_path = Path(right).expanduser().resolve(strict=False)
    except (OSError, RuntimeError):
        left_path = Path(str(left)).expanduser()
        right_path = Path(str(right)).expanduser()
    return left_path == right_path


def source_environment_for_context(args=None):
    args = args or {}
    explicit_root = args.get("automationDir")
    for values in (os.environ, parent_process_environment()):
        source = {
            key: values.get(key)
            for key in (
                "SOYEHT_AUTOMATION_DIR",
                "SOYEHT_CONVERSATION_ID",
                "SOYEHT_HANDLE",
                "SOYEHT_LAUNCH_NONCE",
            )
            if values.get(key)
        }
        if not (source.get("SOYEHT_CONVERSATION_ID") or source.get("SOYEHT_HANDLE")):
            continue
        if explicit_root and not equivalent_automation_dir(source.get("SOYEHT_AUTOMATION_DIR"), explicit_root):
            continue
        return source
    return {}


def parent_process_environment(max_depth=4):
    global _PARENT_PROCESS_ENVIRONMENT
    if _PARENT_PROCESS_ENVIRONMENT is not None:
        return _PARENT_PROCESS_ENVIRONMENT

    values = {}
    pid = os.getppid()
    for _ in range(max_depth):
        if pid <= 1:
            break
        for key, value in process_environment(pid).items():
            if key in SOYEHT_ENV_KEYS and key not in values:
                values[key] = value
        next_pid = parent_pid(pid)
        if next_pid is None or next_pid == pid:
            break
        pid = next_pid

    _PARENT_PROCESS_ENVIRONMENT = values
    return values


def parent_pid(pid):
    try:
        output = subprocess.check_output(
            ["ps", "-o", "ppid=", "-p", str(pid)],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        return int(output) if output else None
    except (subprocess.SubprocessError, ValueError):
        return None


def process_environment(pid):
    try:
        output = subprocess.check_output(
            ["ps", "eww", "-o", "command=", "-p", str(pid)],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except subprocess.SubprocessError:
        return {}
    return parse_soyeht_environment(output)


def parse_soyeht_environment(output):
    matches = list(re.finditer(r"(?:^|\s)([A-Za-z_][A-Za-z0-9_]*)=", output))
    values = {}
    for index, match in enumerate(matches):
        key = match.group(1)
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(output)
        value = output[start:end].strip()
        if key in SOYEHT_ENV_KEYS and value:
            values[key] = value
    return values


def default_agent_command(agent):
    if str(agent).strip().lower() == "shell":
        return ""
    agent_id = str(agent).strip().lower()
    if agent_id in AGENT_CATALOG:
        # Keep the legacy launch tools behaviorally aligned with the dedicated
        # launcher. Agents do not always choose the newest tool, so Codex and
        # OpenCode still need the user's default safety profiles here.
        return build_agent_launch(agent_id)["command"]
    executable = AGENT_CATALOG.get(agent_id, {}).get("executable", agent_id)
    resolved = shutil.which(executable)
    return shlex.quote(resolved) if resolved else executable


def normalize_launch_args(values):
    if values is None:
        return []
    if not isinstance(values, list):
        raise RuntimeError("open_agent_pane args must be an array of strings.")
    normalized = []
    for value in values:
        if not isinstance(value, str):
            raise RuntimeError("open_agent_pane args must contain only strings.")
        if "\0" in value:
            raise RuntimeError("open_agent_pane args cannot contain NUL bytes.")
        normalized.append(value)
    return normalized


def build_agent_launch(agent_id, profile=None, model=None, args=None):
    normalized_agent_id = str(agent_id or "").strip().lower()
    agent = AGENT_CATALOG.get(normalized_agent_id)
    if agent is None:
        valid = ", ".join(AGENT_CATALOG)
        raise RuntimeError(
            f"Unknown agentID: {agent_id!r}. Valid agentIDs: {valid}. "
            "The launch is rejected instead of silently substituting another agent."
        )

    if profile is None:
        resolved_profile = DEFAULT_AGENT_PROFILES.get(normalized_agent_id)
    else:
        resolved_profile = str(profile).strip()
        if not resolved_profile:
            raise RuntimeError("open_agent_pane profile cannot be empty. Use 'base' for no profile flags.")
        if resolved_profile == "base":
            resolved_profile = None

    profile_args = []
    if resolved_profile:
        profile_spec = LAUNCH_PROFILES.get(resolved_profile)
        if profile_spec is None:
            valid = ", ".join(["base", *LAUNCH_PROFILES])
            raise RuntimeError(f"Unknown launch profile: {resolved_profile!r}. Valid profiles: {valid}.")
        if profile_spec["agentID"] != normalized_agent_id:
            raise RuntimeError(
                f"Launch profile {resolved_profile!r} belongs to agentID "
                f"{profile_spec['agentID']!r}, not {normalized_agent_id!r}."
            )
        profile_args = list(profile_spec["args"])

    extra_args = normalize_launch_args(args)
    model_value = None
    if model is not None:
        model_value = str(model).strip()
        if not model_value:
            raise RuntimeError("open_agent_pane model cannot be empty.")
        if any(value in {"--model", "-m"} or value.startswith("--model=") for value in extra_args):
            raise RuntimeError("Pass the model once via model, not again in args.")

    executable = agent["executable"]
    resolved_executable = shutil.which(executable) or executable
    argv = [resolved_executable, *profile_args]
    if model_value is not None:
        argv.extend([agent["modelFlag"], model_value])
    argv.extend(extra_args)
    return {
        "agentID": normalized_agent_id,
        "displayName": agent["displayName"],
        "executable": executable,
        "resolvedExecutable": resolved_executable,
        "profile": resolved_profile or "base",
        "model": model_value,
        "args": extra_args,
        "expectedArgv": argv,
        "command": shlex.join(argv),
    }


def safe_agent_reference(handle):
    value = str(handle or "").strip()
    while value.startswith("@"):
        value = value[1:]
    if value.startswith("[") and value.endswith("]"):
        value = value[1:-1]
    value = value.replace("[", "").replace("]", "").strip() or "agent"
    return f"[{value}]"


def decorate_agent_directory(response, filtered_workspace_id=None):
    if not isinstance(response, dict):
        return response

    source = response.get("sourceIdentity") or {}
    active = response.get("activeContext") or {}
    current_workspace_id = source.get("workspaceID") or active.get("workspaceID")
    current_workspace_name = source.get("workspaceName") or active.get("workspaceName")
    resolution = "sourceIdentity" if source.get("workspaceID") else "activeContext"
    if not current_workspace_id:
        resolution = "unresolved"

    if source:
        source["displayReference"] = safe_agent_reference(source.get("handle"))
        source["safeReference"] = source["displayReference"]

    groups_by_id = {}
    group_order = []
    agents = response.get("listedAgents") or []
    for agent in agents:
        workspace_id = agent.get("workspaceID")
        same_workspace = bool(current_workspace_id and workspace_id == current_workspace_id)
        agent["sameWorkspace"] = same_workspace
        agent["currentWorkspace"] = same_workspace
        agent["displayReference"] = safe_agent_reference(agent.get("handle"))
        agent["safeReference"] = agent["displayReference"]
        agent["routingHandle"] = agent.get("handle")
        agent["replyInstructions"] = (
            f"Reply to {agent['displayReference']} with message_agent using this entry's messageTarget. "
            "Use the bracketed reference in prose; routingHandle is machine-only."
        )
        group_key = workspace_id or ""
        if group_key not in groups_by_id:
            groups_by_id[group_key] = {
                "workspaceID": workspace_id,
                "workspaceName": agent.get("workspaceName") or "",
                "sameWorkspace": same_workspace,
                "currentWorkspace": same_workspace,
                "agents": [],
            }
            group_order.append(group_key)
        groups_by_id[group_key]["agents"].append(agent)

    groups = [groups_by_id[key] for key in group_order]
    groups.sort(key=lambda group: (not group["sameWorkspace"], group["workspaceName"].lower()))
    response["directoryScope"] = "workspace" if filtered_workspace_id else "global"
    response["currentWorkspace"] = {
        "workspaceID": current_workspace_id,
        "workspaceName": current_workspace_name,
        "resolution": resolution,
    }
    response["workspaceGroups"] = groups
    response["displayReferenceFormat"] = "[name]"
    response["safeReferenceFormat"] = "[name]"
    response["routingCompatibility"] = (
        "Legacy @handles and conversation UUIDs remain accepted in tool arguments. "
        "Use safeReference ([name]) in commits, PRs, comments, and other prose."
    )
    return response


