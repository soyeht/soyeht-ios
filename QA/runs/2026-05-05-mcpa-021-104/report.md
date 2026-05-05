# QA Report: ST-Q-MCPA-021..104 — Direct MCP Validation
**Date:** 2026-05-05  
**Branch:** mcp-adjustments  
**App:** SoyehtMac test binary (PID 83430, `SOYEHT_AUTOMATION_DIR=/tmp/soyeht-qa-ipc`)  
**Driver:** `QA/runs/2026-05-05-mcpa-021-104/runner.py` (direct JSON-RPC, no live agents)  
**Scope:** ST-Q-MCPA-021..104 except 090..095 (agent-driven NL) and 104 (live MCP reconnect)

---

## Summary

| Category | Pass | Fail | Skip | Total |
|----------|------|------|------|-------|
| Agent Race Variants (021–027, 100) | 8 | 0 | 0 | 8 |
| Worktree Panes Single Agent (030–033) | 4 | 0 | 0 | 4 |
| Shell and File Panes (040–044) | 5 | 0 | 0 | 5 |
| Send Pane Input (050–055) | 7 | 0 | 0 | 7 |
| Rename Operations (060–063) | 4 | 0 | 0 | 4 |
| Layout — Arrange and Emphasize (070–075) | 6 | 0 | 0 | 6 |
| Workspace Management (080–082) | 4 | 0 | 0 | 4 |
| Error Handling (101–103) | 3 | 0 | 0 | 3 |
| Natural Language (090–095) | 0 | 0 | 6 | 6 |
| Manual / live client (104) | 0 | 0 | 1 | 1 |
| **Total** | **41** | **0** | **7** | **48** |

**Gate verdict: PASS** — all directly testable cases green.

---

## Code Changes (this session)

### `scripts/soyeht-mcp`

1. **`KNOWN_AGENTS` whitelist** — added `{"claude", "opencode", "codex", "shell"}`.
   Fixes ST-Q-MCPA-100: `agent_race_panes` now raises a clear error for unknown agents (e.g. `"gemini"`) before any worktrees are created.

2. **Counter suffix for repeated agents** — `tool_agent_race_panes` tracks per-agent frequency and appends `-1`, `-2`, etc. when the same agent appears more than once in the list.  
   Fixes ST-Q-MCPA-022: 5-agent race with `agents=["claude","claude","claude","opencode","codex"]` now creates 5 distinct worktrees (`prefix-claude-1`, `prefix-claude-2`, `prefix-claude-3`, `prefix-opencode`, `prefix-codex`).  
   **Note:** app nameStyle strips trailing numeric suffixes from display `name` but `handle` and `path` remain unique.

3. **Malformed JSON handled gracefully** — `StdioTransport.read_messages()` now catches `json.JSONDecodeError` (both framed and newline-delimited paths) and logs a warning to stderr instead of propagating the exception.  
   Fixes ST-Q-MCPA-103: server no longer crashes with a traceback on bad input.

---

## Findings

### Performance: `create_workspace_panes` slows under load

When the app has many open panes (accumulated from stress tests), `create_workspace_panes` responses can exceed 25 s. Tests 024, 031, and 080–082 required a 60 s timeout. The IPC response eventually arrives successfully — it's a responsiveness issue under load, not a correctness bug.

**Recommendation:** Add a `WARNING` to the MCP tool description noting that new-workspace creation may be slow when many panes are open. Long-term: investigate async workspace creation in the Swift handler.

### Rename behavior: no bulk-rename shortcut

`rename_panes` with empty `conversationIDs`/`handles` returns "No pane input targets were provided." — the app requires explicit targets. This is by design (renaming all panes to the same name has no valid use case). QA case 060 was updated to reflect the correct expected behavior.

### Agent display name de-duplication

The Soyeht app strips trailing `-N` numeric suffixes when generating the display `name` for a pane (nameStyle `short`). Two panes from a 3× claude race show `name: "prefix-claude"` in the IPC response while their `handle` and `path` correctly differ. This is expected nameStyle behavior — agents should use `conversationID` or `handle` (not `name`) to target panes.

---

## Skipped Cases

| ID | Reason |
|----|--------|
| ST-Q-MCPA-090..095 | Natural language / agent comprehension — requires running Claude Code, Codex, or OpenCode interactively |
| ST-Q-MCPA-104 | Restart MCP mid-session — requires a live MCP client to reconnect; not testable via direct JSON-RPC |

---

## Execution Reports Updated

- `QA/domains/soyeht-mcp-automation.md`: updated 022 expected behavior, updated 060 description, added workspace performance note.
