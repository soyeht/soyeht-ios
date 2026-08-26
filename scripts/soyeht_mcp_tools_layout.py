from soyeht_mcp_runtime import *
from soyeht_mcp_registry import register_tool


@register_tool(
    order=18,
    definition={
        "name": "rename_panes",
        "description": "Rename live Soyeht panes/tabs by conversation id or handle. Default pane/tab names are short and hyphenated.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "conversationIDs": {"type": "array", "items": {"type": "string"}},
                "handles": {"type": "array", "items": {"type": "string"}},
                "newName": {"type": "string"},
                "nameStyle": {"type": "string", "enum": NAME_STYLE_CHOICES},
                "paneNameStyle": {
                    "type": "string",
                    "enum": NAME_STYLE_CHOICES,
                    "description": "Defaults to short hyphen names. Use space/full-space/verbatim only when the user explicitly asks.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 20.0},
            },
            "required": ["newName"],
        },
    },
)
def tool_rename_panes(args):
    new_name = args.get("newName")
    if new_name is None or str(new_name).strip() == "":
        raise RuntimeError("rename_panes requires newName.")
    payload = with_source_context(
        with_window_target(
            with_name_styles(
                {
                    "conversationIDs": args.get("conversationIDs") or [],
                    "handles": args.get("handles") or [],
                    "newName": str(new_name),
                },
                args,
            ),
            args,
        ),
        args,
    )
    return submit_request(
        "rename_panes",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


@register_tool(
    order=19,
    definition={
        "name": "rename_workspace",
        "description": "Rename Soyeht workspaces by id/name, or the active workspace when no target is provided. Default workspace names are short with normal spaces.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "workspaceIDs": {"type": "array", "items": {"type": "string"}},
                "workspaceNames": {"type": "array", "items": {"type": "string"}},
                "newName": {"type": "string"},
                "nameStyle": {"type": "string", "enum": NAME_STYLE_CHOICES},
                "workspaceNameStyle": {
                    "type": "string",
                    "enum": NAME_STYLE_CHOICES,
                    "description": "Defaults to short space names, ideally one or two words. Use verbatim only when the user explicitly asks.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 20.0},
            },
            "required": ["newName"],
        },
    },
)
def tool_rename_workspace(args):
    new_name = args.get("newName")
    if new_name is None or str(new_name).strip() == "":
        raise RuntimeError("rename_workspace requires newName.")
    payload = with_source_context(
        with_window_target(
            with_name_styles(
                {
                    "workspaceIDs": args.get("workspaceIDs") or [],
                    "workspaceNames": args.get("workspaceNames") or [],
                    "newName": str(new_name),
                },
                args,
            ),
            args,
        ),
        args,
    )
    return submit_request(
        "rename_workspace",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


@register_tool(
    order=20,
    definition={
        "name": "arrange_panes",
        "description": "Rearrange Soyeht panes/tabs in the current workspace. Use this when the user asks to put panes one above another, stack tabs, make panes vertical/top-to-bottom, put them side by side, line them up, tile them, or make a grid. If no target is provided, all panes in the active workspace are arranged.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "conversationIDs": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Target pane conversation IDs. Use IDs returned by create/open tools when the user says 'these panes'. Omit to arrange all panes in the active workspace.",
                },
                "handles": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Target pane handles such as @codex or @review-login.",
                },
                "layout": {
                    "type": "string",
                    "enum": PANE_LAYOUT_CHOICES,
                    "default": "stack",
                    "description": "stack means top-to-bottom; row means side-by-side; grid means tiled/balanced.",
                },
                "ratio": {
                    "type": "number",
                    "description": "Optional share for the arranged group when non-target panes remain visible.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 20.0},
            },
        },
    },
)
def tool_arrange_panes(args):
    payload = with_source_context(
        with_window_target(
            {
                "conversationIDs": args.get("conversationIDs") or [],
                "handles": args.get("handles") or [],
                "layout": args.get("layout") or "stack",
                "ratio": args.get("ratio"),
            },
            args,
        ),
        args,
    )
    return submit_request(
        "arrange_panes",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


@register_tool(
    order=21,
    definition={
        "name": "emphasize_pane",
        "description": "Make one Soyeht pane/tab stand out. Use spotlight when the user asks to make a pane larger while keeping other panes visible. Use zoom when they want only that pane visible, and unzoom/restore when they want to return to the split layout.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "conversationIDs": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Target pane conversation ID. Uses the first target. Omit to use the caller/source pane when available, otherwise the active pane.",
                },
                "handles": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Target pane handle such as @codex or @fix-login.",
                },
                "mode": {
                    "type": "string",
                    "enum": PANE_EMPHASIS_MODE_CHOICES,
                    "default": "spotlight",
                    "description": "spotlight makes the target larger and keeps siblings visible; zoom shows only the target; unzoom restores a zoomed pane.",
                },
                "ratio": {
                    "type": "number",
                    "default": 0.72,
                    "description": "Target pane share for spotlight mode.",
                },
                "position": {
                    "type": "string",
                    "enum": PANE_EMPHASIS_POSITION_CHOICES,
                    "default": "left",
                    "description": "Where to place the target in spotlight mode.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 20.0},
            },
        },
    },
)
def tool_emphasize_pane(args):
    payload = with_source_context(
        with_window_target(
            {
                "conversationIDs": args.get("conversationIDs") or [],
                "handles": args.get("handles") or [],
                "mode": args.get("mode") or "spotlight",
                "ratio": normalize_fraction(args.get("ratio")),
                "position": args.get("position"),
            },
            args,
        ),
        args,
    )
    return submit_request(
        "emphasize_pane",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


@register_tool(
    order=22,
    definition={
        "name": "resize_pane_exact",
        "description": "Place one Soyeht pane at an exact share of the workspace on the left, right, top, or bottom. Use fraction=0.5 for 50% of the workspace. Omit targets to resize the caller/source pane when available, otherwise the active pane.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "conversationIDs": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Target pane conversation ID. Uses the first target. Omit with handles to use the caller/source pane when available, otherwise the active pane.",
                },
                "handles": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Target pane handle such as @codex or @feature-screen-recording.",
                },
                "position": {
                    "type": "string",
                    "enum": PANE_EMPHASIS_POSITION_CHOICES,
                    "default": "left",
                    "description": "Side of the workspace occupied by the target pane.",
                },
                "fraction": {
                    "type": "number",
                    "default": 0.5,
                    "description": "Target pane share as 0.1..0.9. Values like 50 are accepted as 50%.",
                },
                "widthFraction": {
                    "type": "number",
                    "description": "Width share for left/right placement. Overrides fraction for horizontal placement.",
                },
                "heightFraction": {
                    "type": "number",
                    "description": "Height share for top/bottom placement. Overrides fraction for vertical placement.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 20.0},
            },
        },
    },
)
def tool_resize_pane_exact(args):
    payload = with_source_context(
        with_window_target(
            {
                "conversationIDs": args.get("conversationIDs") or [],
                "handles": args.get("handles") or [],
                "position": args.get("position") or "left",
                "fraction": normalize_fraction(
                    first_present(args.get("fraction"), args.get("ratio"))
                ),
                "widthFraction": normalize_fraction(args.get("widthFraction")),
                "heightFraction": normalize_fraction(args.get("heightFraction")),
            },
            args,
        ),
        args,
    )
    return submit_request(
        "resize_pane_exact",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


@register_tool(
    order=23,
    definition={
        "name": "set_pane_zoom",
        "description": "Zoom one Soyeht pane so only that pane is visible, or unzoom to restore the split layout. Omit targets to use the caller/source pane when available, otherwise the active pane.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "conversationIDs": {"type": "array", "items": {"type": "string"}},
                "handles": {"type": "array", "items": {"type": "string"}},
                "mode": {
                    "type": "string",
                    "enum": ["zoom", "unzoom"],
                    "description": "Explicit zoom mode. Overrides zoom.",
                },
                "zoom": {
                    "type": "boolean",
                    "default": True,
                    "description": "true zooms the target pane; false restores the split layout.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 20.0},
            },
        },
    },
)
def tool_set_pane_zoom(args):
    mode = args.get("mode")
    if not mode:
        mode = "zoom" if args.get("zoom", True) else "unzoom"
    payload = with_source_context(
        with_window_target(
            {
                "conversationIDs": args.get("conversationIDs") or [],
                "handles": args.get("handles") or [],
                "mode": mode,
            },
            args,
        ),
        args,
    )
    return submit_request(
        "emphasize_pane",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


@register_tool(
    order=24,
    definition={
        "name": "set_pane_font_size",
        "description": "Set or adjust the font size of live Soyeht terminal panes. Omit targets to use the caller/source pane when available, otherwise the active pane.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "conversationIDs": {"type": "array", "items": {"type": "string"}},
                "handles": {"type": "array", "items": {"type": "string"}},
                "fontSize": {
                    "type": "number",
                    "description": "Absolute terminal font size in points. Clamped by the app.",
                },
                "delta": {
                    "type": "number",
                    "description": "Relative font-size adjustment in points. Used when fontSize is omitted.",
                },
                "persist": {
                    "type": "boolean",
                    "default": False,
                    "description": "When true, also save this as the default terminal font size.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 20.0},
            },
        },
    },
)
def tool_set_pane_font_size(args):
    payload = with_source_context(
        with_window_target(
            {
                "conversationIDs": args.get("conversationIDs") or [],
                "handles": args.get("handles") or [],
                "fontSize": args.get("fontSize"),
                "delta": args.get("delta"),
                "persist": bool(args.get("persist", False)),
            },
            args,
        ),
        args,
    )
    return submit_request(
        "set_pane_font_size",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )


@register_tool(
    order=25,
    definition={
        "name": "scroll_pane",
        "description": "Scroll live Soyeht terminal panes without mouse or screen automation. Omit targets to use the caller/source pane when available, otherwise the active pane.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "conversationIDs": {"type": "array", "items": {"type": "string"}},
                "handles": {"type": "array", "items": {"type": "string"}},
                "mode": {
                    "type": "string",
                    "enum": PANE_SCROLL_MODE_CHOICES,
                    "default": "bottom",
                    "description": "Scroll action. position uses scrollPosition; row uses row; up/down use lines.",
                },
                "lines": {
                    "type": "integer",
                    "description": "Line count for up/down. Defaults to the pane height.",
                },
                "scrollPosition": {
                    "type": "number",
                    "description": "Relative scroll position 0..1 for mode=position. Values like 50 are accepted as 50%.",
                },
                "row": {
                    "type": "integer",
                    "description": "Top visible row for mode=row.",
                },
                "targetWindowID": TARGET_WINDOW_ID_PROPERTY,
                "automationDir": {"type": "string"},
                "timeout": {"type": "number", "default": 20.0},
            },
        },
    },
)
def tool_scroll_pane(args):
    payload = with_source_context(
        with_window_target(
            {
                "conversationIDs": args.get("conversationIDs") or [],
                "handles": args.get("handles") or [],
                "mode": args.get("mode") or args.get("direction"),
                "lines": args.get("lines"),
                "scrollPosition": normalize_fraction(
                    first_present(args.get("scrollPosition"), args.get("position"))
                ),
                "row": args.get("row"),
            },
            args,
        ),
        args,
    )
    return submit_request(
        "scroll_pane",
        payload,
        automation_dir=args.get("automationDir"),
        timeout=args.get("timeout", 20.0),
    )
