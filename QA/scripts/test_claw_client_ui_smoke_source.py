#!/usr/bin/env python3
from __future__ import annotations

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SMOKE_SCRIPT = REPO_ROOT / "QA/scripts/run_claw_client_ui_smoke.py"
MATRIX_SCRIPT = REPO_ROOT / "QA/scripts/run_claw_store_matrix.py"


class ClawClientUISmokeSourceTests(unittest.TestCase):
    def test_smoke_defaults_to_dev_bundle_and_refuses_shipping(self) -> None:
        source = SMOKE_SCRIPT.read_text(encoding="utf-8")

        self.assertIn('DEFAULT_BUNDLE_ID = "com.soyeht.app.dev"', source)
        self.assertIn('SHIPPING_BUNDLE_ID = "com.soyeht.app"', source)
        self.assertIn("bundle_id == SHIPPING_BUNDLE_ID", source)
        self.assertIn("refused shipping iOS bundle", source)
        self.assertNotRegex(
            source,
            re.compile(r'os\.environ\.get\("SOYEHT_BUNDLE_ID",\s*"com\.soyeht\.app"\)'),
        )

    def test_smoke_passes_claw_store_e2e_launch_argument(self) -> None:
        source = SMOKE_SCRIPT.read_text(encoding="utf-8")

        self.assertIn('E2E_LAUNCH_ARGUMENT = "-SoyehtClawStoreE2E"', source)
        self.assertIn('UI_TEST_LAUNCH_ARGUMENT = "-SoyehtUITest"', source)
        self.assertIn('"args": [UI_TEST_LAUNCH_ARGUMENT, E2E_LAUNCH_ARGUMENT]', source)

    def test_matrix_row_is_specific_and_default_skipped(self) -> None:
        source = MATRIX_SCRIPT.read_text(encoding="utf-8")

        self.assertIn('row_id="client-ui-ios-dev-smoke"', source)
        self.assertIn("build_client_ui_ios_dev_smoke_row(repo_root)", source)
        self.assertIn("os.environ.get(LIVE_ENV) == \"1\"", source)
        self.assertIn("os.environ.get(CLIENT_UI_ENV) == \"1\"", source)
        self.assertIn('{"SOYEHT_BUNDLE_ID": CLIENT_UI_DEV_BUNDLE_ID}', source)
        self.assertIn('CLIENT_UI_DEV_BUNDLE_ID = "com.soyeht.app.dev"', source)
        self.assertIn("relay_stream_guest_ffi_missing", source)


if __name__ == "__main__":
    unittest.main()
