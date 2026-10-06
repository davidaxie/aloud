"""run.py and native_app.py: bind address, port checks, ALOUD_PORT parsing.

F053 (loopback by default), F060 (run.py checks the port first) and F103
(native_app parses ALOUD_PORT once and only trusts an Aloud /health). Every
probe is mocked; nothing binds or connects.
"""

from __future__ import annotations

import io
import json
import os
import threading
import time
import unittest
import urllib.error
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

from support import load_module  # noqa: I001 — puts backend/ on sys.path first

import native_app


def load_run(**env: str):
    """Import run.py fresh with exactly ``env`` for the ALOUD_* variables."""
    clean = {k: v for k, v in os.environ.items() if not k.startswith("ALOUD_")}
    clean.update(env)
    with mock.patch.dict(os.environ, clean, clear=True):
        return load_module("aloud_run_under_test", "run.py")


class RunHostTests(unittest.TestCase):
    def test_default_bind_is_loopback(self) -> None:
        self.assertEqual(load_run().HOST, "127.0.0.1")

    def test_lan_is_an_explicit_opt_in(self) -> None:
        self.assertEqual(load_run(ALOUD_HOST="0.0.0.0").HOST, "0.0.0.0")

    def test_invalid_port_falls_back_instead_of_crashing(self) -> None:
        self.assertEqual(load_run(ALOUD_PORT="abc").PORT, 8000)
        self.assertEqual(load_run(ALOUD_PORT="8123").PORT, 8123)


class RunPreflightTests(unittest.TestCase):
    def setUp(self) -> None:
        self.run = load_run()

    def preflight(self, *, aloud: bool, in_use: bool):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(
            self.run, "probe_backend", return_value={"engine": "kokoro"} if aloud else None
        ), mock.patch.object(self.run, "port_in_use", return_value=in_use), redirect_stdout(
            out
        ), redirect_stderr(err):
            code = self.run.preflight(8000)
        return code, out.getvalue(), err.getvalue()

    def test_free_port_goes_ahead(self) -> None:
        self.assertEqual(self.preflight(aloud=False, in_use=False)[0], None)

    def test_running_aloud_backend_is_reused(self) -> None:
        code, out, _ = self.preflight(aloud=True, in_use=True)
        self.assertEqual(code, 0)
        self.assertIn("already running", out)

    def test_other_program_on_the_port_stops_startup(self) -> None:
        code, _, err = self.preflight(aloud=False, in_use=True)
        self.assertEqual(code, 1)
        self.assertIn("in use by another program", err)

    def test_main_does_not_start_uvicorn_when_preflight_says_stop(self) -> None:
        with mock.patch.object(self.run, "preflight", return_value=1), mock.patch.object(
            self.run.uvicorn, "run"
        ) as uvicorn_run:
            self.assertEqual(self.run.main(), 1)
        uvicorn_run.assert_not_called()


class FakeResponse:
    def __init__(self, payload) -> None:
        self.status = 200
        self._body = json.dumps(payload).encode()

    def read(self) -> bytes:
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc) -> None:
        return None


class NativePortTests(unittest.TestCase):
    def test_invalid_aloud_port_does_not_crash_choose_port(self) -> None:
        with mock.patch.dict(os.environ, {"ALOUD_PORT": "abc"}), mock.patch.object(
            native_app, "port_in_use", return_value=False
        ):
            self.assertIsNone(native_app.env_port())
            self.assertEqual(native_app.choose_port(), native_app.DEFAULT_PORT)

    def test_valid_aloud_port_is_used(self) -> None:
        with mock.patch.dict(os.environ, {"ALOUD_PORT": "8123"}):
            self.assertEqual(native_app.choose_port(), 8123)


class NativeHealthTests(unittest.TestCase):
    def test_foreign_ok_is_not_mistaken_for_aloud(self) -> None:
        with mock.patch.object(
            native_app.urllib.request, "urlopen", return_value=FakeResponse({"status": "ok"})
        ), mock.patch.object(native_app.time, "sleep"):
            self.assertFalse(native_app._wait_for_health("http://127.0.0.1:1", 0.2))

    def test_non_object_health_is_not_a_crash(self) -> None:
        with mock.patch.object(
            native_app.urllib.request, "urlopen", return_value=FakeResponse(["ok"])
        ), mock.patch.object(native_app.time, "sleep"):
            self.assertFalse(native_app._wait_for_health("http://127.0.0.1:1", 0.2))

    def test_aloud_health_counts_while_warming(self) -> None:
        payload = {"status": "warming", "engine": "kokoro"}
        with mock.patch.object(
            native_app.urllib.request, "urlopen", return_value=FakeResponse(payload)
        ):
            self.assertTrue(native_app._wait_for_health("http://127.0.0.1:1", 5))

    def test_dead_server_thread_fails_at_once(self) -> None:
        dead = threading.Thread(target=lambda: None)
        dead.start()
        dead.join()
        started = time.monotonic()
        with mock.patch.object(
            native_app.urllib.request,
            "urlopen",
            side_effect=urllib.error.URLError("connection refused"),
        ):
            self.assertFalse(native_app._wait_for_health("http://127.0.0.1:1", 30, dead))
        self.assertLess(time.monotonic() - started, 2)


if __name__ == "__main__":
    unittest.main()
