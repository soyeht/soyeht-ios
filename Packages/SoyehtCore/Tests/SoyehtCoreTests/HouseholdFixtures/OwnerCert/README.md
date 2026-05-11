# OwnerCert Fixtures

Place `owner_cert_auth.cbor` from `theyos/admin/rust/server-rs/tests/fixtures/owner_cert_auth.cbor` here.

Populated by the sync script (T039d):
```
scripts/sync-cross-repo-fixtures.sh
```

This fixture is used by `OwnerCertSignerTests.swift` to validate that Swift-produced
signatures are byte-equal to Rust-validated cases.
