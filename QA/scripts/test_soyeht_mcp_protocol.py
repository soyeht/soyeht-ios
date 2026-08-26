#!/usr/bin/env -S uv run
import hashlib
import json
import os
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path


MODULE = runpy.run_path(str(Path(__file__).resolve().parents[2] / "scripts" / "soyeht-mcp"))


class SoyehtMCPProtocolTests(unittest.TestCase):
    def setUp(self):
        MODULE["parent_process_environment"].__globals__["_PARENT_PROCESS_ENVIRONMENT"] = {}

    def test_list_windows_handler_is_registered(self):
        self.assertIn("list_windows", MODULE["TOOL_HANDLERS"])

    def test_initialize_registers_process_bound_messaging_presence(self):
        calls = []
        globals_ = MODULE["handle_message"].__globals__
        original = globals_["register_messaging_client_presence"]
        original_start = globals_["start_messaging_client_presence_heartbeat"]
        try:
            globals_["register_messaging_client_presence"] = lambda: calls.append("register")
            globals_["start_messaging_client_presence_heartbeat"] = lambda: calls.append("heartbeat")
            reply = MODULE["handle_message"]({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {"protocolVersion": "2025-03-26"},
            })
        finally:
            globals_["register_messaging_client_presence"] = original
            globals_["start_messaging_client_presence_heartbeat"] = original_start

        self.assertEqual(calls, ["register", "heartbeat"])
        self.assertEqual(reply["result"]["protocolVersion"], "2025-03-26")
        instructions = reply["result"]["instructions"]
        self.assertIn("existing named Soyeht agent pane", instructions)
        self.assertIn("first call list_agents before choosing any delegation mechanism", instructions)
        self.assertIn("If a normalized target name matches", instructions)
        self.assertIn("use message_agent", instructions)
        self.assertIn("never spawn an internal subagent as its substitute", instructions)
        self.assertIn("do not silently create a replacement", instructions)
        self.assertIn("Internal subagents remain valid", instructions)
        self.assertIn("Never claim that an agent replied", instructions)

    def test_agent_messaging_tools_forbid_internal_subagent_substitution(self):
        schemas = {tool["name"]: tool for tool in MODULE["TOOLS"]}
        directory_description = schemas["list_agents"]["description"]
        messaging_description = schemas["message_agent"]["description"]

        self.assertIn("call this tool BEFORE choosing a delegation mechanism", directory_description)
        self.assertIn("Match normalized names", directory_description)
        self.assertIn("must never be replaced by newly spawned internal harness subagents", directory_description)
        self.assertIn("unmatched names must be reported", directory_description)
        self.assertIn("This does not forbid internal subagents", directory_description)
        self.assertIn("list_agents must be called before choosing a delegation mechanism", messaging_description)
        self.assertIn("Never spawn internal harness subagents as substitutes", messaging_description)
        self.assertIn("Internal subagents remain valid", messaging_description)
        self.assertIn("Never claim a reply merely because delivery succeeded", messaging_description)

    def test_messaging_presence_heartbeat_retries_then_uses_steady_interval(self):
        delays = []
        outcomes = iter((False, True))

        class StopAfterTwoRegistrations:
            def wait(self, delay):
                delays.append(delay)
                return len(delays) > 2

        globals_ = MODULE["start_messaging_client_presence_heartbeat"].__globals__
        original = globals_["register_messaging_client_presence"]
        try:
            globals_["register_messaging_client_presence"] = lambda: next(outcomes)
            globals_["_messaging_presence_heartbeat_loop"](StopAfterTwoRegistrations())
        finally:
            globals_["register_messaging_client_presence"] = original

        self.assertEqual(delays, [0.5, 1.0, 15.0])

    def test_source_context_carries_process_identity_for_presence_refresh(self):
        payload = {}
        globals_ = MODULE["with_source_context"].__globals__
        original_tty = globals_["current_tty"]
        try:
            globals_["current_tty"] = lambda: "/dev/ttys321"
            MODULE["with_source_context"](payload)
        finally:
            globals_["current_tty"] = original_tty

        self.assertEqual(payload["sourceTTY"], "/dev/ttys321")
        self.assertEqual(payload["messagingClientInstanceID"], MODULE["MCP_SERVER_INSTANCE_ID"])
        self.assertEqual(payload["messagingClientPID"], os.getpid())
        self.assertEqual(payload["messagingClientName"], MODULE["SERVER_NAME"])
        self.assertEqual(payload["messagingClientVersion"], MODULE["SERVER_VERSION"])

    def test_presence_registration_does_not_require_stdio_server_tty(self):
        captured = {}
        globals_ = MODULE["register_messaging_client_presence"].__globals__
        original_tty = globals_["current_tty"]
        original_resolve = globals_["resolve_automation_root"]
        original_submit = globals_["submit_request_to_root"]
        original_root = globals_["_MESSAGING_PRESENCE_ROOT"]
        try:
            globals_["current_tty"] = lambda: None
            globals_["_MESSAGING_PRESENCE_ROOT"] = None
            globals_["resolve_automation_root"] = lambda automation_dir, payload: Path("/tmp/dev-automation")
            globals_["submit_request_to_root"] = lambda root, request_type, payload, **kwargs: (
                captured.update(root=root, request_type=request_type, payload=payload) or {"status": "ok"}
            )
            self.assertTrue(MODULE["register_messaging_client_presence"]())
        finally:
            globals_["current_tty"] = original_tty
            globals_["resolve_automation_root"] = original_resolve
            globals_["submit_request_to_root"] = original_submit
            globals_["_MESSAGING_PRESENCE_ROOT"] = original_root

        self.assertEqual(captured["request_type"], "register_messaging_client")
        self.assertNotIn("sourceTTY", captured["payload"])
        self.assertEqual(captured["payload"]["messagingClientPID"], os.getpid())

    def test_tools_list_contract_matches_reviewed_mcp2_golden(self):
        encoded = json.dumps(
            MODULE["TOOLS"],
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")

        self.assertEqual(len(MODULE["TOOLS"]), 43)
        self.assertEqual(
            hashlib.sha256(encoded).hexdigest(),
            "d85ff0b3f8acc677557abeca4ffaaeecf9ec145482674586c7d23fd7ee28fd08",
        )

    def test_tool_registry_has_exactly_one_handler_per_schema(self):
        schema_names = [tool["name"] for tool in MODULE["TOOLS"]]

        self.assertEqual(len(schema_names), len(set(schema_names)))
        self.assertEqual(set(schema_names), set(MODULE["TOOL_HANDLERS"]))
        self.assertNotIn("open_panes", schema_names)

    def test_tool_contract_and_handler_come_from_the_same_registration(self):
        registry = MODULE["TOOL_REGISTRY"]

        self.assertEqual(len(registry), len(MODULE["TOOLS"]))
        self.assertEqual(
            [spec.order for spec in registry],
            list(range(len(registry))),
        )
        self.assertEqual(
            [spec.definition for spec in registry],
            MODULE["TOOLS"],
        )
        self.assertEqual(
            {spec.name: spec.handler for spec in registry},
            MODULE["TOOL_HANDLERS"],
        )
        for spec in registry:
            self.assertIs(spec.handler.__soyeht_tool_spec__, spec)

    def test_open_file_shell_mode_calls_the_creation_domain_handler(self):
        globals_ = MODULE["tool_open_file"].__globals__
        original_choose_file = globals_["choose_file"]
        original_open_shell = globals_["tool_open_shell"]
        captured = {}
        try:
            globals_["choose_file"] = lambda _args: Path("/tmp/example.txt")

            def fake_open_shell(args):
                captured.update(args)
                return {"status": "ok"}

            globals_["tool_open_shell"] = fake_open_shell
            result = MODULE["tool_open_file"]({"mode": "shell", "editor": "vim"})
        finally:
            globals_["choose_file"] = original_choose_file
            globals_["tool_open_shell"] = original_open_shell

        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["selectedFile"], "/tmp/example.txt")
        self.assertEqual(captured["agent"], "shell")
        self.assertEqual(captured["path"], "/tmp")
        self.assertEqual(captured["command"], "vim /tmp/example.txt")

    def test_file_ipc_request_and_directory_are_owner_only(self):
        write_request = MODULE["write_request"]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            request = {"id": "permission-probe", "type": "list_windows", "payload": {}}
            destination = write_request(root, request)

            self.assertEqual(os.stat(destination.parent).st_mode & 0o777, 0o700)
            self.assertEqual(os.stat(destination).st_mode & 0o777, 0o600)
            self.assertFalse((destination.parent / ".permission-probe.tmp").exists())

    def test_file_ipc_response_is_consumed_after_successful_decode(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            responses = root / "Responses"
            responses.mkdir()
            response = responses / "consume-me.json"
            response.write_text(json.dumps({"status": "ok"}), encoding="utf-8")

            self.assertEqual(
                MODULE["wait_response"](root, "consume-me", 0.1),
                {"status": "ok"},
            )
            self.assertFalse(response.exists())

    def test_legacy_launcher_without_profile_infers_the_owning_bundle(self):
        foundation = MODULE["inferred_mcp_client_profile"]
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(
                foundation("/Applications/Soyeht.app/Contents/Resources/soyeht_mcp_foundation.py"),
                "release",
            )
            self.assertEqual(
                foundation("/Applications/Soyeht Dev.app/Contents/Resources/soyeht_mcp_foundation.py"),
                "dev",
            )
            self.assertEqual(foundation("/tmp/worktree/scripts/soyeht_mcp_foundation.py"), "dev")

    def test_empty_profile_override_is_treated_as_unset(self):
        foundation = MODULE["inferred_mcp_client_profile"]
        with patch.dict(os.environ, {"SOYEHT_MCP_PROFILE": "  "}, clear=True):
            self.assertEqual(
                foundation("/Applications/Soyeht.app/Contents/Resources/soyeht_mcp_foundation.py"),
                "release",
            )

    def test_signed_dev_builder_embeds_and_rechecks_binary_provenance(self):
        repo_root = Path(__file__).resolve().parents[2]
        script = (repo_root / "scripts" / "build-install-soyeht-dev").read_text()
        plist = (repo_root / "TerminalApp" / "SoyehtMac" / "Info.plist").read_text()

        self.assertIn('SOYEHT_BUILD_GIT_COMMIT="$source_commit"', script)
        self.assertIn("SoyehtBuildGitCommit", plist)
        self.assertIn('installed_commit', script)
        self.assertIn('installed_sha', script)
        self.assertIn('trap restore_previous ERR', script)
        self.assertNotIn('installed signature changed unexpectedly: expected $team_id, got $installed_team"\n  exit 1', script)

    def test_server_source_remains_split_into_bounded_domain_modules(self):
        scripts_dir = Path(__file__).resolve().parents[2] / "scripts"
        entrypoint = scripts_dir / "soyeht-mcp"
        modules = sorted(scripts_dir.glob("soyeht_mcp_*.py"))

        self.assertLessEqual(len(entrypoint.read_text().splitlines()), 300)
        self.assertGreaterEqual(len(modules), 10)
        oversized = {
            module.name: len(module.read_text().splitlines())
            for module in modules
            if len(module.read_text().splitlines()) > 600
        }
        self.assertEqual(oversized, {})

    def test_bundled_server_does_not_write_bytecode_beside_signed_resources(self):
        scripts_dir = Path(__file__).resolve().parents[2] / "scripts"
        catalog = (
            Path(__file__).resolve().parents[2]
            / "TerminalApp/SoyehtMac/LocalAgentCatalog.json"
        )
        with tempfile.TemporaryDirectory() as temporary:
            bundle_resources = Path(temporary)
            shutil.copy2(scripts_dir / "soyeht-mcp", bundle_resources / "soyeht-mcp")
            shutil.copy2(catalog, bundle_resources / catalog.name)
            for module in scripts_dir.glob("soyeht_mcp_*.py"):
                shutil.copy2(module, bundle_resources / module.name)

            completed = subprocess.run(
                [sys.executable, str(bundle_resources / "soyeht-mcp")],
                input="",
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertFalse((bundle_resources / "__pycache__").exists())

    def test_bundle_loading_e2e_harnesses_never_mutate_signed_resources(self):
        qa_scripts = Path(__file__).resolve().parent
        for name in (
            "soyeht_agent_driven_e2e.py",
            "soyeht_mcp2_broker_queue_e2e.py",
            "soyeht_mcp2_security_probes.py",
        ):
            source = (qa_scripts / name).read_text()
            loader_offset = source.index("loader = importlib.machinery.SourceFileLoader")
            guard_offset = source.index("sys.dont_write_bytecode = True")
            self.assertLess(guard_offset, loader_offset, name)

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

    def test_every_request_identifies_the_new_mcp_client_contract(self):
        captured = {}
        globals_ = MODULE["submit_request_to_root"].__globals__
        original_write_request = globals_["write_request"]
        original_wait_response = globals_["wait_response"]
        try:
            def fake_write_request(_root, request):
                captured.update(request)
                return Path("/tmp/request.json")

            globals_["write_request"] = fake_write_request
            globals_["wait_response"] = lambda _root, _request_id, _timeout: {"status": "ok"}

            MODULE["submit_request_to_root"](
                Path("/tmp/automation"),
                "message_agent",
                {"text": "hello"},
            )
        finally:
            globals_["write_request"] = original_write_request
            globals_["wait_response"] = original_wait_response

        self.assertEqual(captured["payload"]["mcpClientContractVersion"], 3)
        self.assertEqual(captured["payload"]["mcpClientServerVersion"], "2.0.0")
        self.assertEqual(captured["payload"]["mcpClientProfile"], "dev")

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
        for name in ("open_shell", "open_agent_pane", "open_workspace", "create_worktree_panes", "agent_race_panes"):
            tool = next(tool for tool in MODULE["TOOLS"] if tool["name"] == name)
            self.assertIs(tool["inputSchema"]["properties"]["promptDelayMs"], prompt_delay)
            self.assertIs(tool["inputSchema"]["properties"]["promptMode"], prompt_mode)

    def test_agent_catalog_is_loaded_from_the_app_owned_json(self):
        document = __import__("json").loads(
            (Path(__file__).resolve().parents[2] / "TerminalApp" / "SoyehtMac" / "LocalAgentCatalog.json")
            .read_text(encoding="utf-8")
        )

        self.assertEqual(
            list(MODULE["AGENT_CATALOG"]),
            [entry["name"] for entry in document["agents"]],
        )
        self.assertEqual(MODULE["LAUNCH_PROFILES"], document["launchProfiles"])

    def test_message_agent_handler_is_registered_and_fail_closed_by_schema(self):
        self.assertIn("message_agent", MODULE["TOOL_HANDLERS"])
        tool = next(tool for tool in MODULE["TOOLS"] if tool["name"] == "message_agent")

        self.assertIn("agent-to-agent communication", tool["description"])
        self.assertIn("never creates panes", tool["description"])
        self.assertIn("fromHandle", tool["inputSchema"]["properties"])
        self.assertIn("fromConversationID", tool["inputSchema"]["properties"])
        self.assertIn("deliveryPreference", tool["inputSchema"]["properties"])

        for name in (
            "list_agent_messages",
            "ack_agent_messages",
            "set_agent_communication_policy",
            "set_agent_role",
            "save_agent_role_template",
            "configure_agent_orchestration",
        ):
            self.assertIn(name, MODULE["TOOL_HANDLERS"])
            self.assertTrue(any(tool["name"] == name for tool in MODULE["TOOLS"]))

    def test_agent_directory_tools_are_registered_for_multi_agent_routing(self):
        self.assertIn("identify_agent", MODULE["TOOL_HANDLERS"])
        self.assertIn("list_agents", MODULE["TOOL_HANDLERS"])

        identify = next(tool for tool in MODULE["TOOLS"] if tool["name"] == "identify_agent")
        directory = next(tool for tool in MODULE["TOOLS"] if tool["name"] == "list_agents")

        self.assertIn("sourceIdentity", identify["description"])
        self.assertIn("calling terminal TTY", identify["description"])
        self.assertIn("agent/pane directory", directory["description"])
        self.assertIn("NOT a harness/CLI product", directory["description"])
        self.assertIn("return the pane displayReference names", directory["description"])
        self.assertIn("messageTarget", directory["description"])
        self.assertIn("Never create a new pane", directory["description"])

    def test_open_agent_pane_catalog_matches_the_app_catalog(self):
        expected = {
            "claude": "claude",
            "codex": "codex",
            "opencode": "opencode",
            "qwen": "qwen",
            "antigravity": "agy",
            "pi": "pi",
            "droid": "droid",
            "kilo": "kilo",
            "cursor": "cursor-agent",
            "copilot": "copilot",
            "grok": "grok",
            "kimi": "kimi",
            "devin": "devin",
            "qoder": "qodercli",
        }

        self.assertEqual(
            {agent_id: entry["executable"] for agent_id, entry in MODULE["AGENT_CATALOG"].items()},
            expected,
        )
        tool = next(tool for tool in MODULE["TOOLS"] if tool["name"] == "open_agent_pane")
        self.assertEqual(set(tool["inputSchema"]["properties"]["agentID"]["enum"]), set(expected))
        self.assertEqual(tool["inputSchema"]["required"], ["agentID"])
        self.assertIn("live child process argv", tool["description"])
        self.assertIn("not proof", tool["description"])

    def test_launch_profiles_are_agent_specific_and_default_for_codex_and_opencode(self):
        with patch.object(MODULE["shutil"], "which", lambda executable: f"/mock/bin/{executable}"):
            codex = MODULE["build_agent_launch"]("codex")
            opencode = MODULE["build_agent_launch"]("opencode")
            base = MODULE["build_agent_launch"]("codex", profile="base")
            quoted = MODULE["build_agent_launch"](
                "qwen",
                profile="base",
                args=["value with spaces", "$(must-not-execute)"],
            )

        self.assertEqual(codex["profile"], "codex-yolo")
        self.assertEqual(codex["expectedArgv"], ["/mock/bin/codex", "--yolo"])
        self.assertEqual(opencode["profile"], "opencode-auto")
        self.assertEqual(opencode["expectedArgv"], ["/mock/bin/opencode", "--auto"])
        self.assertEqual(base["profile"], "base")
        self.assertEqual(base["expectedArgv"], ["/mock/bin/codex"])
        self.assertEqual(MODULE["shlex"].split(quoted["command"]), quoted["expectedArgv"])

        with self.assertRaisesRegex(RuntimeError, "belongs to agentID"):
            MODULE["build_agent_launch"]("claude", profile="codex-yolo")
        with self.assertRaisesRegex(RuntimeError, "silently substituting"):
            MODULE["build_agent_launch"]("not-real")

    def test_open_agent_pane_forwards_exact_launch_contract_and_requires_real_argv_e2e(self):
        captured = {}
        globals_ = MODULE["tool_open_agent_pane"].__globals__
        original_submit = globals_["submit_request"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=20.0):
                captured["request_type"] = request_type
                captured["payload"] = payload
                return {"status": "ok", "createdPanes": [{"declaredAgent": "codex"}]}

            globals_["submit_request"] = fake_submit_request
            with patch.object(MODULE["shutil"], "which", lambda executable: f"/mock/bin/{executable}"):
                result = MODULE["tool_open_agent_pane"]({
                    "agentID": "codex",
                    "cwd": ".",
                    "workspace": "22222222-2222-2222-2222-222222222222",
                    "model": "gpt-5.6",
                    "args": ["--search"],
                    "name": "exact-agent-pane-name",
                    "prompt": None,
                })
        finally:
            globals_["submit_request"] = original_submit

        expected_argv = ["/mock/bin/codex", "--yolo", "--model", "gpt-5.6", "--search"]
        self.assertEqual(captured["request_type"], "create_worktree_panes")
        self.assertEqual(captured["payload"]["workspaceID"], "22222222-2222-2222-2222-222222222222")
        self.assertEqual(captured["payload"]["agent"], "codex")
        self.assertFalse(captured["payload"]["activateCreatedPane"])
        self.assertEqual(captured["payload"]["paneNameStyle"], "verbatim")
        self.assertEqual(captured["payload"]["panes"][0]["name"], "exact-agent-pane-name")
        self.assertEqual(captured["payload"]["panes"][0]["agent"], "codex")
        self.assertEqual(captured["payload"]["command"], "/mock/bin/codex --yolo --model gpt-5.6 --search")
        self.assertEqual(result["launchContract"]["expectedArgv"], expected_argv)
        self.assertEqual(result["launchContract"]["profile"], "codex-yolo")
        self.assertTrue(result["argvVerification"]["required"])
        self.assertEqual(result["argvVerification"]["status"], "unverified")
        self.assertIn("not proof", result["argvVerification"]["acceptance"])

    def test_open_agent_pane_rejects_conflicting_workspace_aliases(self):
        with self.assertRaisesRegex(RuntimeError, "workspace and workspaceID must match"):
            MODULE["tool_open_agent_pane"]({
                "agentID": "codex",
                "workspace": "workspace-a",
                "workspaceID": "workspace-b",
            })

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
        source_globals = MODULE["with_source_context"].__globals__
        original_submit = globals_["submit_request"]
        original_tty = source_globals["current_tty"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=20.0):
                captured["request_type"] = request_type
                captured["payload"] = payload
                captured["automation_dir"] = automation_dir
                captured["timeout"] = timeout
                return {"status": "ok"}

            globals_["submit_request"] = fake_submit_request
            source_globals["current_tty"] = lambda: "/dev/ttys123"
            with patch.dict("os.environ", {}, clear=True):
                result = MODULE["tool_send_pane_input"]({
                    "handles": ["@dst"],
                    "text": "hello",
                    "targetWindowID": "window-b",
                })
        finally:
            globals_["submit_request"] = original_submit
            source_globals["current_tty"] = original_tty

        self.assertEqual(result["status"], "ok")
        self.assertEqual(captured["request_type"], "send_pane_input")
        self.assertEqual(captured["payload"]["handles"], ["@dst"])
        self.assertEqual(captured["payload"]["text"], "hello")
        self.assertEqual(captured["payload"]["sourceTTY"], "/dev/ttys123")
        self.assertEqual(captured["payload"]["targetWindowID"], "window-b")

    def test_send_pane_input_explicit_source_is_still_bound_to_current_tty(self):
        captured = {}
        globals_ = MODULE["tool_send_pane_input"].__globals__
        source_globals = MODULE["with_source_context"].__globals__
        original_submit = globals_["submit_request"]
        original_tty = source_globals["current_tty"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=20.0):
                captured["request_type"] = request_type
                captured["payload"] = payload
                return {"status": "ok"}

            globals_["submit_request"] = fake_submit_request
            source_globals["current_tty"] = lambda: "/dev/ttys123"
            with patch.dict("os.environ", {}, clear=True):
                result = MODULE["tool_send_pane_input"]({
                    "handles": ["@dst"],
                    "text": "hello",
                    "fromHandle": "@sender",
                })
        finally:
            globals_["submit_request"] = original_submit
            source_globals["current_tty"] = original_tty

        self.assertEqual(result["status"], "ok")
        self.assertEqual(captured["request_type"], "send_pane_input")
        self.assertEqual(captured["payload"]["sourceHandle"], "@sender")
        self.assertEqual(captured["payload"]["sourceTTY"], "/dev/ttys123")

    def test_source_environment_metadata_is_bound_to_the_current_tty(self):
        captured = {}
        globals_ = MODULE["tool_send_pane_input"].__globals__
        source_globals = MODULE["with_source_context"].__globals__
        original_submit = globals_["submit_request"]
        original_tty = source_globals["current_tty"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=20.0):
                captured["request_type"] = request_type
                captured["payload"] = payload
                return {"status": "ok"}

            globals_["submit_request"] = fake_submit_request
            source_globals["current_tty"] = lambda: "/dev/ttys123"
            with patch.dict("os.environ", {
                "SOYEHT_CONVERSATION_ID": "22222222-2222-2222-2222-222222222222",
                "SOYEHT_HANDLE": "@env-source",
                "SOYEHT_LAUNCH_NONCE": "launch-proof",
            }, clear=True):
                result = MODULE["tool_send_pane_input"]({
                    "handles": ["@dst"],
                    "text": "hello",
                })
        finally:
            globals_["submit_request"] = original_submit
            source_globals["current_tty"] = original_tty

        self.assertEqual(result["status"], "ok")
        self.assertEqual(captured["request_type"], "send_pane_input")
        self.assertEqual(captured["payload"]["sourceConversationID"], "22222222-2222-2222-2222-222222222222")
        self.assertEqual(captured["payload"]["sourceHandle"], "@env-source")
        self.assertEqual(captured["payload"]["nonce"], "launch-proof")
        self.assertEqual(captured["payload"]["sourceTTY"], "/dev/ttys123")

    def test_explicit_source_still_forwards_launch_nonce_from_environment(self):
        payload = {}
        globals_ = MODULE["with_source_context"].__globals__
        original_tty = globals_["current_tty"]
        try:
            globals_["current_tty"] = lambda: "/dev/ttys123"
            with patch.dict("os.environ", {"SOYEHT_LAUNCH_NONCE": "launch-proof"}, clear=True):
                MODULE["with_source_context"](payload, {
                    "fromConversationID": "22222222-2222-2222-2222-222222222222",
                    "fromHandle": "@claimed-source",
                })
        finally:
            globals_["current_tty"] = original_tty

        self.assertEqual(payload["sourceConversationID"], "22222222-2222-2222-2222-222222222222")
        self.assertEqual(payload["sourceHandle"], "@claimed-source")
        self.assertEqual(payload["nonce"], "launch-proof")
        self.assertEqual(payload["sourceTTY"], "/dev/ttys123")

    def test_parent_source_environment_is_used_when_mcp_subprocess_env_is_empty(self):
        captured = {}
        globals_ = MODULE["tool_send_pane_input"].__globals__
        source_globals = MODULE["with_source_context"].__globals__
        environment_globals = MODULE["source_environment_for_context"].__globals__
        original_submit = globals_["submit_request"]
        original_tty = source_globals["current_tty"]
        original_parent_env = environment_globals["parent_process_environment"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=20.0):
                captured["request_type"] = request_type
                captured["payload"] = payload
                return {"status": "ok"}

            globals_["submit_request"] = fake_submit_request
            source_globals["current_tty"] = lambda: "/dev/ttys123"
            environment_globals["parent_process_environment"] = lambda: {
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
            source_globals["current_tty"] = original_tty
            environment_globals["parent_process_environment"] = original_parent_env

        self.assertEqual(result["status"], "ok")
        self.assertEqual(captured["request_type"], "send_pane_input")
        self.assertEqual(captured["payload"]["sourceConversationID"], "33333333-3333-3333-3333-333333333333")
        self.assertEqual(captured["payload"]["sourceHandle"], "@parent-codex")
        self.assertEqual(captured["payload"]["sourceTTY"], "/dev/ttys123")

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
        source_globals = MODULE["with_source_context"].__globals__
        environment_globals = MODULE["source_environment_for_context"].__globals__
        original_submit = globals_["submit_request"]
        original_tty = source_globals["current_tty"]
        original_parent_env = environment_globals["parent_process_environment"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=20.0):
                captured["request_type"] = request_type
                captured["payload"] = payload
                captured["automation_dir"] = automation_dir
                return {"status": "ok"}

            globals_["submit_request"] = fake_submit_request
            source_globals["current_tty"] = lambda: None
            environment_globals["parent_process_environment"] = lambda: {
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
            source_globals["current_tty"] = original_tty
            environment_globals["parent_process_environment"] = original_parent_env

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
        self.assertEqual(captured["request_type"], "send_agent_message")
        self.assertEqual(captured["payload"]["handles"], ["@reviewer"])
        self.assertEqual(captured["payload"]["sourceConversationID"], "11111111-1111-1111-1111-111111111111")
        self.assertEqual(captured["payload"]["deliveryPreference"], "automatic")
        self.assertTrue(captured["payload"]["requestAttention"])
        self.assertEqual(captured["payload"]["lineEnding"], "enter")
        self.assertEqual(captured["payload"]["targetWindowID"], "window-a")

    def test_message_agent_refuses_to_create_or_guess_target(self):
        with self.assertRaisesRegex(RuntimeError, "requires handles or conversationIDs"):
            MODULE["tool_message_agent"]({"text": "please review"})

    def test_message_agent_rejects_raw_unsubmitted_terminal_input(self):
        with self.assertRaisesRegex(RuntimeError, "complete message"):
            MODULE["tool_message_agent"]({
                "handles": ["@reviewer"],
                "text": "please review",
                "lineEnding": "none",
            })

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
        self.assertNotIn("promptDeliveryWaitMs", result)

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
        self.assertNotIn("promptDeliveryWaitMs", result)

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
        self.assertNotIn("promptDeliveryWaitMs", result)

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
        self.assertNotIn("promptDeliveryWaitMs", result)

    def test_prompt_delivery_summary_uses_app_ack_without_sleeping(self):
        response = {
            "status": "ok",
            "createdPanes": [
                {"promptDeliveryStatus": "acknowledged"},
                {"promptDeliveryStatus": "acknowledged"},
            ],
        }

        result = MODULE["wait_for_initial_prompt_delivery"]({}, response)

        self.assertEqual(result["promptDeliveryStatus"], "acknowledged")
        self.assertEqual(
            result["promptDeliveryStatuses"],
            ["acknowledged", "acknowledged"],
        )
        self.assertNotIn("promptDeliveryWaitMs", result)

    def test_agent_creation_timeout_scales_with_real_prompt_acknowledgements(self):
        sessions = [
            {"agent": "codex", "prompt": "review"},
            {"agent": "opencode", "prompt": "review"},
            {"agent": "shell", "prompt": "printf ok"},
        ]

        self.assertEqual(MODULE["creation_request_timeout"]({}, sessions), 261.5)
        self.assertEqual(
            MODULE["creation_request_timeout"]({"timeout": 17}, sessions),
            17.0,
        )
        self.assertEqual(
            MODULE["creation_request_timeout"]({}, [{"agent": "shell", "prompt": "ls"}]),
            MODULE["DEFAULT_BATCH_CREATE_TIMEOUT"],
        )

        tool = next(tool for tool in MODULE["TOOLS"] if tool["name"] == "open_agent_pane")
        self.assertEqual(
            tool["inputSchema"]["properties"]["timeout"]["default"],
            MODULE["DEFAULT_AGENT_CREATE_TIMEOUT"],
        )

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

    def test_list_agents_is_global_grouped_and_marks_callers_workspace_first(self):
        globals_ = MODULE["tool_list_agents"].__globals__
        original_submit = globals_["submit_request"]
        try:
            def fake_submit_request(request_type, payload, automation_dir=None, timeout=10.0):
                self.assertNotIn("workspaceIDs", payload)
                return {
                    "status": "ok",
                    "sourceIdentity": {
                        "workspaceID": "workspace-current",
                        "workspaceName": "Current Team",
                        "handle": "@delia",
                    },
                    "activeContext": {
                        "workspaceID": "workspace-other",
                        "workspaceName": "Other",
                    },
                    "listedAgents": [
                        {
                            "conversationID": "other-id",
                            "workspaceID": "workspace-other",
                            "workspaceName": "Other",
                            "handle": "@remote",
                            "messageTarget": {"handles": ["@remote"]},
                            "replyInstructions": "legacy @remote instructions",
                        },
                        {
                            "conversationID": "current-id",
                            "workspaceID": "workspace-current",
                            "workspaceName": "Current Team",
                            "handle": "@caia",
                            "messageTarget": {"handles": ["@caia"]},
                            "replyInstructions": "legacy @caia instructions",
                        },
                    ],
                }

            globals_["submit_request"] = fake_submit_request
            result = MODULE["tool_list_agents"]({"fromHandle": "@delia"})
        finally:
            globals_["submit_request"] = original_submit

        self.assertEqual(result["directoryScope"], "global")
        self.assertEqual(result["currentWorkspace"]["workspaceID"], "workspace-current")
        self.assertEqual(result["currentWorkspace"]["resolution"], "sourceIdentity")
        self.assertEqual(result["workspaceGroups"][0]["workspaceID"], "workspace-current")
        self.assertTrue(result["workspaceGroups"][0]["sameWorkspace"])
        by_id = {agent["conversationID"]: agent for agent in result["listedAgents"]}
        self.assertTrue(by_id["current-id"]["sameWorkspace"])
        self.assertTrue(by_id["current-id"]["currentWorkspace"])
        self.assertEqual(by_id["current-id"]["displayReference"], "[caia]")
        self.assertEqual(by_id["current-id"]["routingHandle"], "@caia")
        self.assertFalse(by_id["other-id"]["sameWorkspace"])
        self.assertEqual(by_id["other-id"]["displayReference"], "[remote]")
        self.assertNotIn("@remote", by_id["other-id"]["replyInstructions"])
        self.assertEqual(result["sourceIdentity"]["displayReference"], "[delia]")
        self.assertIn("Legacy @handles", result["routingCompatibility"])

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

    def test_open_workspace_requires_pane_name(self):
        with self.assertRaisesRegex(RuntimeError, "Pane spec is missing name."):
            MODULE["tool_open_workspace"]({"panes": [{"path": "."}]})


if __name__ == "__main__":
    unittest.main()
