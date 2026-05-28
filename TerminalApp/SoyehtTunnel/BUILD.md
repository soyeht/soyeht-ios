# SoyehtTunnel — Network Extension target build steps

The Swift source + Info.plist + entitlements file in this directory are
ready, but **the Xcode project doesn't yet contain a target that
includes them**. The new target must be added in Xcode manually
because the `project.pbxproj` is risky to edit by hand.

## One-time Xcode setup (~5 minutes)

1. Open `TerminalApp/Soyeht.xcodeproj` in Xcode.
2. **File → New → Target…** → select **Network Extension** (under iOS
   → Application Extension) → Next.
3. Configure:
   - Product Name: `SoyehtTunnel`
   - Provider Type: **Packet Tunnel**
   - Language: Swift
   - Embed in Application: Soyeht
   - Bundle Identifier: `com.soyeht.SoyehtTerm.SoyehtTunnel` (or
     whatever your `Soyeht` bundle id is + `.SoyehtTunnel`).
4. **Delete the auto-generated `PacketTunnelProvider.swift`** Xcode put
   in the new group. Then **drag** the existing
   `TerminalApp/SoyehtTunnel/PacketTunnelProvider.swift` from Finder
   into the new target's group, **Copy items if needed = OFF** (we want
   the file to stay where it is).
5. Same for `Info.plist` (replace the auto-generated one) and
   `SoyehtTunnel.entitlements` (set `CODE_SIGN_ENTITLEMENTS` build
   setting to the path of this file).
6. In **Signing & Capabilities** for the new target, you should see
   "Network Extensions" already added. If not, click `+ Capability` →
   Network Extensions → tick `Packet Tunnel`.
7. Also add the same capability to the parent `Soyeht` app target
   (it needs the entitlement to call `NETunnelProviderManager`).
8. Link **SoyehtCore** to the new target: target's General tab →
   Frameworks and Libraries → `+` → SoyehtCore.

After step 8, build the `SoyehtTunnel` target — it should compile.

## Slice scope vs. production

What lands today: a scaffold that compiles, claims the tunnel "up"
state, decodes the credential from the host app, but discards all
packets (it's a stub).

What's missing for actual traffic flow:
- UniFFI Swift bindings against the `nostr-vpn-app-core` Rust crate.
- An XCFramework bundling the iOS arm64 + simulator targets.
- Replacement of the `startPacketLoopStub()` body with real reads
  + writes through the nvpn private mesh backend.

That's slice 9b, the next focused session.

## Triggering the tunnel from the host app

In the main app, after `ClawShareHTTPClient.performClaim(...)` returns:

```swift
let credentialCBOR = ClawShareCodec.encode(claimedSession.credential)
let proto = NETunnelProviderProtocol()
proto.providerBundleIdentifier = "com.soyeht.SoyehtTerm.SoyehtTunnel"
proto.serverAddress = "soyeht-mesh"  // cosmetic; required by iOS
proto.providerConfiguration = ["credential_cbor": credentialCBOR]

let manager = NETunnelProviderManager()
manager.protocolConfiguration = proto
manager.localizedDescription = "Soyeht claw access"
manager.isEnabled = true
try await manager.saveToPreferences()
try await manager.loadFromPreferences()  // required before startTunnel
try manager.connection.startVPNTunnel()
```

iOS prompts the user once to allow the VPN configuration — this is
expected. Subsequent starts go through without UI.
