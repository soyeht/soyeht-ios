#!/usr/bin/env python3
"""Regression tests for the real-agent behavioral E2E harness."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


RUNNER_PATH = Path(__file__).with_name("soyeht_agent_driven_e2e.py")
SPEC = importlib.util.spec_from_file_location("soyeht_agent_driven_e2e", RUNNER_PATH)
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class NaturalUserPromptTests(unittest.TestCase):
    def assertImplementationBlind(self, prompt):
        RUNNER.require_natural_user_prompt(prompt)

    def test_collaboration_prompt_expresses_intent_without_naming_tools(self):
        prompt = RUNNER.natural_collaboration_prompt(
            child_agent="opencode",
            child_name="revisor",
            directory=Path("/tmp/projeto"),
            token="RESPOSTA_EXATA",
            completion_prefix="CONCLUIDO",
        )

        self.assertIn("abra uma nova pane com opencode", prompt)
        self.assertIn("fale com esse agente", prompt)
        self.assertImplementationBlind(prompt)

    def test_collision_prompts_express_intent_without_naming_tools(self):
        setup = RUNNER.natural_collision_setup_prompt(
            recipient_agent="claude",
            recipient_name="revisor",
            recipient_directory=Path("/tmp/projeto"),
            recipient_ready_token="PRONTO",
            ready_token="PANE_PRONTA",
            relay_token="RESPOSTA_EXATA",
            completion_prefix="CONCLUIDO",
        )

        self.assertIn("abra uma nova pane com claude", setup)
        self.assertIn("fale com o agente revisor", setup)
        self.assertImplementationBlind(setup)

    def test_prompt_guard_rejects_tool_name_leakage(self):
        for prompt in (
            "Use message_agent para falar com o revisor.",
            "Abra com soyeht-dev.open_agent_pane.",
            "Use o MCP para enviar a mensagem.",
        ):
            with self.subTest(prompt=prompt):
                with self.assertRaisesRegex(RuntimeError, "implementation vocabulary"):
                    RUNNER.require_natural_user_prompt(prompt)

    def test_prompt_guard_allows_mcp_as_part_of_a_real_directory_name(self):
        RUNNER.require_natural_user_prompt(
            "Abra o opencode no diretório /tmp/iSoyehtTerm-mcp2-orchestration/QA."
        )


if __name__ == "__main__":
    unittest.main()
