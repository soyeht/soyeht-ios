# T046 — First-time-owner usability walkthrough (SC-006)

**Spec**: `specs/002-owner-device-pairing/spec.md` SC-006
**Goal**: prove a first-time owner pairs the iPhone to a fresh household *without* typing a password, choosing a server, or touching any manual configuration.

## Pre-flight

- [ ] Mac Studio with `theyOS` installed via the macOS app (no terminal commands during setup).
- [ ] iPhone Devs (UDID `00008110-001A48190231801E` per `reference_caio_devices.md`) running the current Soyeht build.
- [ ] iPhone is **factory-clean for Soyeht**: delete app, reinstall, no `HouseholdSession` keychain residue (`xcrun simctl keychain` is irrelevant — this is a real device).
- [ ] Both devices on the same Wi-Fi (Bonjour discovery requires same broadcast domain).
- [ ] Stopwatch ready — SC-006 implicitly says "trivial"; we record the actual scan-to-paired window so future regressions show.

## Procedure

1. Launch Soyeht on iPhone. Confirm the first screen is the QR scanner — no SSH login form, no manual server list, no password field.
2. On Mac Studio: open theyOS app → "Pair iPhone" → QR code displays.
3. Scan the QR with the iPhone camera viewport. **Do not type anything.**
4. Approve the biometric prompt.
5. Stop the stopwatch when the iPhone shows the household home view ("Casa Caio" or whatever the household name is).

## Expected observations

| Observation | Pass criterion |
|---|---|
| No password prompt on iPhone | Required |
| No server-selection screen | Required |
| No manual address/port entry | Required |
| Single biometric prompt | Required (FR-013) |
| Total scan-to-home time | Record actual; spec budget unspecified (subjective "trivial") |
| `HouseholdSession` keychain present after | Required (lifecycle restore on next launch should skip pairing) |

## Operator log

Fill in on first run. Append a row per repeat run.

| Date | Operator | Time (s) | Pass? | Notes |
|------|----------|----------|-------|-------|
|      |          |          |       |       |

## Failure-mode notes

- If the QR is unreadable in low light, that is **not** an SC-006 failure — record the lighting condition and retry.
- If the iPhone shows the SSH login form first instead of the scanner, that **is** an SC-006 failure (production wiring regression in `SSHLoginView`). File an issue with the screenshot.
