"""Calibrate the probe without contacting or restarting any installed service."""
import asyncio
import importlib.util
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[1] / "pty-survival-probe.py"
SPEC = importlib.util.spec_from_file_location("pty_survival_probe", PATH)
probe = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = probe
SPEC.loader.exec_module(probe)


class BehaviourCalibration(unittest.TestCase):
    def test_old_challenge_and_nonce_from_replay_do_not_prove_current_io(self):
        challenges = []

        def reply(_port, _token, _conversation, sends, **_kwargs):
            current = sends[-1].rsplit("'", 2)[1]
            challenges.append(current)
            if len(challenges) == 1:
                # The first attempt answers, but its numbered writer is not
                # done yet. The second returns only replay of that old answer.
                return f"AFTER:{current}:memory\nCHALLENGE:{current}\n"
            return (f"AFTER:{challenges[0]}:memory\nCHALLENGE:{challenges[0]}\n"
                    + "\n".join(f"ABSENT:{n:03}" for n in range(1, 65)))

        with patch.object(probe, "converse", side_effect=reply), patch.object(probe.time, "sleep"):
            result = probe.verify_session(8902, "fixture", "pane", "memory")
        self.assertEqual(len(challenges), 2)
        self.assertNotEqual(*challenges)
        self.assertTrue(result["detached_output"][0])
        self.assertFalse(result["responds"][0])
        self.assertFalse(result["nonce"][0])

    def test_fresh_response_passes_but_exported_nonce_does_not(self):
        def reply(_port, _token, _conversation, sends, **_kwargs):
            challenge = sends[-1].rsplit("'", 2)[1]
            return (f"AFTER:{challenge}:memory\nCHALLENGE:{challenge}\n"
                    + "\n".join(f"ABSENT:{n:03}" for n in range(1, 65)))

        with patch.object(probe, "converse", side_effect=reply):
            result = probe.verify_session(8902, "fixture", "pane", "memory")
        self.assertTrue(all(value[0] for value in result.values()))
        with patch.object(probe, "converse", side_effect=lambda *a, **kw:
                          reply(*a, **kw) + "\nSOYEHT_PROBE_NONCE=memory\n"):
            result = probe.verify_session(8902, "fixture", "pane", "memory")
        self.assertFalse(result["nonce"][0])

    def test_kickstart_names_the_operation_and_bootout_is_not_an_alias(self):
        engine = {"command": probe.DEV_ENGINE_PATH_FRAGMENT, "pid": 123, "start": "original"}
        with patch.object(probe.subprocess, "run") as run, patch.object(probe, "process_identity", return_value=engine):
            probe.provoke_failure("kickstart", engine)
        self.assertEqual(run.call_args.args[0][1:3], ["kickstart", "-k"])
        with patch.object(probe.subprocess, "run") as run, patch.object(probe, "process_identity", return_value=engine), self.assertRaises(SystemExit):
            probe.provoke_failure("bootout", engine)
        run.assert_not_called()

    def test_recycled_pid_cannot_be_killed_after_arming(self):
        engine = {"command": probe.DEV_ENGINE_PATH_FRAGMENT, "pid": 123, "start": "original"}
        current = {**engine, "start": "replacement"}
        with patch.object(probe.os, "kill") as kill, patch.object(probe, "process_identity", return_value=current), self.assertRaises(SystemExit):
            probe.provoke_failure("sigkill", engine)
        kill.assert_not_called()


class FakeSocket:
    def __init__(self, messages):
        self.messages = messages

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_args):
        return False

    def __aiter__(self):
        return self.iterate()

    async def iterate(self):
        for message in self.messages:
            yield message


class SupervisedFrameCalibration(unittest.TestCase):
    def test_payload_prefix_is_decoded_and_offset_discontinuity_is_rejected(self):
        session = {"backend": "supervisor", "session_instance_id": "00000000-0000-4000-8000-000000000001"}

        def read(messages):
            connection = FakeSocket(messages)
            module = types.SimpleNamespace(connect=lambda *_a, **_kw: connection)
            with patch.dict(sys.modules, {"websockets": module}):
                return asyncio.run(probe._converse(8902, "fixture", "pane", [], 0, session=session))

        frame = lambda offset, payload: probe.PTY_PREFIX + offset.to_bytes(8, "big") + payload
        self.assertEqual(read([frame(0, b"first"), frame(5, b"second")]), "firstsecond")
        with self.assertRaisesRegex(RuntimeError, "skipped or duplicated"):
            read([frame(0, b"first"), frame(0, b"first")])
        with self.assertRaisesRegex(RuntimeError, "invalid supervised"):
            read([b"legacy bytes without framing"])


if __name__ == "__main__":
    unittest.main()
