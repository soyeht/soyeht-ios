#!/usr/bin/env python3
"""Emit a well-formed `soyeht://household/pair-machine` URL for the T058
(LAN) and T059 (Tailnet) hardware walkthroughs.

This is the **non-tampered** companion to
`generate_tampered_pair_machine_url.py`. It produces a URL that the
iPhone-side `PairMachineQR` parser MUST accept: `JoinChallenge` is
signed over the same hostname/platform that the URL ships, the nonce
is 32 bytes of CSPRNG entropy, and the TTL is bounded by FR-012
(<=300 s).

The walkthrough operator captures the printed URL (and optionally the
generated keypair PEM, via `--dump-key-pem`) so the resulting
`MachineCert` the founder Mac issues post-acceptance can be verified
out-of-band against the same `m_pub`.

Run via `uv run`:

    uv run --with cbor2 --with cryptography \\
        QA/scripts/generate_pair_machine_url.py \\
        --transport tailscale --addr studio.tailnet:8443

Encode the resulting URL as a QR (the `soyeht://` scheme is not an OS
URL handler — the iPhone reads it from the camera viewfinder):

    qrencode -t ANSIUTF8 -r /tmp/url
    # OR: python -c "import qrcode; qrcode.make(open('/tmp/url').read()).save('qr.png')"
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
    """64-byte raw r||s — matches `CryptoKit.ECDSASignature.rawRepresentation`."""
    der = private_key.sign(message, ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--hostname",
        default="studio.local",
        help="Hostname the candidate publishes (signed AND shipped)",
    )
    parser.add_argument(
        "--platform",
        default="macos",
        choices=["macos", "linux-nix", "linux-other"],
    )
    parser.add_argument(
        "--transport",
        default="lan",
        choices=["lan", "tailscale"],
        help="lan -> T058 walkthrough; tailscale -> T059 walkthrough",
    )
    parser.add_argument(
        "--addr",
        default=None,
        help="Candidate reachable address. Default: studio.local:8443 (lan) / studio.tailnet:8443 (tailscale)",
    )
    parser.add_argument(
        "--ttl-seconds",
        type=int,
        default=240,
        help="TTL window in seconds (must be in (0, 300] — FR-012 hard cap)",
    )
    parser.add_argument(
        "--dump-key-pem",
        type=str,
        default=None,
        help="Path to write the candidate private key PEM (for post-flight cert verification)",
    )
    args = parser.parse_args()

    if args.ttl_seconds <= 0 or args.ttl_seconds > 300:
        parser.error("--ttl-seconds must be in (0, 300] — FR-012 hard cap")

    addr = args.addr or (
        "studio.tailnet:8443" if args.transport == "tailscale" else "studio.local:8443"
    )

    private_key = ec.generate_private_key(ec.SECP256R1())
    machine_pub = compressed_p256_pubkey(private_key.public_key())
    nonce = secrets.token_bytes(32)

    challenge = join_challenge_cbor(
        machine_pub=machine_pub,
        nonce=nonce,
        hostname=args.hostname,
        platform=args.platform,
    )
    signature = raw_p256_signature(private_key=private_key, message=challenge)

    expiry = int(time.time()) + args.ttl_seconds
    params = {
        "v": "1",
        "m_pub": b64url(machine_pub),
        "nonce": b64url(nonce),
        "hostname": args.hostname,
        "platform": args.platform,
        "transport": args.transport,
        "addr": addr,
        "challenge_sig": b64url(signature),
        "ttl": str(expiry),
    }
    url = "soyeht://household/pair-machine?" + urlencode(params)
    print(url)

    if args.dump_key_pem:
        pem = private_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
        with open(args.dump_key_pem, "wb") as fh:
            fh.write(pem)
        print(f"# wrote candidate private key to {args.dump_key_pem}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
