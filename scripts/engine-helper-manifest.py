#!/usr/bin/env python3
"""Read the same required helper manifest packaged in SoyehtCore."""
import argparse
import json
import re
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--support-only", action="store_true")
    parser.add_argument("--all-files", action="store_true")
    parser.add_argument("--receipt-only", action="store_true")
    parser.add_argument("--bundle-receipt-path", action="store_true")
    args = parser.parse_args()
    path = Path(__file__).resolve().parent.parent / "Packages/SoyehtCore/Sources/SoyehtCore/Resources/embedded-engine-helpers.json"
    manifest = json.loads(path.read_text())
    names = manifest.get("executables")
    receipt = manifest.get("artifactReceipt")
    receipt_directory = manifest.get("artifactReceiptBundleDirectory")
    if (not isinstance(names, list) or not all(isinstance(name, str) and re.fullmatch(r"[a-z0-9][a-z0-9_-]*", name) for name in names)
            or len(set(names)) != len(names) or not {"theyos-engine", "soyeht-ptyd"}.issubset(names)):
        raise SystemExit("Invalid embedded engine helper manifest")
    if not isinstance(receipt, str) or not re.fullmatch(r"[a-z0-9][a-z0-9_-]*\.json", receipt):
        raise SystemExit("Invalid engine artifact receipt name")
    if not isinstance(receipt_directory, str) or not re.fullmatch(r"Contents/Resources/[A-Za-z0-9_-]+", receipt_directory):
        raise SystemExit("Invalid engine artifact receipt bundle directory")
    if args.bundle_receipt_path:
        print(f"{receipt_directory}/{receipt}")
        return
    if args.receipt_only:
        print(receipt)
        return
    for name in names:
        if not args.support_only or name != "theyos-engine":
            print(name)
    if args.all_files:
        print(receipt)


if __name__ == "__main__":
    main()
