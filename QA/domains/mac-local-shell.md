---
id: mac-local-shell
ids: ST-Q-MLSH-001..007
profile: quick
automation: assisted
requires_device: false
requires_backend: false
destructive: false
cleanup_required: false
platform: macOS
---

# macOS Local Shell Terminal

## Objective
Verify the local shell tab: correct shell spawned, navigation to local git repositories, PTY resize, process lifecycle (no zombie PTYs after tab close), and theme/font application.

## Risk
- `getShell()` falls back to `/bin/bash` even when user's default is zsh → wrong shell
- PTY resize message not sent when window is resized → garbled column count
- PTY not cleaned up on tab close → zombie process; eventual resource leak over long session
- `ColorTheme.active` not applied to `LocalProcessTerminalView` on macOS → always shows default colors

## Preconditions
- macOS app running, at least one local shell tab open
- A local git repository at a known path (e.g., `~/Documents/SwiftProjects/iSoyehtTerm-macos`)

## How to automate
- **Type commands**: `mcp__XcodeBuildMCP__type_text` into the active terminal view
- **Read output**: `mcp__XcodeBuildMCP__screenshot` + OCR, or `mcp__XcodeBuildMCP__snapshot_ui`
- **Verify process gone**: `Bash("ps aux | grep -v grep | grep defunct")` after tab close

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-MLSH-001 | Open app → local shell tab | Shell prompt appears. `echo $SHELL` output matches the user's default shell (e.g., `/bin/zsh`) | P0 | Yes |
| ST-Q-MLSH-002 | Run `pwd` and `ls` | Output shows correct working directory (home dir) and file listing. No garbled characters | P0 | Yes |
| ST-Q-MLSH-003 | `cd ~/Documents/SwiftProjects/iSoyehtTerm-macos && git status` | Shows correct branch name and file status. Git works inside the local shell tab | P1 | Yes |
| ST-Q-MLSH-004 | `git log --oneline -5` | Last 5 commits shown correctly. Terminal renders color output (if git uses colors) | P2 | Yes |
| ST-Q-MLSH-005 | Drag window edge to resize → run `tput cols` | `tput cols` output matches the new visual column count. Terminal redraws cleanly | P1 | Assisted |
| ST-Q-MLSH-006 | Close the local shell tab (Cmd+W) | Tab disappears. No orphaned PTY: `ps aux \| grep defunct` returns nothing for shell process | P1 | Yes |
| ST-Q-MLSH-007 | Change font size (Preferences or Cmd+Plus) | Terminal text resizes. Column/row count adjusts. No visual corruption | P2 | Assisted |

## Notes
- `getShell()` in `LocalShellViewController` reads from `getpwuid_r` — this is the correct method for the user's login shell, not `$SHELL` env var (which may differ in sandboxed contexts)
- The local shell does NOT connect to any backend; it's a pure local PTY
