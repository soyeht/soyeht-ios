# Research: Phase 2 - Owner Device Pairing

## R1 - Secure Enclave Key API

**Decision**: Create the first owner person key with Security framework `SecKeyCreateRandomKey`, `kSecAttrTokenIDSecureEnclave`, private-key usage access control, and biometric policy. Store only the keychain reference/label.

**Rationale**: The constitution explicitly requires Secure Enclave-backed identity keys created through the Security API. The private scalar must never exist in app memory.

**Alternatives considered**:
- Software CryptoKit P-256 key: rejected for production because it violates hardware-isolated identity-key requirements.
- CryptoKit-only key management: rejected because the constitution names the precise Secure Enclave creation requirement.

## R2 - First Device Chain Shape

**Decision**: The first owner iPhone directly holds `P_priv` and stores PersonCert only. It does not create or store a DeviceCert in this phase.

**Rationale**: The household protocol reserves DeviceCert for second and later devices. This keeps the app aligned with the theyOS companion spec.

**Alternatives considered**:
- Create DeviceCert immediately: rejected because it would create an extra delegation edge not specified for the first device.

## R3 - Pair Endpoint Discovery

**Decision**: Use Network framework Bonjour browsing for `_soyeht-household._tcp`, then select only a service whose TXT nonce and household identity match the scanned QR.

**Rationale**: The QR does not carry host details in this phase, and the product goal is no manual server entry. Matching both nonce and household identity prevents wrong-house pairing on shared networks.

**Alternatives considered**:
- Manual host entry fallback: rejected for this feature because it weakens the Apple-grade onboarding target and is explicitly out of scope.
- Blindly use the first Bonjour result: rejected because multiple households can be present.

## R4 - Local Storage Boundary

**Decision**: Store PersonCert and identity key references in Keychain with this-device-only accessibility. Store non-secret display/cache metadata in UserDefaults.

**Rationale**: Keychain is appropriate for identity-bearing state and survives app restart. This-device-only prevents restoring a device backup into a silently trusted new device.

**Alternatives considered**:
- Store cert JSON in UserDefaults only: rejected because auth state should share the protected storage lifecycle.
- iCloud Keychain sync: rejected because the first-device key must not silently appear on other devices.

## R5 - Request Signing Contract

**Decision**: Add a household request signer that produces `Authorization: Soyeht-PoP v1:<p_id>:<unix_seconds>:<signature_b64url>` over the backend-defined deterministic request context.

**Rationale**: The app can keep existing API request shapes while replacing bearer auth for household-scoped operations. The signer is testable independent of UI.

**Alternatives considered**:
- Put signatures in request body: rejected because GET and WebSocket-style future flows need header auth.
- Continue bearer headers for household operations: rejected by the constitution and theyOS Phase 2 spec.

## R6 - CBOR Handling

**Decision**: Add a small deterministic CBOR codec surface for the specific household signed payloads and cert fixtures used by this phase, rather than introducing broad dynamic CBOR behavior into UI code.

**Rationale**: The app only needs a bounded set of protocol payloads now: pairing proof, PersonCert validation bytes, and request signing context. Keeping this in `SoyehtCore/Household` narrows the audit surface.

**Alternatives considered**:
- Ad hoc string signing: rejected because signed protocol payloads must be deterministic CBOR.
- Full generic CBOR object model in UI layer: rejected because it spreads protocol complexity into views.

## R7 - Failure UX

**Decision**: Pairing failures are represented as typed local states: invalid QR, expired QR, no matching household, identity-key unavailable, proof rejected, cert invalid, network lost, storage failed, and first owner already paired. The UI maps those states to short recovery text and never activates a household on failure.

**Rationale**: Pairing is security-sensitive and non-technical users need a clear next action without server/auth jargon.

**Alternatives considered**:
- Show raw backend errors: rejected because backend intentionally returns generic auth failures.
