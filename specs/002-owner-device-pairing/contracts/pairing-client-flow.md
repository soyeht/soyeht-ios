# Contract: Pairing Client Flow

## Sequence

1. User scans or pastes `soyeht://household/pair-device`.
2. App validates URL and derives `householdId` from `hh_pub`.
3. App browses `_soyeht-household._tcp` and selects only a service whose household id and pairing nonce match the QR.
4. App creates Secure Enclave-backed first-owner person key.
5. App signs deterministic pairing proof context.
6. App posts confirm request to theyOS.
7. App validates returned PersonCert against QR household public key and local person public key.
8. App persists `ActiveHouseholdState`, PersonCert, and private-key reference.
9. App enters paired household state.

## Confirm Request

The iOS client sends the body documented by the theyOS companion contract:

```json
{
  "v": 1,
  "nonce": "base64url-32-byte-nonce",
  "p_pub": "base64url-33-byte-sec1-p256-public-key",
  "display_name": "Caio",
  "proof_sig": "base64url-64-byte-raw-p256-signature"
}
```

`proof_sig` signs deterministic CBOR:

```cbor
{
  "v": 1,
  "purpose": "pair-device-confirm",
  "hh_id": "hh_...",
  "nonce": h'...',
  "p_pub": h'...'
}
```

## Success Criteria

The app only activates the household after all of these are true:

- confirm response is successful
- response contains exactly one PersonCert
- response contains no DeviceCert requirement
- PersonCert verifies against QR household public key
- PersonCert `p_pub` and `p_id` match the local owner identity
- owner caveats are present
- local protected storage write succeeds

## Failure States

Failure states are local and recoverable:

- `invalidQR`
- `expiredQR`
- `noMatchingHousehold`
- `identityKeyUnavailable`
- `pairingRejected`
- `firstOwnerAlreadyPaired`
- `certInvalid`
- `storageFailed`
- `networkUnavailable`

No failure state may activate a household session.
