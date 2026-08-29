from soyeht_mcp_runtime import *
from soyeht_mcp_registry import register_tool


@register_tool(
    order=38,
    definition={
        "name": "capture_pane",
        "description": (
            "Read text directly from a live Soyeht terminal pane without using screen recording, "
            "Accessibility, screenshots, or clipboard automation. Omit conversationIDs and handles "
            "to capture the caller/source pane when available, otherwise the active pane in the resolved window."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "conversationIDs": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "UUIDs of panes to capture. Omit with handles to capture the caller/source pane when available, otherwise the active pane.",
                },
                "handles": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Handles of panes to capture, e.g. ['@codex']. Omit with conversationIDs to capture the caller/source pane when available, otherwise the active pane.",
                },
                "mode": {
                    "type": "string",
                    "enum": PANE_CAPTURE_MODE_CHOICES,
                    "default": "all",
                    "description": "all returns scrollback plus visible rows; visible returns only the viewport; scrollback excludes the viewport.",
                },
                "maxLines": {
                    "type": "integer",
                    "default": 200,
                    "description": "Maximum number of trailing lines to return per pane. Use 0 to return all available text.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 10.0},
            },
        },
    },
)
def tool_capture_pane(args):
    payload = with_source_context(
        with_window_target(
            {
                "conversationIDs": args.get("conversationIDs") or [],
                "handles": args.get("handles") or [],
                "captureMode": args.get("mode") or args.get("captureMode") or "all",
                "maxLines": args.get("maxLines", 200),
            },
            args,
        ),
        args,
    )
    return submit_request(
        "capture_pane",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )


@register_tool(
    order=39,
    definition={
        "name": "capture_pane_range",
        "description": (
            "Read a specific line range from a live Soyeht terminal pane without using screen recording, "
            "Accessibility, screenshots, or clipboard automation. Omit targets to capture the caller/source pane when available, otherwise the active pane."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "conversationIDs": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "UUIDs of panes to capture. Omit with handles to capture the caller/source pane when available, otherwise the active pane.",
                },
                "handles": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Handles of panes to capture, e.g. ['@codex']. Omit with conversationIDs to capture the caller/source pane when available, otherwise the active pane.",
                },
                "mode": {
                    "type": "string",
                    "enum": PANE_CAPTURE_MODE_CHOICES,
                    "default": "all",
                    "description": "all returns scrollback plus visible rows; visible returns only the viewport; scrollback excludes the viewport.",
                },
                "startLine": {
                    "type": "integer",
                    "minimum": 0,
                    "maximum": 1000000,
                    "default": 0,
                    "description": "Zero-based line offset. With fromEnd=true, this is the number of trailing lines to skip.",
                },
                "lineCount": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 5000,
                    "default": 120,
                    "description": "Maximum number of lines to return.",
                },
                "fromEnd": {
                    "type": "boolean",
                    "default": False,
                    "description": "When true, returns a range counted backward from the end.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 10.0},
            },
        },
    },
)
def tool_capture_pane_range(args):
    payload = with_source_context(
        with_window_target(
            {
                "conversationIDs": args.get("conversationIDs") or [],
                "handles": args.get("handles") or [],
                "captureMode": args.get("mode") or args.get("captureMode") or "all",
                "startLine": args.get("startLine"),
                "lineCount": first_present(args.get("lineCount"), args.get("lines")),
                "fromEnd": bool(args.get("fromEnd", False)),
            },
            args,
        ),
        args,
    )
    return submit_request(
        "capture_pane_range",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 10.0),
    )
