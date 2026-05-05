#!/usr/bin/env -S uv run
import runpy
import unittest
from pathlib import Path


MODULE = runpy.run_path(str(Path(__file__).resolve().parents[2] / "scripts" / "soyeht-mcp"))


class SoyehtMCPProtocolTests(unittest.TestCase):
    def test_parse_error_message_returns_jsonrpc_error(self):
        reply = MODULE["handle_message"]({"_parse_error": "bad json"})

        self.assertEqual(reply["jsonrpc"], "2.0")
        self.assertIsNone(reply["id"])
        self.assertEqual(reply["error"]["code"], -32700)
        self.assertIn("Parse error", reply["error"]["message"])

    def test_create_worktree_panes_requires_command_for_unknown_agent(self):
        with self.assertRaisesRegex(RuntimeError, "Unknown agent:"):
            MODULE["tool_create_worktree_panes"]({
                "repo": ".",
                "names": ["review-fix"],
                "agent": "not-a-real-agent",
                "noCreate": True,
            })


if __name__ == "__main__":
    unittest.main()
