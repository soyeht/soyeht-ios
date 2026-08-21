# MCP 2.0 independent-review fixes

This run addresses the four merge-blocking defects reported by the independent
review of PR #56. The changes were tested against the signed Soyeht Dev app,
not only against model metadata or source-code assertions.

## Corrected behavior

1. **Launch ownership survives app restart.** The per-launch nonce is persisted
   with its conversation, restored into `PaneStatusTracker`, and reused when a
   persistent engine pane reconnects. A runtime probe accepted the owning
   pane's nonce, rejected a different live pane's valid nonce, restarted the
   app, and accepted the original owner again after restoration.
2. **Batch acknowledgement is atomic with respect to pruning.** IDs are
   deduplicated and preflighted before mutation, the batch is applied once, and
   completed records are pruned once afterward. Retention age now starts at
   actual completion rather than creation, so acknowledging an old pending
   message does not immediately erase it.
3. **A second relay cannot splice into replayed human input.** Deferred delivery
   no longer queues another envelope behind an active broker paste/Return
   transaction. Human bytes are replayed first, the draft gate observes them,
   and only a later submit/cancel can release the next relay. Mirrored group
   input uses the same safety path.
4. **`message_agent` always submits a complete message.** Its public schema now
   accepts only `lineEnding=enter`, the Python server rejects raw/unsubmitted
   variants, and the app independently rejects them at the wire boundary.
5. **The obsolete controller E2E no longer impersonates agents.** It now tests
   directory grouping, exact process/argv launches, workspace close, and
   cleanup. Authenticated messaging/policy/role/graph checks remain in the
   real-agent runner and security probes, where the launched pane owns the
   nonce.

## Executed evidence

- Python MCP protocol suite: **56 passed**.
- Swift package suite: **840 executed, 5 skipped, 0 failures**.
- Signed Debug app build/install: **passed**, Team ID `W7677A5BK2`.
- External-controller E2E with Codex, Claude, and OpenCode: **passed**; observed
  `codex --yolo`, `claude`, and `opencode --auto` in the requested directory.
- Security-boundary probe against signed build `146f14ce`: **7/7 passed**,
  including cross-pane nonce rejection, complete-message enforcement, and
  launch ownership after app restart. Raw evidence: `security.json`.
- Deterministic broker-queue collision: **passed**. Codex sent the first relay,
  Claude sent the second, OpenCode held a physical human draft, and the second
  relay remained undelivered until physical Return. Raw evidence:
  `broker-queue.json`; the scenario also passed again after the final signed
  install.
- Natural-language physical ring: Codex-to-OpenCode and OpenCode-to-Claude
  passed. Claude-to-Codex preserved the draft and correctly retained the relay,
  but the Accessibility harness's first synthetic Return did not submit the
  visible Codex draft within the timeout. This is recorded as a harness/focus
  failure, not a product pass. Raw evidence: `physical-ring.json`.

## Remaining follow-ups

The other independent-review observations were not silently folded into this
fix. They remain in `docs/mcp2-followups.md`, including manually launched agents
in shell panes, pause semantics, inbox visibility, concurrent workspace
parking, total multi-pane creation deadlines, installer rollback coverage, and
broader CLI/IME coverage.
