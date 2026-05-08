# Data Model: Phase 2 - Owner Device Pairing

## PairDeviceQR

Parsed install-time pairing URL.

| Field | Type | Rules |
|---|---|---|
| `version` | Int | MUST be `1` |
| `householdPublicKey` | Data | 33-byte SEC1 compressed P-256 public key |
| `householdId` | String | Derived from `householdPublicKey` |
| `nonce` | Data | 32 bytes |
| `expiresAt` | Date | Must be in the future |
| `criticalFields` | [String] | Unknown critical fields reject parsing |

State:
- `parsed` after URL validation.
- `expired` if current time is later than `expiresAt`.
- `unsupported` if version is not supported.

## HouseholdDiscoveryCandidate

Bonjour result for `_soyeht-household._tcp`.

| Field | Type | Rules |
|---|---|---|
| `endpoint` | URL/host-port | Must be reachable over local network |
| `householdId` | String | Must match QR-derived household id |
| `householdName` | String | Display only after identity match |
| `machineId` | String | Informational in this phase |
| `pairingState` | String | Must be `device` per theyos `docs/household-protocol.md` §13 (canonical) |
| `shortNonce` | String | Must match the active QR nonce prefix according to backend contract |

## OwnerPersonIdentity

Local first-owner person identity.

| Field | Type | Rules |
|---|---|---|
| `personId` | String | Derived from `personPublicKey` |
| `personPublicKey` | Data | 33-byte SEC1 compressed P-256 |
| `privateKeyReference` | Keychain reference/label | Non-exportable; this-device-only |
| `createdAt` | Date | Local creation time |
| `biometryPolicy` | String | Biometric signing required in production |

No private scalar is stored, logged, exported, or syncable.

## PairingProofContext

Canonical signed payload sent to theyOS.

| Field | Type | Rules |
|---|---|---|
| `version` | Int | MUST be `1` |
| `purpose` | String | `pair-device-confirm` |
| `householdId` | String | QR-derived household id |
| `nonce` | Data | QR nonce |
| `personPublicKey` | Data | Owner public key |

## PersonCert

Owner capability certificate returned by theyOS.

| Field | Type | Rules |
|---|---|---|
| `version` | Int | MUST be `1` |
| `type` | String | `person` |
| `householdId` | String | Must match QR household id |
| `personId` | String | Must match local OwnerPersonIdentity |
| `personPublicKey` | Data | Must match local OwnerPersonIdentity public key |
| `displayName` | String | Display value |
| `caveats` | [Caveat] | Must include owner capability set |
| `notBefore` | Date | Must be active |
| `notAfter` | Date? | Nil means no expiry |
| `issuedBy` | String | Household root subject |
| `signature` | Data | 64-byte P-256 raw signature |

Validation:
- Decode deterministic CBOR.
- Recompute person id.
- Verify signature chain to QR household public key.
- Validate owner caveats.
- Reject any DeviceCert requirement in this phase.

## ActiveHouseholdState

Local paired-household state.

| Field | Type | Rules |
|---|---|---|
| `householdId` | String | Stable active household id |
| `householdName` | String | User-facing display, e.g. `Casa Caio` |
| `endpoint` | URL | Last verified theyOS endpoint |
| `ownerPersonId` | String | Matches OwnerPersonIdentity and PersonCert |
| `personCert` | PersonCert | Validated before activation |
| `pairedAt` | Date | Successful pairing time |
| `lastSeenAt` | Date? | Updated after live requests |

States:
- `unpaired`
- `pairing(qr)`
- `pairedOnline`
- `pairedOfflineReadOnly`
- `failed(reason)`

## ProofOfPossessionAuthorization

Signed household request authorization.

| Field | Type | Rules |
|---|---|---|
| `method` | String | Uppercase HTTP method |
| `pathAndQuery` | String | Exact request target |
| `timestamp` | Date | Current time |
| `bodyHash` | Data | BLAKE3-256 over body bytes |
| `signature` | Data | 64-byte P-256 raw signature |
| `authorizationHeader` | String | `Soyeht-PoP ...` |

Bearer authorization is forbidden for household-scoped requests.
