# Dev-build isolation (macOS)

## Problem

The macOS app ships in two flavours from one project (`TerminalApp/SoyehtMac.xcodeproj`):

| | Shipping | Developer |
|---|---|---|
| Config | Release | Debug |
| App | `Soyeht.app` | `Soyeht Dev.app` |
| Bundle id | `com.soyeht.mac` | `com.soyeht.mac.dev` |

macOS already isolates anything keyed by bundle id (preferences, caches,
HTTPStorages, WebKit, Saved Application State). But the **engine and all of its
state** lived at fixed, literal paths shared by both builds:

- `~/Library/Application Support/Soyeht/` — engine binaries, **identity**,
  **household**, **VMs**, **snapshots**, **conversations**, all databases,
  bootstrap token, APNs key
- `~/.theyos`
- the single LaunchAgent `com.soyeht.engine` (one launchd job, fixed ports
  8892 admin / 8091 household)
- the pairing keychain service `com.soyeht.mac`
- `/tmp/soyeht-engine.log`, `/tmp/vmrunner-macos.sock`, `/tmp/theyos-sessions.db`

So running `Soyeht Dev.app` drove the **same engine, household, VMs, and
databases** as the real app — developer testing could corrupt real data, and
the two engines fought over the same launchd job and ports.

## Design — `SoyehtInstallProfile`

A single value type (`Packages/SoyehtCore/Sources/SoyehtCore/Install/SoyehtInstallProfile.swift`)
resolves every install-namespaced identifier from `Bundle.main.bundleIdentifier`.
The `.release` profile reproduces the historical constants **byte-for-byte**;
only `.dev` (bundle id ending in `.dev`) diverges:

| Field | Release | Dev |
|---|---|---|
| Application Support dir | `Soyeht` | `SoyehtDev` |
| dot dir | `~/.theyos` | `~/.theyos-dev` |
| LaunchAgent plist | `com.soyeht.engine.plist` | `com.soyeht.engine.dev.plist` |
| launchd label | `com.soyeht.engine` | `com.soyeht.engine.dev` |
| keychain service | `com.soyeht.mac` | `com.soyeht.mac.dev` |
| admin port | 8892 | 8902 |
| household/bootstrap port | 8091 | 8101 |
| engine log | `/tmp/soyeht-engine.log` | `/tmp/soyehtdev-engine.log` |
| vmrunner socket | `/tmp/vmrunner-macos.sock` (default) | `/tmp/soyehtdev-vmrunner-macos.sock` |
| session DB | `/tmp/theyos-sessions.db` (default) | `$SoyehtDev/theyos-sessions.db` |
| LLM proxy URL | `http://127.0.0.1:18900` (default) | `http://127.0.0.1:18901` |

The invariant — `dev` and `release` share **no** namespaced value — is enforced
by `SoyehtInstallProfileTests` in `SoyehtCoreTests`.

### How the engine is namespaced

The embedded engine is configured entirely by env vars in its LaunchAgent
plist's shell command, so **no theyos (Rust) change is required**. There are two
static plists; both are embedded in every build (`scripts/embed-engine.sh`), and
`SMAppServiceInstaller` registers only the one matching `SoyehtInstallProfile.current`.

The dev plist (`com.soyeht.engine.dev.plist`) sets `SOYEHT_DIR` to `SoyehtDev`
(which cascades to every `$SOYEHT_DIR`-derived path) and additionally overrides
the three env vars whose engine defaults are *shared* `/tmp` values the shipping
plist leaves unset: `THEYOS_HOUSEHOLD_PORT`, `THEYOS_VMRUNNER_SOCK`,
`THEYOS_SESSION_DB`, and `THEYOS_LLM_PROXY_URL` (the engine is a *client* to a
loopback LLM-proxy daemon; not bundled/spawned by the embedded macOS engine
today, so this is defense-in-depth). A drift guard (`EmbeddedEngineLaunchAgentTests`) asserts the
dev plist exports a **superset** of the shipping plist's env, so a future env var
added to one but not the other fails the build.

### Migrated call sites

`TheyOSEnvironment`, `AppSupportDirectory`, `EnginePackager`,
`SMAppServiceInstaller`, `PairingStore`, plus two correctness fixes:
`WelcomeRootView.ExistingSoyehtStopper` (only stop *this* build's engine) and
`ExistingSoyehtStateResetter` / `TheyOSUninstaller.isEmbeddedSoyehtEngineCommand`
(only reset/match *this* build's engine — a dev "reset" must never delete the
real household's databases). `TheyOSUninstallPlan` lists both namespaces so a
full uninstall is clean.

## Known limitation — Caddy ports

The engine's Caddy ports (`HTTP_PORT=8080`, `HTTPS_PORT=8443`,
`ADMIN_API_PORT=2019`) are hardcoded constants in `theyos/admin/rust/soyeht-rs/src/caddy_manager.rs`
(no env override). Caddy runs only when serving **public** claw sites. If the
dev and shipping engines both serve public sites at the same time, the
second-started Caddy fails to bind — this does **not** corrupt data and does not
affect the shipping app's normal operation. The dev plist already exports
`CADDY_HTTP_PORT=8090` / `CADDY_HTTPS_PORT=8453` for forward-compatibility; making
them effective requires a small theyos change (read those ports + the admin API
port from env) plus an engine rebuild + repin (see `docs/engine-version.md`).

## Validating

```sh
# unit: isolation invariant + plist drift guard + uninstall coverage
( cd Packages/SoyehtCore && swift test --filter SoyehtInstallProfileTests )
( cd TerminalApp/SoyehtMacTests && swift test --filter 'EmbeddedEngineLaunchAgentTests|TheyOSUninstallPlanTests' )

# build both flavours
cd TerminalApp
xcodebuild -project SoyehtMac.xcodeproj -scheme SoyehtMac -configuration Debug   -destination 'platform=macOS' build
THEYOS_BUILD_DIR=/tmp/theyos-engine-dist \
xcodebuild -project SoyehtMac.xcodeproj -scheme SoyehtMac -configuration Release -destination 'platform=macOS' build
```

Empirically verified: running the dev plist's engine command creates databases
under `SoyehtDev/`, binds dev ports 8902/8101, holds **zero** file handles under
the real `Soyeht/` dir, never binds 8892/8091, and leaves the real support dir's
file manifest byte-identical.
