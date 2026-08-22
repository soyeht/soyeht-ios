# Soyeht Dev stable Accessibility identity — 2026-08-21

## Verdict

PASS. The previously installed Soyeht Dev was ad-hoc signed
(`TeamIdentifier=not set`) and therefore did not have a durable macOS TCC
identity. A freshly signed install registered a separate `Soyeht Dev` entry in
Accessibility. After the user enabled it, a second build from a fresh
DerivedData directory replaced the application and the permission remained
enabled.

## Evidence

| Check | Result |
| --- | --- |
| Installed bundle ID | `com.soyeht.mac.dev` |
| Signing identity | `Developer ID Application: Gilberto Filho (W7677A5BK2)` |
| Installed Team ID | `W7677A5BK2` |
| Deep/strict signature verification | PASS |
| Explicit launch | `--request-agent-visual-permissions` invoked the existing product permission flow |
| Accessibility inventory | Separate `Soyeht` and `Soyeht Dev` rows observed |
| User authorization | `Soyeht Dev` checkbox value `1` |
| Controller authorization | `AXIsProcessTrusted() == true` |
| Fresh signed rebuild/reinstall | PASS |
| Permission after replacement | `Soyeht Dev` checkbox remained `1` |
| Relaunch command line | Normal launch, without the permission argument |

The repeatable entry point is:

```sh
scripts/build-install-soyeht-dev --request-permissions
```

It discovers the ignored signing configuration from the primary checkout when
run from a worktree, builds in a fresh directory by default, rejects an empty
Team ID, verifies the bundle and signature before replacement, keeps the
previous app in a temporary backup, and launches the signed Dev identity.

## Automated verification

- Xcode Debug signed build: PASS (twice, using separate DerivedData).
- `AppCommandRoutingPresentationTests`: 29 passed.
- Shell syntax check for the installer: PASS.
- Installed signature and designated requirement: PASS.
