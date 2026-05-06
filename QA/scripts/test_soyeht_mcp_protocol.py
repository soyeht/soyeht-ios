#!/usr/bin/env -S uv run
import runpy
import unittest
from pathlib import Path


MODULE = runpy.run_path(str(Path(__file__).resolve().parents[2] / "scripts" / "soyeht-mcp"))


class SoyehtMCPProtocolTests(unittest.TestCase):
    def test_list_windows_handler_is_registered(self):
        self.assertIn("list_windows", MODULE["TOOL_HANDLERS"])

    def test_window_targets_are_forwarded_to_app_payload(self):
        captured = {}
        globals_ = MODULE["tool_send_pane_input"].__globals__
        original = globals_["submit_request"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=20.0):
                captured["request_type"] = request_type
                captured["payload"] = payload
                captured["automation_dir"] = automation_dir
                captured["timeout"] = timeout
                return {"status": "ok"}

            globals_["submit_request"] = fake_submit_request
            result = MODULE["tool_send_pane_input"]({
                "conversationIDs": ["11111111-1111-1111-1111-111111111111"],
                "text": "hello",
                "targetWindowID": "window-b",
            })
        finally:
            globals_["submit_request"] = original

        self.assertEqual(result["status"], "ok")
        self.assertEqual(captured["request_type"], "send_pane_input")
        self.assertEqual(captured["payload"]["targetWindowID"], "window-b")

    def test_move_pane_forwards_source_and_destination_windows(self):
        captured = {}
        globals_ = MODULE["tool_move_pane"].__globals__
        original = globals_["submit_request"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=20.0):
                captured["request_type"] = request_type
                captured["payload"] = payload
                return {"status": "ok"}

            globals_["submit_request"] = fake_submit_request
            result = MODULE["tool_move_pane"]({
                "conversationIDs": ["11111111-1111-1111-1111-111111111111"],
                "destinationWorkspaceID": "22222222-2222-2222-2222-222222222222",
                "targetWindowID": "source-window",
                "destinationWindowID": "destination-window",
            })
        finally:
            globals_["submit_request"] = original

        self.assertEqual(result["status"], "ok")
        self.assertEqual(captured["request_type"], "move_pane")
        self.assertEqual(captured["payload"]["targetWindowID"], "source-window")
        self.assertEqual(captured["payload"]["destinationWindowID"], "destination-window")

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
