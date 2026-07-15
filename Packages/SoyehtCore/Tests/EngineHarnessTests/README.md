# EngineHarnessTests

This target boots the pinned real `theyos-engine` and drives it through the
same SoyehtCore clients used by production. It is deliberately omitted from a
normal `swift test` run.

From `Packages/SoyehtCore`, run:

```sh
THEYOS_HARNESS=1 swift test --filter EngineHarness
```

That command intentionally compiles the target and skips it on a developer
machine. The real pinned engine is allowed to launch only when both
`THEYOS_HARNESS=1` and one of these second interlocks is present:

- `CI=true` for an isolated CI runner; or
- `THEYOS_HARNESS_ALLOW_LAN_BEACON=1` for a consciously supervised local run.

The extra local opt-in exists because the pin can emit setup/household Bonjour
beacons beyond loopback. Never set it casually on a machine with a live Soyeht
household. PR1.1 tracks removal of this interlock through engine capabilities.

The harness invokes the repository's `scripts/fetch-engine.sh` with its own
temporary `THEYOS_BUILD_DIR`; it never discovers or launches an installed
Soyeht engine. Each test gets a separate temporary state directory, software
keys, a loopback client URL, dynamically allocated free ports, and guaranteed
process-group cleanup (SIGTERM, bounded wait, then SIGKILL for the engine and
its owned IPC helpers).

The current flows are:

- `BootstrapStatusClient` plus `EngineCompat` startup handshake.
- `BootstrapInitializeClient.initialize` followed by the production
  `URLSessionHouseholdPairingHTTPClient` confirm call using a test-generated
  software P-256 owner key. A clearly test-only `QRScanSimulator` performs
  the `initiate` read between them, modelling the physical camera scanning the
  Mac's QR code.
- An authenticated `OwnerEventsLongPoll` handshake: real Soyeht-PoP header,
  canonical CBOR cursor, a two-second held request, then client cancellation
  rather than the engine's fixed 45-second empty-poll timeout.

The `QRScanSimulator` is intentionally not a production client. The current
Swift production surface has no `initiate` client; `initialize` is the real
production stage that opens the first-owner pairing window, while the test
double represents the physical QR scan. Record the missing Swift endpoint
client as Phase 2 contract input if a real product use case emerges.

## Known engine 0.1.21 limitations

The harness itself dials only `http://127.0.0.1:<ephemeral-port>`, but pinned
theyos 0.1.21 also binds eligible LAN/tailnet interfaces on that port. It has
no loopback-only bind override, so this is an explicit engine-side capability
gap for PR1.1—not a claim of fully hermetic network binding. The state,
credentials, binary source, and client traffic remain isolated as described
above.

The pin also cannot use port `0` as a single coherent listener port, so the
harness asks the OS for free loopback ports first and supplies the resulting
nonzero values to the engine. Its empty owner-events poll has no configurable
timeout, the first-owner flow emits no event to consume, and it has no switch
to disable setup/household Bonjour beacons.

PR1.1 owns these five pending hermeticity capabilities:

1. Loopback-only bind scope.
2. A usable single port-0 allocation.
3. Configurable owner-events poll timeout.
4. A test event emitter (or another safe trigger) for owner-events.
5. Disable switches for setup and household Bonjour beacons.
