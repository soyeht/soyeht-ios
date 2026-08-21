# MCP 2.0 follow-ups

This backlog records issues intentionally kept outside the pre-PR
modularization pass. An entry here is not authorization to change behavior;
each item still needs a product decision or a focused validation.

## Validate before declaring MCP 2.0 complete

### Manually launched agents in shell panes

- Reproduce the dominant workflow: open a shell pane, type `codex`, `claude`,
  or `opencode`, then use `message_agent` in Soyeht Dev.
- Determine how a shell pane can be upgraded to an authenticated agent identity
  without trusting a self-declared process name.
- Verify that low-level `send_pane_input` cannot bypass policy, inbox, or draft
  protection after the upgrade.

## Messaging UX and safety

### Pauses in unfinished human input

- Test a focused user draft with pauses longer than the current 0.75-second
  grace period.
- Decide between adaptive grace, release only after an observed submit/cancel,
  or another explicit signal.

### Queued-message visibility

- Design a pane-header badge or equivalent indicator for durable messages that
  are waiting for the human draft to clear.
- Cover unread, deferred, blocked, and uncertain states without conflating
  read with acknowledged.

### Uncertain terminal delivery

- Document the current at-most-once contract: a claim without confirmed
  completion becomes `uncertain_not_replayed` and is never replayed
  automatically with the same message ID.
- Tell the sender explicitly that retrying the content requires a new message
  ID and may duplicate terminal-visible content.
- Product decision remains open between observable at-most-once and an
  alternative at-least-once policy with idempotency support.

## Compatibility matrix

- Expand real-agent E2E beyond Codex, Claude, and OpenCode to the remaining
  local catalog entries.
- Add mixed Soyeht Release/Soyeht Dev coexistence tests.
- Add CJK IME composition, decomposed combining characters, emoji, and ZWJ
  input to the physical draft-collision matrix.
- Add multiline paste/auto-submit and long-lived inbox-retention scenarios.

## Automation and orchestration

- Exercise orchestration-manager grant and revoke through the real UI, then
  verify accepted and rejected role/topology mutations from real agents.
- Specify and test active-graph behavior for panes not bound to a graph node.
- Test request ordering under concurrent IPC load. The current service scans
  request filenames, whose UUID ordering is not temporal FIFO.
- Exercise inbox pruning at the 500-message and 30-day boundaries in a
  behavioral test, not only unit tests.

## Threat model and inventory

- Document that the launch nonce is a possession credential within the current
  file-IPC model, not isolation from hostile processes running as the same
  macOS user. Socket peer authentication remains a future hardening option.
- Re-test app panes and moved/pre-existing panes across `list_panes`,
  `list_agents`, and `get_pane_status` lifecycle transitions.
