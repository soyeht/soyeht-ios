# Household Fixtures

Fixtures in this directory exercise the Phase 2 first-owner household pairing
protocol. Test data must not contain production keys, bearer tokens, raw
private key material, or live household endpoints.

The fixture set is intentionally scoped to the first owner iPhone flow:
`soyeht://household/pair-device` parsing, PersonCert validation, pairing
proof signing, household session persistence, and Soyeht proof-of-possession
request signing. DeviceCert, invitations, gossip, revocation, and second
machine joins belong to later feature directories.
