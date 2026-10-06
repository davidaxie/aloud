"""POST /synthesize bounds, the local-only gate, and dropping abandoned jobs.

Run from the repo root:
    backend/.venv/bin/python -m unittest discover backend/tests
"""

from __future__ import annotations

import threading
import time
import unittest
from unittest import mock

from support import WARMUP_TEXT, call, load_app, make_queue, silent_synth, synth_body


class RecordingSynth:
    """A synth_fn that records every text it is asked for and can hold one in flight."""

    def __init__(self, hold: str | None = None) -> None:
        self.calls: list[str] = []
        self.hold = hold
        self.holding = threading.Event()
        self.release = threading.Event()

    def __call__(self, text: str, voice: str, speed: float):
        if text != WARMUP_TEXT:
            self.calls.append(text)
        if text == self.hold:
            self.holding.set()
            self.release.wait(5)
        return silent_synth(text, voice, speed)


class InputLimitTests(unittest.TestCase):
    """F050: oversized input is refused before it reaches the single worker."""

    def setUp(self) -> None:
        self.app_module = load_app()
        self.synth = RecordingSynth()
        self.queue = make_queue(self.synth)
        patcher = mock.patch.object(self.app_module, "synth_queue", self.queue)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.queue.stop)

    def post(self, body: bytes, **kwargs):
        return call(self.app_module.app, "POST", "/synthesize", body=body, **kwargs)

    def test_text_over_the_limit_is_413_and_never_queued(self) -> None:
        reply = self.post(synth_body("a" * (self.app_module.MAX_TEXT_CHARS + 1)))
        self.assertEqual(reply.status, 413)
        self.assertIs(reply.json()["retryable"], False)
        self.assertEqual(self.synth.calls, [])

    def test_text_at_the_limit_is_synthesized(self) -> None:
        reply = self.post(synth_body("a" * self.app_module.MAX_TEXT_CHARS))
        self.assertEqual(reply.status, 200)
        self.assertEqual(reply.headers["content-type"], "audio/wav")
        self.assertTrue(reply.body.startswith(b"RIFF"))

    def test_overlong_voice_is_400_and_never_queued(self) -> None:
        reply = self.post(synth_body("Hello.", voice="v" * (self.app_module.MAX_VOICE_CHARS + 1)))
        self.assertEqual(reply.status, 400)
        self.assertIs(reply.json()["retryable"], False)
        self.assertEqual(self.synth.calls, [])

    def test_declared_oversized_body_is_413(self) -> None:
        body = b"x" * (self.app_module.MAX_BODY_BYTES + 1)
        reply = self.post(body)
        self.assertEqual(reply.status, 413)
        self.assertIs(reply.json()["retryable"], False)
        self.assertEqual(self.synth.calls, [])

    def test_streamed_oversized_body_without_length_is_413(self) -> None:
        chunk = b" " * 16_384
        reply = call(
            self.app_module.app,
            "POST",
            "/synthesize",
            chunks=[chunk] * 5,  # 80 KB, no Content-Length
            headers={"content-type": "application/json"},
        )
        self.assertEqual(reply.status, 413)
        self.assertEqual(self.synth.calls, [])

    def test_small_streamed_body_still_reaches_the_handler(self) -> None:
        body = synth_body("Hello there.")
        reply = call(
            self.app_module.app,
            "POST",
            "/synthesize",
            chunks=[body[:10], body[10:]],
            headers={"content-type": "application/json"},
        )
        self.assertEqual(reply.status, 200)
        self.assertEqual(self.synth.calls, ["Hello there."])


class LocalOnlyTests(unittest.TestCase):
    """F054: only this machine's pages and Host names get through."""

    def setUp(self) -> None:
        self.app_module = load_app()
        self.synth = RecordingSynth()
        self.queue = make_queue(self.synth)
        patcher = mock.patch.object(self.app_module, "synth_queue", self.queue)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.queue.stop)

    def preflight(self, origin: str):
        return call(
            self.app_module.app,
            "OPTIONS",
            "/synthesize",
            headers={
                "origin": origin,
                "access-control-request-method": "POST",
                "access-control-request-headers": "content-type",
            },
        )

    def test_preflight_from_another_site_is_refused(self) -> None:
        reply = self.preflight("https://any-site.example")
        self.assertNotEqual(reply.status, 200)
        self.assertNotIn("access-control-allow-origin", reply.headers)

    def test_preflight_from_the_dev_server_is_allowed(self) -> None:
        for origin in ("http://localhost:5173", "http://127.0.0.1:5174"):
            reply = self.preflight(origin)
            self.assertEqual(reply.status, 200, origin)
            self.assertEqual(reply.headers.get("access-control-allow-origin"), origin)

    def test_lookalike_origin_is_refused(self) -> None:
        reply = self.preflight("http://localhost.attacker.example")
        self.assertNotIn("access-control-allow-origin", reply.headers)

    def test_rebound_host_is_refused_before_synthesis(self) -> None:
        reply = call(
            self.app_module.app,
            "POST",
            "/synthesize",
            body=synth_body("Hello."),
            headers={"content-type": "application/json"},
            host="rebind.attacker.example:8000",
        )
        self.assertEqual(reply.status, 400)
        self.assertEqual(self.synth.calls, [])

    def test_loopback_hosts_are_served(self) -> None:
        for host in ("localhost:8000", "127.0.0.1:8000"):
            reply = call(self.app_module.app, "GET", "/health", host=host)
            self.assertEqual(reply.status, 200, host)
            self.assertEqual(reply.json()["engine"], "kokoro")


class AbandonedRequestTests(unittest.TestCase):
    """F056: a request whose client hangs up is dropped, not synthesized later."""

    def setUp(self) -> None:
        self.app_module = load_app()
        self.synth = RecordingSynth(hold="in flight")
        self.queue = make_queue(self.synth)
        patcher = mock.patch.object(self.app_module, "synth_queue", self.queue)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.queue.stop)
        self.addCleanup(self.synth.release.set)

    def test_hung_up_request_is_never_synthesized(self) -> None:
        # Occupy the worker so the request has to wait in the queue.
        blocker = threading.Thread(target=self.queue.submit, args=("in flight", "af_heart", 1.0))
        blocker.start()
        self.assertTrue(self.synth.holding.wait(5))

        reply = call(
            self.app_module.app,
            "POST",
            "/synthesize",
            body=synth_body("abandoned"),
            headers={"content-type": "application/json"},
            hang_up_after_body=True,
        )
        self.assertEqual(reply.status, 499)
        self.assertEqual(self.queue.queue_depth, 0)

        self.synth.release.set()
        blocker.join(5)
        # Anything queued after the abandoned job runs; the abandoned job never does.
        self.queue.submit("next", "af_heart", 1.0)
        self.assertEqual(self.synth.calls, ["in flight", "next"])

    def test_connected_request_waits_and_gets_audio(self) -> None:
        blocker = threading.Thread(target=self.queue.submit, args=("in flight", "af_heart", 1.0))
        blocker.start()
        self.assertTrue(self.synth.holding.wait(5))
        threading.Timer(0.4, self.synth.release.set).start()

        started = time.monotonic()
        reply = call(
            self.app_module.app,
            "POST",
            "/synthesize",
            body=synth_body("wanted"),
            headers={"content-type": "application/json"},
        )
        self.assertEqual(reply.status, 200)
        self.assertTrue(reply.body.startswith(b"RIFF"))
        self.assertGreaterEqual(time.monotonic() - started, 0.3)
        self.assertEqual(self.synth.calls, ["in flight", "wanted"])
        blocker.join(5)


if __name__ == "__main__":
    unittest.main()
