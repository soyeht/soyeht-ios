#!/usr/bin/env python3
"""Package failure controls; fixtures are files, never running services."""
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("receipt", Path(__file__).with_name("engine-artifact-receipt.py"))
receipt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipt)


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.binary = Path(self.scratch.name) / "engine"
        self.metadata = self.binary.with_suffix(".json")
        self.uuid = bytes(range(16))
        self.image = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0)
        self.image += struct.pack("<II", 0x1B, 24) + self.uuid
        self.binary.write_bytes(self.image)
        self.record = {"artifact": {"version": "0.0.1", "git_sha": "fixture",
                                    "image_uuid": self.uuid.hex(), "pty_supervisor_protocol": 2},
                       "executable_sha256": receipt.digest(self.binary)}
        self.write_record()

    def write_record(self):
        self.metadata.write_text(json.dumps(self.record))

    def test_valid_package(self):
        self.assertEqual(receipt.validate(self.binary, self.metadata), self.record)

    def test_changed_bytes_with_same_uuid_are_rejected(self):
        self.binary.write_bytes(self.image + b"changed")
        with self.assertRaisesRegex(ValueError, "differs from receipt"):
            receipt.validate(self.binary, self.metadata)

    def test_rebind_requires_same_image(self):
        self.binary.write_bytes(self.image[:-1] + b"X")
        with self.assertRaisesRegex(ValueError, "another linked image"):
            receipt.validate(self.binary, self.metadata, rebind=True)

    def test_controlled_signing_rebinds_bytes(self):
        self.binary.write_bytes(self.image + b"signature")
        updated = receipt.validate(self.binary, self.metadata, rebind=True)
        self.assertNotEqual(updated["executable_sha256"], self.record["executable_sha256"])
        self.assertEqual(updated["artifact"], self.record["artifact"])
        self.metadata.write_text(json.dumps(updated))
        receipt.validate(self.binary, self.metadata)

    def test_absent_receipt_is_not_legacy_compatibility(self):
        self.metadata.unlink()
        with self.assertRaises(FileNotFoundError):
            receipt.validate(self.binary, self.metadata)

    def test_fat_binary_is_rejected(self):
        self.binary.write_bytes(struct.pack(">II", 0xCAFEBABE, 2) + b"\0" * 56)
        with self.assertRaisesRegex(ValueError, "thin arm64"):
            receipt.validate(self.binary, self.metadata)

    def test_duplicate_uuid_is_rejected(self):
        header = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 2, 48, 0, 0)
        self.binary.write_bytes(header + self.image[32:] * 2)
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            receipt.validate(self.binary, self.metadata)

    def test_truncated_load_command_is_rejected(self):
        self.binary.write_bytes(self.image[:-1])
        with self.assertRaisesRegex(ValueError, "truncated"):
            receipt.validate(self.binary, self.metadata)

    def test_embed_verifies_input_and_rebinds_after_signing(self):
        repo = Path(__file__).resolve().parent.parent
        manifest = json.loads((repo / "Packages/SoyehtCore/Sources/SoyehtCore/Resources/embedded-engine-helpers.json").read_text())
        stage = Path(self.scratch.name) / "stage"
        stage.mkdir()
        for name in manifest["executables"]:
            (stage / name).write_bytes(self.image)
        receipt_path = stage / manifest["artifactReceipt"]
        receipt_path.write_text(json.dumps(self.record))
        fake_tools = Path(self.scratch.name) / "tools"
        fake_tools.mkdir()
        # Model codesign's file mutation, not its signature validity. No
        # helper is executable Mach-O in this fixture; invoking one would fail.
        signer = fake_tools / "codesign"
        signer.write_text('#!/bin/bash\nfor last; do :; done\nprintf signature >> "$last"\n')
        signer.chmod(0o700)
        app = Path(self.scratch.name) / "Sample.app"
        env = dict(os.environ, THEYOS_BUILD_DIR=str(stage), SRCROOT=str(repo / "TerminalApp"),
                   CONFIGURATION="Release", CODESIGNING_FOLDER_PATH=str(app), CODE_SIGN_IDENTITY="-",
                   PATH=str(fake_tools) + os.pathsep + os.environ["PATH"])
        def embed():
            return subprocess.run(["bash", str(repo / "scripts/embed-engine.sh")], env=env,
                                  capture_output=True, text=True, timeout=20)
        # Real script must refuse omission, not just the standalone checker.
        (stage / "soyeht-ptyd").unlink()
        self.assertNotEqual(embed().returncode, 0)
        self.assertFalse((app / "Contents/Helpers/theyos-engine").exists())
        (stage / "soyeht-ptyd").write_bytes(self.image)
        receipt_path.unlink()
        self.assertNotEqual(embed().returncode, 0)
        receipt_path.write_text(json.dumps(self.record))
        (stage / "theyos-engine").write_bytes(self.image + b"wrong")
        self.assertNotEqual(embed().returncode, 0)
        self.assertFalse((app / "Contents/Helpers/theyos-engine").exists())
        (stage / "theyos-engine").write_bytes(self.image)
        result = embed()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        helpers = app / "Contents/Helpers"
        result = receipt.validate(helpers / "theyos-engine", helpers / manifest["artifactReceipt"])
        self.assertEqual(result["artifact"], self.record["artifact"])
        self.assertNotEqual(result["executable_sha256"], self.record["executable_sha256"])
        for name in manifest["executables"]:
            self.assertEqual((helpers / name).read_bytes(), self.image + b"signature")


if __name__ == "__main__":
    unittest.main()
