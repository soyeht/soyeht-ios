# Feature Specification: Phase 2 - Owner Device Pairing (Soyeht iPhone)

**Feature Branch**: `002-owner-device-pairing`  
**Created**: 2026-05-06  
**Status**: Draft  
**Input**: User description: "Phase 2 - Owner device pairing in the Soyeht iPhone app. After theyOS install shows a soyeht://household/pair-device QR, the app scans it, verifies the household public key, discovers the matching active household pairing service, generates the owner's EC P-256 person identity key in the Secure Enclave with biometric signing policy, confirms the pairing with theyOS, receives and validates the first owner PersonCert, stores the household identity and cert locally, renders Casa Caio as the active household without login, password, server selection, or manual configuration, and signs subsequent household-scoped requests with Soyeht proof-of-possession instead of bearer tokens. The first owner device receives PersonCert only; DeviceCert is reserved for the later second-device flow. Scope this client feature to the first owner device only; exclude second-machine joining, inviting other people, revocation, gossip replication, Claw creation workflows, and second-device delegation."

**Backend Companion**: theyOS backend spec at `/Users/macstudio/Documents/theyos/specs/002-owner-pairing-auth` and cross-repo protocol at `/Users/macstudio/Documents/theyos/docs/household-protocol.md`. The current protocol specifies EC P-256 for household, machine, person, and device identities.

## User Scenarios & Testing *(mandatory)*

The primary actor is the first household owner using the Soyeht iPhone app. The supporting system is a freshly installed theyOS household named "Casa Caio" on the founding Mac Studio. By the time this client flow starts, theyOS has already created the household root identity, enrolled the Mac as the first machine member, and is showing an active `soyeht://household/pair-device` QR for first-owner pairing.

### User Story 1 - Pair the first owner iPhone (Priority: P1)

Caio installs theyOS on the Mac Studio, names the household "Casa Caio", sees the household pairing QR, opens Soyeht on iPhone, and scans the QR. The app verifies that the scanned household identity matches the active household pairing service on the reachable local network, creates Caio's Secure Enclave-backed owner identity, confirms pairing with theyOS, validates the returned owner PersonCert, stores the trusted household identity locally, and lands directly in "Casa Caio" as the active household.

**Why this priority**: This is the first usable owner onboarding path. Without it, a new household cannot be operated from the iPhone app after theyOS installation.

**Independent Test**: With theyOS showing an active first-owner QR for "Casa Caio", scan the QR from a fresh Soyeht app install and verify that the app reaches an active paired-household state with a validated owner PersonCert and no login or manual setup step.

**Acceptance Scenarios**:

1. **Given** theyOS is showing an active first-owner pairing QR for "Casa Caio", **When** Caio scans it from the Soyeht iPhone app on a reachable local network, **Then** the app verifies the household identity, completes pairing, and shows "Casa Caio" as the active household within 30 seconds.
2. **Given** the app receives the first owner PersonCert from theyOS, **When** local validation completes, **Then** the cert is accepted only if it is for the scanned household, matches the locally created owner identity, is currently valid, and grants owner authority.
3. **Given** pairing succeeds, **When** Caio closes and reopens the app, **Then** the app returns to "Casa Caio" without asking for login, password, server selection, or manual configuration.
4. **Given** this is the first owner device flow, **When** pairing succeeds, **Then** the iPhone is represented by Caio's owner PersonCert only, while the Mac Studio remains the founding household machine.

---

### User Story 2 - Use owner identity for household requests (Priority: P2)

After pairing, Caio uses Soyeht to access household-scoped app surfaces. The app treats the locally stored household identity and PersonCert as the active authorization source and signs household requests with Soyeht proof of possession instead of using bearer tokens.

**Why this priority**: Pairing is only valuable if subsequent household access follows the Soyeht possession-based security model.

**Independent Test**: Complete the first-owner pairing flow, perform a household-scoped action, and verify that the request is authorized by proof of possession and does not use a bearer token.

**Acceptance Scenarios**:

1. **Given** Caio has a valid local owner PersonCert, **When** the app prepares a household-scoped request, **Then** it signs the request context with Caio's owner identity and includes Soyeht proof of possession.
2. **Given** the local PersonCert is missing, invalid, expired, or not for the active household, **When** a household-scoped request would be sent, **Then** the app blocks the request locally and presents a recoverable paired-state problem.
3. **Given** a future household action requires authority not present in the local PersonCert, **When** the app renders that action, **Then** it does not present the action as available before any request is sent.

---

### User Story 3 - Recover from pairing failures safely (Priority: P3)

Caio may scan an expired QR, deny camera access, be on the wrong network, lose connectivity during confirmation, or receive a certificate that cannot be trusted. The app explains the specific failure state, offers retry or paste-link recovery where appropriate, and never activates a household from partial or untrusted pairing data.

**Why this priority**: First-owner pairing is security-sensitive onboarding. Ambiguous failures would either block setup or risk trusting the wrong household.

**Independent Test**: Exercise expired QR payloads, mismatched household services, missing camera permission, network interruption, duplicate token use, and malformed PersonCert responses; verify that no failed path activates a household or enables request signing.

**Acceptance Scenarios**:

1. **Given** the scanned QR is expired or already consumed, **When** Caio attempts pairing, **Then** the app reports that the pairing code is no longer valid and prompts him to create or scan a fresh theyOS QR.
2. **Given** no matching household pairing service can be discovered on the reachable local network, **When** Caio attempts pairing, **Then** the app explains the local network requirement and offers retry or paste-link handling without exposing manual server configuration.
3. **Given** theyOS returns a malformed, mismatched, non-owner, or untrusted PersonCert, **When** the app validates the response, **Then** pairing fails and no household becomes active.

### Edge Cases

- The scanned URL uses the wrong scheme, wrong path, unsupported version, missing household public key, missing nonce, missing expiry, malformed encoded values, or unrecognized critical fields.
- The QR was valid when displayed but expires before confirmation completes.
- Multiple active household pairing services are visible; only the service matching both the scanned household identity and pairing nonce may be used.
- A visible pairing service matches the nonce but presents a different household identity; the app must reject it as a mismatch.
- Network connectivity drops after owner identity creation but before theyOS confirms pairing.
- The user denies camera permission or biometric approval.
- The iPhone cannot create the required protected owner signing identity.
- theyOS consumes the one-shot pairing token before this app confirms, including duplicate scans from the same device.
- theyOS reports that a first owner has already been paired; the app must not create a second first-owner state from the install QR.
- Local protected storage is unavailable, reset, or lost after pairing.
- Older login, bearer-token, or manual server records exist locally from previous app versions.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The app MUST recognize only supported `soyeht://household/pair-device` pairing URLs for this flow and MUST reject malformed, expired, or unsupported URLs before attempting pairing.
- **FR-002**: The app MUST extract the scanned household public identity and pairing nonce from the QR and use them as trust anchors for selecting the matching active household pairing service.
- **FR-003**: The app MUST discover the active household pairing service available on the reachable local network and continue only when the discovered service matches the scanned household identity and nonce.
- **FR-004**: The app MUST create the first owner's EC P-256 person identity key as a Secure Enclave-backed identity requiring biometric approval for signing.
- **FR-005**: The app MUST NOT export, display, log, sync, or store plaintext private key material for the owner identity.
- **FR-006**: The app MUST confirm pairing with theyOS using the scanned one-shot pairing data and Caio's owner person public identity.
- **FR-007**: The app MUST prove control of the newly created owner person identity during pairing confirmation before accepting any returned PersonCert as usable.
- **FR-008**: The app MUST accept pairing only after validating the returned PersonCert for the scanned household, the locally created owner identity, current validity, trusted issuer, and owner authority.
- **FR-009**: The app MUST store the trusted household identity, active household metadata, owner PersonCert, and protected owner-key reference locally after successful validation.
- **FR-010**: The app MUST render "Casa Caio" as the active household after successful first-owner pairing.
- **FR-011**: The successful first-owner app state MUST NOT require login, password, bearer token entry, server selection, or manual configuration.
- **FR-012**: The app MUST treat first-owner pairing as PersonCert-only; it MUST NOT require, request, store, or display a DeviceCert in this feature.
- **FR-013**: The app MUST sign subsequent household-scoped requests with fresh Soyeht proof of possession derived from the local owner identity.
- **FR-014**: The app MUST NOT use bearer-token authorization for household-scoped requests covered by this feature.
- **FR-015**: The app MUST validate local household identity and PersonCert state before presenting protected household actions as available.
- **FR-016**: Pairing failure paths MUST be non-destructive: no failed or partial pairing may activate a household, accept a PersonCert, or enable household request signing.
- **FR-017**: The feature MUST exclude the remaining roadmap journeys: second-machine joining on the same LAN, remote machine joining, inviting other people, restricted single-Claw invite links, Claw creation workflows, permission changes, revocation, gossip replication, outage/failover behavior, offline household browsing beyond this paired-household entry state, and second-device delegation.

### Key Entities

- **PairDeviceQR**: The scanned first-owner pairing URL. Key attributes include protocol version, household public identity, pairing nonce, expiry, and any non-critical display hints.
- **HouseholdIdentity**: The verified public identity of the household. Key attributes include household identifier, household public key, display name, and trust status.
- **FoundingMachine**: The Mac Studio that created the household and is already a certified machine member before iPhone pairing begins. Key attributes include machine identity, household membership status, and availability of the active pairing window.
- **HouseholdPairingService**: The active local theyOS pairing surface that can complete first-owner pairing. Key attributes include household identity, pairing nonce, reachability state, and pairing-window status.
- **OwnerPersonIdentity**: Caio's local first-owner person identity. Key attributes include person public identity, Secure Enclave-backed private-key reference, creation time, and biometric signing policy.
- **PersonCert**: The owner certificate returned by theyOS for the first owner device. Key attributes include household identity, person identity, owner authority, validity window, issuer, and signature.
- **ActiveHouseholdState**: The local app state that makes a household usable after pairing. Key attributes include household identity, display name, PersonCert reference, owner-key reference, and paired status.
- **ProofOfPossessionAuthorization**: The authorization evidence attached to a household-scoped request. Key attributes include target household, request context, signing time, and owner signature.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On a reachable local network with a valid theyOS QR, a first-time owner can scan and reach the active "Casa Caio" household state in under 30 seconds.
- **SC-002**: 100% of malformed, expired, unsupported-version, wrong-household, wrong-nonce, and untrusted-certificate test cases are rejected before any household is marked active.
- **SC-003**: 100% of successful first-owner pairing tests persist a validated owner PersonCert and reopen into the same active household after app restart.
- **SC-004**: 100% of household-scoped request tests after pairing use Soyeht proof of possession and do not include bearer-token authorization.
- **SC-005**: 100% of first-owner pairing failure tests leave no active household, no accepted PersonCert, and no usable household request-signing state.
- **SC-006**: In usability testing, at least 90% of first-time owners can complete valid QR pairing without entering a password, choosing a server, or manually configuring a connection.
- **SC-007**: 100% of successful first-owner pairing tests store no DeviceCert for the iPhone in this phase.

## Assumptions

- theyOS has already completed installation on the founding Mac Studio, created the "Casa Caio" household identity, enrolled the Mac as the first machine member, and is showing an active first-owner `soyeht://household/pair-device` QR before this flow begins.
- The theyOS pairing service is reachable from the iPhone over the household's local network during the pairing window.
- The household display name "Casa Caio" is provided by trusted pairing data after validation and is the name the app should show for this feature.
- The QR and pairing confirmation are one-shot and time-limited; exact expiry duration is owned by the theyOS pairing window behavior.
- Production first-owner pairing requires an iPhone capable of creating and using the required protected biometric signing identity.
- Simulator, development, and automated test environments may use controlled test identities, but production pairing must preserve the same user-visible trust and failure behavior.
- DeviceCert issuance is intentionally reserved for a later second-device flow and is not required for the first owner device.
- The broader household roadmap contains additional user journeys for automatic LAN machine join, remote QR/Tailscale machine join, people invitations, single-agent restricted access, Claw creation, permission updates, revocation, gossip, outage behavior, offline browsing, and per-person multi-device delegation; those journeys are intentionally not implemented by this first-owner iPhone pairing feature.
