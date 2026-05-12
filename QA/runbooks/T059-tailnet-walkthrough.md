# T059 — Remote QR-over-Tailscale walkthrough (Story 2, SC-002)

**Spec**: `specs/003-machine-join/tasks.md` T059 + `spec.md` SC-002
**Goal**: prove the QR-over-Tailscale path on real hardware completes QR-scan → confirmation → gossip-applied member in ≤25 s when the candidate is **not on the same LAN** as the iPhone — only on the household Tailnet.

## Pre-flight

- [ ] Mac with `theyOS` running, paired with iPhone Devs.
- [ ] iPhone Devs running current Soyeht build with Tailscale active and authenticated to the household tailnet.
- [ ] **Remote candidate machine** (separate physical network — different ISP / coffee shop Wi-Fi / mobile hotspot is ideal) joined to the same Tailnet with theyos-cli installed.
- [ ] **Confirm Bonjour discovery is impossible** between iPhone and candidate (different broadcast domain).
- [ ] Generate a well-formed `pair-machine` URL on the candidate; in lab conditions you can use the QA generator to simulate:

  ```sh
  uv run --with cbor2 --with cryptography \
      QA/scripts/generate_pair_machine_url.py \
      --transport tailscale --addr <candidate-tailnet-name>:8443 \
      --hostname <candidate-hostname>
  ```

  In production use, theyos itself emits the QR — the script is for lab simulation when you want a deterministic candidate keypair (`--dump-key-pem` saves it).

- [ ] Encode the URL as a QR (`qrencode -o /tmp/qr.png "$URL"` or print it on the candidate's terminal).

## Procedure

1. On the iPhone household home view, tap the QR scanner entry point.
2. **Start the stopwatch.**
3. Frame the QR in the scanner viewport.
4. Card surfaces with the candidate's hostname + 6-word BIP39 fingerprint.
5. Out-of-band check: the candidate's terminal also shows the fingerprint — confirm both match.
6. Tap **Confirm** → biometric → success.
7. Wait for the new member to appear in the household membership list.
8. **Stop the stopwatch.**

## Expected observations

| Observation | Pass criterion |
|---|---|
| QR-scan to card-visible | <0.4 s p95 (SC-017 — also pinned in `JoinRequestConfirmationFluidityTests`) |
| Card hostname matches the URL `hostname` field | Required |
| Fingerprint matches candidate's terminal output | Required |
| Total scan-to-member-visible | ≤25 s (SC-002) |
| Card transition style | AirDrop-style scale-from-center (T036 — qrTailscale origin) |
| **No fallback to LAN path / Bonjour error** | Required (SC-002 distinguishes Story 2 from Story 1) |

## Network capture (optional but recommended)

If you capture iPhone traffic during the run, assert:
- POST to `/api/v1/household/join-request` (CBOR body, PoP-signed)
- POST to `/api/v1/household/owner-events/<cursor>/approve`
- Gossip WS frames
- **Zero** Bonjour-related traffic from the iPhone (since this is a Tailnet-only path)
- **Zero** requests to per-member endpoints (FR-016 / SC-009)

## Operator log

| Date | Operator | Total time (s) | Card-visible time (s) | Pass? | Notes |
|------|----------|----------------|------------------------|-------|-------|
|      |          |                |                        |       |       |

## Failure-mode notes

- If the QR scanner rejects the URL with `MachineJoinError.qrInvalid(.signatureInvalid)`: the URL was tampered or the QR encoder mangled bytes. Re-scan the same URL or regenerate.
- If the staging POST to `/api/v1/household/join-request` returns 4xx: the household identifier in the URL probably doesn't match the iPhone's active household. Confirm `activeHouseholdId` on the iPhone matches what the candidate signed.
- If the card appears but the `Confirm` POST never completes: the iPhone may not be on the household Tailnet. Confirm Tailscale reachability via `tailscale ping <founder-mac-tailnet>` on the iPhone (Tailscale iOS app diagnostics).
- If the new member appears slower than 25 s: capture the per-phase timing via `HouseholdMachineJoinRuntime.LifecyclePhase` boundaries in the device log.
