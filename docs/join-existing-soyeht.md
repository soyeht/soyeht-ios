# Join Existing Soyeht

PR-4 adds a Mac-initiated path for adding another Mac to an existing Soyeht.

The Mac only offers this path when `GET /bootstrap/status` reports engine
version `0.1.19` or newer and bootstrap state is `uninitialized` or
`ready_for_naming`. The feature gate is side-effect-free. The staging endpoint
`POST /bootstrap/pair-machine/local/stage` is never used as a probe because it
mints a new nonce and anchor secret and invalidates any previous QR.

Flow:

1. Welcome resolves the local engine as fresh and capable.
2. The user chooses `Join existing Soyeht`.
3. SoyehtMac calls `/bootstrap/pair-machine/local/stage` on loopback.
4. The daemon returns the canonical `soyeht://household/pair-machine?...` URI.
5. SoyehtMac renders that URI as QR and shows its TTL countdown.
6. A paired iPhone scans the QR from Add Server and approves the join.
7. SoyehtMac polls `/bootstrap/status` until the local engine reaches `ready`.

Transport policy:

- Try Tailscale first.
- If the daemon returns structured `no_transport_address` for Tailscale, retry
  once with LAN.
- Show the active transport in the UI.

If the QR expires, the user must generate a new QR. Regeneration is intentional:
each `/stage` call replaces the daemon's PairMachineWindow and invalidates the
previous code. Leaving the screen cancels local polling and any in-flight request
only; there is no v0.1.19 daemon endpoint to cancel the remote window early, so
the window lives until TTL or replacement.

This does not change guest image preparation. A joined Mac can still need the
separate guest-image setup before it can host Claws.
