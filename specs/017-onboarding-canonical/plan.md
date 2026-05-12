# Implementation Plan: Onboarding Canônico Soyeht (iOS + macOS)

**Branch**: `017-onboarding-canonical` | **Date**: 2026-05-09 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/017-onboarding-canonical/spec.md`

## Summary

Single bet covering both onboarding entry paths (Caso A: Mac primeiro; Caso B: iPhone primeiro com proximidade Apple) com a tese aprovada **"O motor é invisível"**: o engine (binário Rust do `theyos`) é empacotado dentro do `Soyeht.app` distribuído via .dmg notarizado e instalado como **LaunchAgent per-user com zero sudo prompts**. iPhone-first usa AirDrop como caminho primário pra entregar o instalador no Mac, e publica um service Bonjour `_soyeht-setup._tcp.` na rede confiável (Tailscale-only) com token efêmero pra que o Mac descubra automaticamente o iPhone que iniciou o setup, dispensando QR scan visível ao usuário.

A casa é uma identidade **EC P-256 ECDSA Secure Enclave-native** (per Constitution v2.0.0) gerada localmente; capability certificates emitidas a partir dela controlam autorização. Onboarding entrega: carrossel iOS de 5 cards (já travado), telas Welcome Mac refatoradas, fluxo Caso B com AirDrop + setup-invitation, opt-in de telemetria embarcado no preview do install (default OFF), avatar visual emoji+cor derivado deterministicamente de `hh_pub` pra desambiguação multi-casa, e mensagem de recuperação cedo. Cobertura full Apple-grade de acessibilidade (VoiceOver, Dynamic Type AX5, Reduce Motion, WCAG AA, Voice Control, Increase Contrast, Reduce Transparency, RTL para ar/ur) em todos os 15 idiomas suportados pelo string catalog.

## Technical Context

**Language/Version**:
- Swift 6.0 strict concurrency (iOS app + macOS app + SoyehtCore Swift package)
- Rust 1.75+ (theyos engine, separate repo)

**Primary Dependencies**:
- **iOS app (`TerminalApp/Soyeht`)**: SwiftUI, Network framework (`NWBrowser`/`NWListener` for Bonjour), CryptoKit (`P256.Signing`, `P256.KeyAgreement`), UserNotifications (push handler), UIKit (`UIActivityViewController` for AirDrop bridging), AVFoundation (`AVCaptureSession` for QR fallback), Vision (`VNDetectBarcodesRequest`), LocalAuthentication (Face ID), MultipeerConnectivity (proximity discovery hint).
- **macOS app (`TerminalApp/SoyehtMac`)**: SwiftUI + AppKit interop, `SMAppService` (LaunchAgent registration, macOS 13+), Network framework, CryptoKit P256 with `kSecAttrTokenIDSecureEnclave`, Sparkle 2.x (auto-update), UserNotifications, ContinuityCamera (Vision-backed QR scan via Mac webcam).
- **Shared (`Packages/SoyehtCore`)**: Existing household types (`PairMachineQR`, `JoinRequestEnvelope`, `HouseholdCBOR`, `HouseholdPoPSigner`), to be extended with `BootstrapStatus`, `BootstrapInitialize`, `SetupInvitation` types and `BootstrapClient`/`SetupInvitationClient` networking shims.
- **Engine (`theyos/server-rs`)**: New `bootstrap` module with state machine, `_soyeht-setup._tcp.` mDNS-SD publisher/browser, `claim-setup-invitation` HTTP handler. P-256 keypair generation via `p256` crate, key persistence via `keyring-rs` (Linux) and via `Security.framework` (macOS, when running embedded). Cross-repo contract docs frozen in `theyos/specs/004-onboarding/contracts/`.

**Storage**:
- iOS: Keychain (`kSecAttrTokenIDSecureEnclave` for P-256 device keys, `kSecAccessControlBiometryCurrentSet` ACL); `@AppStorage` for `hasSeenWelcomeTour` flag and telemetry opt-in; SQLite (existing) for app cache.
- macOS: Keychain SE-bound for `hh_priv` and `D_priv`; engine writes household state to `~/Library/Application Support/Soyeht/state/` (sled or sqlite per existing theyos pattern).
- Engine: existing theyos persistence layer (no new schemas required beyond bootstrap state row).

**Testing**:
- Swift: XCTest for non-async; `swift-testing` for new modules. Bootstrap state machine via async tests with synthetic transports. Snapshot tests for accessibility (VoiceOver labels) and RTL rendering.
- Rust: `cargo test` for state machine + bootstrap endpoints; `cargo nextest` for integration; mock mDNS publisher for setup-invitation tests.
- Hardware walkthrough: Caso A (Mac fresh + iPhone fresh) and Caso B (iPhone-first + AirDrop) on real devices, recorded as Story-3 spec test fixtures.

**Target Platform**:
- iOS 18.0+ (`Soyeht.app`), iPhone-only initial (iPad later)
- macOS 15.0+ Sequoia, Apple Silicon-only v1
- theyos engine: Mac (embedded, this delivery) + Linux (parallel theyos work, NixOS/standalone)

**Project Type**: Mobile + API (cross-repo). Two Swift apps in `iSoyehtTerm` (this repo) + Rust engine in `theyos` (separate repo) sharing wire protocol via CBOR contracts.

**Performance Goals**:
- Caso A: ≤45s drag-to-Applications → "primeiro morador confirmado" (SC-001)
- Caso B: ≤4min including ~50–80MB download (SC-002)
- Carrossel: 60fps animation, <16ms frame budget per card transition
- Bonjour discovery: ≤3s from Mac install completion to iPhone setup-invitation pickup
- P-256 keypair generation in SE: ≤300ms with biometry gate

**Constraints**:
- Zero sudo prompts during install (FR-012)
- Zero PII in telemetry; opt-in default OFF (FR-070, FR-073)
- Zero strings hardcoded; all via `LocalizedStringResource` (FR-006)
- WCAG AA contrast minimum (FR-083)
- ≥44pt touch targets iOS (FR-087)
- Apple Silicon-only Mac v1 (Assumption)
- Tailscale-only autodiscovery; LAN bruta opt-in (FR-040, FR-041)

**Scale/Scope**:
- Single-house operator-only this delivery; ≤2 devices (Mac + iPhone)
- 5 user stories (US1+US2 P1, US3+US4 P2, US5 P3) with ~25 acceptance scenarios
- 88 functional requirements (FR-001 to FR-088)
- 15 locales × 2 platforms × ~80 strings ≈ 2400 string variants for localization audit

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### I. Apple-Grade Quality (NON-NEGOTIABLE) — PASS

- Zero SPOF: house identity is local; no central control plane.
- Zero manual ops: drag-to-Applications + auto-LaunchAgent registration; zero sudo prompts.
- Automatic discovery: Tailnet Bonjour browser auto-detects house from iPhone; setup-invitation auto-detected by Mac post-install.
- Automatic failover: AirDrop primary path with graceful fallback to URL+QR; Bonjour discovery with retry.
- UX hides infrastructure: vocabulário banido (FR-001/002) elimina exposição de daemon/server/theyOS.
- "Apple-grade" preferida sobre "good enough": LaunchAgent (não sudo daemon), SMAppService (não SMJobBless legacy), AirDrop (não cloud relay), avatar visual derivado de identidade (não strings cruas).

### II. Capability-Based Authorization (NON-NEGOTIABLE) — PASS

- House root identity is `hh_priv`/`hh_pub` (P-256 ECDSA SE-native), not a role.
- Operator capability flows from ownership of `hh_priv`; no `admin`/`user` enum introduced.
- Bootstrap initialize MUST require local possession of the just-created `hh_priv` for any subsequent state-changing op.
- Setup invitation token (Caso B) is an ephemeral capability with TTL ≤1 hour, single-use, bound to the iPhone's transient Bonjour service publication.
- Pareamento iPhone↔Mac uses proof-of-possession (PoP request signing, existing `HouseholdPoPSigner` pattern from PR #75).

### III. Local-First Identity & State — PASS

- House identity, members, and replicated state live on Mac and iPhone only.
- Telemetry endpoint (Cloudflare Worker `telemetry.soyeht.com`) is opt-in (default OFF, FR-073), receives only enumerated anonymous events (FR-071), and never participates in control-plane decisions.
- Discovery: Tailscale (Tailnet, wide-area + LAN tunnel) and Bonjour/mDNS on Tailnet interface only (Q3 clarification). LAN bruta is per-network opt-in.
- No third-party identity directory; no Apple ID linkage required for house operation (Apple ID only used opportunistically by AirDrop transport, not as identity).

### IV. Adoption-First, No Legacy Compatibility — PASS

- `WelcomeRootView` 3 modos (`localInstall`/`localReuse`/`remoteConnect`) are REPLACED by new state machine (`bootstrap`/`autoJoin`/`recover`) in same change set; no parallel paths.
- `remoteConnect` (paste manual de endereço) deixa de ser top-level; vira "Mais opções → Conectar manualmente" como degraded fallback, NOT as a sustained alternative architecture.
- iSoyehtTerm changes (carrossel, "onde instalar?", AirDrop flow, setup-invitation client) ship together; no behind-feature-flag rollout.
- Cross-repo: theyos contracts frozen as a batch in PR pareados com iSoyehtTerm — both repos land working e2e in same migration phase.

### V. Specification-Driven Development — PASS

- Spec-kit cycle in progress: ✓ specify → ✓ clarify → **plan (this artifact)** → tasks → analyze → implement.
- Plan closes every decision: contracts frozen in `theyos/specs/004-onboarding/contracts/`, no "we could do A or B" left open. Rejected alternatives recorded in research.md.
- Cross-repo contract: bootstrap endpoints + setup-invitation Bonjour TXT shape published in theyos before iSoyehtTerm starts integration.
- All code-facing artifacts (PR titles, commits, comments) in English (memory `feedback_code_artifacts_in_english.md`).

### Engineering Standards Check — PASS

- Apple API rigor: `SMAppService.agent` (não SMJobBless), `NWBrowser`/`NWListener` (não CFNetService), `LocalizedStringResource` (não Text("literal")), `kSecAttrTokenIDSecureEnclave` for hardware-bound keys.
- Crypto: P-256 ECDSA + ECDH SE-native (constitution mandate), 33-byte SEC1 compressed pubkeys, 64-byte raw `r||s` sigs.
- No `try?` swallow at protocol boundaries (replicate existing pattern from `JoinRequestStagingClient`).
- Localization: every UI string via `LocalizedStringResource` with `defaultValue:` and `comment:`; interpolated strings via `LocalizedStringResource(key, defaultValue:, comment:)`.
- Tests required at protocol boundaries: bootstrap state transitions, P-256 keypair gen, setup-invitation TXT decode, AirDrop activity item provider, avatar derivation determinism.

**Result**: All gates PASS. No Complexity Tracking entries required.

## Project Structure

### Documentation (this feature)

```text
specs/017-onboarding-canonical/
├── plan.md              # This file
├── research.md          # Phase 0 output (resolves NEEDS CLARIFICATION + tech choices)
├── data-model.md        # Phase 1 output (entities, relationships, state transitions)
├── quickstart.md        # Phase 1 output (dev setup walkthrough for both repos)
├── contracts/           # Phase 1 output (cross-repo wire contracts)
│   ├── bootstrap-status.md
│   ├── bootstrap-initialize.md
│   ├── bootstrap-teardown.md
│   ├── setup-invitation.md
│   ├── claim-setup-invitation.md
│   └── anchor-handoff.md
├── checklists/
│   └── requirements.md  # Already present from /speckit-specify
└── tasks.md             # Phase 2 output (/speckit-tasks)
```

### Source Code (cross-repo)

```text
# iSoyehtTerm (this repo) — Swift apps + shared package
TerminalApp/
├── Soyeht/                              # iOS app
│   ├── Onboarding/
│   │   ├── Carousel/                    # 5-card welcome tour (US3)
│   │   ├── InstallPicker/               # "Onde instalar Soyeht?" (US2 PB1)
│   │   ├── Proximity/                   # AirDrop flow (US2 PB2-PB3)
│   │   ├── ParkingLot/                  # "Vou fazer mais tarde" (US4)
│   │   ├── HouseNaming/                 # "Como chamar a casa?" (US2 from iPhone side)
│   │   ├── PairingConfirmation/         # Face ID + biometric confirm (US1 step 5, US2 step 6)
│   │   └── RecoveryMessage/             # "Boa notícia" tela (US5)
│   └── Settings/
│       └── ReshowTour.swift             # Re-trigger carrossel (FR-022)
├── SoyehtMac/                           # macOS app
│   ├── Welcome/                         # Refactor of WelcomeRootView (modos novos)
│   │   ├── Bootstrap/                   # Caso A founder flow (US1)
│   │   ├── AutoJoin/                    # Detected casa-existing flow (future spec, stub here)
│   │   ├── Recover/                     # Local state existing
│   │   └── SetupInvitationListener/     # Caso B reception (US2 Mac side)
│   ├── Installer/
│   │   ├── EnginePackager.swift         # Copy engine binary, drop LaunchAgent plist
│   │   ├── SMAppServiceInstaller.swift  # SMAppService.agent registration
│   │   └── HealthCheckPoller.swift      # /bootstrap/status polling
│   ├── HouseAvatar/
│   │   └── DeterministicEmojiColor.swift # FR-046 derivation (shared logic, lifts to SoyehtCore)
│   └── Sparkle/                         # Auto-update wiring
└── (existing files unchanged unless directly touched)

Packages/SoyehtCore/Sources/SoyehtCore/
├── Bootstrap/                           # NEW
│   ├── BootstrapState.swift             # Enum mirroring engine state machine
│   ├── BootstrapStatusClient.swift      # GET /bootstrap/status
│   ├── BootstrapInitializeClient.swift  # POST /bootstrap/initialize
│   ├── BootstrapTeardownClient.swift    # POST /bootstrap/teardown
│   └── BootstrapHealthClient.swift      # GET /health
├── SetupInvitation/                     # NEW
│   ├── SetupInvitationToken.swift       # 32-byte ephemeral token type
│   ├── SetupInvitationPublisher.swift   # iPhone-side: publish _soyeht-setup._tcp.
│   ├── SetupInvitationBrowser.swift     # Mac-side: discover and claim
│   └── SetupInvitationClaimClient.swift # POST /bootstrap/claim-setup-invitation
├── HouseAvatar/                         # NEW (lifted from SoyehtMac)
│   ├── HouseAvatar.swift                # Struct {emoji, color}
│   └── HouseAvatarDerivation.swift      # Deterministic algorithm from hh_pub
├── Telemetry/                           # NEW (stub; endpoint setup deferred)
│   ├── TelemetryEvent.swift             # Enum of allowed events (FR-071)
│   ├── TelemetryClient.swift            # Opt-in-gated event submitter
│   └── TelemetryPreference.swift        # Default OFF, surface to Settings (FR-073)
└── (existing modules unchanged unless directly touched)

# theyos (separate repo, cross-coordinated)
server-rs/src/
├── bootstrap/                           # NEW module
│   ├── state.rs                         # State machine: uninitialized → ready_for_naming → named_awaiting_pair → ready (+ recovering)
│   ├── status.rs                        # GET /bootstrap/status handler
│   ├── initialize.rs                    # POST /bootstrap/initialize handler (mints P-256 keypair, persists)
│   ├── teardown.rs                      # POST /bootstrap/teardown handler
│   ├── claim_setup_invitation.rs        # POST /bootstrap/claim-setup-invitation handler
│   └── health.rs                        # GET /health handler (already exists; verify)
├── discovery/
│   ├── soyeht_setup_browser.rs          # NEW: browse _soyeht-setup._tcp. on Tailnet
│   └── soyeht_publisher.rs              # EXISTING: enrich _soyeht._tcp. TXT (hh_name, owner_display_name, device_count, platform, bootstrap_state)
└── crypto/
    └── identity_keypair.rs              # P-256 keypair gen + Mac SE-binding (when embedded in Soyeht.app)

theyos/specs/004-onboarding/
└── contracts/                           # Cross-repo wire contracts (mirror of iSoyehtTerm contracts/)
    ├── bootstrap-status.md
    ├── bootstrap-initialize.md
    ├── bootstrap-teardown.md
    ├── setup-invitation.md              # Bonjour TXT format + token semantics
    ├── claim-setup-invitation.md        # HTTP shape
    └── anchor-handoff.md                # OUT OF SCOPE THIS DELIVERY (deferred to Sprint 5+)
```

**Structure Decision**: **Mobile + API cross-repo** (Option 3 of template). The two Swift apps + shared package live in `iSoyehtTerm`; the engine lives in `theyos`. They synchronize via CBOR-encoded HTTP contracts and Bonjour TXT, both frozen in `theyos/specs/004-onboarding/contracts/` before integration begins. **Worktrees within this repo** are used for spec/feature isolation (current worktree at `../soyeht-ios-onboarding`), per Owner's directive — but cross-repo coordination is via PR pairing, not worktrees (consistent with Constitution: "Worktrees for spikes only... NOT used to organize cross-repo parallel work").

## Complexity Tracking

> No Constitution Check violations. This section is empty by design.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| (none) | — | — |
