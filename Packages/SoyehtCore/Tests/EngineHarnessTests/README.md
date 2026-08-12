# EngineHarnessTests

This target boots the pinned real `theyos-engine` and drives it through the
same SoyehtCore clients used by production. It is deliberately omitted from a
normal `swift test` run.

From `Packages/SoyehtCore`, run:

```sh
THEYOS_HARNESS=1 swift test --filter EngineHarness
```

That command compiles the target. On a developer machine, the real-engine
flows skip explicitly unless both `THEYOS_HARNESS=1` and one of these second
interlocks is present:

- `CI=true` for an isolated CI runner; or
- `THEYOS_HARNESS_ALLOW_LAN_BEACON=1` for a consciously supervised local run.

The process-group lifecycle regression test is safe to run with only
`THEYOS_HARNESS=1`: it launches no engine, does no network I/O, and proves
that teardown kills an owned child and grandchild together. The extra local
opt-in exists because the pin can emit setup/household Bonjour beacons beyond
loopback. Never set it casually on a machine with a live Soyeht household, and
never set `CI=true` manually to bypass this interlock. PR1.1 tracks removal of
the interlock through engine capabilities.

The harness invokes the repository's `scripts/fetch-engine.sh` with its own
temporary `THEYOS_BUILD_DIR`; it never discovers or launches an installed
Soyeht engine. Each test gets a separate temporary state directory, software
keys, a loopback client URL, explicitly allocated nonzero loopback port
numbers, and process-group cleanup (SIGTERM, bounded wait, then SIGKILL for
the engine and its owned IPC helpers).

The current flows are:

- `BootstrapStatusClient` plus `EngineCompat` startup handshake.
- `BootstrapInitializeClient.initialize` followed by the production
  `URLSessionHouseholdPairingHTTPClient` confirm call using a test-generated
  software P-256 owner key. The pairing QR is consumed EXACTLY from
  `BootstrapInitializeResponse.pairQrUri` — the same boundary the iOS
  production onboarding uses (initialize → `URL(string:)` guard →
  `PairDeviceQR`).
- An authenticated `OwnerEventsLongPoll` handshake: real Soyeht-PoP header,
  canonical CBOR cursor, a two-second held request, then client cancellation
  rather than the engine's fixed 45-second empty-poll timeout.

Contract decision: the harness does NOT call
`POST /api/v1/household/pair-device/initiate`. No production flow in this
repository consumes that route (the product reads the URI from the initialize
response, or re-fetches it via `GET /bootstrap/pair-device-uri`), so the
harness models the surfaces the product actually exercises. The route's own
engine-side behaviour remains an engine-repo contract question; removing the
harness call does not adjudicate it. If a product flow ever adopts the route,
coverage returns as a new case.

The pinned engine omits `hh_pub` from `/bootstrap/status` while the state is
`named_awaiting_pair`. The harness asserts that the initialize response
contains a valid 33-byte household key, that the staged status omits it, and
that the scanned QR carries the exact initialize key. This makes the observed
contract explicit until an engine change intentionally revises it.

## Known pinned-engine limitations

The harness itself dials only `http://127.0.0.1:<allocated-nonzero-port>`, but the
pinned theyos engine also binds eligible LAN/tailnet interfaces on that port. It has
no loopback-only bind override, so this is an explicit engine-side capability
gap for PR1.1—not a claim of fully hermetic network binding. The state,
credentials, binary source, and client traffic remain isolated as described
above.

The pin also cannot use port `0` as a single coherent listener port, so the
harness asks the OS for distinct nonzero loopback port numbers before boot and
supplies them to the engine. This is not an atomic reservation and retains a
TOCTOU window; usable port `0` is the required engine-side capability. Its
empty owner-events poll has no configurable timeout, the first-owner flow
emits no event to consume, and it has no switch to disable setup/household
Bonjour beacons.

PR1.1 owns these five pending hermeticity capabilities:

1. Loopback-only bind scope.
2. A usable single port-0 allocation.
3. Configurable owner-events poll timeout.
4. A test event emitter (or another safe trigger) for owner-events.
5. Disable switches for setup and household Bonjour beacons.
