#!/usr/bin/env python3
"""Require both checkouts and exercise producer receipt -> consumer validation."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--theyos-repo", required=True, type=Path)
    args = parser.parse_args()
    consumer = Path(__file__).resolve().parent
    producer = args.theyos_repo / "scripts/engine-artifact-receipt.py"
    checker = consumer / "engine-artifact-receipt.py"
    if not producer.is_file() or producer.read_bytes() != checker.read_bytes():
        parser.exit(1, "error: receipt checker differs from the producer; both checkouts are required\n")
    with tempfile.TemporaryDirectory(prefix="engine-package-contract-") as directory:
        root = Path(directory)
        binary, metadata, receipt = (root / name for name in ("engine", "artifact.json", "receipt.json"))
        uuid = bytes(range(16))
        binary.write_bytes(struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0)
                           + struct.pack("<II", 0x1B, 24) + uuid)
        metadata.write_text(json.dumps({"version": "0.0.1", "git_sha": "fixture",
                                        "image_uuid": uuid.hex(), "pty_supervisor_protocol": 2}))
        subprocess.run([sys.executable, str(producer), str(binary), str(receipt),
                        "--from-build-info", str(metadata)], check=True, timeout=10)
        subprocess.run([sys.executable, str(checker), str(binary), str(receipt)], check=True, timeout=10)
        record = json.loads(receipt.read_text())
        if record["executable_sha256"] != hashlib.sha256(binary.read_bytes()).hexdigest():
            parser.exit(1, "error: producer emitted an incorrect executable hash\n")
        # A changed producer field must fail in the actual consumer CLI.
        record["artifact"]["loaded_image_uuid"] = record["artifact"].pop("image_uuid")
        receipt.write_text(json.dumps(record))
        negative = subprocess.run([sys.executable, str(checker), str(binary), str(receipt)],
                                  capture_output=True, text=True, timeout=10)
        if negative.returncode == 0 or "incompatible engine package" not in negative.stderr:
            parser.exit(1, "error: malformed producer receipt did not produce the expected consumer refusal\n")
    subprocess.run([sys.executable, str(consumer / "test-engine-artifact-receipt.py")], check=True)
    print("Engine package contract: producer/consumer agree; changed field refused; package failure controls passed.")


if __name__ == "__main__":
    main()
