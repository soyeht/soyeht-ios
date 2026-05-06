# Tasks: Phase 2 - Owner Device Pairing (Soyeht iPhone)

**Input**: Design documents from `/specs/002-owner-device-pairing/`  
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md  
**Tests**: REQUIRED by pairing/auth success criteria and constitution protocol-boundary test requirements.
**Organization**: Tasks are grouped by user story so each story can be independently tested.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel with other `[P]` tasks in the same phase when files do not overlap.
- **[Story]**: Maps to User Story 1, 2, or 3 from spec.md.
- Paths are absolute under `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create the shared household module surface and localization placeholders.

- [X] T001 Create `Household/` source directory with module placeholder in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/HouseholdIdentifiers.swift`
- [X] T002 [P] Create household test fixture directory and README in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/README.md`
- [X] T003 [P] Add localized pairing/failure string keys to `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Resources/Localizable.xcstrings`
- [X] T004 [P] Create iOS household UI directory with placeholder in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/Household/HouseholdPairingViewModel.swift`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Protocol parsing, cert validation, storage, and signing primitives needed by all stories.

**CRITICAL**: No user story work can begin until this phase is complete.

- [X] T005 [P] Implement household identifier derivation and base32/base64url helpers in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/HouseholdIdentifiers.swift`
- [X] T006 [P] Add identifier and base64url fixture tests in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdIdentifiersTests.swift`
- [X] T007 [P] Implement `PairDeviceQR` URL parser and validation in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/PairDeviceQR.swift`
- [X] T008 [P] Add valid/malformed/expired/unsupported QR parser tests in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/PairDeviceQRTests.swift`
- [X] T009 [P] Implement bounded deterministic CBOR helpers for pairing proof, PersonCert, and request signing contexts in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/HouseholdCBOR.swift`
- [X] T010 [P] Add CBOR fixture canonicality tests in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdCBORTests.swift`
- [X] T011 [P] Implement Secure Enclave owner identity wrapper and test-double protocol in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/OwnerIdentityKey.swift`
- [X] T012 [P] Add owner identity key creation/signing tests with production-unavailable simulator double in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/OwnerIdentityKeyTests.swift`
- [X] T013 [P] Implement `PersonCert` decode, validation, caveat inspection, and no-DeviceCert invariant in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/PersonCert.swift`
- [X] T014 [P] Add PersonCert validation/tamper/mismatch/no-DeviceCert tests in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/PersonCertTests.swift`
- [X] T015 Implement `ActiveHouseholdState` and Keychain-backed session persistence in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/HouseholdSession.swift`
- [X] T016 Add household session persistence and storage-failure tests in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdSessionTests.swift`

**Checkpoint**: QR parsing, identity keys, cert validation, and household session storage are testable without UI or live network.

---

## Phase 3: User Story 1 - Pair the first owner iPhone (Priority: P1) MVP

**Goal**: Scan a valid theyOS QR, discover the matching household, create owner identity, confirm pairing, validate PersonCert, and activate "Casa Caio".

**Independent Test**: Use test doubles for QR, Bonjour, Secure Enclave, URLSession, and Keychain to complete pairing and verify active household state.

### Tests for User Story 1

- [X] T017 [P] [US1] Add Bonjour matching tests for household id, nonce, multiple services, and mismatched identity in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdBonjourBrowserTests.swift`
- [X] T018 [P] [US1] Add pairing service success/failure tests with URLSession and key test doubles, including scan-to-paired timing budget fixture, in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdPairingServiceTests.swift`
- [X] T019 [P] [US1] Add iOS pairing view model tests for scan-to-active-household under 30 seconds and restart-open state in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/SoyehtTests/HouseholdPairingViewModelTests.swift`

### Implementation for User Story 1

- [X] T020 [US1] Implement Network framework `_soyeht-household._tcp` browser and TXT matching in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Networking/HouseholdBonjourBrowser.swift`
- [X] T021 [US1] Implement pairing proof construction and confirm request body in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/PairingProof.swift`
- [X] T022 [US1] Implement `HouseholdPairingService` orchestration for parse, discover, key create, proof sign, confirm, cert validate, and persist in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/HouseholdPairingService.swift`
- [X] T023 [US1] Extend `QRScanResult` to represent `soyeht://household/pair-device` without breaking legacy links in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Store/SessionStore.swift`
- [X] T024 [US1] Route scanned/pasted household QR links from the scanner into pairing flow in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/QRScannerView.swift`
- [X] T025 [US1] Implement `HouseholdPairingViewModel` states and actions in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/Household/HouseholdPairingViewModel.swift`
- [X] T026 [US1] Add minimal paired household home state showing active "Casa Caio" in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/Household/HouseholdHomeView.swift`
- [X] T027 [US1] Integrate paired household routing with existing first-screen/login flow in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/SSHLoginView.swift`

**Checkpoint**: User Story 1 is independently complete when T017-T027 pass.

---

## Phase 4: User Story 2 - Use owner identity for household requests (Priority: P2)

**Goal**: After pairing, household-scoped requests are signed with Soyeht-PoP and never use bearer auth.

**Independent Test**: Construct a household request from an active session and inspect that it has a Soyeht-PoP header and no bearer token.

### Tests for User Story 2

- [X] T028 [P] [US2] Add request signing context and header tests in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdPoPSignerTests.swift`
- [X] T029 [P] [US2] Add API client household request tests for no bearer token and blocked invalid local cert in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdAPIClientTests.swift`

### Implementation for User Story 2

- [X] T030 [US2] Implement `HouseholdPoPSigner` for deterministic request context and `Soyeht-PoP` header generation in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/HouseholdPoPSigner.swift`
- [X] T031 [US2] Add household-scoped request builder that validates active session and local caveats before signing in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/API/SoyehtAPIClient.swift`
- [X] T032 [US2] Add active household accessors and cert-validation guards to `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Store/SessionStore.swift`
- [X] T033 [US2] Ensure household-scoped UI actions read local PersonCert/caveats before rendering availability in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/Household/HouseholdHomeView.swift`

**Checkpoint**: User Story 2 is independently complete when T028-T033 pass.

---

## Phase 5: User Story 3 - Recover from pairing failures safely (Priority: P3)

**Goal**: Invalid QR, no matching service, denied permissions, network loss, rejected proof, invalid cert, and storage failure never activate a household.

**Independent Test**: Feed failure fixtures through the pairing service and view model; verify active household state remains absent and recovery UI is shown.

### Tests for User Story 3

- [X] T034 [P] [US3] Add pairing failure matrix tests in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdPairingFailureTests.swift`
- [X] T035 [P] [US3] Add UI state tests for expired QR, no matching household, camera denied, biometry canceled, and storage failure in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/SoyehtTests/HouseholdPairingFailureViewModelTests.swift`

### Implementation for User Story 3

- [X] T036 [US3] Implement typed `HouseholdPairingError` and recovery categories in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/HouseholdPairingError.swift`
- [X] T037 [US3] Map core pairing failures to localized view model states in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/Household/HouseholdPairingViewModel.swift`
- [X] T038 [US3] Update QR scanner error handling for `soyeht://household/pair-device` invalid/expired URLs in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/QRScannerView.swift`
- [X] T039 [US3] Add camera permission recovery handling for household pairing entry in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/TerminalApp/Soyeht/QRScannerView.swift`
- [X] T040 [US3] Ensure failed pairing clears pending non-persisted session state but preserves retryability in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/Packages/SoyehtCore/Sources/SoyehtCore/Household/HouseholdPairingService.swift`

**Checkpoint**: User Story 3 is independently complete when T034-T040 pass.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Documentation, regression, and cross-repo contract checks.

- [X] T041 [P] Update `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/README.md` pairing notes from legacy `theyos://pair` to include household `soyeht://household/pair-device`
- [X] T042 [P] Update `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/specs/002-owner-device-pairing/quickstart.md` if implementation commands differ from planned paths
- [X] T043 [P] Cross-check iOS contracts against `/Users/macstudio/Documents/theyos/specs/002-owner-pairing-auth/contracts/` and record compatibility notes in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/specs/002-owner-device-pairing/quickstart.md`
- [X] T044 Run `swift test --package-path Packages/SoyehtCore` in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/`
- [X] T045 Run `xcodebuild test -project TerminalApp/Soyeht.xcodeproj -scheme Soyeht -destination 'platform=iOS Simulator,name=iPhone 16'` in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/`
- [ ] T046 Run SC-006 first-time-owner usability walkthrough and record whether pairing completed without password, server choice, or manual configuration in `/Users/macstudio/Documents/SwiftProjects/iSoyehtTerm/specs/002-owner-device-pairing/quickstart.md`

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies.
- **Foundational (Phase 2)**: depends on Setup; blocks all user stories.
- **US1 (Phase 3)**: depends on Foundational.
- **US2 (Phase 4)**: depends on Foundational and can use fixtures, but full value depends on US1 active household state.
- **US3 (Phase 5)**: depends on US1 pairing state and foundational error types.
- **Polish (Phase 6)**: depends on desired user stories being complete.

### Parallel Opportunities

- T002-T004 can run in parallel.
- T005-T014 can run in parallel by file after the Household directory exists.
- T017-T019 can be written in parallel before US1 implementation.
- T028-T029 can be written in parallel before US2 implementation.
- T034-T035 can be written in parallel.

## Parallel Example: Foundational

```bash
Task: "Implement PairDeviceQR.swift"
Task: "Implement HouseholdCBOR.swift"
Task: "Implement OwnerIdentityKey.swift"
Task: "Implement PersonCert.swift"
```

## Implementation Strategy

### MVP First

1. Complete Setup and Foundational tasks T001-T016.
2. Complete US1 T017-T027.
3. Stop and validate scan-to-active "Casa Caio" state with a valid backend fixture.

### Incremental Delivery

1. Add US2 request signing after active household state works.
2. Add US3 failure recovery hardening.
3. Run full package and iOS tests.

## Notes

- No commits are performed automatically.
- Production pairing must not fall back to software identity keys.
- Do not add DeviceCert behavior in this phase.
- Do not send bearer tokens to household-scoped operations.
