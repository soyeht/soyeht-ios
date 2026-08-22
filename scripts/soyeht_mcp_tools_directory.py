from soyeht_mcp_runtime import *

def tool_list_windows(args):
    return submit_request(
        "list_windows",
        {},
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )


def tool_list_workspaces(args):
    return submit_request(
        "list_workspaces",
        with_window_target({}, args),
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )


def tool_list_panes(args):
    payload = with_source_context(with_window_target({}, args), args)
    if args.get("workspaceID"):
        payload["workspaceIDs"] = [args["workspaceID"]]
    return submit_request(
        "list_panes",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )


def tool_identify_agent(args):
    payload = with_source_context(with_window_target({}, args), args)
    return submit_request(
        "identify_agent",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 5.0),
    )


def tool_list_agents(args):
    payload = with_source_context(with_window_target({}, args), args)
    if args.get("workspaceID"):
        payload["workspaceIDs"] = [args["workspaceID"]]
    response = submit_request(
        "list_agents",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )
    return decorate_agent_directory(response, filtered_workspace_id=args.get("workspaceID"))


def tool_close_pane(args):
    cids = args.get("conversationIDs") or []
    handles = args.get("handles") or []
    if not cids and not handles:
        raise RuntimeError("close_pane requires conversationIDs or handles.")
    payload = with_source_context(with_window_target({"conversationIDs": cids, "handles": handles}, args), args)
    return submit_request(
        "close_pane",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


def tool_close_workspace(args):
    wids = args.get("workspaceIDs") or []
    wnames = args.get("workspaceNames") or []
    if not wids and not wnames:
        raise RuntimeError("close_workspace requires workspaceIDs or workspaceNames.")
    payload = with_source_context(with_window_target({"workspaceIDs": wids, "workspaceNames": wnames}, args), args)
    return submit_request(
        "close_workspace",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


def tool_move_pane(args):
    cids = args.get("conversationIDs") or []
    handles = args.get("handles") or []
    if not cids and not handles:
        raise RuntimeError("move_pane requires conversationIDs or handles.")
    dest_id = args.get("destinationWorkspaceID")
    dest_name = args.get("destinationWorkspaceName")
    if not dest_id and not dest_name:
        raise RuntimeError("move_pane requires destinationWorkspaceID or destinationWorkspaceName.")
    payload = with_source_context(with_window_target({
        "conversationIDs": cids,
        "handles": handles,
        "destinationWorkspaceID": dest_id,
        "destinationWorkspaceName": dest_name,
    }, args), args)
    return submit_request(
        "move_pane",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


def tool_get_pane_status(args):
    payload = with_source_context(with_window_target({
        "conversationIDs": args.get("conversationIDs") or [],
        "handles": args.get("handles") or [],
    }, args), args)
    return submit_request(
        "get_pane_status",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 15.0),
    )


def tool_get_conversation_context(args):
    payload = with_source_context({
        "afterSequence": args.get("afterSequence"),
        "maxEvents": args.get("maxEvents", 20),
    }, args)
    return submit_request(
        "get_conversation_context",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 15.0),
    )


def tool_ack_conversation_context(args):
    through_sequence = args.get("throughSequence")
    if through_sequence is None:
        raise RuntimeError("ack_conversation_context requires throughSequence.")
    payload = with_source_context({
        "throughSequence": through_sequence,
    }, args)
    return submit_request(
        "ack_conversation_context",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 15.0),
    )


def tool_capture_pane(args):
    payload = with_source_context(with_window_target({
        "conversationIDs": args.get("conversationIDs") or [],
        "handles": args.get("handles") or [],
        "captureMode": args.get("mode") or args.get("captureMode") or "all",
        "maxLines": args.get("maxLines", 200),
    }, args), args)
    return submit_request(
        "capture_pane",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )


def tool_capture_pane_range(args):
    payload = with_source_context(with_window_target({
        "conversationIDs": args.get("conversationIDs") or [],
        "handles": args.get("handles") or [],
        "captureMode": args.get("mode") or args.get("captureMode") or "all",
        "startLine": args.get("startLine"),
        "lineCount": first_present(args.get("lineCount"), args.get("lines")),
        "fromEnd": bool(args.get("fromEnd", False)),
    }, args), args)
    return submit_request(
        "capture_pane_range",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )


def tool_get_active_context(args):
    return submit_request(
        "get_active_context",
        with_source_context(with_window_target({}, args), args),
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 5.0),
    )

