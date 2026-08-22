# MCP 2.0 merge gate — PR #56

Date: 2026-08-22  
Platform: macOS, signed `/Applications/Soyeht Dev.app`  
Verified source commit: `556701d56413349c9c264da71e54d94a8daef128`  
App binary SHA-256: `ae5444b77fed6d27216eb1dd61d2a4e4b9db46ac1fd728078b24d20cc8d192ae`  
MCP bundle SHA-256: `1a709b98b7fa648379761141669db11a192eb86457dce440b7e67e2f99c6f6f9`  
Signing team: `W7677A5BK2`

## Outcome

**PASS — ready for independent code review.**

The final signed build passed the security boundary, natural-language
collaboration, physical unfinished-draft, and broker-queue scenarios. Every
behavioral runner required the installed app commit, binary digest, MCP bundle
digest, and Developer ID team before exercising the product. Cleanup used the
human-owned **Shell → Close Workspace** UI and verified disappearance from the
durable snapshot; no runner treated cleanup failure as a warning.

## Automated results

| Gate | Result | Evidence |
|---|---:|---|
| Swift domain suite | **895 executed, 5 skipped, 0 failed** | `swift test` in `TerminalApp/SoyehtMacTests` |
| MCP protocol suite | **64/64 passed** | `python3 -m unittest QA/scripts/test_soyeht_mcp_protocol.py` |
| Behavioral-harness unit tests | **4/4 passed** | `python3 -m unittest test_soyeht_agent_driven_e2e.py` in `QA/scripts` |
| macOS app build/install | **passed** | clean Developer ID build; embedded commit and post-install hashes verified |
| Security boundary probes | **15/15 passed** | [security-probes.json](security-probes.json) |
| Natural-language agent collaboration | **3/3 passed** | [natural-collaboration.json](natural-collaboration.json) |
| Physical Backspace collision ring | **3/3 passed** | [physical-backspace-ring.json](physical-backspace-ring.json) |
| Broker queue/draft arbitration | **passed** | [broker-queue.json](broker-queue.json) |

## Behavioral acceptance

### Natural user intent

The parent prompts name only the intended action: open a specific agent in a
specific directory, then talk to it. They do not name MCP servers, tools, or
function names. The runtime prompt audit rejects `message_agent`,
`open_agent_pane`, `send_pane_input`, `soyeht-dev`, and the standalone word
`mcp`.

The real process and working-directory oracle passed for all three routes:

- Codex opened OpenCode with `/opt/homebrew/bin/opencode --auto` in `QA`.
- OpenCode opened Claude in `docs`.
- Claude opened Codex with `/opt/homebrew/bin/codex --yolo` in `TerminalApp`.

Each child replied through the new MCP contract, each parent observed the
reply, and no child stole workspace focus.

### Human draft protection

The physical ring used macOS Accessibility keyboard events, not automation
input, against Codex, OpenCode, and Claude recipients. For every route:

1. the unfinished draft was visible in dynamic terminal capture;
2. the durable relay existed but had no terminal-delivery timestamp;
3. the relay token was absent from the TUI before release;
4. ordinary Backspace events erased the draft one character at a time; and
5. only then did the relay become terminal-delivered and visible.

The runner re-raises and verifies the exact AX window immediately before the
destructive key sequence. A failed focus check aborts without sending keys.

### Inbox versus terminal arbitration

An authenticated recipient ACK before terminal claim reclassifies that exact
message to `semanticInbox` and removes its pending PTY fallback. Once terminal
delivery has started, ACK cannot reclassify it. Role-control messages follow
the same exact-revision rule: an older semantic ACK cannot authorize a newer
role revision.

The broker scenario separately exercised the deterministic terminal path: two
relays targeted one OpenCode pane, the second remained queued while a human
draft was present, and was delivered only after the physical Return. This
prevents semantic-ACK success from being misreported as proof of terminal
queue release.

## Security probes

The 15 runtime probes covered legacy raw writes to agent panes, absent and
cross-pane launch nonces, a valid owner nonce, authenticated context access,
forbidden incomplete agent-message endings, old MCP contract rejection,
wrong Dev/Release profile rejection, and launch-ownership restoration for an
agent in an inactive workspace after app restart.

## Assisted/manual follow-ups

These are non-blocking for this gate and remain tracked in
`docs/mcp2-followups.md`:

- extend the real-agent ring beyond Codex, Claude, and OpenCode;
- test CJK IME, decomposed combining characters, emoji/ZWJ, multiline paste,
  and long pauses in unfinished drafts;
- exercise orchestration-manager grant/revoke and non-member graph semantics
  through the real UI;
- validate manually launched agents in shell panes and define an authenticated
  upgrade path;
- add visible queued/unread inbox status to pane chrome;
- replace remaining source-wiring greps with runtime boundary tests where
  practical.

No destructive external-resource tests were required. All temporary Soyeht
Dev workspaces created by this gate report `closed_via_ui` in their evidence.
