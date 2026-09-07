#!/usr/bin/env python3
"""Exercise the inspector on real signed artifacts and disposable damaged copies.

These are artifact controls. They do not operate a phone or test pairing.
Both real inputs are required; absence is refusal, not a skipped success.
"""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

from inspect_ios_distribution import Refused, digest, inspect_bundle, inspect_ipa, require, unpack


def expect_refusal(label, operation, *, reason=None):
    try:
        operation()
    except (Refused, OSError) as error:
        require(reason is None or reason in str(error),
                f"{label} refused for an unrelated reason: {error}")
        print(f"PASS: {label} refused ({error})")
    else:
        raise AssertionError(f"accepted {label}")


def damage_executable(bundle):
    executable = plistlib.loads((bundle / "Info.plist").read_bytes())["CFBundleExecutable"]
    path = bundle / executable
    with path.open("r+b") as stream:
        stream.seek(4096)
        byte = stream.read(1)
        require(bool(byte), "fixture executable is too small")
        stream.seek(4096)
        stream.write(bytes([byte[0] ^ 1]))


def change_extension_identity(bundle, existing):
    # Keep the count unchanged: checking only the number of extensions must
    # not satisfy the policy that names the expected extensions.
    info_path = bundle / existing / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["CFBundleIdentifier"] = "com.soyeht.app.Unexpected"
    info_path.write_bytes(plistlib.dumps(info))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--development-app", type=Path, required=True)
    args = parser.parse_args()
    require(args.ipa.is_file() and args.development_app.is_dir(), "real fixtures are required")
    original = digest(args.ipa)
    report = inspect_ipa(args.ipa)
    require(report["artifact_checks"] == "passed", "positive artifact control failed")
    require(report["delivery"] == "not_observed" and report["pairing"] == "not_measured",
            "artifact inspection claimed runtime acceptance")
    print("PASS: real App Store export accepted, delivery and pairing still unmeasured")

    # This control must start with a VALID development signature. Otherwise a
    # damaged file would test corruption rejection rather than channel rejection.
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict",
                    str(args.development_app)], check=True, capture_output=True)
    expect_refusal("valid development-signed app",
                   lambda: inspect_bundle(args.development_app, root=True),
                   reason="not signed with a distribution identity")

    with tempfile.TemporaryDirectory(prefix="soyeht-artifact-controls-") as directory:
        root = Path(directory)
        unpack(args.ipa, root / "original")
        original_app = next((root / "original" / "Payload").glob("*.app"))
        extension = next(original_app.rglob("*.appex"))
        cases = [
            ("changed app executable", lambda app: damage_executable(app), None),
            ("changed extension executable", lambda app: damage_executable(
                app / extension.relative_to(original_app)), None),
            ("missing profile", lambda app: (app / "embedded.mobileprovision").unlink(), None),
            ("missing extension", lambda app: shutil.rmtree(
                app / extension.relative_to(original_app)), "unexpected extension inventory"),
            ("unexpected extension with unchanged count", lambda app: change_extension_identity(
                app, extension.relative_to(original_app)), "unexpected extension inventory"),
            # Keep the set of identifiers unchanged, but duplicate one. A set
            # comparison alone must not accept the extra extension.
            ("duplicate extension with unchanged identity set", lambda app: shutil.copytree(
                app / extension.relative_to(original_app), app / "PlugIns" / "Duplicate.appex"),
             "unexpected extension inventory"),
        ]
        for index, (label, mutate, reason) in enumerate(cases):
            app = root / f"case-{index}" / "Soyeht.app"
            shutil.copytree(original_app, app)
            mutate(app)
            expect_refusal(label, lambda: inspect_bundle(app, root=True), reason=reason)
    require(digest(args.ipa) == original, "input IPA was modified")
    print("Artifact controls: 8/8; input IPA unchanged. No device behavior was tested.")


if __name__ == "__main__":
    main()
