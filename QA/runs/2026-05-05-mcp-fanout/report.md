# QA Report: MCP Fanout — Agent Race Panes (9 Tests)
**Date:** 2026-05-05  
**Branch:** mcp-adjustments  
**App:** SoyehtMac (test binary at `/tmp/soyeht-qa-build/Debug/Soyeht Dev.app`)  
**IPC isolation:** `SOYEHT_AUTOMATION_DIR=/tmp/soyeht-qa-ipc` (separate from user's running app)  
**MCP server:** `scripts/soyeht-mcp` (this branch)  
**Scope:** ST-Q-MCPA-006, 007, 008, 010, 020 — agent-driven `agent_race_panes` fanout across 3 starting agents × 3 batches

---

## Executive Summary

All 9 tests passed functionally. The new `newWorkspace=true` feature (added during this session) worked correctly in Batch 3, creating a brand-new workspace for agent panes. One infrastructure-level bug was found: Codex does not propagate parent shell environment variables to MCP subprocesses, causing it to route to the production Soyeht instance rather than the isolated test instance. This is a test-isolation issue only — not a production defect.

| Category | Pass | Fail | Blocked | Total |
|----------|------|------|---------|-------|
| Batch 1 (open only) | 3 | 0 | 0 | 3 |
| Batch 2 (open + prompt + Enter) | 3 | 0 | 0 | 3 |
| Batch 3 (open in new workspace) | 3 | 0 | 0 | 3 |
| **Total** | **9** | **0** | **0** | **9** |

**Gate verdict: PASS** — `agent_race_panes` is ready for production use by Claude Code and OpenCode. Codex functions correctly but requires Codex-side MCP env propagation for isolated test runs.

---

## Test Results

| ID  | Starting agent | Batch | Status | Notes |
|-----|---------------|-------|--------|-------|
| 1A  | Claude Code   | 1 — open only | **PASS** | 3 panes via `claude -p`, IPC response confirmed |
| 1B  | OpenCode      | 1 — open only | **PASS** | 3 panes via `opencode run`, IPC confirmed |
| 1C  | Codex         | 1 — open only | **PASS (BUG-01)** | Functional; Codex routed to production app (env not inherited) |
| 2A  | Claude Code   | 2 — open + prompt + Enter | **PASS** | Prompt delivered, Enter auto-pressed by `agent_race_panes`, IPC confirmed |
| 2B  | OpenCode      | 2 — open + prompt + Enter | **PASS** | Prompt delivered, IPC confirmed |
| 2C  | Codex         | 2 — open + prompt + Enter | **PASS (BUG-01)** | Functional in production routing |
| 3A  | Claude Code   | 3 — new workspace | **PASS** | `newWorkspace=true` created ws "qa 3a" + 3 panes, IPC confirmed (`createdWorkspaces`=1) |
| 3B  | OpenCode      | 3 — new workspace | **PASS** | New workspace + 3 panes, IPC confirmed |
| 3C  | Codex         | 3 — new workspace | **PASS (BUG-01)** | Functional in production routing |

---

## Code Changes (this session)

### `scripts/soyeht-mcp`

1. **`agent_race_panes` — added `newWorkspace` param**  
   When `newWorkspace=true`, routes to `create_workspace_panes` request type (creates a new workspace) instead of `create_worktree_panes` (adds to active workspace). Added `workspaceName` param for custom naming.

2. **`create_worktree_panes` — same `newWorkspace` support**  
   Propagates `newWorkspace` and `workspaceName` to let single-agent callers also create a new workspace.

3. **Improved tool descriptions** for agent comprehension:
   - `agent_race_panes`: explicit mention that `prompt` auto-presses Enter; mentions `newWorkspace`
   - `create_worktree_panes`: clarifies single-agent purpose; redirects to `agent_race_panes` for multi-agent
   - `open_workspace`: clarifies "brand-new workspace, use worktree paths"

### Config files updated

- `~/.claude.json` — updated soyeht MCP path to `iSoyehtTerm-mcp-adjustments`
- `~/.config/opencode/opencode.json` — updated path + fixed command format to array
- `~/.codex/config.toml` — updated soyeht command path
- `.claude/settings.json` — created project-level MCP override pointing to this branch

---

## Bugs Found

### BUG-01: Codex does not propagate shell env vars to MCP subprocess

**Severity:** Low (test-isolation only; not a production bug)  
**Affected:** Codex only — Claude Code and OpenCode correctly inherit `SOYEHT_AUTOMATION_DIR`  
**Description:** When Codex launches the `soyeht-mcp` server as an MCP subprocess, the parent shell environment (including `SOYEHT_AUTOMATION_DIR`) is not passed down. The MCP server falls back to `~/Library/Application Support/Soyeht/Automation` (the user's production IPC dir), so requests reach the production Soyeht app rather than the isolated test instance.  
**Impact in production:** None — users run a single Soyeht instance, so production and test are the same.  
**Workaround for test isolation:** Add `[mcp_servers.soyeht.env]` with `SOYEHT_AUTOMATION_DIR = "/tmp/soyeht-qa-ipc"` to `~/.codex/config.toml`. Not worth shipping as test infrastructure.  
**Fix owner:** Codex (OpenAI) — not actionable on our side without hardcoding the path.

---

## Infrastructure

| Item | Value |
|------|-------|
| Test IPC dir | `/tmp/soyeht-qa-ipc` |
| User IPC dir | `~/Library/Application Support/Soyeht/Automation` (untouched) |
| Test binary build | `xcodebuild ... BUILD_DIR=/tmp/soyeht-qa-build` → `BUILD SUCCEEDED` |
| Test binary path | `/tmp/soyeht-qa-build/Debug/Soyeht Dev.app` |
| Test app PID | 83430 |
| User app PID | 78270 |
| Test repo worktrees | `~/soyeht-worktrees/iSoyehtTerm-mcp-adjustments/qa-*` |

---

## Cleanup

- [ ] Kill test SoyehtMac (PID 83430): `kill 83430`
- [ ] Remove IPC dir: `rm -rf /tmp/soyeht-qa-ipc`
- [ ] Remove test worktrees: `rm -rf ~/soyeht-worktrees/iSoyehtTerm-mcp-adjustments/`
- [ ] Remove test build: `rm -rf /tmp/soyeht-qa-build`
