# T060 — APNS-disabled walkthrough (FR-028 OFF, SC-015)

**Spec**: `specs/003-machine-join/tasks.md` T060 + `spec.md` SC-015 + FR-028
**Goal**: prove that with APNS push registration disabled (the user toggle in *Settings → Apple Push Service*), the iPhone still completes Story 1 + Story 2 in foreground via the Tailscale-routed long-poll alone, without any silent push tickle.

## Pre-flight

- [ ] T058 + T059 already passed (otherwise their failures contaminate this run).
- [ ] iPhone Devs running current Soyeht build, paired to a household.
- [ ] Mac Studio + a second machine on the LAN (for Story 1 leg) and a remote candidate on the Tailnet (for Story 2 leg).
- [ ] Toggle **Settings → Apple Push Service → OFF** on the iPhone.
- [ ] Confirm via device log that `APNSRegistrationCoordinator` deregistered: tail for `APNSRegistrationCoordinator.suspend()` log line.

## Procedure

### Story 1 leg (foreground long-poll only)

1. iPhone foregrounded on the household home view.
2. Trigger the LAN candidate's join exactly as in T058.
3. **Confirm card appears within 15 s** (SC-001).
4. Confirm + biometric + member appears.

### Story 2 leg (foreground long-poll + QR scan only)

1. iPhone foregrounded on the household home view.
2. QR-scan the remote candidate's `pair-machine` URL exactly as in T059.
3. **Confirm card appears within 0.4 s** (SC-017).
4. Confirm + biometric + member appears within 25 s total (SC-002).

### Background-suppression sanity check

1. Send the iPhone to the home screen (background it).
2. Trigger a third candidate's join from the LAN.
3. Wait 30 s **without** foregrounding the iPhone.
4. Bring the iPhone back to foreground.
5. Card should appear during the next foreground long-poll, **not** instantly. If a card appears during the background window itself, APNS was actually still registered → toggle did not take effect. File an issue.

## Expected observations

| Observation | Pass criterion |
|---|---|
| Settings → Apple Push Service toggle visible only with active household | Required (T044b gating) |
| Toggle persists across app restart | Required (per-household preference) |
| Story 1 foreground completes in ≤15 s with APNS off | SC-015 + SC-001 |
| Story 2 foreground completes in ≤25 s with APNS off | SC-015 + SC-002 |
| Background candidate request **not** delivered until foreground | Required — proves no silent push tickle is reaching the iPhone |
| Restoring the toggle to ON re-registers without app restart | Required (T044b) |

## Operator log

| Date | Operator | Story 1 time (s) | Story 2 time (s) | Background-defer worked? | Pass? | Notes |
|------|----------|------------------|-------------------|---------------------------|-------|-------|
|      |          |                  |                   |                           |       |       |

## Failure-mode notes

- If a card appears during the background window: APNS registration was not actually suspended. Inspect the iPhone log for `APNSOpaqueTickle` notifications — receiving any is a regression in `APNSRegistrationCoordinator.suspend()`.
- If foreground long-poll never delivers the card with APNS off: the iPhone may not be reaching the household endpoint over Tailscale (since the LAN broadcast wakeup is APNS-flagged in current architecture). Verify Tailscale connectivity.
- If toggling APNS back to ON requires an app restart: regression in T044b's `resume()` integration.
