# RelayStream IpTunnel Network Extension boundary

## Deliberate ratchet crossing

This slice intentionally crosses the `MeshDataPlaneInertBoundaryTests` ratchet
that previously rejected any real `packetFlow`, `NETunnelProviderManager`,
`startVPNTunnel`, or tunnel settings surface. The ratchet was a security gate,
not dead code. Its replacement pins the authenticated activation and packet
boundaries described below and must receive a security review on the exact PR
head.

The requested security reviewer is Safia.

## Runtime path

1. The host receives an owner-signed `RelayStreamOfferContract` whose exact
   resource is `ip_tunnel`, expected path is `relay_stream`, audience is Group,
   and guest key, group, member, and claw match the claimed session.
2. Rust prepares the short-lived authentication bytes. The host app signs those
   exact bytes using the guest identity backed by the Secure Enclave.
3. The host saves only static NetworkExtension configuration. It passes the
   offer, prepared request, and signature in the in-memory
   `startVPNTunnel(options:)` call.
4. The extension revalidates the canonical offer, owner signature, guest
   binding, Group audience, resource, path, endpoint, target, authentication
   material, and lifetime.
5. `RelayStreamGuestFFI` dials the relay, establishes Noise, authenticates, and
   opens the `IpTunnel` resource. The authentication `TunnelAck` remains
   unchanged. Immediately after the Open acknowledgment, the client requires
   the IpTunnel-only `NetworkSettings` frame (`0x17`) on the ordered,
   Noise-authenticated stream.
6. The native client accepts that frame only within a bounded timeout and only
   when its MTU and session ID exactly match the authenticated acknowledgment.
   Missing, out-of-order, malformed, or mismatched settings fail before the
   interface is configured. A later duplicate is an unexpected tunnel frame
   and tears the session down.
7. The extension validates `mesh_ipv4 { addr, prefix_len, peer }`, applies the
   assigned address, and installs exactly the IPv4 pool CIDR as the included
   route. It never installs an IPv4 or IPv6 default route. It then starts a
   bidirectional packet pump. Both directions structurally validate IPv4/IPv6
   version, header length, packet length, and address-family metadata. PTY
   control frames fail closed.

## Key and persistence boundary

- The Network Extension has no Secure Enclave signing API and receives no
  private key.
- The prepared request and signature are ephemeral start options. They are not
  stored in `providerConfiguration`, UserDefaults, the App Group, the
  keychain, or files.
- The persistent provider configuration contains only a schema marker and the
  statement that start options are ephemeral.
- The extension accepts only the manager whose provider bundle identifier is
  exact for the host build (`Soyeht` or `Soyeht Dev`); it never selects the
  first unrelated VPN manager.
- Auth material is short-lived, bounded to at most five minutes remaining, and
  is revalidated inside the extension at start time.

## Positive activation gate

Merging this capability is not an activation decision. The first operation in
`RelayStreamIPTunnelController.activate(claimed:)` checks the dedicated
`SoyehtFeatureFlags.relayStreamIPTunnelActivationEnabled` gate and returns
before offer validation, signing, preference access, profile creation, or
tunnel start when it is off.

The shipped default is off. Only an allowlisted Soyeht Dev bundle with the
dedicated `-SoyehtRelayStreamIPTunnelE2E` launch argument can opt in; shipping
bundle identifiers cannot enable the gate with process arguments. The provider
also fails closed when launched without ephemeral start options.

Any technical PASS on this PR covers code safety only. It does not authorize
enabling the gate, adding a production caller, changing NetworkExtension
entitlements, merging, or activating the data plane. Those remain explicit
owner decisions and require review as activation changes.

## Current integration boundary

The host API is
`RelayStreamIPTunnelController.activate(claimed:)`. A development harness may
feed it a manually acquired and already authenticated
`ClaimedGroupRelayStreamOffer`; no unsigned debug deep link or persisted fixture
is introduced.

The native protocol source is reproducibly pinned to a commit on theyos main.
Vendoring and artifact provenance use coordinated `SOURCE_REV` values in two
independent scripts: `prepare-household-rs-source.sh` checks out the vendored
tree, while `build-relay-stream-guest-ffi-xcframework.sh` stamps its own copy
into `buildinfo.json` as `source_rev`. The pinned tree carries the post-Open
`NetworkSettings` frame, which derives its IPv4 assignment from the real VPN
pool with server-side route-scope validation, together with the strict
canonical-CBOR ingress that rejects a malformed or out-of-scope frame before
it reaches the tunnel. The iOS client independently revalidates the same
boundary.

This does not claim a deployed end-to-end product. That engine change must
still be deployed and physically validated; the product flow for
choosing a claw and inviting a person is a separate slice. Those integration
gates do not weaken the extension's fail-closed boundary.
