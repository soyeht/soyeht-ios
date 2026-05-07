# Contract: Household Snapshot

This local iPhone contract closes the snapshot envelope required by T021c/T021d.
The base snapshot body comes from protocol section 10. Theyos must co-version a
dedicated contract before production snapshot bootstrap ships.

## Endpoint

```http
GET /api/v1/household/snapshot
Authorization: Soyeht-PoP ...
Accept: application/cbor
```

The iPhone fetches this once after Phase 2 household session activation and
before starting the gossip consumer.

## Envelope

```cbor
HouseholdSnapshotEnvelope = {
  "v": 1,
  "snapshot": HouseholdSnapshotBody,
  "signature": bytes(64)
}
```

`signature` is raw P-256 ECDSA `r || s` over canonical CBOR of
`HouseholdSnapshotBody`, verified directly against stored `hh_pub`.

## Body

```cbor
HouseholdSnapshotBody = {
  "v": 1,
  "hh_id": text,
  "as_of_cursor": uint / bytes,
  "as_of_vc": map,
  "household": HouseholdRecord,
  "machines": [MachineCert],
  "people": [PersonCert],
  "devices": [DeviceCert],
  "claws": [ClawRecord],
  "crl": [RevocationEntry],
  "head_event_hash": bytes(32),
  "issued_at": uint
}
```

For the iPhone Phase 3 implementation, only these fields are required to mutate
local state:

- `hh_id`
- `as_of_cursor` or `as_of_vc`
- `machines`
- `crl`
- `head_event_hash`
- `issued_at`

Other arrays may be decoded and ignored until their features ship.

## RevocationEntry

```cbor
RevocationEntry = {
  "subject_id": text,
  "revoked_at": uint,
  "reason": text,
  "cascade": "self_only" | "machine_and_dependents",
  "signature": bytes(64)
}
```

Snapshot CRL entries seed `CRLStore` before any MachineCert from the same
snapshot is accepted into `HouseholdMembershipStore`.

## Verification Recipe

1. Require `Content-Type: application/cbor`.
2. Decode envelope as deterministic CBOR.
3. Require envelope `v == 1`.
4. Re-encode `snapshot` canonically and verify `signature` under local `hh_pub`.
5. Require `snapshot.hh_id == local hh_id`.
6. Validate every CRL entry signature according to the revocation contract.
7. Seed an in-memory CRL view with snapshot CRL entries.
8. Decode each `MachineCert` from `machines`.
9. Validate each MachineCert against local `hh_pub`, `hh_id`, and the seeded
   CRL view.
10. Build `HouseholdMember` projections from non-revoked certs.
11. Commit CRL and members atomically.
12. Persist the snapshot cursor/vector-clock token for gossip resume.

Any failure aborts the entire snapshot application. No partial CRL or membership
state may be committed.

## Atomic Application

The bootstrapper prepares all state off to the side, then commits in one
operation:

1. `CRLStore.seedFromSnapshot(entries, snapshotCursor)`.
2. Replace or initialize `HouseholdMembershipStore` with validated members.
3. Persist resume cursor.
4. Start `HouseholdGossipConsumer`.

If gossip starts before snapshot commits, a revoked historical machine can slip
through as a fresh `machine_added` delta. That violates SC-011.

## Errors

| Condition | Swift error |
|---|---|
| wrong content type | `MachineJoinError.protocolViolation(.wrongContentType)` |
| malformed CBOR | `MachineJoinError.protocolViolation(.unexpectedResponseShape)` |
| bad snapshot signature | `MachineJoinError.certValidationFailed(.signatureInvalid)` |
| household mismatch | `MachineJoinError.hhMismatch` |
| revoked MachineCert in snapshot | excluded from membership; logged as CRL-seeded rejection |
| invalid MachineCert | `MachineJoinError.certValidationFailed(...)` |

## Open Cross-Repo Item

Theyos protocol documentation currently defines the snapshot body, but the
dedicated Phase 3 contract file has not yet pinned this root-signed envelope.
Do not implement production `HouseholdSnapshotBootstrapper` until theyos accepts
or revises this envelope.
