# Even Pane MCP Layout CQA

**Date:** 2026-05-06 03:11 -03
**Worktree:** `/Users/macstudio/Documents/SwiftProjects/even-pane-auto-layout`
**Target:** macOS app (`Soyeht Dev.app`) built from this worktree

## Verdict

PASS.

MCP batch creation now persists a two-band layout for even pane counts. Validation used a real isolated macOS app launch with `SOYEHT_AUTOMATION_DIR` and `SOYEHT_WORKSPACE_STORE_URL` under `/private/tmp/soyeht-even-pane-layout-20260506`.

## Build And Automated Tests

| Check | Result | Evidence |
| --- | --- | --- |
| SwiftPM macOS tests | PASS | `swift test` in `TerminalApp/SoyehtMacTests`; 241 tests, 0 failures |
| macOS app build | PASS | `xcodebuild -project TerminalApp/SoyehtMac.xcodeproj -scheme SoyehtMac -configuration Debug build` |
| Isolated validation build | PASS | `xcodebuild -project TerminalApp/SoyehtMac.xcodeproj -scheme SoyehtMac -configuration Debug -derivedDataPath .build/soyeht-dev-validation build` |
| QA gate quick | PASS WITH FOLLOW-UPS | `QA/runs/2026-05-05-codex-gate-quick-2/gate-report.md` |

The first sandboxed QA gate attempt failed due environment sandboxing around simulator/caches; the re-run outside that restriction passed.

## MCP Operational Validation

The app was launched with:

```sh
SOYEHT_WORKSPACE_STORE_URL=/private/tmp/soyeht-even-pane-layout-20260506/workspaces.json \
SOYEHT_AUTOMATION_DIR=/private/tmp/soyeht-even-pane-layout-20260506/Automation \
'.build/soyeht-dev-validation/Build/Products/Debug/Soyeht Dev.app/Contents/MacOS/Soyeht Dev'
```

Screenshots were not captured; structural evidence came from the actual persisted `PaneNode` tree after MCP requests. The persisted layout uses `axis=horizontal` for visual top/bottom bands and `axis=vertical` inside each band for left-to-right columns.

| MCP Call | Expected | Structural Evidence | Result |
| --- | --- | --- | --- |
| `open_workspace` with 2 shell panes | 1 top, 1 bottom | `root_axis=horizontal ratio=0.5 rows=[1, 1] top=[@qa-even-2-1] bottom=[@qa-even-2-2]` | PASS |
| `open_workspace` with 4 shell panes | 2 top, 2 bottom | `root_axis=horizontal ratio=0.5 rows=[2, 2] top=[@qa-even-4-1,@qa-even-4-2] bottom=[@qa-even-4-3,@qa-even-4-4]` | PASS |
| `open_workspace` with 6 shell panes | 3 top, 3 bottom | `root_axis=horizontal ratio=0.5 rows=[3, 3] top=[@qa-even-6-1,@qa-even-6-2,@qa-even-6-3] bottom=[@qa-even-6-4,@qa-even-6-5,@qa-even-6-6]` | PASS |
| `open_workspace` with 8 shell panes | 4 top, 4 bottom | `root_axis=horizontal ratio=0.5 rows=[4, 4] top=[@qa-even-8-1,@qa-even-8-2,@qa-even-8-3,@qa-even-8-4] bottom=[@qa-even-8-5,@qa-even-8-6,@qa-even-8-7,@qa-even-8-8]` | PASS |

## Agent Path Validation

`create_worktree_panes` was run against pre-created dummy git worktree directories with `noCreate=true`, `newWorkspace=true`, and `command="/bin/sleep 120"` so the test exercised the MCP/app pane creation path without launching real agent CLIs.

| Agent | Expected | Structural Evidence | Result |
| --- | --- | --- | --- |
| Codex | 4 panes in 2x2 | `agents=[codex] rows=[2, 2] top=[@qa-agent-codex-a,@qa-agent-codex-b] bottom=[@qa-agent-codex-c,@qa-agent-codex-d]` | PASS |
| Claude Code | 4 panes in 2x2 | `agents=[claude] rows=[2, 2] top=[@qa-agent-claude-a,@qa-agent-claude-b] bottom=[@qa-agent-claude-c,@qa-agent-claude-d]` | PASS |
| OpenCode | 4 panes in 2x2 | `agents=[opencode] rows=[2, 2] top=[@qa-agent-opencode-a,@qa-agent-opencode-b] bottom=[@qa-agent-opencode-c,@qa-agent-opencode-d]` | PASS |
| Droid custom | 4 panes in 2x2 | `agents=[droid] rows=[2, 2] top=[@qa-agent-droid-a,@qa-agent-droid-b] bottom=[@qa-agent-droid-c,@qa-agent-droid-d]` | PASS as custom agent with explicit command |

Limitation: Droid/Droide is not a built-in `agent_race_panes` agent because `scripts/soyeht-mcp` currently whitelists `codex`, `claude`, `opencode`, and `shell`. It is extensible through `create_worktree_panes` as a custom agent when `command` is explicit.

## Cleanup

Closed all validation workspaces through MCP `close_workspace`.

Closed workspaces:

- `QA Even Layout 2`
- `QA Even Layout 4`
- `QA Even Layout 6`
- `QA Even Layout 8`
- `QA Agent Codex Layout`
- `QA Agent Claude Layout`
- `QA Agent OpenCode Layout`
- `QA Agent Droid Custom Layout`

Post-cleanup store evidence: only the isolated `Default` workspace remained and `conversation_count=0`. The isolated `Soyeht Dev` process and `/bin/sleep 120` processes were stopped.

## Residual Risk

The OpenCode and Droid custom validation requests completed successfully in the app, but the MCP client timed out at 15s/20s before reading the response file. Follow-up change: MCP and CLI batch creation defaults were raised to 60s for pane/workspace creation tools to avoid false negatives on slower multi-pane app creation.
