#!/usr/bin/env python3
"""Read an exported Soyeht IPA without executing or installing its code.

This preflight checks the local export, NOT TestFlight delivery or pairing.
An App Store export is an input to device acceptance, never its substitute.
Only Apple tooling reads signatures/profiles; no credentials are requested.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import stat
import subprocess
import tempfile
import unicodedata
import zipfile


BUNDLE_ID = "com.soyeht.app"
TEAM_ID = "W7677A5BK2"
# The production app's accepted composition. Change this deliberately when
# adding/removing a product extension, alongside its distribution review.
EXTENSION_IDS = frozenset({
    BUNDLE_ID + ".HouseCreatedNotificationService",
    BUNDLE_ID + ".SoyehtLiveActivity",
})
MAX_UNPACKED_BYTES = 3 * 1024**3


class Refused(ValueError):
    pass


def digest(path: Path) -> str:
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def run(argv: list[str]) -> subprocess.CompletedProcess:
    result = subprocess.run(argv, capture_output=True, timeout=60)
    if result.returncode:
        # Raw codesign/profile output may contain names and device identifiers.
        raise Refused(f"{Path(argv[0]).name} failed (exit {result.returncode})")
    return result


def require(condition: bool, message: str) -> None:
    if not condition:
        raise Refused(message)


def unpack(ipa: Path, destination: Path) -> None:
    """Reject ambiguous/escaping archives before writing into a private temp dir."""
    with zipfile.ZipFile(ipa) as archive:
        entries = archive.infolist()
        require(len(entries) <= 100_000, "too many IPA entries")
        require(sum(item.file_size for item in entries) <= MAX_UNPACKED_BYTES,
                "IPA exceeds the unpacked size limit")
        names: set[str] = set()
        for item in entries:
            name = item.filename.rstrip("/")
            path = PurePosixPath(name)
            require(bool(name) and not path.is_absolute()
                    and ".." not in path.parts and "\\" not in name
                    and str(path) == name, "unsafe IPA entry path")
            # Default macOS filesystems also alias names differing only in case.
            filesystem_name = unicodedata.normalize("NFD", name).casefold()
            require(filesystem_name not in names, "duplicate IPA entry path")
            names.add(filesystem_name)
            kind = stat.S_IFMT(item.external_attr >> 16)
            require(kind in (0, stat.S_IFREG, stat.S_IFDIR),
                    "non-regular IPA entry (including a symlink)")
        archive.extractall(destination)


def inspect_bundle(bundle: Path, *, root: bool, version: tuple | None = None) -> dict:
    info = plistlib.loads((bundle / "Info.plist").read_bytes())
    identifier = info["CFBundleIdentifier"]
    require(identifier == BUNDLE_ID if root else identifier.startswith(BUNDLE_ID + "."),
            "bundle does not belong to the production Soyeht app")
    require(info.get("DTPlatformName") == "iphoneos", "not an iPhone device build")
    observed_version = (info["CFBundleShortVersionString"], info["CFBundleVersion"])
    require(all(isinstance(x, str) and x for x in observed_version), "missing app version/build")
    require(version is None or version == observed_version,
            "extension version/build differs from the app")
    if root:
        identifiers = [plistlib.loads((path / "Info.plist").read_bytes())["CFBundleIdentifier"]
                       for path in bundle.rglob("*.appex")]
        require(len(identifiers) == len(EXTENSION_IDS) and set(identifiers) == EXTENSION_IDS,
                "unexpected extension inventory (missing, extra or duplicate extension)")
    executable = info["CFBundleExecutable"]
    require(isinstance(executable, str) and bool(executable)
            and Path(executable).name == executable and executable not in (".", ".."),
            "invalid executable name")
    require((bundle / executable).is_file(), "bundle executable is absent")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R",
         f'=anchor apple generic and certificate leaf[subject.OU] = "{TEAM_ID}"', str(bundle)])
    signature = run(["/usr/bin/codesign", "-d", "--verbose=4", str(bundle)])
    lines = signature.stderr.decode("utf-8", errors="replace").splitlines()
    require(f"TeamIdentifier={TEAM_ID}" in lines, "unexpected signing team")
    require(f"Identifier={identifier}" in lines, "signature identifier differs from Info.plist")
    require(any(line.startswith(("Authority=Apple Distribution:", "Authority=iPhone Distribution:"))
                for line in lines), "not signed with a distribution identity")
    entitlements = plistlib.loads(run([
        "/usr/bin/codesign", "-d", "--entitlements", ":-", str(bundle)]).stdout)
    app_identifier = f"{TEAM_ID}.{identifier}"
    require(entitlements.get("application-identifier") == app_identifier,
            "unexpected effective application identifier")
    require(entitlements.get("com.apple.developer.team-identifier") == TEAM_ID,
            "unexpected effective entitlement team")
    require(entitlements.get("get-task-allow") is False,
            "debug entitlement present or unknown")
    require(entitlements.get("beta-reports-active") is True,
            "missing App Store beta reporting entitlement")
    provision = bundle / "embedded.mobileprovision"
    profile = plistlib.loads(run([
        "/usr/bin/security", "cms", "-D", "-i", str(provision)]).stdout)
    require("ProvisionedDevices" not in profile
            and profile.get("ProvisionsAllDevices", False) is False,
            "development, ad hoc or enterprise provisioning is not App Store provisioning")
    expiration = profile.get("ExpirationDate")
    require(isinstance(expiration, datetime)
            and expiration.replace(tzinfo=timezone.utc) > datetime.now(timezone.utc),
            "provisioning profile expired or has no readable expiry")
    profile_entitlements = profile["Entitlements"]
    require(profile_entitlements.get("application-identifier") == app_identifier
            and profile_entitlements.get("com.apple.developer.team-identifier") == TEAM_ID
            and profile_entitlements.get("get-task-allow") is False
            and profile_entitlements.get("beta-reports-active") is True,
            "profile does not describe this App Store application")
    if root:
        require(entitlements.get("aps-environment") == "production",
                "production app has no production push entitlement")
        require(set(entitlements.get("keychain-access-groups", [])) == {
            f"{TEAM_ID}.com.soyeht.app", f"{TEAM_ID}.com.soyeht.mobile.clawshare.mesh"},
                "production keychain groups changed; review update compatibility")
        require(set(entitlements.get("com.apple.security.application-groups", [])) == {
            "group.com.soyeht.mobile.clawshare"}, "production application groups changed")
    return {
        "bundle_id": identifier, "version": observed_version[0], "build": observed_version[1],
        "executable_sha256": digest(bundle / executable),
        "profile_sha256": digest(provision), "profile_expires_utc": expiration.isoformat() + "Z",
        "team_id": TEAM_ID, "get_task_allow": False,
        "minimum_os": info.get("MinimumOSVersion"),
        "keychain_groups": sorted(entitlements.get("keychain-access-groups", [])),
    }


def inspect_ipa(ipa: Path) -> dict:
    before = digest(ipa)
    with tempfile.TemporaryDirectory(prefix="soyeht-ios-artifact-") as directory:
        extracted = Path(directory)
        unpack(ipa, extracted)
        apps = list((extracted / "Payload").glob("*.app"))
        require(len(apps) == 1, "expected exactly one payload app")
        app = apps[0]
        require(not list(app.rglob("*.app")), "nested apps need an explicit acceptance policy")
        observed = inspect_bundle(app, root=True)
        version = (observed["version"], observed["build"])
        extensions = [inspect_bundle(path, root=False, version=version)
                      for path in sorted(app.rglob("*.appex"))]
    require(digest(ipa) == before, "IPA changed during inspection")
    return {
        "schema_version": 1, "kind": "ios-export-inspection",
        "artifact_checks": "passed", "ipa_sha256": before,
        "app": observed, "extensions": extensions,
        "delivery": "not_observed", "pairing": "not_measured",
        "limits": ["Does not prove upload, installation, TestFlight processing or device behavior.",
                   "Apple may transform the upload. Bind installed evidence to the ASC build, not this IPA hash.",
                   "No source commit is inferred from version, signature or filename."],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--output", type=Path, help="new JSON file; refuses to overwrite")
    args = parser.parse_args()
    try:
        report = inspect_ipa(args.ipa)
        rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
        if args.output:
            with args.output.open("x") as output:
                output.write(rendered)
        else:
            print(rendered, end="")
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile,
            plistlib.InvalidFileException, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"IPA inspection REFUSED: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
