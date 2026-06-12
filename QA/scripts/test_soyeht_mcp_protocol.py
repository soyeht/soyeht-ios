#!/usr/bin/env -S uv run
import runpy
import unittest
from pathlib import Path


MODULE = runpy.run_path(str(Path(__file__).resolve().parents[2] / "scripts" / "soyeht-mcp"))


class SoyehtMCPProtocolTests(unittest.TestCase):
    def test_list_windows_handler_is_registered(self):
        self.assertIn("list_windows", MODULE["TOOL_HANDLERS"])

    def test_list_panes_describes_declared_agent_as_metadata(self):
        tool = next(tool for tool in MODULE["TOOLS"] if tool["name"] == "list_panes")

        self.assertIn("declaredAgent", tool["description"])
        self.assertIn("not runtime process identity", tool["description"])
        self.assertIn("Do not use declaredAgent", tool["description"])
        self.assertNotIn("agent types", tool["description"])

    def test_send_pane_input_description_describes_agent_messaging_boundary(self):
        tool = next(tool for tool in MODULE["TOOLS"] if tool["name"] == "send_pane_input")

        self.assertIn("prefer message_agent", tool["description"])
        self.assertIn("fromHandle", tool["description"])
        self.assertIn("fromConversationID", tool["description"])
        self.assertIn("do not create a new pane", tool["description"])
        self.assertIn("whether an agent envelope was applied", tool["description"])

    def test_message_agent_handler_is_registered_and_fail_closed_by_schema(self):
        self.assertIn("message_agent", MODULE["TOOL_HANDLERS"])
        tool = next(tool for tool in MODULE["TOOLS"] if tool["name"] == "message_agent")

        self.assertIn("agent-to-agent communication", tool["description"])
        self.assertIn("never creates panes", tool["description"])
        self.assertIn("fromHandle", tool["inputSchema"]["properties"])
        self.assertIn("fromConversationID", tool["inputSchema"]["properties"])

    def test_agent_directory_tools_are_registered_for_multi_agent_routing(self):
        self.assertIn("identify_agent", MODULE["TOOL_HANDLERS"])
        self.assertIn("list_agents", MODULE["TOOL_HANDLERS"])

        identify = next(tool for tool in MODULE["TOOLS"] if tool["name"] == "identify_agent")
        directory = next(tool for tool in MODULE["TOOLS"] if tool["name"] == "list_agents")

        self.assertIn("sourceIdentity", identify["description"])
        self.assertIn("calling terminal TTY", identify["description"])
        self.assertIn("agent/pane directory", directory["description"])
        self.assertIn("messageTarget", directory["description"])
        self.assertIn("Never create a new pane", directory["description"])

    def test_concrete_tty_path_rejects_generic_dev_tty(self):
        self.assertIsNone(MODULE["concrete_tty_path"]("/dev/tty"))
        self.assertIsNone(MODULE["concrete_tty_path"]("tty"))
        self.assertEqual(MODULE["concrete_tty_path"]("ttys057"), "/dev/ttys057")

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

    def test_send_pane_input_forwards_source_tty_and_keeps_text_raw(self):
        captured = {}
        globals_ = MODULE["tool_send_pane_input"].__globals__
        original_submit = globals_["submit_request"]
        original_tty = globals_["current_tty"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=20.0):
                captured["request_type"] = request_type
                captured["payload"] = payload
                captured["automation_dir"] = automation_dir
                captured["timeout"] = timeout
                return {"status": "ok"}

            globals_["submit_request"] = fake_submit_request
            globals_["current_tty"] = lambda: "/dev/ttys123"
            result = MODULE["tool_send_pane_input"]({
                "handles": ["@dst"],
                "text": "hello",
                "targetWindowID": "window-b",
            })
        finally:
            globals_["submit_request"] = original_submit
            globals_["current_tty"] = original_tty

        self.assertEqual(result["status"], "ok")
        self.assertEqual(captured["request_type"], "send_pane_input")
        self.assertEqual(captured["payload"]["handles"], ["@dst"])
        self.assertEqual(captured["payload"]["text"], "hello")
        self.assertEqual(captured["payload"]["sourceTTY"], "/dev/ttys123")
        self.assertEqual(captured["payload"]["targetWindowID"], "window-b")

    def test_send_pane_input_explicit_source_suppresses_tty_fallback(self):
        captured = {}
        globals_ = MODULE["tool_send_pane_input"].__globals__
        original_submit = globals_["submit_request"]
        original_tty = globals_["current_tty"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=20.0):
                captured["request_type"] = request_type
                captured["payload"] = payload
                return {"status": "ok"}

            globals_["submit_request"] = fake_submit_request
            globals_["current_tty"] = lambda: "/dev/ttys123"
            result = MODULE["tool_send_pane_input"]({
                "handles": ["@dst"],
                "text": "hello",
                "fromHandle": "@sender",
            })
        finally:
            globals_["submit_request"] = original_submit
            globals_["current_tty"] = original_tty

        self.assertEqual(result["status"], "ok")
        self.assertEqual(captured["request_type"], "send_pane_input")
        self.assertEqual(captured["payload"]["sourceHandle"], "@sender")
        self.assertNotIn("sourceTTY", captured["payload"])

    def test_message_agent_requires_existing_target_and_requests_envelope(self):
        captured = {}
        globals_ = MODULE["tool_message_agent"].__globals__
        original_submit = globals_["submit_request"]
        original_tty = globals_["current_tty"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=20.0):
                captured["request_type"] = request_type
                captured["payload"] = payload
                return {"status": "ok"}

            globals_["submit_request"] = fake_submit_request
            globals_["current_tty"] = lambda: None
            result = MODULE["tool_message_agent"]({
                "handles": ["@reviewer"],
                "text": "please review",
                "fromConversationID": "11111111-1111-1111-1111-111111111111",
                "targetWindowID": "window-a",
            })
        finally:
            globals_["submit_request"] = original_submit
            globals_["current_tty"] = original_tty

        self.assertEqual(result["status"], "ok")
        self.assertEqual(captured["request_type"], "send_pane_input")
        self.assertEqual(captured["payload"]["handles"], ["@reviewer"])
        self.assertEqual(captured["payload"]["sourceConversationID"], "11111111-1111-1111-1111-111111111111")
        self.assertTrue(captured["payload"]["forceAgentEnvelope"])
        self.assertTrue(captured["payload"]["requireAgentEnvelope"])
        self.assertEqual(captured["payload"]["lineEnding"], "enter")
        self.assertEqual(captured["payload"]["targetWindowID"], "window-a")

    def test_message_agent_refuses_to_create_or_guess_target(self):
        with self.assertRaisesRegex(RuntimeError, "requires handles or conversationIDs"):
            MODULE["tool_message_agent"]({"text": "please review"})

    def test_identify_agent_forwards_explicit_source(self):
        captured = {}
        globals_ = MODULE["tool_identify_agent"].__globals__
        original_submit = globals_["submit_request"]
        original_tty = globals_["current_tty"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=5.0):
                captured["request_type"] = request_type
                captured["payload"] = payload
                captured["automation_dir"] = automation_dir
                captured["timeout"] = timeout
                return {"status": "ok"}

            globals_["submit_request"] = fake_submit_request
            globals_["current_tty"] = lambda: "/dev/ttys123"
            result = MODULE["tool_identify_agent"]({
                "fromHandle": "@codex",
                "automationDir": "/tmp/soyeht-agent-directory",
            })
        finally:
            globals_["submit_request"] = original_submit
            globals_["current_tty"] = original_tty

        self.assertEqual(result["status"], "ok")
        self.assertEqual(captured["request_type"], "identify_agent")
        self.assertEqual(captured["payload"]["sourceHandle"], "@codex")
        self.assertNotIn("sourceTTY", captured["payload"])
        self.assertEqual(captured["automation_dir"], "/tmp/soyeht-agent-directory")

    def test_list_agents_forwards_source_workspace_and_window(self):
        captured = {}
        globals_ = MODULE["tool_list_agents"].__globals__
        original_submit = globals_["submit_request"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=10.0):
                captured["request_type"] = request_type
                captured["payload"] = payload
                captured["timeout"] = timeout
                return {"status": "ok"}

            globals_["submit_request"] = fake_submit_request
            result = MODULE["tool_list_agents"]({
                "fromConversationID": "11111111-1111-1111-1111-111111111111",
                "workspaceID": "22222222-2222-2222-2222-222222222222",
                "targetWindowID": "window-a",
            })
        finally:
            globals_["submit_request"] = original_submit

        self.assertEqual(result["status"], "ok")
        self.assertEqual(captured["request_type"], "list_agents")
        self.assertEqual(captured["payload"]["sourceConversationID"], "11111111-1111-1111-1111-111111111111")
        self.assertEqual(captured["payload"]["workspaceIDs"], ["22222222-2222-2222-2222-222222222222"])
        self.assertEqual(captured["payload"]["targetWindowID"], "window-a")

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

    def test_session_spec_requires_name_by_default(self):
        with self.assertRaisesRegex(RuntimeError, "Pane spec is missing name."):
            MODULE["session_spec"]({"path": "."})

    def test_open_shell_allows_app_generated_name(self):
        captured = {}
        globals_ = MODULE["tool_open_shell"].__globals__
        original = globals_["submit_request"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=20.0):
                captured["request_type"] = request_type
                captured["payload"] = payload
                return {"status": "ok"}

            globals_["submit_request"] = fake_submit_request
            result = MODULE["tool_open_shell"]({"path": "."})
        finally:
            globals_["submit_request"] = original

        self.assertEqual(result["status"], "ok")
        self.assertEqual(captured["request_type"], "create_worktree_panes")
        self.assertTrue(captured["payload"]["allowAutoPaneNames"])
        self.assertNotIn("name", captured["payload"]["panes"][0])

    def test_open_panes_requires_name(self):
        with self.assertRaisesRegex(RuntimeError, "Pane spec is missing name."):
            MODULE["tool_open_panes"]({"panes": [{"path": "."}]})

    def test_open_workspace_requires_pane_name(self):
        with self.assertRaisesRegex(RuntimeError, "Pane spec is missing name."):
            MODULE["tool_open_workspace"]({"panes": [{"path": "."}]})


if __name__ == "__main__":
    unittest.main()
