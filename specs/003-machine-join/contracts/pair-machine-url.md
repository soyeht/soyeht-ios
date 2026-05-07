# Contract: pair-machine URL

Co-versioned with theyos:
`/Users/macstudio/Documents/theyos/specs/003-machine-join/contracts/pair-machine-url.md`
and protocol section 11.

## URI Grammar

```text
pair-machine-uri =
  "soyeht://household/pair-machine?"
  "v=1"
  "&m_pub=" base64url-no-pad-bytes33
  "&nonce=" base64url-no-pad-bytes32
  "&hostname=" pct-encoded-utf8-hostname
  "&platform=" ("macos" / "linux-nix" / "linux-other")
  "&transport=" ("lan" / "tailscale")
  "&addr=" hostport
  "&challenge_sig=" base64url-no-pad-bytes64
  "&ttl=" unix-seconds
```

Query parameter ordering is not security-significant. Consumers must parse by
name and reject duplicate parameters for security-critical fields.

## Field Rules

| Field | Rule |
|---|---|
| `v` | exactly `1` |
| `m_pub` | base64url-no-pad, 33-byte SEC1 compressed P-256 point, prefix `02` or `03` |
| `nonce` | base64url-no-pad, exactly 32 random bytes |
| `hostname` | percent-decoded UTF-8, 1..64 bytes |
| `platform` | exactly `macos`, `linux-nix`, or `linux-other` |
| `transport` | exactly `lan` or `tailscale` |
| `addr` | non-empty host:port reachability hint |
| `challenge_sig` | base64url-no-pad, exactly 64-byte raw P-256 ECDSA `r || s` |
| `ttl` | unix seconds, in the future, max 300 seconds from issuance |

`transport` and `addr` are not signed and are not trust inputs. Tampering them
can cause a failed reachability path only.

## Signed Challenge

The candidate signs this canonical CBOR map before rendering the QR:

```cbor
JoinChallenge = {
  "v": 1,
  "purpose": "machine-join-request",
  "m_pub": bytes(33),
  "nonce": bytes(32),
  "hostname": text,
  "platform": "macos" | "linux-nix" | "linux-other"
}
```

Canonicalization:

- deterministic CBOR per RFC 8949 section 4.2.1;
- shortest integer encodings;
- definite-length byte and text strings;
- map keys sorted by the encoded text-key bytes;
- no unknown fields.

The iPhone reconstructs `JoinChallenge` from the decoded URL fields and verifies
`challenge_sig` under `m_pub` before presenting the confirmation card or
contacting any household member.

## iPhone Consumer Flow

1. Parse scheme, host, path, and query parameters.
2. Validate every field.
3. Reject expired `ttl`.
4. Reconstruct canonical `JoinChallenge`.
5. Verify `challenge_sig` under `m_pub`.
6. Derive the six-word fingerprint from `BLAKE3-256(m_pub)` using the pinned
   BIP-39 English wordlist.
7. Build canonical CBOR `JoinRequest`.
8. Submit `JoinRequest` to the household founding member through
   `POST /api/v1/household/join-request` with Soyeht-PoP.

The iPhone never connects to the candidate address from the QR.

## JoinRequest CBOR

```cbor
JoinRequest = {
  "v": 1,
  "m_pub": bytes(33),
  "hostname": text,
  "platform": "macos" | "linux-nix" | "linux-other",
  "nonce": bytes(32),
  "addr": text,
  "transport": "lan" | "tailscale",
  "challenge_sig": bytes(64)
}
```

Stories converge on this same byte shape:

- QR path: iPhone reconstructs it from the URL.
- Bonjour shortcut: M1 fetches it from M2's local seed endpoint, then stages an
  owner event containing exact `join_request_cbor` bytes.

## Error Taxonomy

| Condition | Swift error |
|---|---|
| wrong scheme/path/version | `MachineJoinError.qrInvalid(.schemaUnsupported)` |
| missing field | `MachineJoinError.qrInvalid(.missingField(name))` |
| invalid `m_pub` | `MachineJoinError.qrInvalid(.invalidPublicKey)` |
| invalid `nonce` | `MachineJoinError.qrInvalid(.invalidNonce)` |
| invalid `hostname` | `MachineJoinError.qrInvalid(.invalidHostname)` |
| unsupported `platform` | `MachineJoinError.qrInvalid(.unsupportedPlatform(value))` |
| unsupported `transport` | `MachineJoinError.qrInvalid(.unsupportedTransport(value))` |
| invalid `addr` | `MachineJoinError.qrInvalid(.invalidAddress)` |
| malformed or failing `challenge_sig` | `MachineJoinError.qrInvalid(.challengeSigInvalid)` |
| malformed or too-large `ttl` | `MachineJoinError.qrInvalid(.ttlOutOfRange)` |
| expired `ttl` | `MachineJoinError.qrExpired` |

## Golden Vectors

Fingerprint vectors are vendored byte-identical from theyos at:

```text
Packages/SoyehtCore/Tests/SoyehtCoreTests/HouseholdFixtures/MachineJoin/fingerprint_vectors.json
```

The fixture validates the `m_pub -> fingerprint` binding. Pair-machine URL
parser tests generate signed URLs locally because each `challenge_sig` requires
the corresponding private key.
