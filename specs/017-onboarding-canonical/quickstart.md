# Quickstart — Onboarding Canônico Soyeht (Dev Setup)

**Feature**: 017-onboarding-canonical
**Date**: 2026-05-09
**Audience**: Developers picking up implementation work for this feature.

## Prerequisites

- macOS 15+ on Apple Silicon (engine is Apple Silicon-only v1)
- Xcode 16+ (Swift 6 strict concurrency)
- Rust 1.75+ via `rustup`
- Tailscale CLI + account on the user-tagged dev tailnet
- An iPhone with iOS 18+ for hardware walkthrough
- A second Mac (or VM) for testing Caso A from a "fresh" state
- Apple Developer Account access (Developer ID for notarization, APNs key)

## Repo layout (cross-repo)

| Repo | Path | Role |
|---|---|---|
| `iSoyehtTerm` | this worktree | Swift apps (`Soyeht` iOS, `SoyehtMac` macOS) + `Packages/SoyehtCore` shared |
| `theyos` | separate clone | Rust engine + cross-repo contract mirror under `specs/004-onboarding/contracts/` |

## Worktree usage (this feature)

This feature lives in a worktree at `../soyeht-ios-onboarding` (branch `017-onboarding-canonical`). Main repo (`/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm`) stays on `main` for parallel work. **Always run feature-specific commands from the worktree path.**

```bash
cd /Users/macstudio/Documents/SwiftProjects/soyeht-ios-onboarding
git status      # confirms branch 017-onboarding-canonical
```

## Build cycle

### theyos engine

```bash
cd /path/to/theyos
cargo build --release --target aarch64-apple-darwin
# Output: target/aarch64-apple-darwin/release/server
```

### iSoyehtTerm Swift package + apps

```bash
cd /Users/macstudio/Documents/SwiftProjects/soyeht-ios-onboarding

# Run unit tests for shared package
swift test --package-path Packages/SoyehtCore

# Build iOS app
xcodebuild -project TerminalApp/Soyeht.xcodeproj \
  -scheme Soyeht \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  build

# Build macOS app (with engine bundled — see "Embedding engine" below)
xcodebuild -project TerminalApp/SoyehtMac.xcodeproj \
  -scheme SoyehtMac \
  -destination 'platform=macOS' \
  build
```

### Embedding the engine in Soyeht.app

Build phase script in SoyehtMac.xcodeproj (to be added in implementation):

```bash
# In Run Script phase named "Embed engine binary"
ENGINE_PATH="${SRCROOT}/../../theyos/target/aarch64-apple-darwin/release/server"
DEST="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Helpers"
mkdir -p "${DEST}"
cp "${ENGINE_PATH}" "${DEST}/soyeht-engine"
codesign --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
         --options=runtime --timestamp \
         "${DEST}/soyeht-engine"
```

`EnginePackager.swift` then copies from `Contents/Helpers/soyeht-engine` to `~/Library/Application Support/Soyeht/engine/` on first launch and registers via `SMAppService.agent`.

## Local dev flow (no install yet)

For UI development without going through the full LaunchAgent install:

```bash
# Terminal 1: run engine standalone
cd /path/to/theyos
THEYOS_DIR=~/.theyos-dev cargo run --release -- --transport tailscale

# Terminal 2: run SoyehtMac in Xcode with environment override
# Set SOYEHT_ENGINE_URL=http://127.0.0.1:8091 in Xcode scheme env vars
# App will skip the install flow and connect directly
```

For iOS, run in simulator with engine on host:

```bash
# In Xcode iOS scheme, set:
# SOYEHT_ENGINE_URL=http://<mac-tailscale-ip>:8091
# or use Network framework's Bonjour discovery (works in sim only when host engine publishes)
```

## Hardware walkthrough (validation)

Per spec Success Criteria SC-001 (Caso A ≤45s) and SC-002 (Caso B ≤4min), every PR closing one of the two P1 user stories MUST include a recorded walkthrough.

### Caso A — Mac primeiro

1. On a "fresh" Mac (or wipe via `POST /bootstrap/teardown` + `SMAppService.unregister()`)
2. Drag Soyeht.app to /Applications
3. Open Soyeht.app
4. Time from open → "primeiro morador iPhone confirmado" — record video, SC-001 measures elapsed time

### Caso B — iPhone primeiro

1. Fresh iPhone (uninstall Soyeht if previously installed)
2. Install via App Store TestFlight (or local build)
3. Open Soyeht
4. Carrossel → "Vamos começar" → "Tenho um Mac aqui" → AirDrop to Mac
5. Mac receives, installs, claims setup invitation, gets name from iPhone
6. Time from app open → "primeiro morador" — SC-002

## Implementing a screen (UX-driven workflow)

Per Caio's directive, Sprint 0 produces wireframes BEFORE code:

1. Add markdown wireframe to `specs/017-onboarding-canonical/wireframes/<scene-id>.md`
2. Get Caio's approval in chat (single round)
3. Then implement SwiftUI view + tests
4. Run accessibility snapshot tests
5. Hardware test on device (not just sim) for AirDrop / Bonjour-related scenes

## Cross-repo PR pairing

When iSoyehtTerm + theyos PRs are dependent (e.g., new `/bootstrap/initialize` shape), they MUST ship paired:

1. Open theyos PR first; reference iSoyehtTerm PR #X "blocks-on" in description
2. Open iSoyehtTerm PR; reference theyos PR #Y "blocks-on" in description
3. CI on both must pass
4. Merge theyos first (engine forward-compatible); merge iSoyehtTerm second
5. Verify hardware walkthrough on both

## Quick reference — useful commands

```bash
# Run RTL snapshot tests (FR-088)
xcodebuild test -project TerminalApp/Soyeht.xcodeproj \
  -scheme Soyeht -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -testPlan RTLAcceptance

# Generate Soyeht.dmg locally (for AirDrop testing)
./Scripts/build-dmg.sh   # to be added in implementation; see contracts/

# Verify engine binary is self-contained (no brew/system deps)
otool -L /path/to/server | grep -v '/usr/lib/\|/System/Library/' | wc -l
# Expected: 0
```

## Where to ask for help

- `@super-agente` (soyeht pane): cross-cutting backend or hard problem (per memory `reference_super_agente.md`)
- `@agente-backend` (soyeht pane): theyos engine work
- Caio (chat): UX/visual approval gates, vocabulário decisions, cross-platform alignment
