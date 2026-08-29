# Manual Split Pane Universal Messaging E2E

Date: 2026-08-26

Result: **passed for the exercised Codex/OpenCode round trip, Claude receive path, and the physical mouse/draft collision scenario.**

## Terminology contract

- An **agent** is a named Soyeht pane identity, for example
  `[e2e-manual-codex]`, `[e2e-manual-claude]`, or
  `[e2e-manual-opencode]`.
- A **harness** is the CLI/application running inside an agent pane, for
  example Claude Code, Codex, OpenCode, Qwen Code, Antigravity, Pi, Droid,
  Kilo Code, Cursor, Copilot CLI, Grok, Kimi, Devin, or Qoder.
- Asking which agents are in a workspace must return the named panes. It must
  not return the harness catalog.
- Pane identity survives a harness or model change. Messaging authorization is
  consequently pane-bound, not catalog-bound.

This contract is also stated in `docs/agent-handoff-protocol.md` and in the
agent-facing `list_agents` tool description. A protocol regression test fixes
the wording.

## Build provenance

- Source commit: `766a9fbb3c342aaec281e7091c56940049a772e1`
- Base `origin/main`: `63321ff0a2d3893efc05d59717d7ff205ae37878`
- Installed bundle: `/Applications/Soyeht Dev.app`
- Bundle identifier: `com.soyeht.mac.dev`
- Sealed `SoyehtBuildGitCommit`: `766a9fbb3c342aaec281e7091c56940049a772e1`
- Developer ID team: `W7677A5BK2`
- Executable SHA-256:
  `00437fe247ccfbc5b26fe9ec3f557f0f4306273b0199030736cca199077e8117`

## Physical setup

The three participants were created through the ordinary product flow:

1. Split the pane using the Soyeht UI.
2. Keep the pane as an ordinary shell pane.
3. Change directory from the shell.
4. Type the harness command physically in the terminal.

| Agent pane | Conversation ID | Declared agent | Harness command |
| --- | --- | --- | --- |
| `[e2e-manual-codex]` | `782AD7B6-F790-417A-9EE5-D274D1C3CAAF` | `shell` | `codex --yolo` |
| `[e2e-manual-claude]` | `1248DAE7-3060-41DC-844E-30BA53DD783E` | `shell` | `claude` |
| `[e2e-manual-opencode]` | `9FC696EC-E856-4593-90D9-64309B7D958D` | `shell` | `opencode --auto` |

Workspace: `E2E Manual MCP`
(`2DE0237C-46AE-405B-8643-822E11465260`).

None of these panes was converted to the legacy special agent presentation.
Normal shell-pane mouse reporting and terminal behavior remained enabled.

## Agent-driven results

The human prompts used natural language. They did not name MCP functions or
tell the model which tool to call.

| Scenario | Result |
| --- | --- |
| Ask Codex which agents are in the workspace | Returned named pane identities rather than the harness catalog |
| OpenCode sends a token to Codex; Codex replies to OpenCode | Passed bidirectionally through `message_agent` |
| Codex sends a token to Claude Code | Envelope arrived in the Claude pane |
| Claude Code reply | Not exercised: the account reported its weekly usage limit, which is not a Soyeht delivery failure |
| Rename a live manual pane | Presence and `canReceiveMessage` remained valid |

This is evidence for the three installed harnesses exercised here, not a claim
that every possible harness has already passed physical E2E. Unknown harnesses
are no longer authorization-denied merely because they are absent from a
hard-coded catalog, but each MCP-capable harness still needs its own physical
compatibility row.

## Physical mouse and draft collision

This scenario specifically protects the user's normal Split-pane experience:

1. Physically click the OpenCode composer, generating terminal mouse reports.
2. Type `RASCUNHO-MOUSE-OK` without pressing Enter.
3. Physically select Codex and ask in natural language:
   `Envie uma mensagem para o agente e2e-manual-opencode dizendo TOKEN-MOUSE-DRAFT-FIX-OK. Nao crie nenhuma pane.`
4. Verify that the message is queued and that the visible draft is unchanged.
5. Click OpenCode again and delete the draft with 17 physical Backspaces.
6. Verify that the deferred envelope appears only after the draft is clear.

Observed result: **passed**. The draft was neither submitted nor spliced with
the incoming message. SGR/X10 terminal mouse reports did not create a phantom
draft gate.

Durable delivery evidence:

- Message ID: `A9EB51FA-7CE3-4247-AC89-3C228147B352`
- Body: `TOKEN-MOUSE-DRAFT-FIX-OK`
- Created: `2026-08-26T10:13:27-03:00`
- Delivery claimed: `2026-08-26T10:13:52-03:00`
- Terminal delivery completed: `2026-08-26T10:13:54-03:00`
- Persistent source:
  `~/Library/Application Support/SoyehtDev/workspaces.json`

The timestamps show persist-before-effect and a completed deferred terminal
delivery after the human draft was cleared.

## Automated verification

- Focused `AgentMessagingCoreTests`: 57 passed, 0 failed.
- Full Swift suite: 902 executed, 5 skipped, 0 failed.
- MCP protocol suite: 68 passed, 0 failed.
- Debug Xcode build: passed.
- Signed Dev build/install: passed; commit, Developer ID team, and executable
  digest were verified against the installed app.

## Scope and safety conclusions

- Ordinary Split panes remain ordinary panes; the feature does not opt them
  into the special mouse/keyboard behavior that caused the earlier UX damage.
- Messaging presence is process/pane-bound and survives manual harness launch,
  app restart heartbeat, pane rename, and absence of a stdio TTY on the MCP
  child process.
- Common messaging no longer depends on launch nonce or declared harness.
- Privileged role, topology, and communication-policy mutations remain behind
  their stronger authorization boundary.
- Human input is never replayed after automation. Delivery waits for a clear
  draft and preserves the existing persist-before-effect flow.
