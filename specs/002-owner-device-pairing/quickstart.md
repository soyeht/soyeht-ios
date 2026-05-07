# Quickstart: Phase 2 Owner Device Pairing

## Prerequisites

- theyOS Phase 2 backend companion available with owner PersonCert issuance.
- iPhone target with Secure Enclave for manual verification.
- Simulator tests use explicit Secure Enclave and Bonjour test doubles.

## 1. Run core tests

```bash
cd /Users/macstudio/Documents/SwiftProjects/iSoyehtTerm
swift test --package-path Packages/SoyehtCore
```

Expected:

- QR parser fixtures pass.
- PersonCert validation fixtures pass.
- request signer fixtures prove no bearer header is emitted for household requests.

## 2. Run iOS app tests

```bash
xcodebuild test \
  -project TerminalApp/Soyeht.xcodeproj \
  -scheme Soyeht \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6'
```

If only one iPhone 16 runtime is installed, `-destination 'platform=iOS Simulator,name=iPhone 16'` is equivalent.

Expected:

- QR scanner can route `soyeht://household/pair-device` links.
- pairing view model reaches paired state only after a valid cert.
- failed pairing fixtures do not activate a household.

## 3. Manual end-to-end check

1. Start theyOS and open a fresh install-time pair QR for "Casa Caio".
2. Open Soyeht on iPhone.
3. Scan the QR.
4. Confirm that the app discovers the matching local household service.
5. Complete pairing.

Expected:

- App reaches "Casa Caio" in under 30 seconds.
- No login, password, token entry, or server picker is shown.
- App reopens into "Casa Caio" after force quit.

## 4. Offline check

1. Pair successfully.
2. Disable network.
3. Reopen app.

Expected:

- App opens within 2 seconds into cached read-only household state.
- Live operations are clearly unavailable.

## 5. Auth inspection

Use a URLSession test double or local proxy during tests.

Expected:

- household request has `Authorization: Soyeht-PoP ...`
- household request has no bearer token
- request construction fails locally when PersonCert is missing or invalid

## 6. Contract compatibility notes

- `pair-device-confirm`: iOS sends `v`, `nonce`, `p_pub`, `display_name`, and `proof_sig`; the proof signs deterministic CBOR `{v, purpose, hh_id, nonce, p_pub}`. The first-owner response accepts `person_cert_cbor` only; any `device_cert` is rejected in this phase.
- `person-cert-cbor`: iOS validates `type == "person"`, P-256 compressed `p_pub`, derived `p_id`, owner caveats, validity window, and root signature against the scanned household public key.
- `proof-of-possession`: iOS sends `Authorization: Soyeht-PoP v1:<p_id>:<unix_seconds>:<signature_b64url>`, signs deterministic CBOR over method, path/query, timestamp, and BLAKE3-256 body hash, and blocks bearer-token household requests locally.

## 7. SC-006 walkthrough record

### 2026-05-07 repository validation

Status: automated first-owner walkthrough surrogate passed; live first-time-owner usability walkthrough not run in this workspace.

Validated commands:

- `swift test --package-path Packages/SoyehtCore`: passed 344 tests across 36 suites.
- `xcodebuild test -project TerminalApp/Soyeht.xcodeproj -scheme Soyeht -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6'`: passed 54 XCTest tests and 272 Swift Testing tests. The unpinned `name=iPhone 16` destination failed on this machine because Xcode selected `OS:latest`, and no `iPhone 16` simulator exists for the latest installed runtime.

Observed repository-side coverage:

- `HouseholdPairingViewModelTests/testScanToActiveHouseholdState` reaches active "Casa Caio" from a valid household pairing QR using QR, Bonjour, Secure Enclave, URLSession, and Keychain doubles.
- `HouseholdPairingFailureViewModelTests` covers expired QR, no matching household, camera denied, biometry canceled, and storage failure without activating a household.
- The validated pairing path does not present login, password, bearer-token entry, server selection, or manual host configuration before activation.

Live SC-006 result: not run. A fresh theyOS install pairing QR and physical iPhone walkthrough are still required to measure the real under-30-second path and human completion rate. Pass criteria remain: reaches "Casa Caio" without login, password, server selection, or manual configuration, reopens into "Casa Caio", and subsequent household requests use Soyeht-PoP.
