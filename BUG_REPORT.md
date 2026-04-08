# Bug Report: Soyeht iOS Post-API Standardization QA

Date: 2026-04-08
App commit: 92089a5
Backend: <backend-host> (deployed with Phases 1-4), Mac Studio (old deploy, used for most tests via cache)

3 bugs found. Fix all 3. Do not change anything else.

---

## BUG-1 (P0): ATS blocks connections to non-local servers

### Symptom
iPhone cannot connect to servers reachable only via Tailscale VPN (e.g. `<host>.<tailnet>.ts.net` or `100.x.x.x` IPs). The QR pairing succeeds at the HTTP layer but subsequent API calls fail silently. This means any user whose server is only reachable via Tailscale (not on the same LAN) cannot use the app.

### Root Cause
`Info.plist` only has `NSAllowsLocalNetworking = true`, which covers `192.168.x.x`, `10.x.x.x`, `172.16-31.x.x`, and `localhost`. Tailscale IPs (`100.x.x.x`) and Tailscale hostnames (`*.ts.net`) are NOT considered "local network" by iOS ATS.

### Location
`~/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/Info.plist` lines 88-92:
```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

### Fix
Add `NSAllowsArbitraryLoads = true` to the ATS dictionary. This app connects to user-owned self-hosted servers on arbitrary hosts/ports — there is no fixed domain list to allowlist. The app already uses HTTPS when the server provides TLS.

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>
```

Note: The QA agent tried adding `NSAllowsArbitraryLoads` and it still failed. This suggests there may be a secondary issue — the iPhone might not be resolving Tailscale DNS (MagicDNS) or the Tailscale VPN tunnel isn't routing properly on the test device. The `NSAllowsArbitraryLoads` fix is still correct and necessary; the DNS/routing issue is device-specific and not a code bug.

### How to verify
1. Add `NSAllowsArbitraryLoads` to Info.plist
2. Build and install on iPhone
3. Ensure Tailscale is connected on iPhone (check Tailscale app shows "Connected")
4. Try pairing with <backend-host> via QR code or paste link
5. Instance list should load from <backend-host>

---

## BUG-2 (P2): Stopped instances disappear from instance list

### Symptom
After stopping an instance, it vanishes from the instance list. User cannot restart it from the UI — has to use the web admin or CLI. This blocks the stop→restart workflow entirely.

### Root Cause
**Backend**, not iOS. The mobile instances endpoint filters to only return `Active` instances.

### Location
`~/Documents/theyos/admin/rust/server-rs/src/handlers_mobile.rs` line 454:
```rust
.filter(|r| r.status == store_rs::InstanceStatus::Active)
```

### Fix
Change the filter to include `Stopped` status (and optionally `Provisioning`, `Error`). Exclude only `Deleted`.

```rust
.filter(|r| r.status != store_rs::InstanceStatus::Deleted)
```

Or if you want to be more selective (only active + stopped):
```rust
.filter(|r| matches!(r.status, store_rs::InstanceStatus::Active | store_rs::InstanceStatus::Stopped))
```

The iOS app already handles this correctly:
- `InstanceListView.swift` line 109: online instances are tappable (opens terminal)
- `InstanceListView.swift` line 121-123: offline instances show "start" (restart) button in context menu
- `InstanceListView.swift` line 303: online=green dot, offline=gray dot
- `InstanceListView.swift` line 332: offline instances render at 50% opacity

No iOS changes needed for this bug.

### How to verify
1. Apply the backend fix
2. Deploy to server (`soyeht build && soyeht test && sudo soyeht deploy`)
3. Stop an instance from the iOS app
4. Instance should remain in list with gray indicator and 50% opacity
5. Long-press stopped instance → context menu should show "start"
6. Tap "start" → instance should return to active

### Also update the test
Check if `server-rs/tests/handlers.rs` has a test for `handle_mobile_instances`. If so, add a test case:
- Create instance with Active status → appears in list
- Create instance with Stopped status → also appears in list
- Create instance with Deleted status → does NOT appear in list

---

## BUG-3 (P3): Rebuild not available in instance context menu

### Symptom
Long-pressing an instance shows stop/restart/delete but not rebuild. The `InstanceAction` enum has `.rebuild` defined (ClawModels.swift line 149), but the UI doesn't expose it.

### Root Cause
**iOS app** — `InstanceListView.swift` context menu (lines 113-130) only has buttons for stop, restart, and delete. No rebuild button.

### Location
`~/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/InstanceListView.swift` lines 113-130:
```swift
.contextMenu {
    if instance.isOnline {
        Button { Task { await performInstanceAction(instance, action: .stop) } } label: {
            Label("stop", systemImage: "stop.circle")
        }
        Button { Task { await performInstanceAction(instance, action: .restart) } } label: {
            Label("restart", systemImage: "arrow.clockwise.circle")
        }
    } else {
        Button { Task { await performInstanceAction(instance, action: .restart) } } label: {
            Label("start", systemImage: "play.circle")
        }
    }
    Divider()
    Button(role: .destructive) { confirmDelete = instance } label: {
        Label("delete", systemImage: "trash")
    }
}
```

### Fix
Add a rebuild button in the `isOnline` branch, after restart:

```swift
if instance.isOnline {
    Button { Task { await performInstanceAction(instance, action: .stop) } } label: {
        Label("stop", systemImage: "stop.circle")
    }
    Button { Task { await performInstanceAction(instance, action: .restart) } } label: {
        Label("restart", systemImage: "arrow.clockwise.circle")
    }
    Button { Task { await performInstanceAction(instance, action: .rebuild) } } label: {
        Label("rebuild", systemImage: "arrow.triangle.2.circlepath")
    }
} else {
    // ...
}
```

### How to verify
1. Build and install app
2. Long-press an online instance
3. Context menu should show: stop, restart, rebuild, (divider), delete
4. Tap rebuild → instance goes through provisioning, returns to active

---

## Fix Priority Order

1. **BUG-2** first (backend, 1 line change, unblocks stop/restart testing)
2. **BUG-3** second (iOS, 3 lines, quick)
3. **BUG-1** third (iOS, 1 line in plist + needs device-level Tailscale debugging)

After fixing BUG-2 + BUG-3, deploy backend to Mac Studio (`soyeht update` or manual build) and rebuild iOS app, then re-run the full QA suite.
