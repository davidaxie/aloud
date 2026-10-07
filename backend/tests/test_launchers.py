"""run.py and native_app.py: bind address, port checks, ALOUD_PORT parsing.

F053 (loopback by default), F060 (run.py checks the port first) and F103
(native_app parses ALOUD_PORT once and only trusts an Aloud /health). Every
probe is mocked; nothing binds or connects.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from support import BACKEND, load_module  # noqa: I001 — puts backend/ on sys.path first

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

    def test_print_port_answers_without_serving(self) -> None:
        run = load_run(ALOUD_PORT=" 8001 ")
        out = io.StringIO()
        with mock.patch.object(run.uvicorn, "run") as uvicorn_run, mock.patch.object(
            run, "preflight"
        ) as preflight, redirect_stdout(out):
            self.assertEqual(run.main(["--print-port"]), 0)
        self.assertEqual(out.getvalue().strip(), "8001")
        uvicorn_run.assert_not_called()
        preflight.assert_not_called()


# Stand-ins run.sh finds instead of the real backend, npm and curl. Each logs
# what it was asked into $FAKE_LOG so a test can see what run.sh did.
_FAKE_PYTHON = """#!/bin/bash
if [[ "$1" == run.py && "$2" == --print-port ]]; then
  exec "$REAL_PYTHON" "$REAL_BACKEND/run.py" --print-port
fi
echo "serve $*" >> "$FAKE_LOG/python"
exec sleep 30
"""
_FAKE_NPM = """#!/bin/bash
echo "${VITE_API_BASE-unset}" > "$FAKE_LOG/npm"
"""
_FAKE_CURL = """#!/bin/bash
for url; do :; done
echo "$url" >> "$FAKE_LOG/curl"
if [[ "$url" == "http://127.0.0.1:$FAKE_SERVE_PORT/health" ]]; then
  echo '{"status":"ok","engine":"kokoro"}'
  exit 0
fi
exit 7
"""


class RunShTests(unittest.TestCase):
    """G009 and G027: run.sh waits on the port run.py serves and points the reader at it.

    run.sh runs from a temp copy of the repo layout with a fake backend, npm and
    curl, so nothing binds a port, loads a model or reaches the network.
    """

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        shutil.copy(BACKEND.parent / "run.sh", root / "run.sh")
        (root / "backend" / "models").mkdir(parents=True)
        for name in ("kokoro-v1.0.onnx", "voices-v1.0.bin"):
            (root / "backend" / "models" / name).touch()
        (root / "frontend" / "node_modules").mkdir(parents=True)
        self.log = root / "log"
        self.log.mkdir()
        fakes = {
            root / "backend" / ".venv" / "bin" / "python": _FAKE_PYTHON,
            root / "bin" / "npm": _FAKE_NPM,
            root / "bin" / "curl": _FAKE_CURL,
        }
        for path, text in fakes.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            path.chmod(0o755)
        self.root = root

    def run_sh(self, serve_port: int, **env: str) -> subprocess.CompletedProcess:
        clean = {
            k: v
            for k, v in os.environ.items()
            if not k.startswith("ALOUD_") and k != "VITE_API_BASE"
        }
        clean.update(
            PATH=f"{self.root / 'bin'}{os.pathsep}{os.environ.get('PATH', '')}",
            REAL_PYTHON=sys.executable,
            REAL_BACKEND=str(BACKEND),
            FAKE_LOG=str(self.log),
            FAKE_SERVE_PORT=str(serve_port),
            **env,
        )
        proc = subprocess.Popen(
            ["bash", str(self.root / "run.sh")],
            env=clean,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            out, err = proc.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            out, err = "", ""
            self.fail("run.sh was still waiting after 10 s")
        finally:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
        return subprocess.CompletedProcess(proc.args, proc.returncode, out, err)

    def polled(self) -> set[str]:
        return set((self.log / "curl").read_text().split())

    def test_waits_on_the_port_run_py_serves(self) -> None:
        for raw, served in (("80000", 8000), ("0", 8000), ("8001 ", 8001)):
            with self.subTest(ALOUD_PORT=raw):
                (self.log / "curl").unlink(missing_ok=True)
                result = self.run_sh(served, ALOUD_PORT=raw)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Aloud is ready", result.stdout)
                self.assertEqual(self.polled(), {f"http://127.0.0.1:{served}/health"})

    def test_reader_is_pointed_at_the_backend_port(self) -> None:
        result = self.run_sh(8001, ALOUD_PORT="8001")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.log / "npm").read_text().strip(), "http://localhost:8001")

    def test_reader_keeps_an_api_base_set_by_hand(self) -> None:
        result = self.run_sh(8000, VITE_API_BASE="http://my-mac.local:8000")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.log / "npm").read_text().strip(), "http://my-mac.local:8000")

    def test_gives_up_when_nothing_answers(self) -> None:
        started = time.monotonic()
        result = self.run_sh(1, ALOUD_START_TIMEOUT="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("http://127.0.0.1:8000/health", result.stderr)
        self.assertNotIn("Aloud is ready", result.stdout)
        self.assertNotIn("ALOUD_HOST", result.stderr)
        self.assertLess(time.monotonic() - started, 15)

    def test_timeout_names_a_bind_address_that_leaves_out_loopback(self) -> None:
        result = self.run_sh(1, ALOUD_START_TIMEOUT="1", ALOUD_HOST="192.168.1.5")
        self.assertEqual(result.returncode, 1)
        self.assertIn("ALOUD_HOST", result.stderr)


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
