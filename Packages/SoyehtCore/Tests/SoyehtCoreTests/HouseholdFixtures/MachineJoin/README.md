# MachineJoin Test Fixtures

Cross-repo fixtures consumed by Phase 3 tests (`specs/003-machine-join/`).

## Files

- `fingerprint_vectors.json` — **VENDORED 2026-05-07**, byte-identical clone of `theyos/specs/003-machine-join/tests/fingerprint_vectors.json` (SHA-256 `09b027c74bb517781745460f4508a96ba1a1c3133b96e90a137b6b5789c1d54f`, 16 golden tuples `{ index, m_pub_sec1_hex, fingerprint, fingerprint_words: [String × 6] }`). Covers the BLAKE3-256 → 66-bit → 6 × BIP-39 English derivation and is consumed byte-for-byte by `OperatorFingerprintTests.crossRepoFingerprintBindingMatchesTheyos` per spec SC-004. Registered as a `.copy` resource in `Package.swift`'s test target. Do not regenerate locally — the cross-repo binding only holds when both sides read the same bytes.

## Vendoring rules

1. Copy the file from `theyos/specs/003-machine-join/tests/<name>` without re-formatting (preserve line endings and whitespace exactly).
2. Run `shasum -a 256` on both copies and confirm they match before committing.
3. When the upstream file changes, re-vendor and run `swift test --filter OperatorFingerprintTests` to confirm the iPhone derivation still matches.
4. Never edit the file in place — the cross-repo binding test (SC-004) treats this fixture as the canonical reference.

## Why a separate subdirectory

`HouseholdFixtures/` already holds Phase 2 (owner-pairing) artefacts. Keeping Phase 3 fixtures under `MachineJoin/` lets each phase's binding fixtures live and be vendored independently.
