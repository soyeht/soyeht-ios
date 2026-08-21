# MCP 2.0 real-agent E2E — 2026-08-21

## Verdict

PASS. Three real parent agents interpreted natural-language instructions,
opened the requested child agent in the requested directory, exchanged a
durable round-trip through the new MCP contract, and observed the reply before
finishing. Two further three-route rings exercised every primary CLI as sender
and recipient while unfinished user input held the relay until Enter. The last
ring used actual macOS mouse and keyboard events against the signed Soyeht Dev
app, not MCP input injection. All nine routes passed and every isolated test
workspace was removed automatically.

## Behavioral ring

| Parent → child | Observed child argv | Observed child cwd | MCP request | MCP reply | Focus |
| --- | --- | --- | --- | --- | --- |
| Codex → OpenCode | `/opt/homebrew/bin/opencode --auto` | `QA` | contract 2 / server 2.0.0 | contract 2 / server 2.0.0 | child inactive |
| OpenCode → Claude | `/Users/macstudio/.local/bin/claude` | `docs` | contract 2 / server 2.0.0 | contract 2 / server 2.0.0 | child inactive |
| Claude → Codex | `/opt/homebrew/bin/codex --yolo` | `TerminalApp` | contract 2 / server 2.0.0 | contract 2 / server 2.0.0 | child inactive |

Raw evidence: [agent-driven-e2e-1787320915.json](../agent-driven-e2e-1787320915.json).

## Real-agent typing-collision ring

Each recipient was focused and accepted unfinished input without Enter. A
different real agent then sent it a message through
`soyeht-dev.message_agent`:

| Sender → recipient | Observed recipient argv | Before Enter | After Enter | Round trip |
| --- | --- | --- | --- | --- |
| Codex → OpenCode | `/opt/homebrew/bin/opencode --auto` | token absent; delivery timestamp `null` | token visible; delivery timestamp set | request + reply contract 2 / server 2.0.0 |
| OpenCode → Claude | `/Users/macstudio/.local/bin/claude` | token absent; delivery timestamp `null` | token visible; delivery timestamp set | request + reply contract 2 / server 2.0.0 |
| Claude → Codex | `/opt/homebrew/bin/codex --yolo` | token absent; delivery timestamp `null` | token visible; delivery timestamp set | request + reply contract 2 / server 2.0.0 |

In every route, the recipient replied through MCP v2 and the real sender
observed the reply before completing.

Soyeht's alternate-screen capture did not reliably expose the live editor
draft, so the acceptance oracle uses the accepted no-Enter input plus the
durable delivery state rather than trusting a transient screen redraw.

Raw evidence: [agent-driven-e2e-1787323903.json](../agent-driven-e2e-1787323903.json).

## Physical-keyboard typing-collision ring

After the user enabled Accessibility for the stable signed Soyeht Dev identity,
the same three sender/recipient routes were repeated with
`--physical-keyboard-only`. The runner raised the exact Soyeht Dev window by
its Accessibility identifier, clicked the recipient terminal with Quartz,
typed an unfinished draft with macOS Accessibility keystrokes, and submitted it
with a physical Return only after proving the incoming relay remained queued.

| Sender → recipient | Observed sender argv | Observed recipient argv / cwd | Before physical Return | After physical Return |
| --- | --- | --- | --- | --- |
| Codex → OpenCode | `/opt/homebrew/bin/codex --yolo` | `/opt/homebrew/bin/opencode --auto` / `QA` | draft visible; relay absent; delivery timestamp `null` | relay visible; timestamp set; MCP v2 reply observed |
| OpenCode → Claude | `/opt/homebrew/bin/opencode --auto` | `/Users/macstudio/.local/bin/claude` / `docs` | draft visible; relay absent; delivery timestamp `null` | relay visible; timestamp set; MCP v2 reply observed |
| Claude → Codex | `/Users/macstudio/.local/bin/claude` | `/opt/homebrew/bin/codex --yolo` / `TerminalApp` | draft visible; relay absent; delivery timestamp `null` | relay visible; timestamp set; MCP v2 reply observed |

All six observed processes also had the expected real cwd. Every request and
reply persisted MCP contract 2 / server 2.0.0, and every sender observed the
reply before completing.

Command:

```sh
python3 QA/scripts/soyeht_agent_driven_e2e.py \
  --automation-dir "$HOME/Library/Application Support/SoyehtDev/Automation" \
  --timeout 360 \
  --physical-keyboard-only
```

Raw evidence: [agent-driven-e2e-1787327670.json](../agent-driven-e2e-1787327670.json).

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
5. The first physical-input run exposed that OpenCode enables Kitty's enhanced
   keyboard protocol. Printable keys arrived as CSI-u packets, which the draft
   gate previously ignored, so a relay could interrupt visible human input.
   The gate now decodes Kitty printable, Return, Backspace, cancel, modifier,
   and release events while continuing to ignore non-text terminal reports.

## Other verification

- MCP protocol unit tests: 48 passed.
- Focused Swift messaging/presentation tests: 47 passed.
- Swift draft-gate unit tests after Kitty CSI-u coverage: 22 passed.
- Full Swift package regression: 818 passed, 5 skipped, 0 failed.
- Xcode Debug build: passed.
- [Quick gate](../2026-08-21-codex-gate-quick/gate-report.md): PASS WITH FOLLOW-UPS
  (iOS, SwiftPM, and contract smoke passed; four existing assisted macOS checks
  remain manual).
