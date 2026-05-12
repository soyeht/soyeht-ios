# Implementation Plan: Phase 2 - Owner Device Pairing (Soyeht iPhone)

**Branch**: `002-owner-device-pairing` | **Date**: 2026-05-06 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/002-owner-device-pairing/spec.md`

## Summary

Soyeht on iPhone gains the client half of install-time household owner pairing. The app recognizes `soyeht://household/pair-device` QR links, discovers the matching active theyOS household service on the local network, verifies the scanned household public identity and nonce, creates Owner's first owner person identity key in the Secure Enclave, proves possession of that key to theyOS, validates the returned owner PersonCert, stores household identity locally, and renders "Sample Home" as the active household without login, server picker, password, or manual host entry. After pairing, household-scoped requests are signed with Soyeht proof-of-possession instead of bearer tokens.

The technical approach adds household protocol models and crypto helpers to `SoyehtCore`, keeps the QR scanner UI path in the iOS app, uses Apple's Security framework for Secure Enclave key creation/signing, uses Network framework Bonjour browsing for `_soyeht-household._tcp`, persists private-key references and cert state in Keychain, and adds a household request signer to the shared API client without disturbing legacy non-household bearer-token flows.

## Technical Context

**Language/Version**: Swift 5.9  
**Primary Dependencies**: SwiftUI, UIKit, AVFoundation, Foundation, Security, CryptoKit for verification helpers where appropriate, Network framework for Bonjour browsing, existing `SoyehtCore` package and `Soyeht` iOS app target  
**Storage**: Keychain for owner identity key reference, PersonCert, and household session secrets; UserDefaults only for non-secret household display/cache metadata  
**Testing**: Swift Package tests for `SoyehtCore`, Xcode/XCTest for iOS app surfaces, test doubles for camera, Bonjour, URLSession, and Secure Enclave signing  
**Target Platform**: iOS 16+ iPhone for production pairing; simulator uses test doubles only  
**Project Type**: iOS app plus shared Swift package  
**Performance Goals**: Scan-to-paired state <30s on a reachable local network; offline paired state opens <2s; request signing overhead <50ms p95 in local tests  
**Constraints**: No software fallback for production identity keys; no DeviceCert in this phase; no central cloud control plane; no manual server entry for household pairing; household-scoped requests cannot use bearer tokens  
**Scale/Scope**: One app, one first owner identity, one active household session, one theyOS Phase 2 backend companion

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design. See `.specify/memory/constitution.md`.*

| # | Principle | Status | Notes |
|---|-----------|--------|-------|
| I | Apple-Grade Quality (no SPOF, no manual ops, automatic discovery/failover, UX hides infrastructure from non-technical users) | PASS | QR scan plus Bonjour matching avoids manual server entry. Failure states are human-readable and retryable. |
| II | Capability-Based Authorization (signed certs chain to household root; no RBAC; no bearer for household ops; UI rendered from local cert) | PASS | The app stores PersonCert, renders from local caveats, and signs household requests with PoP. |
| III | Local-First Identity & State (no central cloud control plane; Bonjour + Tailscale only) | PASS | Pairing uses local discovery and direct theyOS calls; no cloud identity or directory. |
| IV | Adoption-First, No Legacy Compatibility (no parallel old/new code paths; phase ends end-to-end functional) | PASS | Household routes use the new cert/PoP path. Legacy bearer flows remain only for existing non-household endpoints during migration and do not grant household authority. |
| V | Specification-Driven Development (closed plan, no open alternatives; English artifacts; spec exists before implementation) | PASS | Spec is closed and this plan selects concrete Apple APIs and local storage contracts. |

Engineering standards check:

- [x] Apple APIs used precisely (Security `SecKeyCreateRandomKey` with Secure Enclave; Network framework Bonjour; AVFoundation camera scanner)
- [x] Cryptographic primitives match Engineering Standards (EC P-256 ECDSA, deterministic CBOR signed payloads, protocol identifier hashing)
- [x] No silent error swallowing at protocol boundaries
- [x] Tests planned at protocol boundaries

**Result**: All gates PASS. No entries required in Complexity Tracking.

## Project Structure

### Documentation (this feature)

```text
specs/002-owner-device-pairing/
├── plan.md
├── spec.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── pair-device-url.md
│   ├── pairing-client-flow.md
│   └── proof-of-possession-client.md
└── tasks.md
```

### Source Code (repository root)

```text
Packages/SoyehtCore/
├── Sources/SoyehtCore/
│   ├── Household/
│   │   ├── HouseholdIdentifiers.swift
│   │   ├── PairDeviceQR.swift
│   │   ├── PersonCert.swift
│   │   ├── HouseholdSession.swift
│   │   ├── OwnerIdentityKey.swift
│   │   ├── PairingProof.swift
│   │   ├── HouseholdPoPSigner.swift
│   │   └── HouseholdPairingService.swift
│   ├── Networking/
│   │   └── HouseholdBonjourBrowser.swift
│   ├── Store/
│   │   └── SessionStore.swift
│   └── API/
│       └── SoyehtAPIClient.swift
├── Tests/SoyehtCoreTests/
│   ├── PairDeviceQRTests.swift
│   ├── PersonCertTests.swift
│   ├── HouseholdPoPSignerTests.swift
│   └── HouseholdPairingServiceTests.swift
└── Package.swift

TerminalApp/Soyeht/
├── QRScannerView.swift
├── SSHLoginView.swift
├── SessionStore.swift
└── Household/
    ├── HouseholdPairingViewModel.swift
    └── HouseholdHomeView.swift

TerminalApp/SoyehtTests/
└── HouseholdPairingViewModelTests.swift
```

**Structure Decision**: Protocol parsing, cryptographic validation, storage, Bonjour, and request signing live in `SoyehtCore` so iOS and future macOS app surfaces share one implementation. iOS-specific scanner and onboarding state stay under `TerminalApp/Soyeht/`, where the existing QR scanner and login entry point already live.

## Complexity Tracking

No violations.
