# Relay Stream Dev Relay Status

This note records the current Dev E2E topology without storing real hostnames,
device identifiers, IP addresses, or account names.

## Current Dev Topology

- The canonical Dev relay candidate is the operator-controlled external machine
  at a separate network, referenced here only as `external-dev-relay`.
- Do not treat Pinggy/free tunnels as the durable Dev topology. They are useful
  only for short diagnostics when the external relay is unavailable.
- The observed working path is:

  `iPhone Dev on cellular -> external-dev-relay over public IPv6 -> Mac Dev`

- This is `relay_stream`/app-layer data path, not `nvpn` mesh. In the current
  audit, `nvpn` was not observed as a running process.

## 2026-07-01 E2E Result

- `relay_stream_public_relay` was built and run on `external-dev-relay`.
- Public IPv4 reachability for the relay port was not available.
- UPnP/IGD automatic port mapping was not available.
- Public IPv6 reachability for the relay port was available after opening the
  local firewall rule on the external relay host.
- Mac Dev was configured to use the external IPv6 relay endpoint.
- Mac Tailscale was turned off for the live marker tests, then restored after
  validation.
- iPhone Dev launched on the physical test phone and reached Mac Dev through
  the external relay.

Validated markers:

- `SOYEHT_E2E_RELAY_IPV6_OK`
- `SOYEHT_E2E_RELAY_RECONNECT_OK`

Both markers were observed with relay-stream/rendezvous/reverse-connect/claim
and PTY/terminal categories present, with no observed error, failure, or
rejection categories in the sanitized monitor.

## 2026-07-01 Remaining Test Sweep

Sanitized checks run after the live marker test:

- `friend-cli-rs relay_stream_`: 11/11 passed. Covers PTY payload, ClawSite
  payload, authenticated open, malformed offer bytes, expired offer, signer
  mismatch, wrong audience, and wrong expected path.
- `server-rs relay_stream`: 180/180 passed on rerun. The first broad run had
  one timeout in an end-to-end composition test; the exact test passed
  immediately in isolation and the full rerun passed cleanly.
- `server-rs rendezvous_stream`: passed. Covers duplicate role, token reuse,
  token expiry, garbage/oversized hello, idle/timeouts, splice behavior, Noise
  E2E, and abuse limits.
- `server-rs push`: passed. Covers APNs payload/dispatch/registration code
  paths.
- `server-rs claw_store`: passed. Covers Claw Store/file-browser related
  backend contracts.
- `server-rs replay` and `server-rs retry`: passed.
- `Native/RelayStreamGuestFFI`: 7/7 passed. Covers guest FFI connect/auth/open
  and data round trip.
- `Packages/SoyehtCore` relay/Nostr tests: 13/13 passed. Covers relay-stream
  offer canonical parity, Nostr claim submitter behavior, and NIP44 vectors.
- Physical iPhone `RelayStreamOpenControllerTests`: passed.
- Physical iPhone APNs/background coordinator tests: passed.
- Physical iPhone API/file-browser client tests: passed.

The APNs tests above prove app/client/server code paths and background
coordinator behavior. They are not the same as a field proof that Apple's APNs
delivered a silent push to a locked phone on cellular.

## Remaining Work Before Product-Level Claims

- Make the external relay host configuration persistent:
  - supervised `relay_stream_public_relay` service;
  - persistent firewall allow for the relay port;
  - explicit operator-owned configuration for the public IPv6 endpoint.
- Keep a clear product claim:
  - OK: terminal/PTY data path worked without Tailscale for the tested Dev
    route through the external relay.
  - Not OK: claiming `nvpn`/mesh VPN is active from this evidence.
- Not OK: claiming every feature is 100% covered until file/browser,
    push/background wake through Apple APNs, offline/retry, and adversarial
    relay checks are run in a live field matrix.
- For users without public IPv6 or a reachable external relay, a hosted fixed
  relay or explicit router/firewall setup is still required.
