# T058 — Same-LAN machine-join walkthrough (Story 1, SC-001)

**Spec**: `specs/003-machine-join/tasks.md` T058 + `spec.md` SC-001
**Goal**: prove the Bonjour-shortcut path on real hardware completes long-poll-arrival → confirmation → gossip-applied member in ≤15 s, with no operator interaction beyond the biometric tap.

## Pre-flight

- [ ] Mac Studio with `theyOS` running, paired with iPhone Devs as the household owner (T046 already passed).
- [ ] iPhone Devs running current Soyeht build, household home view visible.
- [ ] **Second machine** (any macOS / linux-nix / linux-other) on the same LAN with `theyos-cli` (or equivalent) able to issue a Bonjour-advertised join request.
- [ ] Both machines and the iPhone share the same broadcast domain (no isolated VLANs).
- [ ] Stopwatch + screen recorder on iPhone (Lock-screen → Control Center → Screen Recording).

## Procedure

1. On the **second machine**, run the Bonjour-shortcut join entry point. The exact command depends on theyOS's tooling — typical shape: `theyos household join --transport lan`. The candidate emits the join-request via Bonjour service discovery, which the founder Mac (Mac Studio) forwards to the iPhone via the owner-events long-poll.
2. **Start the stopwatch** the moment the candidate command emits.
3. Wait — within 15 s, the iPhone home view should surface a `JoinRequestConfirmationCard` with the candidate's hostname + 6-word BIP39 fingerprint.
4. Confirm the fingerprint matches what the candidate displays on its terminal (out-of-band check — operator reads both).
5. Tap **Confirm** → biometric prompt → tap to authenticate.
6. Card transitions to the success checkmark for ~600 ms, then dismisses.
7. Within another second the household home view shows the new member in the membership list.
8. **Stop the stopwatch** when the new member visibly appears.

## Expected observations

| Observation | Pass criterion |
|---|---|
| Card appears on iPhone | Within 15 s of step 1 (SC-001) |
| 6-word fingerprint matches candidate's terminal output | Required (SC-004 — also covered by `OperatorFingerprintTests`) |
| Single biometric prompt | Required (FR-013) |
| New member in household home list | Within total 15 s budget |
| **No** other dialogs / errors / retries | Required |

## Network capture (optional but recommended)

If you can capture the iPhone's outbound traffic during the run (e.g. via a Tailnet exit node, or RVI for USB-tethered captures), assert via inspection:
- Long-poll GET to `/api/v1/household/owner-events` with `?since=<cursor>`
- POST to `/api/v1/household/owner-events/<cursor>/approve`
- Gossip WebSocket frames on `/api/v1/household/gossip`
- **Zero requests** to per-member endpoints (FR-016 / SC-009)

`MachineJoinStory1IntegrationTests` already pins the traffic shape under stubs; this hardware capture closes the loop on whether the production transport behaves the same way.

## Operator log

| Date | Operator | Total time (s) | Card-visible time (s) | Pass? | Notes |
|------|----------|----------------|------------------------|-------|-------|
|      |          |                |                        |       |       |

## Failure-mode notes

- If the card never appears: check Bonjour traffic on the LAN (`dns-sd -B _soyeht-household._tcp` on a third device). If the founder Mac never picks up the candidate's advertisement, the failure is on theyOS's side, not the iPhone.
- If the card appears but biometric is rejected unexpectedly: capture the iPhone log (`xcrun devicectl device process log capture …`) and check for `OwnerIdentityKeyError.biometryLockout`. T060 may also surface the same issue.
- If the candidate appears in the home view but slower than 15 s: record the actual time and the bottleneck phase (long-poll arrival, biometric, approve POST, or gossip apply). The `phaseObserver` boundaries the runtime emits in `HouseholdMachineJoinRuntime.LifecyclePhase` give per-phase timing if you tail the device log.
