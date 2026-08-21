# MCP 2.0 real-agent E2E — 2026-08-21

## Verdict

PASS. Three real parent agents interpreted natural-language instructions,
opened the requested child agent in the requested directory, exchanged a
durable round-trip through the new MCP contract, and observed the reply before
finishing. A fourth real-agent scenario held an MCP relay behind unfinished
user input and released it only after Enter. Every isolated test workspace was
removed automatically.

## Behavioral ring

| Parent → child | Observed child argv | Observed child cwd | MCP request | MCP reply | Focus |
| --- | --- | --- | --- | --- | --- |
| Codex → OpenCode | `/opt/homebrew/bin/opencode --auto` | `QA` | contract 2 / server 2.0.0 | contract 2 / server 2.0.0 | child inactive |
| OpenCode → Claude | `/Users/macstudio/.local/bin/claude` | `docs` | contract 2 / server 2.0.0 | contract 2 / server 2.0.0 | child inactive |
| Claude → Codex | `/opt/homebrew/bin/codex --yolo` | `TerminalApp` | contract 2 / server 2.0.0 | contract 2 / server 2.0.0 | child inactive |

Raw evidence: [agent-driven-e2e-1787320915.json](../agent-driven-e2e-1787320915.json).

## Real-agent typing collision

A focused OpenCode process (`opencode --auto`) received an unfinished input
without Enter. A real Codex process (`codex --yolo`) then sent it a message
through `soyeht-dev.message_agent`:

- before Enter, the relay token was absent from the recipient terminal and its
  durable `deferredTerminalDeliveredAt` field was `null`;
- after Enter, the relay appeared and received a delivery timestamp;
- OpenCode replied through MCP contract 2 / server 2.0.0;
- Codex observed that real reply before completing.

Soyeht's alternate-screen capture did not reliably expose the live editor
draft, so the acceptance oracle uses the accepted no-Enter input plus the
durable delivery state rather than trusting a transient screen redraw.

Raw evidence: [agent-driven-e2e-1787322999.json](../agent-driven-e2e-1787322999.json).

## Direct MCP 2.0 regression suite

`QA/scripts/soyeht_mcp2_e2e.py --agents codex,claude,opencode` passed all ten
check groups:

- global directory grouped with the caller's workspace first;
- custom roles and planner/executor/reviewer graph;
- semantic inbox stored and acknowledged without PTY bytes;
- deferred universal terminal delivery with bracket-safe references;
- unfinished human draft protected until Enter;
- pane and cross-workspace deny policies;
- undeclared graph edge denied;
- real Codex, Claude, and OpenCode process/flag observation;
- `close_workspace` regression with an irrelevant destination field;
- automatic cleanup of test workspaces.

## Defects exposed and fixed during the run

1. OpenCode initially inherited only the Release MCP entry. New agent startup
   now repairs the current build's integration before spawning the process.
2. A model could still choose the Release tool while controlling Dev. Dev now
   rejects collaboration mutations without MCP contract 2, and envelopes name
   `soyeht-dev.message_agent` explicitly.
3. `activate=false` could not attach a PTY in an inactive workspace. The app now
   temporarily renders the target and restores the original workspace.
4. Deferred Enter could mark a message delivered without submitting it in an
   enhanced-keyboard TUI. The terminal now borrows first-responder status only
   for the synchronous Return command and restores it immediately.

## Other verification

- MCP protocol unit tests: 48 passed.
- Focused Swift messaging/presentation tests: 47 passed.
- Xcode Debug build: passed.
- [Quick gate](../2026-08-21-codex-gate-quick/gate-report.md): PASS WITH FOLLOW-UPS
  (iOS, SwiftPM, and contract smoke passed; four existing assisted macOS checks
  remain manual).
