"""SynthQueue.cancel: an abandoned job leaves the queue without running (F056)."""

from __future__ import annotations

import threading
import unittest

from support import WARMUP_TEXT, make_queue, silent_synth  # noqa: I001 — puts backend/ on sys.path first

from synth_queue import JobCancelledError


class CancelTests(unittest.TestCase):
    def setUp(self) -> None:
        self.calls: list[str] = []
        self.holding = threading.Event()
        self.release = threading.Event()

        def synth(text: str, voice: str, speed: float):
            if text != WARMUP_TEXT:
                self.calls.append(text)
            if text == "in flight":
                self.holding.set()
                self.release.wait(5)
            return silent_synth(text, voice, speed)

        self.queue = make_queue(synth)
        self.addCleanup(self.queue.stop)
        self.addCleanup(self.release.set)
        self.in_flight = self.queue.enqueue("in flight", "af_heart", 1.0)
        self.assertTrue(self.holding.wait(5))

    def test_cancelled_waiting_jobs_never_run(self) -> None:
        stale_voice_b = self.queue.enqueue("voice B", "bf_emma", 1.0)
        stale_prefetch = self.queue.enqueue("lookahead", "bf_emma", 1.0, "prefetch")
        wanted = self.queue.enqueue("voice C", "am_adam", 1.0)

        self.assertTrue(self.queue.cancel(stale_voice_b))
        self.assertTrue(self.queue.cancel(stale_prefetch))
        self.assertEqual(self.queue.queue_depth, 1)
        with self.assertRaises(JobCancelledError):
            self.queue.result(stale_voice_b)

        self.release.set()
        self.queue.result(wanted)
        self.assertEqual(self.calls, ["in flight", "voice C"])

    def test_identical_requests_are_cancelled_one_at_a_time(self) -> None:
        first = self.queue.enqueue("same", "af_heart", 1.0)
        second = self.queue.enqueue("same", "af_heart", 1.0)

        self.assertTrue(self.queue.cancel(second))
        self.release.set()
        self.queue.result(first)
        self.assertEqual(self.calls, ["in flight", "same"])

    def test_in_flight_job_cannot_be_recalled(self) -> None:
        self.assertFalse(self.queue.cancel(self.in_flight))
        self.release.set()
        self.queue.result(self.in_flight)  # finishes normally; nobody reads it

    def test_submit_still_blocks_and_returns_the_result(self) -> None:
        self.release.set()
        samples, rate = self.queue.submit("plain", "af_heart", 1.0)
        self.assertEqual(rate, 24000)
        self.assertEqual(len(samples), 240)


if __name__ == "__main__":
    unittest.main()
