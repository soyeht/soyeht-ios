#!/usr/bin/env -S uv run
"""Presence-heartbeat pacing: a permanent profile rejection must not retry
at the fast "app not ready" cadence.

26 stranded dev-profile clients inside release panes retrying at the old
5-second cap produced a sustained ~5 req/s rejection storm in the app's
automation loop (2026-08-29). These tests pin the classification and the
pacing so a regression back to fast-retry-on-rejection goes red.
"""
import threading
import time
import unittest
from pathlib import Path

import runpy

MODULE = runpy.run_path(str(Path(__file__).resolve().parents[2] / "scripts" / "soyeht-mcp"))
RUNTIME = MODULE["register_messaging_client_presence"].__globals__


class PresenceOutcomeClassificationTests(unittest.TestCase):
    def classify(self, response):
        return RUNTIME["_presence_outcome"](response)

    def test_ok_status_is_registered(self):
        self.assertEqual(self.classify({"status": "ok"}), RUNTIME["PRESENCE_REGISTERED"])

    def test_profile_rejection_in_message_is_rejected(self):
        response = {
            "status": "error",
            "message": "Soyeht rejected MCP profile dev; this app accepts the release integration.",
        }
        self.assertEqual(self.classify(response), RUNTIME["PRESENCE_REJECTED"])

    def test_profile_rejection_in_error_field_is_rejected(self):
        response = {
            "status": "error",
            "error": "Soyeht rejected MCP profile release; this app accepts the dev integration.",
        }
        self.assertEqual(self.classify(response), RUNTIME["PRESENCE_REJECTED"])

    def test_other_failures_stay_unavailable(self):
        self.assertEqual(
            self.classify({"status": "error", "message": "no pane bound"}),
            RUNTIME["PRESENCE_UNAVAILABLE"],
        )
        self.assertEqual(self.classify({}), RUNTIME["PRESENCE_UNAVAILABLE"])


class PresenceDelayTests(unittest.TestCase):
    def next_delay(self, outcome, current):
        return RUNTIME["_next_presence_delay"](outcome, current)

    def test_registered_uses_heartbeat_cadence(self):
        self.assertEqual(
            self.next_delay(RUNTIME["PRESENCE_REGISTERED"], 0.5),
            RUNTIME["PRESENCE_DELAY_REGISTERED"],
        )

    def test_unavailable_doubles_up_to_the_historical_cap(self):
        delays = []
        current = 0.5
        for _ in range(5):
            current = self.next_delay(RUNTIME["PRESENCE_UNAVAILABLE"], current)
            delays.append(current)
        self.assertEqual(delays, [1.0, 2.0, 4.0, 5.0, 5.0])

    def test_rejection_parks_far_above_the_fast_cadence(self):
        rejected = self.next_delay(RUNTIME["PRESENCE_REJECTED"], 0.5)
        self.assertEqual(rejected, RUNTIME["PRESENCE_DELAY_REJECTED"])
        # The load-bearing property: a rejected client must be at least two
        # orders of magnitude quieter than the "app not ready" retry. A mutant
        # that folds rejection back into the fast cadence fails here.
        self.assertGreaterEqual(rejected, RUNTIME["PRESENCE_DELAY_UNAVAILABLE_CAP"] * 100)

    def test_rejection_is_not_terminal_it_still_probes(self):
        self.assertLess(RUNTIME["PRESENCE_DELAY_REJECTED"], float("inf"))


class PresenceLoopWiringTests(unittest.TestCase):
    def test_loop_paces_by_classified_outcome(self):
        recorded = []
        stop = threading.Event()

        original_register = RUNTIME["register_messaging_client_presence"]
        original_next = RUNTIME["_next_presence_delay"]

        def fake_register():
            return RUNTIME["PRESENCE_REJECTED"]

        def recording_next(outcome, current):
            recorded.append(outcome)
            if len(recorded) >= 2:
                stop.set()
            return 0.01

        RUNTIME["register_messaging_client_presence"] = fake_register
        RUNTIME["_next_presence_delay"] = recording_next
        try:
            thread = threading.Thread(
                target=RUNTIME["_messaging_presence_heartbeat_loop"],
                kwargs={"stop_event": stop},
                daemon=True,
            )
            thread.start()
            thread.join(timeout=5)
            self.assertFalse(thread.is_alive(), "heartbeat loop did not stop")
        finally:
            RUNTIME["register_messaging_client_presence"] = original_register
            RUNTIME["_next_presence_delay"] = original_next

        self.assertTrue(recorded)
        self.assertTrue(all(o == RUNTIME["PRESENCE_REJECTED"] for o in recorded))


if __name__ == "__main__":
    unittest.main()
