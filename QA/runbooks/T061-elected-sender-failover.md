# T061 — Elected-sender failover walkthrough (SC-016)

**Spec**: `specs/003-machine-join/tasks.md` T061 + `spec.md` SC-016 + theyos `docs/household-protocol.md` §13
**Goal**: prove that when the founding Mac is powered down mid-flow, a backup household machine takes over the APNS-sender role within 1 s and Story 1 still completes within the SC-001 budget.

> **Cross-repo gate.** The <1 s switchover is a property of theyos's leader-election protocol. The iPhone-side scaffolding is pinned in `MachineJoinFailoverIntegrationTests`; this walkthrough is the **only** end-to-end validation of the timing.

## Pre-flight

- [ ] **Two** household members already joined: the founder Mac (Mac) AND a backup Mac on the same LAN. Both must be eligible APNS senders per theyos §13. Confirm with `theyos household members list` (or whatever theyos's introspection command is).
- [ ] iPhone Devs paired to the household, foregrounded on home view.
- [ ] **Third candidate machine** ready to issue a Bonjour-shortcut join request (this is the Story 1 candidate whose join must complete across the swap).
- [ ] Stopwatch + screen recorder on iPhone.
- [ ] Physical access to the founder Mac's power button (or its UPS) — software shutdown is **too gentle** for this test; we want abrupt power loss to model real failure.

## Procedure

1. On the iPhone, ensure foreground. Tail the device log for `APNSOpaqueTickle` notifications and `OwnerEventsCoordinator` state transitions.
2. On the **third candidate**, queue the Bonjour-shortcut join command but **do not run it yet**.
3. **Yank the founder Mac's power** (pull the cable / hit the UPS kill switch / hold the power button for forced off). Note the wall-clock time.
4. Within 1–2 s, run the candidate's join command on the third machine. The candidate broadcasts via Bonjour; only the backup Mac is now alive to forward to the iPhone.
5. **Start the stopwatch** the moment the candidate command emits.
6. The iPhone should surface the confirmation card within the SC-001 15 s budget. If it does, the backup Mac took over inside the SC-016 budget.
7. Confirm + biometric + member appears.
8. **Stop the stopwatch.**

## Expected observations

| Observation | Pass criterion |
|---|---|
| iPhone receives APNS tickle from backup Mac | Within ~1 s of step 3 (theyos §13 + SC-016) |
| Confirmation card visible | Within 15 s of candidate emit (SC-001 still holds) |
| `OwnerEventsCoordinator` state | Foreground active throughout (no transition to `.failed`) |
| `OwnerEventsLongPoll` cursor | Preserved across the swap (visible in the device log) |
| Operator interaction needed | None — single biometric tap (FR-013) |

## Network capture (optional but recommended)

If you can capture iPhone outbound traffic during the run, assert:
- Long-poll connection drops once (when the founder Mac's TCP died).
- Long-poll re-establishes against a household-routed endpoint that's still alive.
- `since=<cursor>` query on the second long-poll matches the cursor at the time of the swap.
- The owner-event the iPhone consumes post-swap has `issuer_m_id` = backup Mac's `m_id`, **not** the founder.

The iPhone-side `MachineJoinFailoverIntegrationTests` already pins this property under stubs; this hardware run validates that the production transport behaves identically.

## Operator log

| Date | Operator | Power-down → tickle (s) | Power-down → member-visible (s) | Pass? | Notes |
|------|----------|--------------------------|-----------------------------------|-------|-------|
|      |          |                          |                                   |       |       |

## Failure-mode notes

- If the iPhone never receives the tickle: theyos leader-election is the suspect, not the iPhone. Capture the backup Mac's logs and inspect for §13 election state.
- If the iPhone receives the tickle but the long-poll never reconnects to the backup: the iPhone's outbound URL probably hard-routes to the founder's IP. Audit `ActiveHouseholdState.endpoint` resolution — it should be a household-routed name (Tailnet MagicDNS or theyos's load-balancer), not a fixed IP.
- If the candidate join completes but slower than 15 s: record the per-phase timings and decide whether the slowdown is in theyos election (>1 s) or in the iPhone re-poll (>0.5 s reconnect backoff). The `OwnerEventsLongPoll.Configuration` defaults are (initialReconnectBackoff: 1, maxReconnectBackoff: 60, multiplier: 2) — first reconnect is 1 s, so a single transport drop costs ~1 s of the SC-001 budget.
- **Power-cycling caveat**: re-run T061 a few times. APNS leader-election can race differently across power-down conditions (warm vs cold, network-layer vs application-layer drop). Three consistent passes is more informative than one.
