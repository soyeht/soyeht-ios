#!/usr/bin/env python3
"""Strict UI cleanup for Soyeht Dev E2E workspaces.

MCP agents intentionally cannot delete workspaces: that remains a human/UI
operation.  Behavioral runners still need to release the real engine sessions
they create, so cleanup exercises that same UI boundary through Accessibility.
Failure is an E2E failure, never a warning, because leaked persistent sessions
eventually exhaust the engine's session cap and invalidate later results.
"""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
from time import monotonic, sleep


def _workspace(snapshot_path: Path, workspace_id: str):
    snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
    workspace = next(
        (item for item in snapshot.get("workspaces", []) if item.get("id") == workspace_id),
        None,
    )
    if workspace is None:
        return None
    pane_count = sum(
        item.get("workspaceID") == workspace_id
        for item in snapshot.get("conversations", [])
    )
    return workspace.get("name") or "", pane_count


def close_workspace_through_ui(
    *,
    snapshot_path: Path,
    workspace_id: str,
    window_id: str,
    timeout: float = 20.0,
):
    """Close one exact test workspace through the app's human-owned UI."""
    snapshot_path = Path(snapshot_path).expanduser().resolve()
    record = _workspace(snapshot_path, workspace_id)
    if record is None:
        return {"workspaceID": workspace_id, "status": "already_absent"}
    workspace_name, pane_count = record
    if not workspace_name or pane_count < 1:
        raise RuntimeError(
            f"Cannot safely identify test workspace {workspace_id} in the persisted snapshot."
        )
    snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
    same_window_workspace_ids = snapshot.get("workspaceOrderByWindow", {}).get(
        window_id,
        [],
    )
    if len(same_window_workspace_ids) < 2:
        raise RuntimeError(
            "Soyeht intentionally refuses to close the final workspace in a window; "
            f"cannot clean test workspace {workspace_id} without a non-test anchor."
        )

    expected_window_identifier = f"com.soyeht.mac.mainwindow.{window_id}"
    script = r'''
on run argv
  set expectedWindowIdentifier to item 1 of argv
  set workspaceName to item 2 of argv
  tell application id "com.soyeht.mac.dev" to activate
  delay 0.25
  tell application "System Events"
    if UI elements enabled is false then error "Accessibility UI control is disabled"
    tell process "Soyeht Dev"
      set targetWindow to first window whose value of attribute "AXIdentifier" is expectedWindowIdentifier
      perform action "AXRaise" of targetWindow
      try
        set value of attribute "AXMain" of targetWindow to true
      end try
      delay 0.15
      if value of attribute "AXIdentifier" of front window is not expectedWindowIdentifier then
        error "The requested Soyeht Dev window did not become frontmost"
      end if
      click menu item workspaceName of menu 1 of menu bar item "Workspaces" of menu bar 1
      delay 0.2
      set closeWorkspaceItem to menu item "Close Workspace" of menu 1 of menu bar item "Shell" of menu bar 1
      if enabled of closeWorkspaceItem is false then
        error "Close Workspace is disabled for the selected test workspace"
      end if
      click closeWorkspaceItem
      -- Selecting a workspace can rebuild the window and invalidate every
      -- AXUIElement proxy, including the sheet's parent window. The close
      -- action makes its destructive confirmation the default button; use the
      -- physical Return path and let the snapshot assertion below prove that
      -- the exact workspace disappeared.
      delay 0.35
      keystroke return
      return "workspace"
    end tell
  end tell
end run
'''
    completed = subprocess.run(
        [
            "/usr/bin/osascript",
            "-e",
            script,
            expected_window_identifier,
            workspace_name,
        ],
        capture_output=True,
        text=True,
        timeout=max(min(timeout, 10.0), 1.0),
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip() or "unknown UI error"
        raise RuntimeError(
            f"Could not close E2E workspace {workspace_id} through Soyeht Dev UI: {detail}"
        )
    deadline = monotonic() + timeout
    while monotonic() < deadline:
        if _workspace(snapshot_path, workspace_id) is None:
            return {"workspaceID": workspace_id, "status": "closed_via_ui"}
        sleep(0.1)
    raise RuntimeError(
        f"Soyeht Dev UI reported {completed.stdout.strip()!r}, but test workspace "
        f"{workspace_id} remained in the snapshot."
    )
