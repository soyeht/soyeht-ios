# T046 — First-time-owner walkthrough (SC-006)

**Spec**: `specs/002-owner-device-pairing/spec.md` SC-006
**Goal**: prove a first-time owner reaches a live terminal *without* typing a
password, choosing a server, scanning anything, or touching any manual
configuration.

The QR is not the happy path any more. The phone finds the Mac on its own and
the person compares six words — the camera is a fallback, kept for a phone
that cannot see the Mac at all.

## Pre-flight

- [ ] Mac reset to zero with `QA/runbooks/T070-onboarding-neo-reset-to-zero.md`.
      No terminal commands during setup itself.
- [ ] iPhone Devs reset with the same runbook, then reinstalled. No
      `HouseholdSession` keychain residue.
- [ ] Tailscale on **both** devices. From `named_awaiting_pair` onward the
      engine only accepts pairing over loopback or the tailnet — Wi-Fi alone
      lets the phone *see* the Mac during M1–M3 and nothing more.
- [ ] Only one Soyeht is running on the Mac. A second install (production
      beside Dev) pushes its own claim at the fresh phone every few seconds,
      and the card shows whichever landed last.
- [ ] Stopwatch. SC-006 says "trivial"; we record the actual number so a
      regression shows up as a number.

## Procedure

1. Launch Soyeht on the Mac. Walk M1 → M2 → M3, naming the home.
2. Launch Soyeht on the iPhone. The first screen is **I1** — no QR scanner, no
   SSH login form, no server list, no password field.
3. Tap Get started, then answer I2. The phone starts looking.
4. When I4 appears, compare the six words with the Mac's M4. **Do not type
   anything and do not scan anything.**
5. Tap Connect this iPhone.
6. Stop the stopwatch when I5 appears ("<Mac> is yours.").
7. Tap Open a terminal, then New session. A shell opens on the Mac and the
   phone lands in it.

## Expected observations

| Observation | Pass criterion |
|---|---|
| No password prompt on iPhone | Required |
| No server-selection screen | Required |
| No manual address/port entry | Required |
| No QR scan on the happy path | Required |
| Six words identical on both screens | Required |
| The Mac reaches M6 with no click | Required |
| I5 shown to the first owner | Required — it used to be skipped for exactly this person |
| Total start-to-I5 time | Record actual |
| Terminal reached from New session | Required |
| `HouseholdSession` keychain present after | Required (next launch skips pairing) |

## Operator log

| Date | Operator | Time (s) | Pass? | Notes |
|------|----------|----------|-------|-------|
| | | | | |

## Failure-mode notes

- **Words differ between the screens.** A real failure. Both sides derive them
  from the same `(hh_pub, nonce)`; different words mean two producers.
- **"I couldn't connect this time" while the Mac reaches `ready`.** A real
  failure, and the interesting one: the engine accepted the pairing and the
  phone threw the session away. The guard that refused it is logged under
  `com.soyeht.core/household-pairing` as `pair.certInvalid guard=…`. Capture
  that line — it names which check failed.
- **The phone shows I4 for a Mac you did not set up.** Two Soyeht installs on
  one network. Tap "Not my Mac" and check which engines are answering.
- **The camera opens first.** An SC-006 failure: the launch root regressed.
  File an issue with the screenshot.
