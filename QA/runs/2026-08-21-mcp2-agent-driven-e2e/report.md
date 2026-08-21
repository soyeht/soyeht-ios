# MCP 2.0 real-agent E2E — 2026-08-21

> Methodology correction: the early runs in this historical report named MCP
> tools in prompts shown to the parent agents. They remain transport and draft-
> gate evidence, but they do not prove that an agent discovers the capability
> from an ordinary user request. The implementation-blind replacement runs and
> their complete prompts are documented in
> [MCP 2.0 natural-language agent E2E](../mcp2-natural-language-agent-e2e-2026-08-21.md).

## Verdict

PASS. Three real parent agents interpreted natural-language instructions,
opened the requested child agent in the requested directory, exchanged a
durable round-trip through MCP contract 2, and observed the reply before
finishing. The final post-review ring exercised Codex, OpenCode, and Claude as
both sender and recipient while exact UTF-8 human input (`café ação`) held the
relay. Physical Backspace, OpenCode `Ctrl+U`, and Claude `Ctrl+C` then discarded
the draft and released exactly one delivery. The installed, signed Soyeht Dev
app supplied a real prompt-delivery acknowledgement; no fixed sleep was used.
Every isolated test workspace was removed automatically.

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

## Abandoning a draft without Enter

The physical-input runner was extended with `--draft-release-action` and a
route filter. Each case first proved that the draft was visible and that an MCP
v2 relay was durable but not terminal-delivered. Valid user actions then
removed the draft without Return; the negative control intentionally did not.

| Physical action | Recipient | Result | Evidence |
| --- | --- | --- | --- |
| Backspace once per draft character | OpenCode | PASS — last Backspace released the queued relay | [run 1787329408](../agent-driven-e2e-1787329408.json) |
| Backspace once per draft character | Claude | PASS — last Backspace released the queued relay | [run 1787329408](../agent-driven-e2e-1787329408.json) |
| Backspace once per draft character | Codex | PASS — last Backspace released the queued relay | [run 1787329408](../agent-driven-e2e-1787329408.json) |
| `Ctrl+U` | Claude | PASS — cleared the draft and released the relay | [run 1787330292](../agent-driven-e2e-1787330292.json) |
| `Ctrl+U` | Codex | PASS — cleared the draft and released the relay | [run 1787330414](../agent-driven-e2e-1787330414.json) |
| `Ctrl+C` | OpenCode | PASS — cancelled the draft and released the relay | [run 1787330538](../agent-driven-e2e-1787330538.json) |
| `Ctrl+U` historical control | OpenCode | EXPECTED HOLD in the pre-hardening runner; retained as historical evidence | [run 1787330668](../agent-driven-e2e-1787330668.json) |

Every passing route delivered the queued envelope after the draft became
empty, received an MCP contract 2 / server 2.0.0 reply, and showed that reply in
the real sender transcript. The historical control is important: Soyeht did
not infer that a shortcut had cleared text and did not risk splicing the relay
into the still-visible draft.

### Post-review UTF-8 retest

The runner was hardened to paste exact UTF-8 through macOS Accessibility,
verify the exact window identifier before every event, and restore the user's
clipboard. These fresh runs supersede the old OpenCode `Ctrl+U` observation:

| Sender → recipient | Physical discard | Result | Evidence |
| --- | --- | --- | --- |
| Codex → OpenCode | Backspace over `café ação` | PASS — held before discard, delivered after | [Codex/OpenCode Backspace](../agent-driven-mcp2-codex-opencode-backspace-2026-08-21.json) |
| OpenCode → Claude | Backspace over `café ação` | PASS — held before discard, delivered after | [OpenCode/Claude Backspace](../agent-driven-mcp2-opencode-claude-backspace-2026-08-21.json) |
| Claude → Codex | Backspace over `café ação` | PASS — held before discard, delivered after | [Claude/Codex Backspace](../agent-driven-mcp2-claude-codex-backspace-2026-08-21.json) |
| Codex → OpenCode | `Ctrl+U` | PASS — draft cleared and exactly one relay delivered | [OpenCode Ctrl-U](../agent-driven-mcp2-codex-opencode-ctrl-u-negative-2026-08-21.json) |
| OpenCode → Claude | `Ctrl+C` | PASS — draft cancelled and exactly one relay delivered | [Claude Ctrl-C](../agent-driven-mcp2-opencode-claude-ctrl-c-2026-08-21.json) |

All five fresh reports observed real process argv and cwd, prompt ACK,
`relayAbsentBeforeRelease=true`, `relayObservedAfterRelease=true`, and MCP
contract 2 / server 2.0.0 in both request and reply. On the Claude → Codex
route, Claude accepted the typed follow-up but ignored the first automated
Return; the operator sent a second Return to the same verified Accessibility
window. The protected Codex draft and relay ordering remained correct. This is
recorded as harness/TUI focus instability, not hidden as a product pass.

## Post-review security boundary probes

The installed Dev app was probed while real Codex and OpenCode panes were live:

| Probe | Result |
| --- | --- |
| MCP v2 `send_pane_input` aimed at an agent pane | Rejected; caller is told to use `message_agent` so policy, inbox, and defer are enforced |
| Policy mutation claiming a live pane identity without its launch nonce | Rejected as unauthenticated; no policy changed |
| Sensitive policy mutation using MCP contract 1 | Rejected; Dev requires contract 2 |

These are behavioral probes against the signed app, in addition to the Swift
and protocol regression tests. Raw evidence:
[security boundary probes](../mcp2-security-boundary-probes-2026-08-21.json).

## Post-review implementation result

- User-owned communication policy and agent-requested restrictions are stored
  separately. Effective policy is deny-dominant, so an agent can restrict
  itself but cannot erase a UI block.
- Agent identity mutations require the pane's injected launch nonce. A caller
  cannot select another pane merely by declaring its handle or UUID.
- One or more panes can be authorized by the user as orchestration managers.
  Only those panes may change roles, templates, or active graph topology.
- Low-level pane input fails closed for agent targets; all inter-agent traffic
  passes through the durable inbox, policy evaluator, and draft gate.
- The draft state machine counts UTF-8 characters rather than bytes and fully
  consumes SS3 terminal sequences.
- Sensitive collaboration tools require MCP client contract 2 in Dev.
- Prompt delivery uses a real agent hook acknowledgement. Automation requests
  are processed concurrently so an awaiting creation request cannot block its
  own acknowledgement.
- The Python MCP now uses event-driven filesystem notifications, split IPC and
  catalog modules, an app-owned JSON launch catalog, bounded inbox retention,
  delivery claims, uncertain-delivery recovery, and idempotent retry IDs.

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

- MCP protocol unit tests: 52 passed.
- Focused Swift messaging/presentation tests: 47 passed.
- Swift draft-gate unit tests after Kitty CSI-u coverage: 22 passed.
- Full Swift package regression: 438 passed, 0 failed (current package graph).
- Xcode Debug build: passed.
- [Quick gate](../2026-08-21-codex-gate-quick/gate-report.md): PASS WITH FOLLOW-UPS
  (iOS, SwiftPM, and contract smoke passed; four existing assisted macOS checks
  remain manual).
