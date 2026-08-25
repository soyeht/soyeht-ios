# Manual Split Pane MCP E2E — 2026-08-24

## Verdict

**PASS.** Ordinary panes created through the visible Split controls can launch
Codex, Claude Code, and OpenCode, authenticate their runtime MCP identity, and
exchange agent messages without changing the pane's declared `shell` style.

## Tested build

- Git commit: `2918120ceb95b3a30002c4466bd40d457e520f59`
- Installed bundle: `/Applications/Soyeht Dev.app`
- Team ID: `W7677A5BK2`
- Binary SHA-256: `497bf08e169e780582018270410a192630a3b81648a811ec597a0d1acf25720c`
- Evidence: [evidence.json](evidence.json)

## Physical flow

1. Created a disposable workspace and three additional panes by pressing the
   visible Split button and the visible **Start bash session** action.
2. Typed the real commands through macOS Accessibility keyboard events:
   `codex --yolo`, `claude`, and `opencode --auto`, from this worktree.
3. Observed each real process and cwd without persisting its environment.
4. Confirmed all three directory entries remained `declaredAgent: shell`, had
   the expected authenticated runtime identity, and could receive messages.
5. Enabled and disabled Codex's orchestrator privilege using the visible pane
   header control; both persisted states were observed.
6. Asked in natural user language—without MCP or tool names—for the agents to
   communicate in the ring Codex → Claude → OpenCode → Codex. All three request
   and reply pairs were persisted with MCP contract 3.
7. With OpenCode idle, physically typed an unfinished draft. A Codex relay was
   retained as `deferredTerminal`; no terminal delivery occurred while the
   draft existed. After physical Backspaces removed the draft character by
   character, terminal delivery occurred and OpenCode replied.
8. Posted a real mouse click, scroll wheel, arrow keys, Tab, and Escape to the
   ordinary OpenCode pane. It remained declared as `shell` and its authenticated
   runtime stayed healthy. These are event-path smokes; subjective TUI behavior
   on every control remains appropriate for assisted/manual UX coverage.
9. Closed only the exact disposable workspace through the UI.

The collision scenario focuses the composer through pane chrome state rather
than clicking inside the TUI. This is intentional: ordinary shell panes retain
mouse reporting, so an in-terminal click is real TUI input that may move the
cursor or activate an action and must conservatively make draft state unknown.
Mouse and scroll are exercised separately in step 8.

## Automated regression results

| Gate | Result |
| --- | --- |
| `AgentMessagingCoreTests` | 58 passed, 0 failed |
| macOS domain Swift suite | 904 executed, 5 skipped, 0 failed |
| MCP protocol suite | 66 passed, 0 failed |
| iOS unit suite | 488 executed, 6 skipped, 0 failed |
| QA gate quick | PASS WITH FOLLOW-UPS |

The quick gate's remaining follow-ups are its standard assisted macOS checks
(Auth & Session, Tab Management, Local Shell, and Soyeht Terminal), listed in
[the generated gate report](../2026-08-24-codex-gate-quick-2/gate-report.md).
