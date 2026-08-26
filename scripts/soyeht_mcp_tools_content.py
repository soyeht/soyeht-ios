from soyeht_mcp_runtime import *
from soyeht_mcp_tools_launch import tool_open_shell
from soyeht_mcp_registry import register_tool


@register_tool(
    order=2,
    definition={
        "name": "open_file",
        "description": "Open a file in vim or another editor inside a new Soyeht shell pane/tab. Use this when the user asks to open a random file, any file, or a specific file in vim/nvim/nano/code in a new shell, terminal, tab, or pane. If file is omitted, the tool picks a random matching file from directory. Do not use Terminal.app or osascript for this intent.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "file": {
                    "type": "string",
                    "description": "Specific file to open. If omitted, a random matching file is selected from directory/path.",
                },
                "directory": {
                    "type": "string",
                    "default": ".",
                    "description": "Directory to search when file is omitted.",
                },
                "path": {
                    "type": "string",
                    "description": "Alias for directory.",
                },
                "root": {
                    "type": "string",
                    "description": "Native editor root folder. Used only when mode=native/editor.",
                },
                "editor": {
                    "type": "string",
                    "default": "vim",
                    "description": "Editor command to run when mode=shell. Defaults to vim.",
                },
                "mode": {
                    "type": "string",
                    "enum": ["shell", "native", "editor"],
                    "default": "shell",
                    "description": "shell preserves the legacy behavior and opens vim in a terminal pane. native/editor opens Soyeht's native editor pane.",
                },
                "line": {
                    "type": "integer",
                    "description": "Optional 1-based line number for vim/nvim/vi.",
                },
                "column": {
                    "type": "integer",
                    "description": "Optional 1-based column for mode=native/editor.",
                },
                "patterns": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Glob patterns for random file selection.",
                    "default": DEFAULT_FILE_PATTERNS,
                },
                "maxDepth": {
                    "type": "integer",
                    "default": 4,
                    "description": "Maximum directory depth for random file search.",
                },
                "name": {
                    "type": "string",
                    "description": "Pane/tab name. Defaults to editor-file.",
                },
                "nameStyle": {"type": "string", "enum": NAME_STYLE_CHOICES},
                "paneNameStyle": {
                    "type": "string",
                    "enum": NAME_STYLE_CHOICES,
                    "description": "Pane/tab names default to short hyphen names.",
                },
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": DEFAULT_REQUEST_TIMEOUT},
            },
        },
    },
)
def tool_open_file(args):
    mode = str(args.get("mode") or "shell").strip().lower()
    if mode in {"native", "editor"}:
        return tool_open_editor(args)
    if mode != "shell":
        raise RuntimeError("open_file mode must be shell, native, or editor.")

    file_path = choose_file(args)
    editor = args.get("editor") or "vim"
    command = editor_command(editor, file_path, args.get("line"))
    editor_name = Path(str(editor).split()[0]).name or "editor"
    name = args.get("name") or f"{editor_name}-{file_path.stem}"
    response = tool_open_shell(
        {
            **args,
            "path": str(file_path.parent),
            "name": name,
            "agent": "shell",
            "command": command,
        }
    )
    response["selectedFile"] = str(file_path)
    response["command"] = command
    return response


@register_tool(
    order=3,
    definition={
        "name": "open_editor",
        "description": "Open or focus a native Soyeht editor pane for a file. Use this when the user says 'open this file in the editor', 'show README in the editor', or equivalent. This does not run vim or any shell command.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "file": {
                    "type": "string",
                    "description": "File to open in the native editor.",
                },
                "directory": {
                    "type": "string",
                    "default": ".",
                    "description": "Directory used for file search when file is omitted.",
                },
                "path": {"type": "string", "description": "Alias for directory."},
                "root": {
                    "type": "string",
                    "description": "Root folder for the file explorer sidebar.",
                },
                "line": {
                    "type": "integer",
                    "description": "Optional 1-based line number.",
                },
                "column": {
                    "type": "integer",
                    "description": "Optional 1-based column number.",
                },
                "patterns": {
                    "type": "array",
                    "items": {"type": "string"},
                    "default": DEFAULT_FILE_PATTERNS,
                },
                "maxDepth": {"type": "integer", "default": 4},
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": DEFAULT_REQUEST_TIMEOUT},
            },
        },
    },
)
def tool_open_editor(args):
    directory_arg = args.get("root") or args.get("directory") or args.get("path")
    if args.get("file"):
        directory = require_visible_directory(directory_arg) if directory_arg else None
        file_path = require_visible_file(args.get("file"), cwd=directory)
        directory = directory or infer_editor_root(file_path)
    else:
        directory = require_visible_directory(directory_arg or ".")
        file_path = choose_file({**args, "directory": str(directory)})
        file_path = require_visible_file(str(file_path))

    payload = with_source_context(
        with_window_target(
            {
                "file": str(file_path),
                "root": str(directory),
                "line": args.get("line"),
                "column": args.get("column"),
            },
            args,
        ),
        args,
    )
    return submit_request(
        "open_editor",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", DEFAULT_REQUEST_TIMEOUT),
    )


@register_tool(
    order=4,
    definition={
        "name": "open_explorer",
        "description": "Open or focus a native Soyeht file explorer/editor pane for a folder. Use this when the user says 'open this folder in the explorer' or equivalent.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "default": ".",
                    "description": "Folder to open.",
                },
                "root": {"type": "string", "description": "Alias for path."},
                "directory": {"type": "string", "description": "Alias for path."},
                "cwd": {"type": "string", "description": "Alias for path."},
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": DEFAULT_REQUEST_TIMEOUT},
            },
        },
    },
)
def tool_open_explorer(args):
    directory = require_visible_directory(
        args.get("root")
        or args.get("directory")
        or args.get("path")
        or args.get("cwd")
        or "."
    )
    payload = with_source_context(
        with_window_target({"root": str(directory)}, args), args
    )
    return submit_request(
        "open_explorer",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", DEFAULT_REQUEST_TIMEOUT),
    )


def safe_optional_selected_file(value, cwd=None):
    if not value:
        return None
    raw = Path(str(value)).expanduser()
    if raw.is_absolute():
        resolved = ensure_safe_visible_path(raw)
        if cwd:
            root = Path(cwd).expanduser().resolve()
            try:
                return str(resolved.relative_to(root))
            except ValueError:
                pass
        return str(resolved)
    if cwd:
        root = Path(cwd).expanduser().resolve()
        candidate = ensure_safe_visible_path(root / raw)
        if candidate != root and root not in candidate.parents:
            raise RuntimeError(f"Refusing to select path outside repository: {value}")
    return str(value)


@register_tool(
    order=5,
    definition={
        "name": "open_git",
        "description": "Open or focus a native Soyeht Git pane for a repository. Use this when the user says 'open the changes', 'show git for this branch', 'open this repo in Git', or equivalent. Git commands only run when the user clicks buttons inside the pane.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "repo": {
                    "type": "string",
                    "default": ".",
                    "description": "Repository folder or any folder inside the repository.",
                },
                "path": {"type": "string", "description": "Alias for repo."},
                "root": {"type": "string", "description": "Alias for repo."},
                "selectedFile": {
                    "type": "string",
                    "description": "Optional file to select in the Git pane.",
                },
                "file": {"type": "string", "description": "Alias for selectedFile."},
                "branch": {"type": "string"},
                "compareBase": {"type": "string"},
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": DEFAULT_REQUEST_TIMEOUT},
            },
        },
    },
)
def tool_open_git(args):
    repo_arg = args.get("repo") or args.get("path") or args.get("root") or "."
    repo = require_visible_directory(repo_arg)
    selected = safe_optional_selected_file(
        args.get("selectedFile") or args.get("file"), cwd=repo
    )
    payload = with_source_context(
        with_window_target(
            {
                "repo": str(repo),
                "selectedFile": selected,
                "branch": args.get("branch"),
                "compareBase": args.get("compareBase"),
            },
            args,
        ),
        args,
    )
    return submit_request(
        "open_git",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", DEFAULT_REQUEST_TIMEOUT),
    )


@register_tool(
    order=6,
    definition={
        "name": "open_diff",
        "description": "Open or focus a native Soyeht Git pane with a file diff selected. Use this when the user asks to open/review the diff for a file or changes in a repo.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "file": {
                    "type": "string",
                    "description": "File whose diff should be selected.",
                },
                "selectedFile": {"type": "string", "description": "Alias for file."},
                "repo": {
                    "type": "string",
                    "description": "Repository folder when no file is provided.",
                },
                "path": {
                    "type": "string",
                    "description": "Alias for repo when no file is provided.",
                },
                "root": {"type": "string", "description": "Alias for repo."},
                "branch": {"type": "string"},
                "compareBase": {"type": "string"},
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": DEFAULT_REQUEST_TIMEOUT},
            },
        },
    },
)
def tool_open_diff(args):
    selected = args.get("selectedFile") or args.get("file")
    repo_arg = args.get("repo") or args.get("path") or args.get("root")
    if repo_arg:
        repo = repo_root(require_visible_directory(repo_arg))
        selected_file = safe_optional_selected_file(selected, cwd=repo)
    elif selected:
        file_path = require_visible_file(selected)
        repo = repo_root(file_path.parent)
        selected_file = safe_optional_selected_file(str(file_path), cwd=repo)
    else:
        repo_arg = args.get("repo") or args.get("path") or args.get("root") or "."
        repo = repo_root(require_visible_directory(repo_arg))
        selected_file = None

    payload = with_source_context(
        with_window_target(
            {
                "repo": str(repo),
                "selectedFile": selected_file,
                "branch": args.get("branch"),
                "compareBase": args.get("compareBase"),
            },
            args,
        ),
        args,
    )
    return submit_request(
        "open_diff",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", DEFAULT_REQUEST_TIMEOUT),
    )


@register_tool(
    order=7,
    definition={
        "name": "open_web",
        "description": (
            "Open or focus a native Soyeht web pane (browser) for a URL. Use this when the user asks to open a website or web app in a pane. "
            "Only http/https URLs are accepted; the app validates fail-closed. "
            "By default, opening the same URL focuses the existing web pane for it and navigates it back to that URL (tab-like reuse). "
            "Set newPane=true to always create a separate pane. "
            "Snake_case aliases workspace_id, window_id and new_pane are also accepted."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "url": {
                    "type": "string",
                    "description": "http(s) URL to open. A bare host (e.g. example.com) is accepted and https:// is assumed.",
                },
                "newPane": {
                    "type": "boolean",
                    "default": False,
                    "description": "When true, always create a new web pane instead of reusing the existing pane for this URL.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": DEFAULT_REQUEST_TIMEOUT},
            },
            "required": ["url"],
        },
    },
)
def tool_open_web(args):
    raw_url = str(args.get("url") or "").strip()
    if not raw_url:
        raise RuntimeError("open_web requires a non-empty url.")

    # URL validation is NOT done here: this script is not a trust boundary.
    # The macOS app validates fail-closed (http/https only) in the request
    # router before any pane is created.
    args = dict(args)
    if args.get("workspace_id") and not args.get("workspaceID"):
        args["workspaceID"] = args["workspace_id"]
    if args.get("window_id") and not args.get("windowID"):
        args["windowID"] = args["window_id"]
    new_pane = bool(first_present(args.get("newPane"), args.get("new_pane"), False))
    payload = with_source_context(
        with_window_target(
            {
                "url": raw_url,
                "newPane": new_pane,
            },
            args,
        ),
        args,
    )
    return submit_request(
        "open_web",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", DEFAULT_REQUEST_TIMEOUT),
    )


@register_tool(
    order=8,
    definition={
        "name": "install_app",
        "description": (
            "Install a local Soyeht app bundle (a directory with a manifest.json) so it can be opened in app panes. "
            "Returns the install record, including the installID that open_app needs and the bundle fingerprint. "
            "The app validates the bundle fail-closed (manifest shape, symlink confinement, no capabilities in phase 2a)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Path to the app bundle directory (must contain manifest.json).",
                },
                "root": {"type": "string", "description": "Alias for path."},
                "directory": {"type": "string", "description": "Alias for path."},
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": DEFAULT_REQUEST_TIMEOUT},
            },
            "required": ["path"],
        },
    },
)
def tool_install_app(args):
    raw_path = str(
        args.get("path") or args.get("root") or args.get("directory") or ""
    ).strip()
    if not raw_path:
        raise RuntimeError("install_app requires a bundle directory path.")

    # The bundle directory must exist and be visible, but the security
    # validation (manifest shape, symlink confinement, capabilities) happens
    # in the macOS app — this script is not a trust boundary.
    bundle = require_visible_directory(raw_path)
    payload = with_source_context({"path": str(bundle)}, args)
    return submit_request(
        "install_app",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", DEFAULT_REQUEST_TIMEOUT),
    )


@register_tool(
    order=9,
    definition={
        "name": "open_app",
        "description": (
            "Open or focus the app pane for an installed Soyeht app. Use the installID returned by install_app. "
            "Snake_case aliases install_id, workspace_id and window_id are also accepted."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "installID": {
                    "type": "string",
                    "description": "Installer-issued installation ID, as returned by install_app.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "workspaceID": WORKSPACE_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": DEFAULT_REQUEST_TIMEOUT},
            },
            "required": ["installID"],
        },
    },
)
def tool_open_app(args):
    install_id = str(
        first_present(args.get("installID"), args.get("install_id"), "") or ""
    ).strip()
    if not install_id:
        raise RuntimeError("open_app requires an installID (returned by install_app).")

    args = dict(args)
    if args.get("workspace_id") and not args.get("workspaceID"):
        args["workspaceID"] = args["workspace_id"]
    if args.get("window_id") and not args.get("windowID"):
        args["windowID"] = args["window_id"]
    payload = with_source_context(
        with_window_target({"installID": install_id}, args), args
    )
    return submit_request(
        "open_app",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", DEFAULT_REQUEST_TIMEOUT),
    )
