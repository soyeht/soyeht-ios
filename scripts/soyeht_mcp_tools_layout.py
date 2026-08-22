from soyeht_mcp_runtime import *

def tool_rename_panes(args):
    new_name = args.get("newName")
    if new_name is None or str(new_name).strip() == "":
        raise RuntimeError("rename_panes requires newName.")
    payload = with_source_context(with_window_target(with_name_styles({
        "conversationIDs": args.get("conversationIDs") or [],
        "handles": args.get("handles") or [],
        "newName": str(new_name),
    }, args), args), args)
    return submit_request(
        "rename_panes",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


def tool_rename_workspace(args):
    new_name = args.get("newName")
    if new_name is None or str(new_name).strip() == "":
        raise RuntimeError("rename_workspace requires newName.")
    payload = with_source_context(with_window_target(with_name_styles({
        "workspaceIDs": args.get("workspaceIDs") or [],
        "workspaceNames": args.get("workspaceNames") or [],
        "newName": str(new_name),
    }, args), args), args)
    return submit_request(
        "rename_workspace",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


def tool_arrange_panes(args):
    payload = with_source_context(with_window_target({
        "conversationIDs": args.get("conversationIDs") or [],
        "handles": args.get("handles") or [],
        "layout": args.get("layout") or "stack",
        "ratio": args.get("ratio"),
    }, args), args)
    return submit_request(
        "arrange_panes",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


def tool_emphasize_pane(args):
    payload = with_source_context(with_window_target({
        "conversationIDs": args.get("conversationIDs") or [],
        "handles": args.get("handles") or [],
        "mode": args.get("mode") or "spotlight",
        "ratio": normalize_fraction(args.get("ratio")),
        "position": args.get("position"),
    }, args), args)
    return submit_request(
        "emphasize_pane",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


def tool_resize_pane_exact(args):
    payload = with_source_context(with_window_target({
        "conversationIDs": args.get("conversationIDs") or [],
        "handles": args.get("handles") or [],
        "position": args.get("position") or "left",
        "fraction": normalize_fraction(first_present(args.get("fraction"), args.get("ratio"))),
        "widthFraction": normalize_fraction(args.get("widthFraction")),
        "heightFraction": normalize_fraction(args.get("heightFraction")),
    }, args), args)
    return submit_request(
        "resize_pane_exact",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


def tool_set_pane_zoom(args):
    mode = args.get("mode")
    if not mode:
        mode = "zoom" if args.get("zoom", True) else "unzoom"
    payload = with_source_context(with_window_target({
        "conversationIDs": args.get("conversationIDs") or [],
        "handles": args.get("handles") or [],
        "mode": mode,
    }, args), args)
    return submit_request(
        "emphasize_pane",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


def tool_set_pane_font_size(args):
    payload = with_source_context(with_window_target({
        "conversationIDs": args.get("conversationIDs") or [],
        "handles": args.get("handles") or [],
        "fontSize": args.get("fontSize"),
        "delta": args.get("delta"),
        "persist": bool(args.get("persist", False)),
    }, args), args)
    return submit_request(
        "set_pane_font_size",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


def tool_scroll_pane(args):
    payload = with_source_context(with_window_target({
        "conversationIDs": args.get("conversationIDs") or [],
        "handles": args.get("handles") or [],
        "mode": args.get("mode") or args.get("direction"),
        "lines": args.get("lines"),
        "scrollPosition": normalize_fraction(first_present(args.get("scrollPosition"), args.get("position"))),
        "row": args.get("row"),
    }, args), args)
    return submit_request(
        "scroll_pane",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


