# OwnerCert Fixtures

Place `owner_cert_auth.cbor` from `theyos/tests/fixtures/owner_cert_auth.cbor` here.

Populated by the pre-test sync step (T039d):
```
cp $THEYOS_REPO/tests/fixtures/owner_cert_auth.cbor .
```

This fixture is used by `OwnerCertSignerTests.swift` to validate that Swift-produced
signatures are byte-equal to Rust-validated cases.
