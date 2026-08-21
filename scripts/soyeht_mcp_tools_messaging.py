from soyeht_mcp_runtime import *

def tool_send_pane_input(args):
    text = args.get("text")
    if text is None or text == "":
        raise RuntimeError("send_pane_input requires text.")
    line_ending = args.get("lineEnding")
    if line_ending is None:
        line_ending = "enter" if args.get("appendNewline", True) else "none"
    payload = with_source_context(with_window_target({
        "conversationIDs": args.get("conversationIDs") or [],
        "handles": args.get("handles") or [],
        "text": text,
        "appendNewline": line_ending != "none",
        "lineEnding": line_ending,
        "forceAgentEnvelope": bool(args.get("forceAgentEnvelope", False)),
        "requireAgentEnvelope": bool(args.get("requireAgentEnvelope", False)),
    }, args), args)
    return submit_request(
        "send_pane_input",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


def tool_message_agent(args):
    text = args.get("text")
    if text is None or text == "":
        raise RuntimeError("message_agent requires text.")
    conversation_ids = args.get("conversationIDs") or []
    handles = args.get("handles") or []
    if not conversation_ids and not handles:
        raise RuntimeError("message_agent requires handles or conversationIDs. Use list_panes first; do not create a new pane when you intend to message an existing agent.")
    line_ending = (args.get("lineEnding") or "enter").strip().lower()
    if line_ending != "enter":
        raise RuntimeError(
            "message_agent always submits a complete message with lineEnding=enter. "
            "Use send_pane_input only when you intentionally need raw terminal input."
        )
    payload = with_source_context(with_window_target({
        "conversationIDs": conversation_ids,
        "handles": handles,
        "text": text,
        "lineEnding": line_ending,
        "deliveryPreference": args.get("deliveryPreference") or args.get("deliveryMode") or "automatic",
        "requestAttention": bool(args.get("requestAttention", True)),
        "messageIDs": [args["messageID"]] if args.get("messageID") else [],
    }, args), args)
    return submit_request(
        "send_agent_message",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


def tool_list_agent_messages(args):
    payload = with_source_context({
        "unreadOnly": bool(args.get("unreadOnly", False)),
        "markRead": bool(args.get("markRead", True)),
    }, args)
    return submit_request(
        "list_agent_messages",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )


def tool_ack_agent_messages(args):
    message_ids = args.get("messageIDs") or []
    if not message_ids:
        raise RuntimeError("ack_agent_messages requires messageIDs.")
    payload = with_source_context({"messageIDs": message_ids}, args)
    return submit_request(
        "ack_agent_messages",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )


def tool_set_agent_communication_policy(args):
    payload = with_source_context({
        "incomingEnabled": args.get("incomingEnabled"),
        "incomingAllowsCrossWorkspace": args.get("incomingAllowsCrossWorkspace"),
        "outgoingEnabled": args.get("outgoingEnabled"),
        "outgoingAllowsCrossWorkspace": args.get("outgoingAllowsCrossWorkspace"),
        "blockedPaneIDs": args.get("blockedPaneIDs"),
        "blockedWorkspaceIDs": args.get("blockedWorkspaceIDs"),
    }, args)
    return submit_request(
        "set_agent_communication_policy",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )


def tool_set_agent_role(args):
    payload = with_source_context({
        "conversationIDs": args.get("conversationIDs") or [],
        "handles": args.get("handles") or [],
        "roleTemplateID": args.get("roleTemplateID"),
        "roleName": args.get("roleName"),
        "roleInstructions": args.get("roleInstructions"),
    }, args)
    return submit_request(
        "set_agent_role",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )


def tool_save_agent_role_template(args):
    if not str(args.get("roleName") or "").strip() or not str(args.get("roleInstructions") or "").strip():
        raise RuntimeError("save_agent_role_template requires roleName and roleInstructions.")
    payload = with_source_context({
        "templateID": args.get("templateID"),
        "roleName": args.get("roleName"),
        "roleInstructions": args.get("roleInstructions"),
    }, args)
    return submit_request(
        "save_agent_role_template",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )


def tool_configure_agent_orchestration(args):
    payload = with_source_context({
        "preset": args.get("preset"),
        "ideatorCount": args.get("ideatorCount"),
        "nodeBindings": args.get("nodeBindings") or {},
    }, args)
    return submit_request(
        "configure_agent_orchestration",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )

