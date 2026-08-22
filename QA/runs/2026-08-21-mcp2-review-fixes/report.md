# MCP 2.0 independent-review fixes

This run addresses the four merge-blocking defects reported by the independent
review of PR #56. The changes were tested against the signed Soyeht Dev app,
not only against model metadata or source-code assertions.

## Corrected behavior

1. **Launch ownership survives app restart without visiting the workspace.**
   The per-launch nonce is persisted with its conversation and every live
   engine credential is restored into `PaneStatusTracker` during store
   bootstrap, before lazy workspace views are materialized. The runtime probe
   leaves the agent in an inactive workspace, restarts the app into a separate
   parking workspace, and authenticates the inactive agent without opening its
   tab. The local-engine resolver also reuses the sole persisted engine
   credential on loopback when a redundant repair-pair is rejected; it fails
   closed rather than guessing when multiple engine credentials exist.
2. **Batch acknowledgement is atomic with respect to pruning.** IDs are
   deduplicated and preflighted before mutation, the batch is applied once, and
   completed records are pruned once afterward. Retention age now starts at
   actual completion rather than creation, so acknowledging an old pending
   message does not immediately erase it.
3. **A second terminal submission cannot splice into replayed human input.** Deferred delivery
   no longer queues another envelope behind an active broker paste/Return
   transaction. Human bytes are replayed first, the draft gate observes them,
   and only a later submit/cancel can release the next relay or a complete
   `send_pane_input`. Mirrored group input is recorded only after a live
   terminal transport accepts it, so disconnected panes do not acquire phantom
   drafts.
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
- Swift package suite: **842 executed, 5 skipped, 0 failures**.
- Signed Debug app build/install: **passed**, Team ID `W7677A5BK2`.
- External-controller E2E with Codex, Claude, and OpenCode: **passed**; observed
  `codex --yolo`, `claude`, and `opencode --auto` in the requested directory.
- Security-boundary probe against the signed build recorded in
  `security.json`: **7/7 passed**,
  including cross-pane nonce rejection, complete-message enforcement, and
  launch ownership in an inactive workspace after app restart. The probe
  refuses to claim this result unless the tested panes are engine-owned and
  persistent. Raw evidence: `security.json`.
- Deterministic broker-queue collision: **passed in both producer paths**.
  Codex sent the first relay, Claude sent the second, OpenCode held a physical
  human draft, and the second relay remained undelivered until physical
  Return. A second phase mixed a durable relay with raw and complete
  `send_pane_input`: the complete submission stayed held behind the raw draft,
  raw Return released it, and the next relay drained only afterward. Raw
  evidence: `broker-queue.json`.
- Natural-language physical ring: Codex-to-OpenCode and OpenCode-to-Claude
  passed. Claude-to-Codex preserved the draft and correctly retained the relay,
  but the Accessibility harness's first synthetic Return did not submit the
  visible Codex draft within the timeout. This is recorded as a harness/focus
  failure, not a product pass. Raw evidence: `physical-ring.json`.

## Remaining follow-ups

The other independent-review observations were not silently folded into this
fix. They remain in `docs/mcp2-followups.md`, including manually launched agents
in shell panes, pause semantics, inbox visibility, terminal receipt semantics,
nonce storage at rest, concurrent workspace parking, total multi-pane creation
deadlines, installer rollback coverage, and broader CLI/IME coverage.
