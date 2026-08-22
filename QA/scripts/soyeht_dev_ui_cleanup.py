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

    expected_window_identifier = f"com.soyeht.mac.mainwindow.{window_id}"
    script = r'''
on run argv
  set expectedWindowIdentifier to item 1 of argv
  set workspaceName to item 2 of argv
  set paneCount to (item 3 of argv) as integer
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
      repeat paneCount times
        click menu item "Close Pane" of menu 1 of menu bar item "Pane" of menu bar 1
        delay 0.2
        -- The title changes when workspace activation changes. AppleScript
        -- retains AX window references by title, so re-address the already
        -- verified front window instead of using the now-stale specifier.
        if (count of sheets of front window) > 0 then
          if exists button "Close Workspace" of sheet 1 of front window then
            click button "Close Workspace" of sheet 1 of front window
            return "closed"
          end if
        end if
      end repeat
      error "Closing the final pane did not offer the Close Workspace confirmation"
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
            str(pane_count),
        ],
        capture_output=True,
        text=True,
        timeout=max(timeout, 1.0),
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
        f"Soyeht Dev UI accepted cleanup but workspace {workspace_id} remained persisted."
    )
