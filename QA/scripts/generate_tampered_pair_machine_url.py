#!/usr/bin/env python3
"""Emit a tampered `soyeht://household/pair-machine` URL for the T062
hardware walkthrough.

The tamper inverts the FR-029 anti-phishing gate: the candidate signs a
`JoinChallenge` over hostname A; the URL ships hostname B with the
original signature attached. The iPhone reconstructs the challenge from
the URL fields, verifies the signature, and rejects locally — no
network call.

Mirrors `HouseholdCBOR.joinChallenge` byte-for-byte: canonical CBOR map
with keys `hostname, m_pub, nonce, platform, purpose, v` sorted
lex-on-encoded-key, definite-length, no indefinite-length items.

Run via `uv run`:

    uv run --with cbor2 --with cryptography \
        QA/scripts/generate_tampered_pair_machine_url.py

The output is a single URL line ready to encode as QR and scan from the
household home view. Shipping builds do not register `soyeht://` as an OS
URL handler.
"""

from __future__ import annotations

import argparse
import base64
import secrets
import sys
import time
from urllib.parse import urlencode

import cbor2
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def compressed_p256_pubkey(public_key: ec.EllipticCurvePublicKey) -> bytes:
    """SEC1 compressed encoding: 0x02/0x03 prefix + 32-byte X."""
    return public_key.public_bytes(
        encoding=serialization.Encoding.X962,
        format=serialization.PublicFormat.CompressedPoint,
    )


def join_challenge_cbor(
    *,
    machine_pub: bytes,
    nonce: bytes,
    hostname: str,
    platform: str,
) -> bytes:
    """Canonical CBOR matching `HouseholdCBOR.joinChallenge`."""
    payload = {
        "hostname": hostname,
        "m_pub": machine_pub,
        "nonce": nonce,
        "platform": platform,
        "purpose": "machine-join-request",
        "v": 1,
    }
    return cbor2.dumps(payload, canonical=True)


def raw_p256_signature(
    *, private_key: ec.EllipticCurvePrivateKey, message: bytes
) -> bytes:
    """64-byte raw r||s, matching CryptoKit's `ECDSASignature.rawRepresentation`."""
    der = private_key.sign(message, ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--signed-hostname",
        default="studio.local",
        help="Hostname the candidate signed (the truth)",
    )
    parser.add_argument(
        "--tampered-hostname",
        default="evil.local",
        help="Hostname the URL falsely claims (the lie)",
    )
    parser.add_argument(
        "--platform",
        default="macos",
        choices=["macos", "linux-nix", "linux-other"],
    )
    parser.add_argument(
        "--transport",
        default="tailscale",
        choices=["lan", "tailscale"],
    )
    parser.add_argument(
        "--addr",
        default="100.64.1.5:8443",
        help="Candidate reachable address (LAN or Tailnet)",
    )
    parser.add_argument(
        "--ttl-seconds",
        type=int,
        default=240,
        help="TTL window in seconds (must be <= 300 — FR-012 hard cap)",
    )
    args = parser.parse_args()

    if args.ttl_seconds <= 0 or args.ttl_seconds > 300:
        parser.error("--ttl-seconds must be in (0, 300] — FR-012 hard cap")

    if args.signed_hostname == args.tampered_hostname:
        print(
            "refusing to emit a non-tampered URL — pass --tampered-hostname different from --signed-hostname",
            file=sys.stderr,
        )
        return 2

    private_key = ec.generate_private_key(ec.SECP256R1())
    machine_pub = compressed_p256_pubkey(private_key.public_key())
    # 32-byte nonce drawn from the OS CSPRNG so the entropy distribution
    # matches the real candidate path the iPhone validates against (FR-014).
    # The earlier `time_ns * 4` shortcut was deterministic but left the 24
    # high bytes pinned to 0x00, which made the tampered-QR fixture
    # structurally distinguishable from a real one and could mask
    # nonce-coverage regressions in downstream tests.
    nonce = secrets.token_bytes(32)

    challenge = join_challenge_cbor(
        machine_pub=machine_pub,
        nonce=nonce,
        hostname=args.signed_hostname,
        platform=args.platform,
    )
    signature = raw_p256_signature(private_key=private_key, message=challenge)

    expiry = int(time.time()) + args.ttl_seconds
    params = {
        "v": "1",
        "m_pub": b64url(machine_pub),
        "nonce": b64url(nonce),
        "hostname": args.tampered_hostname,
        "platform": args.platform,
        "transport": args.transport,
        "addr": args.addr,
        "challenge_sig": b64url(signature),
        "ttl": str(expiry),
    }
    url = "soyeht://household/pair-machine?" + urlencode(params)
    print(url)
    return 0


if __name__ == "__main__":
    sys.exit(main())
