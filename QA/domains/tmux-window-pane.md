---
id: tmux-window-pane
ids: ST-Q-TMUX-001..009
profile: standard
automation: auto
requires_device: true
requires_backend: mac
destructive: false
cleanup_required: false
---

# Tmux Window & Pane Management

## Objective
Verify window/pane CRUD after API standardization (Phase 1 envelope, Phase 2 snake_case, Phase 3 204 for select/kill/rename).

## Risk
If `data` key isn't read from window/pane list responses, tabs won't appear. If select-window/select-pane 204 response causes decode error, switching tabs fails.

## Preconditions
- Connected to an instance with active tmux session

## Test Cases

| ID | Step | Expected | Severity | Auto |
|----|------|----------|----------|------|
| ST-Q-TMUX-001 | View tmux tab bar | Windows appear as tabs with correct names and indices | P1 | Yes |
| ST-Q-TMUX-002 | Create a new window (+ button) | New tab appears. Terminal switches to it | P1 | Yes |
| ST-Q-TMUX-003 | Switch between windows (tap tabs) | Terminal content changes. No error | P1 | Yes |
| ST-Q-TMUX-004 | Rename a window | Tab name updates | P2 | Yes |
| ST-Q-TMUX-005 | Kill/close a window | Tab disappears. Terminal switches to adjacent window | P1 | Yes |
| ST-Q-TMUX-006 | Split pane | New pane appears. Pane navigation controls visible | P1 | Yes |
| ST-Q-TMUX-007 | Switch between panes | Active pane changes. Content correct for each | P1 | Yes |
| ST-Q-TMUX-008 | Kill a pane | Pane disappears. Remaining panes adjust | P1 | Yes |
| ST-Q-TMUX-009 | Open the history button (capture-pane viewer) and scroll up | Previous output is visible when scrolling up, and the existing history viewer still works independently of the floating scrollback panel | P2 | Yes |

## Related Runs
- [2026-04-05 Pane/Window/Tab](../runs/2026-04-05-pane-window-tab/report.md) — 44/44 PASS
- [2026-04-06 History View](../runs/2026-04-06-history-view/report.md) — 26/33 PASS
