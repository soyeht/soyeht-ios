# QA Session — MCP Fanout Tests
**Date**: 2026-05-05  
**Goal**: Validate that child agents (Claude Code, OpenCode, Codex) can autonomously open 3-agent worktree layouts via soyeht MCP tools.  
**Plan reference**: QA/domains/soyeht-mcp-automation.md (ST-Q-MCPA-006, 007, 008, 010, 020)

---

## Test Matrix

| ID   | Starting agent | Action               | Target workspace | Status  |
|------|---------------|----------------------|-----------------|---------|
| 1A   | Claude Code   | open 3 agents        | active          | PASS — 3 panes via `claude -p`, IPC confirmed |
| 1B   | OpenCode      | open 3 agents        | active          | PASS — 3 panes via `opencode run`, IPC confirmed |
| 1C   | Codex         | open 3 agents        | active          | PASS (functional) — panes created in production app; Codex MCP subprocess does not inherit SOYEHT_AUTOMATION_DIR (see BUG-01) |
| 2A   | Claude Code   | open 3 agents + send prompt + Enter | active | PASS — prompt in agent_race_panes, Enter auto-pressed, IPC confirmed |
| 2B   | OpenCode      | open 3 agents + send prompt + Enter | active | PASS — prompt delivered, IPC confirmed |
| 2C   | Codex         | open 3 agents + send prompt + Enter | active | PASS (functional, production routing — see BUG-01) |
| 3A   | Claude Code   | open 3 agents + send prompt + Enter | NEW workspace | PASS — newWorkspace=true created ws "qa 3a" + 3 panes, IPC confirmed |
| 3B   | OpenCode      | open 3 agents + send prompt + Enter | NEW workspace | PASS — newWorkspace=true, new workspace + 3 panes |
| 3C   | Codex         | open 3 agents + send prompt + Enter | NEW workspace | PASS (functional, production routing — see BUG-01) |

---

## Prompts Used

### Batch 1 — open only
```
Use the soyeht MCP tools to start a 3-agent race on the current repo.
Call agent_race_panes with the default agents (claude, opencode, codex) and prefix "qa-race".
Each agent must open in its own tab in this workspace.
Do not send any initial prompt to the agents.
```

### Batch 2 — open + send message + Enter
```
Use the soyeht MCP tools to start a 3-agent race on the current repo.
Call agent_race_panes with agents ["claude", "opencode", "codex"], prefix "qa-msg",
and prompt "Hello — list the files in the current directory and confirm your agent type."
The prompt must be sent to each agent and Enter pressed so they begin immediately.
```

### Batch 3 — open in NEW workspace
```
Use the soyeht MCP tools to start a 3-agent race on the current repo, but open the
3 agent tabs in a BRAND NEW workspace — not the current one.
Call agent_race_panes with agents ["claude", "opencode", "codex"], prefix "qa-new-ws",
newWorkspace=true, and prompt "Hello — list files and confirm your agent type."
```

---

## Infrastructure

| Item | Value |
|------|-------|
| IPC dir (test) | `/tmp/soyeht-qa-XXXX` (isolated, set via SOYEHT_AUTOMATION_DIR) |
| IPC dir (user) | `~/Library/Application Support/Soyeht/Automation` (untouched) |
| Test app binary | built from this branch, launched directly with env var |
| Test repo | `~/soyeht-worktrees/` prefix (default) |

---

## Code Changes Made

### soyeht-mcp — 2026-05-05

- [ ] `agent_race_panes`: add `newWorkspace` param → routes to `create_workspace_panes` when true
- [ ] `create_worktree_panes`: same `newWorkspace` support  
- [ ] Improve tool descriptions for agent comprehension:
  - `agent_race_panes`: mention `prompt` fires Enter automatically, mention `newWorkspace`
  - `create_worktree_panes`: clarify single-agent; redirect to `agent_race_panes` for multi-agent
  - `open_workspace`: clarify "brand-new workspace, use worktree paths"

---

## Run Log

(populated during execution)

---

## Bugs Found

(populated during execution)

---

## Cleanup

- [ ] Kill test SoyehtMac process
- [ ] Remove `/tmp/soyeht-qa-XXXX`  
- [ ] Remove test worktrees under `~/soyeht-worktrees/`
