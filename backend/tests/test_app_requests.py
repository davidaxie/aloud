"""POST /synthesize bounds, the local-only gate, and dropping abandoned jobs.

Run from the repo root:
    backend/.venv/bin/python -m unittest discover backend/tests
"""

from __future__ import annotations

import importlib.util
import os
import shutil
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest import mock

from fastapi import FastAPI
from support import (
    BACKEND,
    WARMUP_TEXT,
    FakeEngine,
    call,
    load_app,
    load_module,
    make_queue,
    silent_synth,
    synth_body,
)
from synth_queue import QueueFullError


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

    def test_extension_origin_is_allowed(self) -> None:
        # G011: the extension has host permission only for localhost, so against
        # a LAN backend its service worker's calls are ordinary CORS requests.
        origin = "chrome-extension://abcdefghijklmnopabcdefghijklmnop"
        reply = self.preflight(origin)
        self.assertEqual(reply.status, 200)
        self.assertEqual(reply.headers.get("access-control-allow-origin"), origin)
        for path in ("/health", "/voices"):
            reply = call(self.app_module.app, "GET", path, headers={"origin": origin})
            self.assertEqual(reply.headers.get("access-control-allow-origin"), origin, path)

    def test_extension_lookalike_origins_are_refused(self) -> None:
        for origin in (
            "chrome-extension://short",
            "chrome-extension://qrstuvwxyzqrstuvwxyzqrstuvwxyzqr",
            "chrome-extension://abcdefghijklmnopabcdefghijklmnop.attacker.example",
            "https://chrome-extension.example",
        ):
            reply = self.preflight(origin)
            self.assertNotIn("access-control-allow-origin", reply.headers, origin)

    def test_cross_origin_page_can_read_retry_after(self) -> None:
        # G031: the dev reader on :5173 is cross-origin, and Retry-After is not a
        # header a page may read unless the server exposes it.
        full = mock.patch.object(self.queue, "enqueue", side_effect=QueueFullError(8, 8))
        with full:
            reply = call(
                self.app_module.app,
                "POST",
                "/synthesize",
                body=synth_body("Later.", priority="prefetch"),
                headers={"origin": "http://localhost:5173"},
            )
        self.assertEqual(reply.status, 429)
        self.assertEqual(reply.headers.get("retry-after"), "1")
        exposed = reply.headers.get("access-control-expose-headers", "")
        self.assertIn("retry-after", [h.strip().lower() for h in exposed.split(",")])


class AllowedHostsTests(unittest.TestCase):
    """H028: ALOUD_ALLOWED_HOSTS adds LAN names; this Mac's own stay allowed."""

    def setUp(self) -> None:
        load_app()  # quiets the app's import-time logging, as for every other test
        fake = types.ModuleType("kokoro_engine")
        fake.engine = FakeEngine()
        with mock.patch.dict(os.environ, {"ALOUD_ALLOWED_HOSTS": "my-mac.local"}):
            self.app_module = load_module(
                "aloud_app_lan_under_test", "app.py", {"kokoro_engine": fake}
            )
        self.addCleanup(self.app_module.synth_queue.stop)

    def status(self, host: str) -> int:
        return call(self.app_module.app, "GET", "/health", host=host).status

    def test_loopback_names_are_kept_alongside_the_lan_name(self) -> None:
        for host in ("localhost:8000", "127.0.0.1:8000", "my-mac.local:8000"):
            self.assertEqual(self.status(host), 200, host)

    def test_other_names_are_still_refused(self) -> None:
        self.assertEqual(self.status("rebind.attacker.example:8000"), 400)


class ContentTypeTests(unittest.TestCase):
    """G030: a body not declared as JSON never reaches the worker.

    A cross-site page can POST with no Content-Type (or text/plain) and no
    preflight. FastAPI 0.132 and later refuse that body by default, but the
    floor in requirements.txt is older, so the handler checks for itself.
    """

    def setUp(self) -> None:
        self.app_module = load_app()
        self.synth = RecordingSynth()
        self.queue = make_queue(self.synth)
        patcher = mock.patch.object(self.app_module, "synth_queue", self.queue)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.queue.stop)

    def lenient_app(self):
        """The real handler on an app that parses an untyped body as JSON, like FastAPI < 0.132."""
        lenient = FastAPI(strict_content_type=False)
        lenient.post("/synthesize")(self.app_module.synthesize)
        return lenient

    def test_untyped_body_is_refused_even_when_the_framework_parses_it(self) -> None:
        reply = call(
            self.lenient_app(),
            "POST",
            "/synthesize",
            body=synth_body("x" * 2000),
            headers={"origin": "https://any-site.example"},
            content_type=None,
        )
        self.assertEqual(reply.status, 415)
        self.assertIs(reply.json()["retryable"], False)
        self.assertEqual(self.synth.calls, [])

    def test_untyped_body_never_reaches_the_worker(self) -> None:
        for content_type in (None, "text/plain"):
            reply = call(
                self.app_module.app,
                "POST",
                "/synthesize",
                body=synth_body("Hello."),
                content_type=content_type,
            )
            self.assertIn(reply.status, (415, 422), content_type)
        self.assertEqual(self.synth.calls, [])

    def test_json_with_a_charset_is_served(self) -> None:
        for app in (self.app_module.app, self.lenient_app()):
            reply = call(
                app,
                "POST",
                "/synthesize",
                body=synth_body("Hello."),
                content_type="application/json; charset=utf-8",
            )
            self.assertEqual(reply.status, 200)
        self.assertEqual(self.synth.calls, ["Hello.", "Hello."])


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


class SpaShellCacheTests(unittest.TestCase):
    """I016: the window keeps its HTTP cache between launches now, so after a
    rebuild it must not reuse the old index.html, whose bundles are gone."""

    def setUp(self) -> None:
        engine = load_app().engine  # also quiets the app's import-time logging
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = tmp.name
        os.mkdir(os.path.join(root, "backend"))
        shutil.copy(BACKEND / "app.py", os.path.join(root, "backend", "app.py"))
        dist = os.path.join(root, "frontend", "dist")
        os.makedirs(os.path.join(dist, "assets"))
        files = {
            "index.html": "<!doctype html><script src=/assets/index-abc.js></script>",
            "assets/index-abc.js": "console.log(1)",
            "favicon.svg": "<svg/>",
        }
        for name, text in files.items():
            with open(os.path.join(dist, name), "w") as f:
                f.write(text)
        fake = types.ModuleType("kokoro_engine")
        fake.engine = engine
        spec = importlib.util.spec_from_file_location(
            "aloud_app_with_dist", os.path.join(root, "backend", "app.py")
        )
        module = importlib.util.module_from_spec(spec)
        with mock.patch.dict(sys.modules, {"kokoro_engine": fake}):
            spec.loader.exec_module(module)
        self.addCleanup(module.synth_queue.stop)
        self.app = module.app

    def get(self, path: str):
        reply = call(self.app, "GET", path)
        self.assertEqual(reply.status, 200, path)
        return reply

    def test_the_shell_is_checked_before_each_use(self) -> None:
        for path in ("/", "/library/some-book", "/index.html"):
            reply = self.get(path)
            self.assertIn(b"index-abc.js", reply.body, path)
            self.assertEqual(reply.headers.get("cache-control"), "no-cache", path)

    def test_hashed_bundles_and_other_files_stay_cacheable(self) -> None:
        for path in ("/assets/index-abc.js", "/favicon.svg"):
            self.assertNotIn("no-cache", self.get(path).headers.get("cache-control", ""), path)
