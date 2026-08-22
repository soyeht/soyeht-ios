from soyeht_mcp_runtime import *
from soyeht_mcp_tools_creation import tool_open_shell

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
    response = tool_open_shell({
        **args,
        "path": str(file_path.parent),
        "name": name,
        "agent": "shell",
        "command": command,
    })
    response["selectedFile"] = str(file_path)
    response["command"] = command
    return response


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

    payload = with_source_context(with_window_target({
        "file": str(file_path),
        "root": str(directory),
        "line": args.get("line"),
        "column": args.get("column"),
    }, args), args)
    return submit_request(
        "open_editor",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", DEFAULT_REQUEST_TIMEOUT),
    )


def tool_open_explorer(args):
    directory = require_visible_directory(
        args.get("root") or args.get("directory") or args.get("path") or args.get("cwd") or "."
    )
    payload = with_source_context(with_window_target({"root": str(directory)}, args), args)
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


def tool_open_git(args):
    repo_arg = args.get("repo") or args.get("path") or args.get("root") or "."
    repo = require_visible_directory(repo_arg)
    selected = safe_optional_selected_file(args.get("selectedFile") or args.get("file"), cwd=repo)
    payload = with_source_context(with_window_target({
        "repo": str(repo),
        "selectedFile": selected,
        "branch": args.get("branch"),
        "compareBase": args.get("compareBase"),
    }, args), args)
    return submit_request(
        "open_git",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", DEFAULT_REQUEST_TIMEOUT),
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

    payload = with_source_context(with_window_target({
        "repo": str(repo),
        "selectedFile": selected_file,
        "branch": args.get("branch"),
        "compareBase": args.get("compareBase"),
    }, args), args)
    return submit_request(
        "open_diff",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", DEFAULT_REQUEST_TIMEOUT),
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
    payload = with_source_context(with_window_target({
        "url": raw_url,
        "newPane": new_pane,
    }, args), args)
    return submit_request(
        "open_web",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", DEFAULT_REQUEST_TIMEOUT),
    )


def tool_install_app(args):
    raw_path = str(args.get("path") or args.get("root") or args.get("directory") or "").strip()
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


def tool_open_app(args):
    install_id = str(first_present(args.get("installID"), args.get("install_id"), "") or "").strip()
    if not install_id:
        raise RuntimeError("open_app requires an installID (returned by install_app).")

    args = dict(args)
    if args.get("workspace_id") and not args.get("workspaceID"):
        args["workspaceID"] = args["workspace_id"]
    if args.get("window_id") and not args.get("windowID"):
        args["windowID"] = args["window_id"]
    payload = with_source_context(with_window_target({"installID": install_id}, args), args)
    return submit_request(
        "open_app",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", DEFAULT_REQUEST_TIMEOUT),
    )

