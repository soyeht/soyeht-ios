---
description: "Task list for feature 017-onboarding-canonical implementation"
---

# Tasks: Onboarding Canônico Soyeht (iOS + macOS)

**Input**: Design documents from `/specs/017-onboarding-canonical/`
**Prerequisites**: plan.md ✓, spec.md ✓, research.md ✓, data-model.md ✓, contracts/ ✓, quickstart.md ✓

**Tests**: Generated test tasks per Constitution Engineering Standards ("Tests required at protocol boundaries: cert encode/decode/validate, signature verify, replication conflict resolution, Shamir round-trip"). Onboarding-specific test obligations: bootstrap state transitions, P-256 keypair gen, setup-invitation TXT decode, AirDrop activity item provider, avatar derivation determinism, banned-vocab audit, accessibility (VoiceOver/Dynamic Type/RTL).

**Organization**: Tasks grouped by user story (US1, US2 = P1 MVP; US3, US4 = P2; US5 = P3). Setup + Foundational phases block ALL user stories. Polish phase finalizes cross-cutting concerns.

## Format: `[ID] [P?] [Story?] Description with file path`

- **[P]**: Parallelizable (different files, no dependencies on incomplete tasks in same phase)
- **[Story]**: User story label for Phase 3+ tasks (US1..US5); Setup/Foundational/Polish: NO label

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Project structure scaffolding + CI gates. Blocking for all subsequent phases.

**Cross-repo prerequisite (no iSoyehtTerm action)**: theyos publishes canonical contracts in `theyos/specs/005-soyeht-onboarding/contracts/` (owned by agente-backend, committed in their worktree as of 2026-05-09 commit `6c78fe7`). iSoyehtTerm consumes via T039c mirror headers + T039b CI sync verifier — both are Swift-side tasks. No action required here beyond mirror tracking.

- [X] T002 [P] Add `Packages/SoyehtCore/Sources/SoyehtCore/Bootstrap/` directory + empty Swift module file `Bootstrap.swift` for namespace
- [X] T003 [P] Add `Packages/SoyehtCore/Sources/SoyehtCore/SetupInvitation/` directory + empty `SetupInvitation.swift` namespace file
- [X] T004 [P] Add `Packages/SoyehtCore/Sources/SoyehtCore/HouseAvatar/` directory + empty `HouseAvatar.swift` namespace file
- [X] T005 [P] Add `Packages/SoyehtCore/Sources/SoyehtCore/Telemetry/` directory + empty `Telemetry.swift` namespace file
- [X] T006 [P] Add `TerminalApp/Soyeht/Onboarding/` directory tree (Carousel, InstallPicker, Proximity, ParkingLot, HouseNaming, PairingConfirmation, RecoveryMessage) with placeholder SwiftUI files
- [X] T007 [P] Add `TerminalApp/SoyehtMac/Welcome/` subdirectories (Bootstrap, AutoJoin, Recover, SetupInvitationListener) + `Installer/` + `HouseAvatar/` with placeholder files
- [X] T008 [P] Configure CI banned-vocabulary lint: GitHub Action that runs `swift run --package-path Packages/SoyehtCore banned-vocab-audit` against all `.xcstrings` files; fail on any banned term (FR-001)
- [X] T009 [P] Configure CI accessibility audit: snapshot tests for RTL (ar, ur) + Dynamic Type AX5; integrate with existing `axiom:audit-accessibility` agent
- [X] T010 Add Xcode build phase script in SoyehtMac.xcodeproj: copy `theyos/target/aarch64-apple-darwin/release/server` to `Soyeht.app/Contents/Helpers/soyeht-engine` + sign with same Developer ID

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: State machine, contracts, shared types, engine plumbing. Required before any user story.

**⚠️ CRITICAL**: No user story work begins until this phase is complete.

### Cross-repo dependency — theyos engine

The Rust engine state machine, `/bootstrap/*` HTTP handlers, P-256 keypair generation (Secure Enclave on Mac, keyring on Linux), Bonjour publisher/browser, anchor-handoff endpoint, and APNs push provider are owned by **agente-backend** in the theyos repo. See `theyos/specs/005-soyeht-onboarding/tasks.md` Phase 2 for the canonical task list. iSoyehtTerm depends on:
- `/bootstrap/status`, `/bootstrap/initialize`, `/bootstrap/teardown`, `/bootstrap/claim-setup-invitation`, `/health`, `/pair-machine/anchor-handoff` HTTP endpoints (per contracts in `specs/017-onboarding-canonical/contracts/`)
- `_soyeht-household._tcp.` enriched TXT keys + `_soyeht-setup._tcp.` service shape
- Cross-language fixtures: `theyos/tests/fixtures/owner_cert_auth.cbor` (consumed via T039d) + `theyos/tests/fixtures/avatar-derivation-fixtures.csv` (consumed via T039e)

PR pairing: theyos PR merges first (engine forward-compatible); iSoyehtTerm PR follows.

### iSoyehtTerm SoyehtCore (Swift shared package)

- [X] T020 [P] In `Packages/SoyehtCore/Sources/SoyehtCore/Bootstrap/BootstrapState.swift`: define `BootstrapState` enum mirroring theyos exactly (5 cases) + Codable conformance via canonical CBOR
- [X] T021 [P] In `Packages/SoyehtCore/Sources/SoyehtCore/Bootstrap/BootstrapStatusClient.swift`: implement client per `contracts/bootstrap-status.md` (poll cadence, retry backoff, fail-closed CBOR allowlist matching `JoinRequestStagingClient` pattern); add tests covering decoding each enum value, retry schedule, and unknown-key rejection
- [X] T022 [P] In `Packages/SoyehtCore/Sources/SoyehtCore/Bootstrap/BootstrapInitializeClient.swift`: implement client per `contracts/bootstrap-initialize.md` (CBOR encode request, decode response with hh_id/hh_pub/pair_qr_uri, claim_token threading); add tests for happy path + each error code
- [X] T023 [P] In `Packages/SoyehtCore/Sources/SoyehtCore/Bootstrap/BootstrapTeardownClient.swift`: implement client per `contracts/bootstrap-teardown.md`; add tests for confirm-mismatch + PoP signing
- [X] T024 [P] In `Packages/SoyehtCore/Sources/SoyehtCore/Bootstrap/BootstrapHealthClient.swift`: simple `GET /health` client + tests
- [X] T025 [P] In `Packages/SoyehtCore/Sources/SoyehtCore/SetupInvitation/SetupInvitationToken.swift`: define 32-byte token type with crypto-random init + Codable
- [X] T026 [P] In `Packages/SoyehtCore/Sources/SoyehtCore/SetupInvitation/SetupInvitationPublisher.swift`: implement iPhone-side `NWListener` publisher of `_soyeht-setup._tcp.` per `contracts/setup-invitation.md` (CBOR-in-TXT base64url encoding, Tailscale interface filter); add tests with mocked NWListener
- [X] T027 [P] In `Packages/SoyehtCore/Sources/SoyehtCore/SetupInvitation/SetupInvitationBrowser.swift`: implement Mac-side `NWBrowser` discovery + TXT decoding; add tests
- [X] T028 [P] In `Packages/SoyehtCore/Sources/SoyehtCore/SetupInvitation/SetupInvitationClaimClient.swift`: implement `POST /bootstrap/claim-setup-invitation` client per `contracts/claim-setup-invitation.md`; tests for happy + 409 paths
- [X] T029 [P] In `Packages/SoyehtCore/Sources/SoyehtCore/HouseAvatar/HouseAvatar.swift`: define `HouseAvatar` struct {emoji: Character, colorHSL: (h, s, l)}
- [X] T030 In `Packages/SoyehtCore/Sources/SoyehtCore/HouseAvatar/HouseAvatarEmojiCatalog.swift`: define curated 512-emoji catalog (research R4) with Unicode 12 stable emojis only; depends on T029
- [X] T031 In `Packages/SoyehtCore/Sources/SoyehtCore/HouseAvatar/HouseAvatarDerivation.swift`: implement deterministic derivation `derive(hh_pub:) -> HouseAvatar` using SHA-256 + index slicing per research R4; tests must verify determinism over 1000 random hh_pub values
- [X] T032 [P] In `Packages/SoyehtCore/Sources/SoyehtCore/Localization/BannedVocabularyAuditor.swift`: implement audit that scans `.xcstrings` files for banned terms (FR-001 list); add CLI entry point for CI use; tests with synthetic catalogs containing each banned term
- [X] T033 [P] In `Packages/SoyehtCore/Sources/SoyehtCore/Telemetry/TelemetryEvent.swift`: define `TelemetryEvent` enum + `InstallErrorClass` enum per data-model.md
- [X] T034 [P] In `Packages/SoyehtCore/Sources/SoyehtCore/Telemetry/TelemetryPreference.swift`: implement opt-in flag wrapper (default OFF per FR-073) backed by `@AppStorage` for iOS / `UserDefaults` for Mac
- [X] T035 [P] In `Packages/SoyehtCore/Sources/SoyehtCore/Telemetry/TelemetryClient.swift`: implement opt-in-gated event submitter; queues events when offline (local SQLite queue with 1000-event cap, oldest-evicted overflow); rate-limits ≤1/min, 50/day; targets `https://telemetry.soyeht.com/event`; tests verify gating + rate-limit behavior; **MUST tolerate endpoint absence**: T150 endpoint may not be live when this ships, so client buffers locally and retries on online events without surfacing failures to UX

### Apple-grade UX foundation (FR-100..FR-140 enablers)

- [X] T036 [P] In `Packages/SoyehtCore/Sources/SoyehtCore/Animation/AnimationCatalog.swift`: define typed catalog of animation tokens per research R14 (sceneTransition, keyForging, carouselPageDot, avatarReveal, confettiBurst, buttonPress, staggerWord, safetyGlow); each token wraps `Animation` + duration + Reduce Motion override; export public API; tests verify Reduce Motion override produces linear cross-fade
- [X] T037 [P] In `Packages/SoyehtCore/Sources/SoyehtCore/Haptics/HapticDirector.swift`: centralized haptic invoker with profiles (pairingProgress, pairingSuccess, ctaTap, disabledTap, avatarLanded, recoverableError, fatalError, codeMatch) per research R15; reads `UIAccessibility.isReduceHapticsEnabled` (iOS 17+); suppresses non-essential haptics when ON; tests with mock generator stub
- [X] T038 [P] In `Packages/SoyehtCore/Sources/SoyehtCore/Sound/SoundDirector.swift` + assets `Resources/casa-criada.caf` + `Resources/morador-pareado.caf`: 2 audio assets per research R16 (440Hz fundamental + warm harmonics, ≤0.5s, ADSR shaped, peak −12dBFS); director plays via `AVAudioPlayer` + checks `secondaryAudioShouldBeSilencedHint` + respects user mute settings; pitch-shift +5 semitones for morador-pareado variant
- [X] T039 [P] In `Packages/SoyehtCore/Sources/SoyehtCore/Onboarding/RestoredFromBackupDetector.swift`: detect restored vs first-launch via `NSUbiquitousKeyValueStore` flag `soyeht.first_launch_completed_at` per research R18; expose `isRestoredFromBackup: Bool` flag at app launch; tests with mock kvStore covering nil→first-launch, present→restored, syncFailure→fallback
- [X] T039a [P] In `Packages/SoyehtCore/Sources/SoyehtCore/Localization/CopyVoiceAuditor.swift`: extends `BannedVocabularyAuditor` (T032) to cover error voice (FR-119: erro, falha, problema, inválido, rejeitado, aguarde, carregando, processando) + presentation phrases (sucesso, concluído, "operação..."); produces structured report with file:line citations; CI gate same as T032

### Cross-repo coordination (contracts + fixtures)

- [X] T039b [P] Add CI workflow `/.github/workflows/contracts-mirror-verify.yml`: hash-compares each `specs/017-onboarding-canonical/contracts/*.md` against the source-of-truth in `theyos/specs/005-soyeht-onboarding/contracts/<file>.md` (last-sync commit hash declared in mirror header `<!-- mirror of theyos:005/contracts/<file>.md as of <hash> -->`); fail PR merge if mirror is stale. Pairs with `T040d` on theyos side
- [X] T039c [P] Inject mirror header at top of each iSoyehtTerm contract file referencing `theyos/specs/005-soyeht-onboarding/contracts/<file>.md` as canonical source; populate last-sync commit hash via release tag automation
- [X] T039d [P] Build phase script in SoyehtCore (or pre-test fetch step) imports `theyos/tests/fixtures/owner_cert_auth.cbor` (produced by agente-backend) into `Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/owner-cert-auth/`; tests in `OwnerCertSignerTests.swift` validate Swift-produced signatures byte-equal Rust-validated cases
- [X] T039e [P] Build phase script imports `theyos/tests/fixtures/avatar-derivation-fixtures.csv` (produced by agente-backend) into `Packages/SoyehtCore/Tests/SoyehtCoreTests/Fixtures/avatar/`; tests in `HouseAvatarDerivationTests.swift` validate Swift `derive(hh_pub:)` output byte-equal CSV expected `(emoji_unicode, h, s, l)` for all 1000 cases — invariant per FR-046 + research R4

**Checkpoint**: Foundation ready — user story implementation can now begin. theyos PR (T011-T019) merged + iSoyehtTerm PR (T020-T039a) merged in paired sequence.

---

## Phase 3: User Story 1 — Casa nasce no Mac com primeiro morador (Priority: P1) 🎯 MVP

**Goal**: Operador opens Soyeht.app on a fresh Mac, names the house, and adds his iPhone as first morador. End state: house alive on Mac with iPhone confirmed. Tempo alvo ≤45s.

**Independent Test**: With fresh Mac (or post-teardown) + fresh iPhone, drag Soyeht.app to Applications, open, complete flow until "primeiro morador iPhone confirmado". Time elapsed ≤45s = SC-001 pass.

### Mac install flow (Welcome scenes MA1-MA4)

- [X] T040 [US1] In `TerminalApp/SoyehtMac/Welcome/WelcomeRootView.swift`: refactor to new state machine with **4 modes** (`bootstrap` Caso A founder fresh, `autoJoin` descobriu casa existente US5, `setupAwaiting` descobriu setup-invitation iPhone Caso B Mac side, `recover` state local existente); replace existing 3-mode router; remove `localInstall`/`localReuse`/`remoteConnect` enum cases per Constitution IV. **Important**: `autoJoin` e `setupAwaiting` são telas distintas mesmo que ambos usem Bonjour browser (different UX copy + different next-step routing)
- [X] T041 [US1] In `TerminalApp/SoyehtMac/Welcome/Bootstrap/BootstrapWelcomeView.swift`: cena MA1 ("Bem-vindo ao Soyeht. Vamos preparar este Mac em poucos passos. [Continuar]") with progress "1 de 3" indicator; LocalizedStringResource for all text
- [X] T042 [US1] In `TerminalApp/SoyehtMac/Welcome/Bootstrap/InstallPreviewView.swift`: cena MA2 (3 bullet points + telemetria opt-in toggle default OFF + Instalar button) per FR-011, FR-070, FR-073
- [X] T043 [US1] In `TerminalApp/SoyehtMac/Welcome/Bootstrap/InstallProgressView.swift`: cena MA3 (4 micro-steps animation: verificando, pedindo permissão, instalando, acordando) per FR-013
- [X] T044 [US1] In `TerminalApp/SoyehtMac/Welcome/Bootstrap/HouseNamingView.swift`: cena post-install ("Como você quer chamar sua casa?") with TextField pre-filled "Casa <NSFullUserName().firstWord>" + 1-32 char validation + forbidden-chars guard per FR-015
- [X] T045 [US1] In `TerminalApp/SoyehtMac/Welcome/Bootstrap/HouseCreationProgressView.swift`: chave girando 3s animation while `POST /bootstrap/initialize` runs per FR-016
- [X] T046 [US1] In `TerminalApp/SoyehtMac/Welcome/Bootstrap/HouseCardView.swift`: cartão visual da casa (avatar from FR-046 + nome + Mac Studio listed + slot ✨ "adicionar iPhone" pulsing) per FR-017
- [X] T047 [US1] In `TerminalApp/SoyehtMac/Installer/EnginePackager.swift`: copy `Contents/Helpers/soyeht-engine` to `~/Library/Application Support/Soyeht/engine/` on first launch
- [X] T048 [US1] In `TerminalApp/SoyehtMac/Installer/SMAppServiceInstaller.swift`: register LaunchAgent via `SMAppService.agent(plistName:)` (research R3); zero sudo per FR-012; expose `register()`, `unregister()`, `status` API; map `SMAppService.Status` enum to typed `InstallerOutcome` enum
- [X] T048a [US1] In `TerminalApp/SoyehtMac/Installer/SMAppServiceFailureCoordinator.swift`: handle `SMAppService.register()` failures per FR-126 with case-specific UX. Cases: `requiresApproval` → `RequiresLoginItemsApprovalView` (animated arrow pointing to System Settings) + button `Abrir Configurações` deeplinks `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`; `notFound` → silent retry once + auto-trigger reinstall flow; `notRegistered` → diagnostic log + retry; `unknown`/`enabled` → idempotent path; NUNCA surfaces "erro" word (FR-119); tests with mock SMAppService covering each enum
- [X] T048b [US1] In `TerminalApp/SoyehtMac/Welcome/Bootstrap/RequiresLoginItemsApprovalView.swift`: SwiftUI view with subtle animated arrow + screenshot illustration of System Settings panel + `Abrir Configurações` button (NSWorkspace.open URL); tone: educativo, não burocrático
- [X] T049 [US1] In `TerminalApp/SoyehtMac/Installer/HealthCheckPoller.swift`: poll `GET /bootstrap/status` every 500ms during MA3, exponential backoff [1, 2, 4, 8s] on errors with 30s cap; transition UI when state == ready_for_naming
- [X] T049a [US1] Apply `AnimationCatalog.keyForging` token to HouseCreationProgressView (T045) per FR-101: total duration 2.4-3.0s split em 4 micro-steps de 0.6-0.75s cada com easing custom; sincronia visível entre animação da chave e progressão dos steps; verifica em snapshot tests
- [X] T050 [US1] In `TerminalApp/SoyehtMac/HouseAvatar/HouseAvatarView.swift`: SwiftUI view rendering HouseAvatar (emoji + HSL background); used by HouseCardView; persists derived avatar at house creation, NEVER recomputes em render path (FR-046)
- [X] T050a [US1] Apply `AnimationCatalog.avatarReveal` token to HouseAvatarView initial reveal (FR-103): scale-in 0.6→1.0 com .spring + cross-fade emoji opacity 0→1 em 0.4s + soft glow halo pulsa uma vez ≤0.6s e fade; subsequent renders sem animação; HapticDirector.avatarLanded (FR-112) fired no apex
- [X] T050b [US1] In `TerminalApp/SoyehtMac/HouseAvatar/HouseCardCelebrationView.swift`: confetti burst (4-6 emoji-stickers via .symbolEffect ou particle layer) + iPhone icon "voando" pro slot quando primeiro morador adicionado (FR-104); ≤1.2s; Reduce Motion fallback é cross-fade simples
- [ ] T051 [US1] Hardware walkthrough recording: Caso A on fresh Mac with timer overlay; commit recording to `specs/017-onboarding-canonical/walkthroughs/us1-caso-a.mov`; verify SC-001 (≤45s elapsed)

### iPhone partner side (auto-join Caso A)

- [X] T052 [US1] In `TerminalApp/Soyeht/Onboarding/PairingConfirmation/CasaCalledView.swift`: receive `_soyeht._tcp.` discovery of newly-named casa, surface notification + tap-to-confirm (cena P8 design)
- [X] T053 [US1] In `TerminalApp/Soyeht/Onboarding/PairingConfirmation/BiometricConfirmView.swift`: Face ID confirmation + show owner readback ("Casa Caio criada agora há pouco no Mac Studio do Caio") + 6-word código de segurança per FR-045
- [X] T053a [US1] Apply `AnimationCatalog.staggerWord` to código de segurança rendering (FR-128): 6 words fade-in 60ms apart, total 0.36s, monospace 22pt, agrupados 3+3 com spacing generoso; consistente entre Mac (T053b) e iPhone
- [X] T053b [US1] In `TerminalApp/SoyehtMac/Welcome/SafetyCodeDisplay.swift`: apresentação Mac-side do mesmo código de segurança (mesma fonte, size, agrupamento)
- [X] T053c [US1] On biometric confirm tap (FR-129): both Mac e iPhone animar `AnimationCatalog.safetyGlow` (≤0.4s subtle green glow halo around 6 words) + `HapticDirector.codeMatch` (FR-114) em ambos
- [X] T054 [US1] In `TerminalApp/Soyeht/Onboarding/PairingConfirmation/PairingProgressView.swift`: 3-step animation (verificando, entrando, pronto) during pareamento commit; HapticDirector.pairingProgress no step 1, HapticDirector.pairingSuccess no step 3 (FR-110); SoundDirector.casaCriada no step 3 (FR-116)
- [X] T055 [US1] In `TerminalApp/Soyeht/Onboarding/PairingConfirmation/PairingSuccessView.swift`: cena P10 ("Você é o primeiro morador da Casa Caio.") + transition to RecoveryMessageView (US5)

**Checkpoint US1**: All Caso A tasks complete + walkthrough verified ≤45s. MVP achievable here alone.

---

## Phase 4: User Story 2 — iPhone primeiro traz o Mac via proximidade (Priority: P1)

**Goal**: Fresh user with no Soyeht anywhere downloads iPhone app, sees carrossel, confirms "Tenho um Mac aqui", and via AirDrop + Bonjour discovery brings the Mac into the casa, naming the casa from the iPhone keyboard. End state: casa created with both devices, naming done from iPhone. Tempo alvo ≤4min.

**Independent Test**: Fresh iPhone + fresh Mac + same Tailnet. From iPhone first launch, complete carrossel + "Meu Mac" + proximidade + AirDrop + Mac install + naming-on-iPhone + first-morador. Verify SC-002 (≤4min including download).

### iPhone-driven flow (cenas PB1-PB5)

- [X] T060 [US2] In `TerminalApp/Soyeht/Onboarding/InstallPicker/InstallPickerView.swift`: cena PB1 ("Onde você quer instalar Soyeht? [Meu Mac] [Meu Linux em breve disabled] [Pegar link depois]") per FR-023
- [X] T061 [US2] In `TerminalApp/Soyeht/Onboarding/InstallPicker/MoradorExplainerView.swift`: link educativo "Como assim, 'morar'?" expanding to short prose per FR-023
- [X] T062 [US2] In `TerminalApp/Soyeht/Onboarding/Proximity/ProximityQuestionView.swift`: cena PB2 ("Tá perto do Mac agora? [Sim] [Vou fazer mais tarde]") per FR-024
- [X] T063 [US2] In `TerminalApp/Soyeht/Onboarding/Proximity/AirDropPresenter.swift`: wrap `UIActivityViewController` with NSItemProvider for `Soyeht.dmg` resource bundled in app, restrict `excludedActivityTypes` to AirDrop-only (research R1); fallback handler when AirDrop completion=false → trigger QRFallbackView
- [X] T063a [US2] In `TerminalApp/Soyeht/Onboarding/Proximity/NetworkDownloadGuard.swift`: pre-flight check before AirDrop transfer/download per FR-123 (cellular awareness via `NWPathMonitor`) + FR-124 (battery <20% via `UIDevice.batteryLevel`); surface `ProminentConfirmationSheet` SwiftUI views com copy carinhoso (FR-119/120 voice rules); per research R19, default highlighted action é o caminho conservador; tests com mock NetworkPath + battery state matrices
- [X] T063b [US2] In `TerminalApp/Soyeht/Onboarding/Proximity/CellularConfirmationSheet.swift` + `LowBatteryWarningSheet.swift`: SwiftUI sheets dispatched por NetworkDownloadGuard quando condições aplicam; copy passa CopyVoiceAuditor (T039a)
- [X] T064 [US2] In `TerminalApp/Soyeht/Onboarding/Proximity/AwaitingMacView.swift`: ("Procurando seu Mac...") with spinner + iPhone publishes setup-invitation in background via SetupInvitationPublisher (T026)
- [X] T065 [US2] In `TerminalApp/Soyeht/Onboarding/HouseNaming/HouseNamingFromiPhoneView.swift`: same UX as Mac HouseNamingView (T044) but POST goes to discovered Mac engine via Tailscale-resolved endpoint; iPhone shows "Aguardando o Mac criar a casa..." while POST in flight
- [X] T066 [US2] In `TerminalApp/Soyeht/APNs/APNsTokenRegistrar.swift`: capture device token from `UNUserNotificationCenter.requestAuthorization` per `contracts/push-events.md` (iPhone-side authority); persist token; carry into `_soyeht-setup._tcp.` Bonjour TXT (T026) AND into `ClaimSetupInvitationRequest.iphone_apns_token` field (per setup-invitation.md update). Tests verify token persistence + flow integration with SetupInvitationPublisher
- [X] T067 [US2] In `TerminalApp/Soyeht/APNs/CasaNasceuPushHandler.swift`: handle incoming `casa_nasceu` push payload per `contracts/push-events.md`; parse `soyeht` JSON section; on tap, foreground app to PairingConfirmation flow shared with US1 (T053-T055); ignore unknown `type` values (forward-extensibility safe)
- [X] T067a [US2] In `TerminalApp/Soyeht/APNs/CasaNasceuNotificationService/`: Notification Service Extension that mutates incoming push pre-display per FR-046 — extracts `hh_id` from soyeht payload, derives avatar (emoji + HSL), attaches as notification attachment image (rendered emoji-on-color circle); ensures notification surface shows house avatar even before app foregrounded
- [X] T067b [US2] Add cross-language fixture consumer test in `Packages/SoyehtCore/Tests/SoyehtCoreTests/CasaNasceuPushPayloadTests.swift`: imports `theyos/tests/fixtures/casa_nasceu_push.json` (when produced by agente-backend); validates Swift parser decodes byte-equal across all fixture cases per push-events.md "Cross-language fixture" section
- [X] T068 [US2] In `TerminalApp/Soyeht/Onboarding/Proximity/QRFallbackView.swift`: cena PB3b (URL `soyeht.com/mac` + ShareSheet + QR code rendered by iPhone for Mac webcam scan) per FR-025

### Mac-side reception (cenas Mac de Caso B)

- [X] T070 [US2] In `TerminalApp/SoyehtMac/Welcome/SetupInvitationListener/SetupInvitationListener.swift`: on Mac first launch, before showing HouseNamingView, browse `_soyeht-setup._tcp.` (T027) on Tailnet; if found, claim token via `POST /bootstrap/claim-setup-invitation` (T028) + skip naming UI
- [X] T071 [US2] In `TerminalApp/SoyehtMac/Welcome/SetupInvitationListener/AwaitingNameFromiPhoneView.swift`: Mac shows "Aguardando o nome da casa do seu iPhone..." while iPhone POSTs initialize with name
- [X] T072 [US2] In `TerminalApp/SoyehtMac/Continuity/ContinuityCameraQRScanner.swift`: AVCaptureSession + VNDetectBarcodesRequest QR scanner from Mac webcam (research R9); fires when iPhone shows QR (cena PB3b fallback); 3-state visual machine per FR-130 + research R20: searching/acquiring/confirmed
- [X] T072a [US2] In `TerminalApp/SoyehtMac/Continuity/ContinuityCameraView.swift`: SwiftUI view com 3 estados visuais sequenciais — searching (4 cantos pulsando offset 0.3s), acquiring (cantos firmes + scan-line varrendo + colorMultiply verde sutil), confirmed (freeze frame + check-mark spring) — per FR-130; sem som harsh; cross-fade ≤0.6s pra Safari abertura
- [X] T073 [US2] In `TerminalApp/SoyehtMac/SafariOpener.swift`: open `soyeht.com/mac?token=...` URL in default browser when QR scanned + iPhone-initiated download path

### Cross-repo dependency — APNs push provider

APNs direct push (research R6, decision (c) shared bundled `.p8`) implementation lives in theyos repo (`server-rs/src/apns/provider.rs`). Provider key file is bundled by SoyehtMac in `Soyeht.app/Contents/Resources/push-provider.p8` and read by the engine at runtime. iSoyehtTerm depends on:
- Engine emitting `"casa_nasceu"` push payload with `{type, hh_id, owner_display_name}` after Caso B initialize completes
- Engine respecting iPhone APNs token from setup-invitation TXT

See `theyos/specs/005-soyeht-onboarding/tasks.md` for canonical APNs task ownership. iSoyehtTerm side: T067 (CasaNasceuPushHandler) consumes the payload.

### Hardware validation

- [ ] T077 [US2] Build `Soyeht.dmg` locally (notarized + stapled) and bundle in iSoyehtTerm app `Resources/Soyeht.dmg` for AirDrop testing; combined IPA size MUST stay ≤80MB total (≤30MB iOS app + ≤50MB dmg per Risk #3 in plan); ASR strip dSYMs/debug symbols in dmg engine binary pra atingir 50MB cap
- [ ] T078 [US2] Hardware walkthrough recording: Caso B on fresh iPhone + fresh Mac (same Tailnet) with timer overlay; commit to `walkthroughs/us2-caso-b.mov`; verify SC-002 (≤4min)

**Checkpoint US2**: Caso B end-to-end walkthrough green. Both P1 user stories complete = full MVP.

---

## Phase 5: User Story 3 — Carrossel iOS de apresentação (Priority: P2)

**Goal**: Fresh iPhone user sees 5-card welcome tour before any functional flow. Carrossel only shows on first launch; revivable via Settings.

**Independent Test**: Wipe app state → open → carrossel appears with 5 cards + CTA "Vamos começar" → second launch suppresses → Settings > Reapresentar tour replays.

- [X] T080 [P] [US3] In `TerminalApp/Soyeht/Onboarding/Carousel/CarouselRootView.swift`: TabView `.page` style with 5 page cards + dot indicator + CTA button on last card per FR-020
- [X] T081 [P] [US3] In `TerminalApp/Soyeht/Onboarding/Carousel/Cards/CardClawStore.swift`: card 1 (Loja Claw) — hero illustration (App Store-vitrine style with install check) + title/subtitle from xcstrings keys
- [X] T082 [P] [US3] In `TerminalApp/Soyeht/Onboarding/Carousel/Cards/CardAgentTeams.swift`: card 2 (Times de agentes) — orbiting circles illustration
- [X] T083 [P] [US3] In `TerminalApp/Soyeht/Onboarding/Carousel/Cards/CardAgentAsSite.swift`: card 3 (Seu agente vira site) — Mac broadcast illustration with anonymous visitors lighting up
- [X] T084 [P] [US3] In `TerminalApp/Soyeht/Onboarding/Carousel/Cards/CardVoice.swift`: card 4 (Voz é mais rápido) — microphone+wave illustration sequence
- [X] T085 [P] [US3] In `TerminalApp/Soyeht/Onboarding/Carousel/Cards/CardMacAndIphone.swift`: card 5 (Mac e iPhone, juntos) — split-screen illustration
- [X] T086 [US3] In `TerminalApp/Soyeht/Onboarding/Carousel/ParallaxHeroIllustration.swift`: parallax+cross-fade transition modifier consumindo `AnimationCatalog.sceneTransition` (T036); hero illustration parallax 0.4× vs 1.0× content; respects `UIAccessibility.isReduceMotionEnabled` (FR-082)
- [X] T086a [US3] In `TerminalApp/Soyeht/Onboarding/Carousel/MorphingPageIndicator.swift`: indicator de páginas onde dot ativo MORPHA pro próximo (não slide simples) usando `AnimationCatalog.carouselPageDot` (FR-102); tests RTL/LTR direção correta
- [X] T086b [US3] CTA "Vamos começar" no card 5 usa material Liquid Glass (iOS 26+) + `AnimationCatalog.buttonPress` (FR-106) + `HapticDirector.ctaTap` (FR-111)
- [X] T087 [US3] In `TerminalApp/Soyeht/Onboarding/Carousel/CarouselSeenStorage.swift`: `@AppStorage("carousel_seen_at")` flag wrapper persisting Date; nil = not seen (FR-021); short-circuit quando `RestoredFromBackupDetector.isRestoredFromBackup == true` (FR-122) — restored devices não veem carrossel auto
- [X] T087a [US3] When restored-from-backup detected (FR-122), surface tela "Você já usou Soyeht antes. Vamos reconectar com sua casa." em lugar do carrossel; copy passa CopyVoiceAuditor; tests com mock RestoredFromBackupDetector
- [X] T088 [US3] In `TerminalApp/Soyeht/Settings/ReshowTourView.swift`: Settings > Sobre > Reapresentar tour link; clears CarouselSeenStorage and navigates to CarouselRootView per FR-022
- [X] T089 [US3] Add VoiceOver accessibilityLabel for each card (title + descriptive content) + dot indicator (current page X of 5) per FR-080
- [X] T090 [US3] Add snapshot tests for RTL (ar, ur) + Dynamic Type AX5 + Reduce Motion ON + 1 LTR baseline at default size; commit baselines to `Tests/Snapshots/Carousel/`
- [X] T091 [US3] Extend `TelemetryEvent` enum (T033) com case `carouselCompleted`; wire `TelemetryClient.fire(.carouselCompleted)` no tap do CTA "Vamos começar" (T086b); respects opt-in (FR-070); SC-006 (≥85% conversion) measurável

**Checkpoint US3**: Carrossel green; first-launch behavior verified; Settings replay works.

---

## Phase 6: User Story 4 — "Vou fazer mais tarde" parking lot (Priority: P2)

**Goal**: iPhone user without Mac proximity gets graceful deferral path with link/QR/email reminder; home view shows persistent banner until setup completes.

**Independent Test**: From iPhone, choose "Meu Mac" + "Vou fazer mais tarde" → "Sem pressa" tela appears → optionally enable email reminder → home view shows "Soyeht ainda não tem casa" banner → tap banner resumes flow at proximity question.

- [X] T100 [P] [US4] In `TerminalApp/Soyeht/Onboarding/ParkingLot/LaterParkingLotView.swift`: cena PB4 ("Sem pressa") with link `soyeht.com/mac` + ShareSheet + opt-in email reminder + dismiss path per FR-030
- [X] T101 [P] [US4] In `TerminalApp/Soyeht/Onboarding/ParkingLot/EmailReminderForm.swift`: minimal email input with explicit opt-in (no checkbox pre-checked) + sends to telemetry endpoint (or marketing endpoint stub); validates email format
- [X] T102 [US4] In `TerminalApp/Soyeht/Home/NoCasaBanner.swift`: persistent banner visible on home view when no casa configured + tap navigates to ProximityQuestionView per FR-030
- [X] T103 [US4] In `TerminalApp/Soyeht/Home/HomeViewState.swift`: derive `noCasaBannerVisible` from telemetry of `state == uninitialized` and `parking_lot_active == true`; auto-clear when first morador confirmed
- [X] T104 [US4] Add snapshot tests for parking-lot view + banner in 4 locales (pt-BR, en, ar RTL, ja CJK)

**Checkpoint US4**: Parking lot ergonomic; banner persists correctly.

---

## Phase 7: User Story 5 — Recuperação cedo (Priority: P3)

**Goal**: After first morador confirmation, surface tranquilizing message about iPhone-loss recovery. Not actionable; informational.

**Independent Test**: Mock pareamento confirmation → verify "Boa notícia" tela appears → "Entendi" dismisses → Settings > Sobre a Casa > Como recuperar shows same content.

- [X] T110 [P] [US5] In `TerminalApp/Soyeht/Onboarding/RecoveryMessage/RecoveryMessageView.swift`: tela "Boa notícia" com texto sobre recuperação via outro Mac per FR-050; "Entendi" CTA dismisses; non-alarmant tone; copy passa CopyVoiceAuditor
- [X] T110a [US5] In `TerminalApp/Soyeht/Onboarding/RecoveryMessage/KeyHandoffMetaphorView.swift`: animação de chave dissolvendo de uma silueta de iPhone e reaparecendo numa silueta de Mac (≤2s, gentle, runs once on appear); botão "Entendi" só habilita após animação completar (Apple pattern); Reduce Motion: substitui por ícones estáticos lado-a-lado com seta entre
- [X] T111 [P] [US5] In `TerminalApp/Soyeht/Settings/AboutCasa/HowToRecoverView.swift`: Settings entry point that shows same content with "Re-dispensar é seguro" footer per FR-051
- [X] T112 [US5] Add snapshot tests for RecoveryMessageView in 5 locales (pt-BR, en, ar, ja, hi); verify Dynamic Type AX3+; verify Reduce Motion fallback rendering

**Checkpoint US5**: Recovery message shipping; reachable from settings.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Apple-grade finalization across all user stories. No new functionality; lifts quality bar.

### Accessibility (FR-080-088)

- [X] T120 Audit pass: every interactive element across all onboarding views has `accessibilityLabel` per FR-080; integrate `axiom:audit-accessibility` agent into PR check
- [X] T121 [P] Audit pass: every text element scales correctly through Dynamic Type AX1-AX5 per FR-081; fix truncation regressions; add snapshot baselines at AX5 for all key views
- [X] T122 [P] Audit pass: Reduce Motion respected throughout (FR-082) — verify carrossel + chave girando + progress indicators all degrade
- [X] T123 [P] Audit pass: WCAG AA contrast (4.5:1 / 3:1) verified in light + dark mode for every text/background pair per FR-083; use `axiom:hig` reference + Color Contrast Analyzer
- [X] T124 [P] Audit pass: Increase Contrast respected; bordered fallbacks for translucent surfaces per FR-084
- [X] T125 [P] Audit pass: Reduce Transparency replaces Liquid Glass with solid backgrounds per FR-085
- [X] T126 [P] Audit pass: Voice Control labels short, natural, action-aligned per FR-086
- [X] T127 [P] Audit pass: Touch targets ≥44pt iPhone per FR-087; iPad/Mac targets ≥28pt
- [X] T128 [P] Audit pass: RTL (ar, ur) layout mirroring + carrossel page direction reversed; **macOS traffic lights MUST stay top-LEFT physical position even em RTL** per Apple HIG + memória interna `feedback_macos_rtl_traffic_lights.md` (research R10) per FR-088; integration test snapshot Mac em ar locale verifica posição

### Localization (FR-004-006, FR-138-140)

- [X] T129 Author `specs/017-onboarding-canonical/copy-voice.md` per research R17: voice guide com banned words (FR-119), preferred substitutos, tone rules ("amigo paciente, não burocrático"), exclamation cap, emoji policy
- [ ] T130 Translate all new keys (carrossel, install flow, naming, recovery, parking lot, error messages) to all 15 locales (ar, bn, de, en, es, fr, hi, id, ja, mr, pt-BR, pt-PT, ru, te, ur); use professional translation service or in-house native speakers; commit to existing `.xcstrings` files; **review cultural** por falante nativo de cada locale (FR-140) catch frases impositivas/frias
- [X] T130a [P] Audit plural rules: cada string que envolve contagem (ex: "{n} morador(es)") usa xcstrings substitution variants `one`/`few`/`many`/`other` conforme CLDR rules pra cada locale (FR-138); strings sem plural rules adequadas falham CI lint
- [ ] T130b [P] Audit gender-neutral phrasing: strings que possam carregar gênero passem por revisão pra reformular gender-neutral onde idioma permite (FR-139); documenta exceções em `copy-voice.md` quando idioma não permite neutralidade
- [X] T131 [P] Run banned-vocabulary audit (T032) + CopyVoiceAuditor (T039a) against all 15 locale variants; fix any leak; CI gate green
- [X] T132 [P] Verify `LocalizedStringResource` pattern used for all interpolated strings (FR-006); grep test in CI

### Auto-update + distribution

- [X] T140 In `TerminalApp/SoyehtMac/Sparkle/`: integrate Sparkle 2.x for `.app` auto-update (research R7); embed APNs provider key + engine binary in atomic update
- [X] T141 In `Scripts/build-dmg.sh`: build pipeline producing notarized+stapled `Soyeht.dmg` from Xcode archive; integrate with PR #43 notarization infra; run on every release tag

**Cross-repo prerequisite (no iSoyehtTerm action)**: Engine self-containment is verified by theyos CI smoke test (`Scripts/verify-engine-self-contained.sh`, owned by agente-backend). iSoyehtTerm consumes the verified engine binary via release artifact metadata before bundling — no action here beyond reading the artifact.

### Telemetry endpoint (cross-repo prerequisite)

**Cross-repo prerequisite (no iSoyehtTerm action)**: Telemetry endpoint at `telemetry.soyeht.com/event` (Cloudflare Worker) is operationally owned outside iSoyehtTerm. T035 (Swift TelemetryClient) tolerates endpoint absence by buffering locally — this is the only action needed here. Endpoint contract documented in `theyos/specs/005-soyeht-onboarding/research.md`.

### Performance + final validation

- [ ] T160 Performance pass: profile carrossel transitions @ 60fps on iPhone 12 (oldest supported); ensure no frame drops in Reduce Motion ON + Increase Contrast ON combo
- [ ] T161 [P] Performance pass: end-to-end `POST /bootstrap/initialize` latency from Swift client (BootstrapInitializeClient) ≤500ms p95 against running engine; integration tests using XCTest with mocked + real engine endpoints (engine-internal SE keypair gen budget ~300ms is owned by theyos perf task — out of frontend scope)
- [ ] T162 [P] Performance pass: Bonjour discovery latency ≤3s from Mac install completion to iPhone setup-invitation pickup, measured iPhone-side via SetupInvitationBrowser callback timing
- [ ] T163 SC-validation: re-run hardware walkthroughs (T051, T078) after polish phase; commit final recordings; SC-001 (≤45s) and SC-002 (≤4min) verified

### CI + quality gates

- [X] T170 [P] Add CI workflow: every PR runs `swift test --package-path Packages/SoyehtCore`, snapshot tests RTL+AX5, banned-vocab audit, accessibility audit
- [X] T171 [P] Add CI workflow: cross-repo dependency check — if iSoyehtTerm PR touches `Bootstrap*Client.swift` or `SetupInvitation*.swift`, require companion theyos PR linked

---

## Dependencies

```
Phase 1 (Setup)              ─────────┐
Phase 2 (Foundational)        ────────┤── blocks all Phases 3-7
Phase 3 (US1 — Caso A) [P1]   ────────┤   [parallel with US2 after Foundational]
Phase 4 (US2 — Caso B) [P1]   ────────┤
Phase 5 (US3 — Carrossel) [P2] ───────┤   [parallel with US4 after US1+US2 frozen]
Phase 6 (US4 — Parking) [P2]   ───────┤
Phase 7 (US5 — Recovery) [P3]   ──────┘   [after US1, US2 since extends them]
Phase 8 (Polish)              ──── final, after all stories pass
```

**MVP scope** = Phase 1 + Phase 2 + Phase 3 (US1) — sufficient for first end-to-end walkthrough demonstration. Phase 4 (US2) closes second P1 entry path. Phases 5-8 ship together for the full v1.

**Cross-repo PR pairing** (theyos task IDs documented in `theyos/specs/005-soyeht-onboarding/tasks.md`, not duplicated here):
- Phase 1: theyos contracts PR lands first; iSoyehtTerm syncs mirror headers (T039c)
- Phase 2: theyos engine foundational PR + iSoyehtTerm SoyehtCore PR (T020-T039e) paired, theyos merged first
- Phase 3-7: Mostly iSoyehtTerm-only changes; theyos APNs work paired with US2 iSoyehtTerm PR
- Phase 8: independent quality work; no cross-repo blocking

---

## Parallel Execution Examples

**Phase 2 Foundational, after theyos engine foundational PR lands**:
- T020, T025, T029, T032, T033, T034 (Swift type definitions) all parallel after package scaffolding
- T021, T022, T023, T024 (Bootstrap clients) parallel — different files, all depend only on T020
- T036, T037, T038, T039 (Apple-grade UX foundation) parallel after package scaffolding
- T039b, T039c, T039d, T039e (cross-repo coordination) parallel

**Phase 3 US1, after Foundational complete**:
- T041, T042, T043, T044, T045, T046, T050 (UI views) all parallel — different files
- T047, T048, T049 sequential (installer chain depends on each other)
- T052, T053, T054, T055 (iPhone partner views) parallel after T040

**Phase 4 US2, after Foundational complete (parallel with US1)**:
- T060, T061, T062, T063, T064, T065 (iPhone PB cenas) parallel
- T070, T071, T072, T073 (Mac reception) parallel
- T077 (dmg embedding) sequential after Phase 3 dmg pipeline established

**Phase 5 US3 carrossel**:
- T081-T085 (5 card files) all parallel — different files
- T086, T087, T088 sequential

**Phase 8 Polish**:
- T120-T128 (a11y audits) all parallel — independent passes
- T130, T131, T132 (localization) parallel after T130 freeze

---

## Implementation Strategy

**MVP-first delivery**:
1. Week 1: Lock Phase 1 (T002-T010 setup) — theyos foundational PR lands in parallel (their tasks)
2. Week 2: Land T020-T039e (Swift foundational) → MVP foundation green
3. Week 3: Phase 3 US1 → first hardware walkthrough recording (T051)
4. Week 4: Phase 4 US2 → second P1 walkthrough (T078); full MVP demonstrable
5. Weeks 5-6: Phases 5-7 (P2/P3 stories)
6. Weeks 7-8: Phase 8 polish → ship-ready
7. Week 8: Hardware validation pass (T163) → tag v1.0.0

**Cross-repo coordination cadence**: weekly sync (Caio + agente-backend + agente-front) covering: theyos PR queue, iSoyehtTerm PR queue, contract changes, hardware walkthrough findings.

**Quality gates per phase**:
- Phase 1: CI green (lint, test scaffolding)
- Phase 2: theyos integration tests green + Swift package tests green + cross-repo paired PR merge
- Phase 3-7: per-story walkthrough recording + snapshot baselines committed
- Phase 8: SC-001/SC-002 verified; banned-vocab audit green for all 15 locales; accessibility audit green
