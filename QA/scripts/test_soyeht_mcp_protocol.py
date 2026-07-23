#!/usr/bin/env -S uv run
import runpy
import unittest
from unittest.mock import patch
from pathlib import Path


MODULE = runpy.run_path(str(Path(__file__).resolve().parents[2] / "scripts" / "soyeht-mcp"))


class SoyehtMCPProtocolTests(unittest.TestCase):
    def setUp(self):
        MODULE["handle_message"].__globals__["_PARENT_PROCESS_ENVIRONMENT"] = {}
        self.sleep_patch = patch.object(MODULE["time"], "sleep", lambda _seconds: None)
        self.sleep_patch.start()

    def tearDown(self):
        self.sleep_patch.stop()

    def test_list_windows_handler_is_registered(self):
        self.assertIn("list_windows", MODULE["TOOL_HANDLERS"])

    def test_main_ignores_pane_group_sighup_before_reading_stdio(self):
        transport = MODULE["StdioTransport"]
        original_read_messages = transport.read_messages
        transport.read_messages = lambda _self: ()
        try:
            with patch.object(MODULE["signal"], "signal") as install_handler:
                MODULE["main"]()
        finally:
            transport.read_messages = original_read_messages

        install_handler.assert_called_once_with(
            MODULE["signal"].SIGHUP,
            MODULE["signal"].SIG_IGN,
        )

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

    def test_prompt_delay_schema_describes_agent_aware_default(self):
        prompt_delay = MODULE["PROMPT_DELAY_MS_PROPERTY"]
        prompt_mode = MODULE["PROMPT_MODE_PROPERTY"]

        self.assertNotIn("default", prompt_delay)
        self.assertIn("startup-aware", prompt_delay["description"])
        self.assertIn("Codex/Claude", prompt_delay["description"])
        self.assertEqual(prompt_mode["enum"], ["auto", "message", "raw"])
        self.assertIn("agent message", prompt_mode["description"])
        self.assertIn("raw", prompt_mode["description"])
        for name in ("open_panes", "open_shell", "open_workspace", "create_worktree_panes", "agent_race_panes"):
            tool = next(tool for tool in MODULE["TOOLS"] if tool["name"] == name)
            self.assertIs(tool["inputSchema"]["properties"]["promptDelayMs"], prompt_delay)
            self.assertIs(tool["inputSchema"]["properties"]["promptMode"], prompt_mode)

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

    def test_resolve_automation_root_prefers_explicit_directory(self):
        root = MODULE["resolve_automation_root"]("/tmp/explicit-automation", {"sourceTTY": "/dev/ttys123"})
        self.assertEqual(str(root), "/tmp/explicit-automation")

    def test_default_automation_candidates_use_parent_soyeht_environment(self):
        globals_ = MODULE["default_automation_candidates"].__globals__
        original_parent_env = globals_["parent_process_environment"]
        try:
            globals_["parent_process_environment"] = lambda: {
                "SOYEHT_AUTOMATION_DIR": "/tmp/soyeht-dev-agent-enter-e2e/Automation"
            }
            with patch.dict("os.environ", {}, clear=True):
                roots = MODULE["default_automation_candidates"]()
        finally:
            globals_["parent_process_environment"] = original_parent_env

        self.assertEqual(roots, [Path("/tmp/soyeht-dev-agent-enter-e2e/Automation")])

    def test_parse_soyeht_environment_handles_space_containing_paths(self):
        output = (
            "/opt/homebrew/bin/codex "
            "SOYEHT_AUTOMATION_DIR=/Users/test/Library/Application Support/Soyeht/Automation "
            "OSLogRateLimit=64 "
            "SOYEHT_CONVERSATION_ID=11111111-1111-1111-1111-111111111111 "
            "GIT_PAGER=cat "
            "SOYEHT_HANDLE=@codex"
        )

        self.assertEqual(
            MODULE["parse_soyeht_environment"](output),
            {
                "SOYEHT_AUTOMATION_DIR": "/Users/test/Library/Application Support/Soyeht/Automation",
                "SOYEHT_CONVERSATION_ID": "11111111-1111-1111-1111-111111111111",
                "SOYEHT_HANDLE": "@codex",
            },
        )

    def test_resolve_automation_root_uses_target_window_when_env_is_missing(self):
        globals_ = MODULE["resolve_automation_root"].__globals__
        original_candidates = globals_["default_automation_candidates"]
        original_has_window = globals_["automation_root_has_window"]
        release = Path("/tmp/soyeht-release/Automation")
        dev = Path("/tmp/soyeht-dev/Automation")
        try:
            globals_["default_automation_candidates"] = lambda: [release, dev]
            globals_["automation_root_has_window"] = lambda root, window_id: root == dev and window_id == "dev-window"

            root = MODULE["resolve_automation_root"](None, {"targetWindowID": "dev-window"})
        finally:
            globals_["default_automation_candidates"] = original_candidates
            globals_["automation_root_has_window"] = original_has_window

        self.assertEqual(root, dev)

    def test_resolve_automation_root_uses_source_tty_when_env_is_missing(self):
        globals_ = MODULE["resolve_automation_root"].__globals__
        original_candidates = globals_["default_automation_candidates"]
        original_resolves_source = globals_["automation_root_resolves_source"]
        release = Path("/tmp/soyeht-release/Automation")
        dev = Path("/tmp/soyeht-dev/Automation")
        try:
            globals_["default_automation_candidates"] = lambda: [release, dev]
            globals_["automation_root_resolves_source"] = lambda root, payload: root == dev and payload.get("sourceTTY") == "/dev/ttys123"

            root = MODULE["resolve_automation_root"](None, {"sourceTTY": "/dev/ttys123"})
        finally:
            globals_["default_automation_candidates"] = original_candidates
            globals_["automation_root_resolves_source"] = original_resolves_source

        self.assertEqual(root, dev)

    def test_resolve_automation_root_uses_calling_tty_for_source_unaware_tools(self):
        globals_ = MODULE["resolve_automation_root"].__globals__
        original_candidates = globals_["default_automation_candidates"]
        original_resolves_source = globals_["automation_root_resolves_source"]
        original_tty = globals_["current_tty"]
        release = Path("/tmp/soyeht-release/Automation")
        dev = Path("/tmp/soyeht-dev/Automation")
        try:
            globals_["default_automation_candidates"] = lambda: [release, dev]
            globals_["current_tty"] = lambda: "/dev/ttys456"
            globals_["automation_root_resolves_source"] = lambda root, payload: root == dev and payload.get("sourceTTY") == "/dev/ttys456"

            root = MODULE["resolve_automation_root"](None, {})
        finally:
            globals_["default_automation_candidates"] = original_candidates
            globals_["automation_root_resolves_source"] = original_resolves_source
            globals_["current_tty"] = original_tty

        self.assertEqual(root, dev)

    def test_resolve_automation_root_uses_cwd_when_agent_mcp_subprocess_has_no_tty(self):
        globals_ = MODULE["resolve_automation_root"].__globals__
        original_candidates = globals_["default_automation_candidates"]
        original_resolves_source = globals_["automation_root_resolves_source"]
        original_has_cwd = globals_["automation_root_has_pane_cwd"]
        original_tty = globals_["current_tty"]
        release = Path("/tmp/soyeht-release/Automation")
        dev = Path("/tmp/soyeht-dev/Automation")
        try:
            globals_["default_automation_candidates"] = lambda: [release, dev]
            globals_["current_tty"] = lambda: None
            globals_["automation_root_resolves_source"] = lambda root, payload: False
            globals_["automation_root_has_pane_cwd"] = lambda root, cwd: root == dev

            root = MODULE["resolve_automation_root"](None, {})
        finally:
            globals_["default_automation_candidates"] = original_candidates
            globals_["automation_root_resolves_source"] = original_resolves_source
            globals_["automation_root_has_pane_cwd"] = original_has_cwd
            globals_["current_tty"] = original_tty

        self.assertEqual(root, dev)

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
            with patch.dict("os.environ", {}, clear=True):
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
            with patch.dict("os.environ", {}, clear=True):
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

    def test_source_environment_is_used_before_tty_when_explicit_source_absent(self):
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
            with patch.dict("os.environ", {
                "SOYEHT_CONVERSATION_ID": "22222222-2222-2222-2222-222222222222",
                "SOYEHT_HANDLE": "@env-source",
            }, clear=True):
                result = MODULE["tool_send_pane_input"]({
                    "handles": ["@dst"],
                    "text": "hello",
                })
        finally:
            globals_["submit_request"] = original_submit
            globals_["current_tty"] = original_tty

        self.assertEqual(result["status"], "ok")
        self.assertEqual(captured["request_type"], "send_pane_input")
        self.assertEqual(captured["payload"]["sourceConversationID"], "22222222-2222-2222-2222-222222222222")
        self.assertEqual(captured["payload"]["sourceHandle"], "@env-source")
        self.assertNotIn("sourceTTY", captured["payload"])

    def test_parent_source_environment_is_used_when_mcp_subprocess_env_is_empty(self):
        captured = {}
        globals_ = MODULE["tool_send_pane_input"].__globals__
        original_submit = globals_["submit_request"]
        original_tty = globals_["current_tty"]
        original_parent_env = globals_["parent_process_environment"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=20.0):
                captured["request_type"] = request_type
                captured["payload"] = payload
                return {"status": "ok"}

            globals_["submit_request"] = fake_submit_request
            globals_["current_tty"] = lambda: "/dev/ttys123"
            globals_["parent_process_environment"] = lambda: {
                "SOYEHT_CONVERSATION_ID": "33333333-3333-3333-3333-333333333333",
                "SOYEHT_HANDLE": "@parent-codex",
            }
            with patch.dict("os.environ", {}, clear=True):
                result = MODULE["tool_send_pane_input"]({
                    "handles": ["@dst"],
                    "text": "hello",
                })
        finally:
            globals_["submit_request"] = original_submit
            globals_["current_tty"] = original_tty
            globals_["parent_process_environment"] = original_parent_env

        self.assertEqual(result["status"], "ok")
        self.assertEqual(captured["request_type"], "send_pane_input")
        self.assertEqual(captured["payload"]["sourceConversationID"], "33333333-3333-3333-3333-333333333333")
        self.assertEqual(captured["payload"]["sourceHandle"], "@parent-codex")
        self.assertNotIn("sourceTTY", captured["payload"])

    def test_capture_pane_forwards_source_context_before_active_window_fallback(self):
        captured = {}
        globals_ = MODULE["tool_capture_pane"].__globals__
        original_submit = globals_["submit_request"]
        original_tty = globals_["current_tty"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=10.0):
                captured["request_type"] = request_type
                captured["payload"] = payload
                captured["timeout"] = timeout
                return {"status": "ok"}

            globals_["submit_request"] = fake_submit_request
            globals_["current_tty"] = lambda: "/dev/ttys999"
            with patch.dict("os.environ", {
                "SOYEHT_CONVERSATION_ID": "55555555-5555-5555-5555-555555555555",
                "SOYEHT_HANDLE": "@caller",
            }, clear=True):
                result = MODULE["tool_capture_pane"]({
                    "mode": "visible",
                    "maxLines": 40,
                })
        finally:
            globals_["submit_request"] = original_submit
            globals_["current_tty"] = original_tty

        self.assertEqual(result["status"], "ok")
        self.assertEqual(captured["request_type"], "capture_pane")
        self.assertEqual(captured["payload"]["conversationIDs"], [])
        self.assertEqual(captured["payload"]["handles"], [])
        self.assertEqual(captured["payload"]["captureMode"], "visible")
        self.assertEqual(captured["payload"]["maxLines"], 40)
        self.assertEqual(captured["payload"]["sourceConversationID"], "55555555-5555-5555-5555-555555555555")
        self.assertEqual(captured["payload"]["sourceHandle"], "@caller")
        self.assertNotIn("sourceTTY", captured["payload"])

    def test_open_shell_forwards_workspace_target_and_source_context(self):
        captured = {}
        globals_ = MODULE["tool_open_shell"].__globals__
        original_submit = globals_["submit_request"]
        original_tty = globals_["current_tty"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=20.0):
                captured["request_type"] = request_type
                captured["payload"] = payload
                captured["timeout"] = timeout
                return {"status": "ok"}

            globals_["submit_request"] = fake_submit_request
            globals_["current_tty"] = lambda: "/dev/ttys777"
            with patch.dict("os.environ", {
                "SOYEHT_CONVERSATION_ID": "77777777-7777-7777-7777-777777777777",
                "SOYEHT_HANDLE": "@caller",
            }, clear=True):
                result = MODULE["tool_open_shell"]({
                    "path": ".",
                    "agent": "shell",
                    "workspaceID": "88888888-8888-8888-8888-888888888888",
                    "targetWindowID": "window-alpha",
                })
        finally:
            globals_["submit_request"] = original_submit
            globals_["current_tty"] = original_tty

        self.assertEqual(result["status"], "ok")
        self.assertEqual(captured["request_type"], "create_worktree_panes")
        self.assertEqual(captured["payload"]["workspaceID"], "88888888-8888-8888-8888-888888888888")
        self.assertEqual(captured["payload"]["targetWindowID"], "window-alpha")
        self.assertEqual(captured["payload"]["sourceConversationID"], "77777777-7777-7777-7777-777777777777")
        self.assertEqual(captured["payload"]["sourceHandle"], "@caller")
        self.assertNotIn("sourceTTY", captured["payload"])

    def test_explicit_automation_dir_ignores_foreign_parent_source_environment(self):
        captured = {}
        globals_ = MODULE["tool_send_pane_input"].__globals__
        original_submit = globals_["submit_request"]
        original_tty = globals_["current_tty"]
        original_parent_env = globals_["parent_process_environment"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=20.0):
                captured["request_type"] = request_type
                captured["payload"] = payload
                captured["automation_dir"] = automation_dir
                return {"status": "ok"}

            globals_["submit_request"] = fake_submit_request
            globals_["current_tty"] = lambda: None
            globals_["parent_process_environment"] = lambda: {
                "SOYEHT_AUTOMATION_DIR": "/Users/test/Library/Application Support/Soyeht/Automation",
                "SOYEHT_CONVERSATION_ID": "33333333-3333-3333-3333-333333333333",
                "SOYEHT_HANDLE": "@production-codex",
            }
            with patch.dict("os.environ", {}, clear=True):
                result = MODULE["tool_send_pane_input"]({
                    "handles": ["@dst"],
                    "text": "hello",
                    "automationDir": "/Users/test/Library/Application Support/SoyehtDev/Automation",
                })
        finally:
            globals_["submit_request"] = original_submit
            globals_["current_tty"] = original_tty
            globals_["parent_process_environment"] = original_parent_env

        self.assertEqual(result["status"], "ok")
        self.assertEqual(captured["request_type"], "send_pane_input")
        self.assertEqual(captured["automation_dir"], "/Users/test/Library/Application Support/SoyehtDev/Automation")
        self.assertNotIn("sourceConversationID", captured["payload"])
        self.assertNotIn("sourceHandle", captured["payload"])
        self.assertNotIn("sourceTTY", captured["payload"])

    def test_explicit_automation_dir_uses_matching_parent_source_environment(self):
        captured = {}
        globals_ = MODULE["tool_send_pane_input"].__globals__
        original_submit = globals_["submit_request"]
        original_tty = globals_["current_tty"]
        original_parent_env = globals_["parent_process_environment"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=20.0):
                captured["request_type"] = request_type
                captured["payload"] = payload
                captured["automation_dir"] = automation_dir
                return {"status": "ok"}

            globals_["submit_request"] = fake_submit_request
            globals_["current_tty"] = lambda: None
            globals_["parent_process_environment"] = lambda: {
                "SOYEHT_AUTOMATION_DIR": "/Users/test/Library/Application Support/SoyehtDev/Automation",
                "SOYEHT_CONVERSATION_ID": "44444444-4444-4444-4444-444444444444",
                "SOYEHT_HANDLE": "@dev-codex",
            }
            with patch.dict("os.environ", {}, clear=True):
                result = MODULE["tool_send_pane_input"]({
                    "handles": ["@dst"],
                    "text": "hello",
                    "automationDir": "/Users/test/Library/Application Support/SoyehtDev/Automation",
                })
        finally:
            globals_["submit_request"] = original_submit
            globals_["current_tty"] = original_tty
            globals_["parent_process_environment"] = original_parent_env

        self.assertEqual(result["status"], "ok")
        self.assertEqual(captured["request_type"], "send_pane_input")
        self.assertEqual(captured["automation_dir"], "/Users/test/Library/Application Support/SoyehtDev/Automation")
        self.assertEqual(captured["payload"]["sourceConversationID"], "44444444-4444-4444-4444-444444444444")
        self.assertEqual(captured["payload"]["sourceHandle"], "@dev-codex")
        self.assertNotIn("sourceTTY", captured["payload"])

    def test_explicit_source_overrides_source_environment(self):
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
            with patch.dict("os.environ", {
                "SOYEHT_CONVERSATION_ID": "22222222-2222-2222-2222-222222222222",
                "SOYEHT_HANDLE": "@env-source",
            }, clear=True):
                result = MODULE["tool_send_pane_input"]({
                    "handles": ["@dst"],
                    "text": "hello",
                    "fromHandle": "@explicit-source",
                })
        finally:
            globals_["submit_request"] = original_submit
            globals_["current_tty"] = original_tty

        self.assertEqual(result["status"], "ok")
        self.assertEqual(captured["request_type"], "send_pane_input")
        self.assertNotIn("sourceConversationID", captured["payload"])
        self.assertEqual(captured["payload"]["sourceHandle"], "@explicit-source")
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

    def test_open_shell_agent_prompt_defaults_to_message_mode_with_source(self):
        captured = {}
        globals_ = MODULE["tool_open_shell"].__globals__
        original_submit = globals_["submit_request"]
        original_tty = globals_["current_tty"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=20.0):
                captured["request_type"] = request_type
                captured["payload"] = payload
                return {"status": "ok"}

            globals_["submit_request"] = fake_submit_request
            globals_["current_tty"] = lambda: "/dev/ttys123"
            result = MODULE["tool_open_shell"]({
                "path": ".",
                "agent": "claude",
                "prompt": "please review this",
                "fromHandle": "@codex",
            })
        finally:
            globals_["submit_request"] = original_submit
            globals_["current_tty"] = original_tty

        self.assertEqual(result["status"], "ok")
        self.assertEqual(captured["request_type"], "create_worktree_panes")
        self.assertEqual(captured["payload"]["sourceHandle"], "@codex")
        self.assertNotIn("sourceTTY", captured["payload"])
        self.assertEqual(captured["payload"]["promptMode"], "message")
        self.assertEqual(captured["payload"]["panes"][0]["promptMode"], "message")
        self.assertEqual(captured["payload"]["panes"][0]["prompt"], "please review this")
        self.assertEqual(captured["payload"]["panes"][0]["promptDelayMs"], 15_000)
        self.assertEqual(result["promptDeliveryWaitMs"], 18_000)
        self.assertEqual(result["promptDeliveryStatus"], "waited")

    def test_open_shell_raw_prompt_mode_preserves_literal_agent_input(self):
        captured = {}
        globals_ = MODULE["tool_open_shell"].__globals__
        original_submit = globals_["submit_request"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=20.0):
                captured["payload"] = payload
                return {"status": "ok"}

            globals_["submit_request"] = fake_submit_request
            result = MODULE["tool_open_shell"]({
                "path": ".",
                "agent": "claude",
                "prompt": "act like the user typed this",
                "promptMode": "raw",
                "fromHandle": "@driver",
            })
        finally:
            globals_["submit_request"] = original_submit

        self.assertEqual(result["status"], "ok")
        self.assertEqual(captured["payload"]["sourceHandle"], "@driver")
        self.assertEqual(captured["payload"]["promptMode"], "raw")
        self.assertEqual(captured["payload"]["panes"][0]["promptMode"], "raw")
        self.assertEqual(captured["payload"]["panes"][0]["promptDelayMs"], 15_000)
        self.assertEqual(result["promptDeliveryWaitMs"], 18_000)

    def test_open_shell_codex_prompt_waits_for_default_delivery_delay(self):
        captured = {}
        globals_ = MODULE["tool_open_shell"].__globals__
        original_submit = globals_["submit_request"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=20.0):
                captured["payload"] = payload
                return {"status": "ok"}

            globals_["submit_request"] = fake_submit_request
            result = MODULE["tool_open_shell"]({
                "path": ".",
                "agent": "codex",
                "command": "codex --yolo",
                "prompt": "ask another agent",
                "fromHandle": "@driver",
            })
        finally:
            globals_["submit_request"] = original_submit

        self.assertEqual(result["status"], "ok")
        self.assertEqual(captured["payload"]["promptMode"], "message")
        self.assertEqual(captured["payload"]["panes"][0]["promptDelayMs"], 8_000)
        self.assertEqual(result["promptDeliveryWaitMs"], 11_000)

    def test_shell_prompt_defaults_to_raw_mode(self):
        captured = {}
        globals_ = MODULE["tool_open_shell"].__globals__
        original_submit = globals_["submit_request"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=20.0):
                captured["payload"] = payload
                return {"status": "ok"}

            globals_["submit_request"] = fake_submit_request
            result = MODULE["tool_open_shell"]({
                "path": ".",
                "agent": "shell",
                "prompt": "printf ok",
            })
        finally:
            globals_["submit_request"] = original_submit

        self.assertEqual(result["status"], "ok")
        self.assertEqual(captured["payload"]["promptMode"], "raw")
        self.assertEqual(captured["payload"]["panes"][0]["promptMode"], "raw")
        self.assertEqual(captured["payload"]["panes"][0]["promptDelayMs"], 1_500)
        self.assertEqual(result["promptDeliveryWaitMs"], 1_500)

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
