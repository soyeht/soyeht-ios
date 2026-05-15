# Contract: Operator Authorization

Co-versioned with theyos:
`/Users/macstudio/Documents/theyos/specs/003-machine-join/contracts/owner-events.md`.

The iPhone authorizes a candidate join by signing an inner canonical CBOR
context with the owner PersonCert key after biometric authentication. The iPhone
does not sign `MachineCert`.

## Endpoint

```http
POST /api/v1/household/owner-events/<cursor>/approve
Authorization: Soyeht-PoP ...
Content-Type: application/cbor
```

Decline is path-disambiguated:

```http
POST /api/v1/household/owner-events/<cursor>/decline
Authorization: Soyeht-PoP ...
```

The current theyos contract defines decline with an empty body. Approval uses
the body below.

## Signed Context

```cbor
OwnerApprovalContext = {
  "v": 1,
  "purpose": "owner-approve-join",
  "hh_id": text,
  "p_id": text,
  "cursor": uint,
  "challenge_sig": bytes(64),
  "timestamp": uint
}
```

`challenge_sig` is the candidate install-time signature copied verbatim from
the `JoinRequest` being approved. It transitively binds `m_pub`, `nonce`,
`hostname`, and `platform` without duplicating those fields in the approval
context.

## Wire Body

```cbor
OwnerApproval = {
  "v": 1,
  "cursor": uint,
  "approval_sig": bytes(64)
}
```

`approval_sig = P-256-ECDSA-rs64(owner_p_priv, canonical(OwnerApprovalContext))`.

## Canonical CBOR Rules

- deterministic CBOR per RFC 8949 section 4.2.1;
- definite lengths only;
- shortest integer encodings;
- byte strings encode as major type 2;
- text keys encode as major type 3;
- map keys are sorted by encoded key bytes;
- no floating point, indefinite-length values, tags, or non-text map keys.

The Swift canonical encoders live in `HouseholdCBOR.ownerApprovalContext` and
`HouseholdCBOR.ownerApprovalBody`.

## iPhone Signing Preconditions

The signer must verify before calling the owner identity key:

- active household session exists;
- `JoinRequestEnvelope.householdId == localHouseholdId`;
- owner PersonCert `p_id` is available;
- request has not expired by local queue TTL;
- biometric-only Secure Enclave signing is available.

Biometric policy is `deviceOwnerAuthenticationWithBiometrics` semantics through
the Secure Enclave access control. Passcode fallback is not an approval path.

## Server Verification Recipe

Theyos validates:

1. Soyeht-PoP header under the owner PersonCert.
2. Request `Content-Type` is `application/cbor`.
3. Path cursor equals body `cursor`.
4. Reconstructed `OwnerApprovalContext.cursor` equals active
   `PairMachineWindow.owner_event_cursor`.
5. `challenge_sig` bit-equals the active cached `JoinRequest.challenge_sig`.
6. `hh_id` equals local household id.
7. `p_id` equals the owner PersonCert subject.
8. `timestamp` is within the replay window.
9. `approval_sig` verifies under owner `p_pub`.

Any failure returns the generic Phase 3 CBOR error shape.

## Responses

Success:

```cbor
OwnerApprovalAck = {
  "v": 1,
  "machine_cert_hash": bytes(32)
}
```

Failure:

```cbor
{ "v": 1, "error": "unauthenticated" }
```

with `Content-Type: application/cbor`.

## Local Errors

| Condition | Swift error |
|---|---|
| household mismatch | `MachineJoinError.hhMismatch` |
| biometric cancel | `MachineJoinError.biometricCancel` |
| biometric lockout | `MachineJoinError.biometricLockout` |
| Secure Enclave signing failure | `MachineJoinError.signingFailed` |
| CBOR/content-type mismatch | `MachineJoinError.protocolViolation` |
| server CBOR error | `MachineJoinError.serverError` or mapped typed case |
