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
- Decide whether acknowledged deferred-terminal records that never obtain a
  delivery timestamp remain durable forever or receive a separate retention
  ceiling. The current completion-date policy deliberately does not prune
  them as ordinary completed messages.

### Terminal submission receipt

- `deferredTerminalDeliveredAt` currently means the paste and Return were
  dispatched to the local terminal transport; it does not prove that a TUI
  accepted the Return. Define a capability-specific receipt before treating
  terminal delivery as semantic acceptance.
- Add a recovery/diagnostic path for a Return swallowed by a TUI so a later
  relay cannot silently concatenate with the still-visible envelope.

### Inbox acknowledgement diagnostics

- Bound `ack_agent_messages.messageIDs` and report stale/unknown IDs per item.
  Batch acknowledgement is atomic today, so one ID pruned between list and ack
  rejects the entire retry without item-level detail.

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

### Independent PR review backlog

- Serialize or ownership-token workspace parking/restoration for concurrent
  pane creations so a late request cannot restore another request's workspace
  or override navigation the user performed meanwhile.
- Make `agent_race_panes` launch profiles/flags explicit in its public contract
  instead of silently inheriting `--yolo`/`--auto` with no per-pane escape.
- Preserve a top-level custom shell command when a nested pane specification
  selects `agent: shell`; the Python runtime currently normalizes the missing
  nested command to `""`, which then wins over the top-level command.
- Put a total deadline on multi-pane creation requests rather than multiplying
  the per-prompt 120-second timeout by pane count.
- Replace the remaining security source-grep guards with runtime or extracted
  pure-boundary tests where practical; source guards should cover wiring only.
- Make the Dev installer restore its previous signed bundle on every explicit
  post-install validation failure, not only failures that trigger `ERR`.
- Specify whether long multiline auto-submit can hold deferred delivery
  indefinitely, then add physical-input coverage.
- Route group voice input and `BrokerInjector` writes through the same draft
  admission contract as physical and mirrored keyboard input.
- Stabilize the Accessibility harness's physical Return on Codex. In the
  Claude-to-Codex route the draft and queued relay remained intact, but one
  synthetic Return intermittently failed to submit the visible Codex draft.

## Threat model and inventory

- Document that the launch nonce is a possession credential within the current
  file-IPC model, not isolation from hostile processes running as the same
  macOS user. Socket peer authentication remains a future hardening option.
- The persisted launch nonce is plaintext in the workspace snapshot. Decide
  whether it should move to Keychain/protected storage or be replaced with a
  verifier that does not persist the bearer credential; document backup and
  same-user-process exposure explicitly.
- Re-test app panes and moved/pre-existing panes across `list_panes`,
  `list_agents`, and `get_pane_status` lifecycle transitions.

## Verification harness debt

- Exercise all MCP-contract-v1-sensitive request types behaviorally; source
  greps remain wiring checks, not security proofs.
- Derive `promptVocabularyAudit` from the audit result instead of emitting a
  fixed `"passed"` literal.
- Decide whether vocabulary forms such as `MCP2`, `MCPs`, and `mcp_` should be
  rejected by the natural-language E2E prompt audit, then encode that rule.
- Stop rewriting `func` to `private func` inside the macOS source-test helper
  before assertions; compile the production access level or test an extracted
  boundary directly.
