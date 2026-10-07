"""run.py, native_app.py, run.sh and download_models.py.

F053 (loopback by default), F060 (run.py checks the port first) and F103
(native_app parses ALOUD_PORT once and only trusts an Aloud /health). H026
(a server on ::1 alone counts), H061 (the window keeps its storage), H062 (the
reader keeps to the port run.sh prints), H063 (pinned packages and model
hashes) and H064 (an attached window takes over when its backend stops). Every
probe is mocked; nothing binds or connects, and nothing is downloaded.
"""

from __future__ import annotations

import contextlib
import hashlib
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
import types
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
echo "$*" > "$FAKE_LOG/npm-args"
exit "${FAKE_NPM_STATUS:-0}"
"""
_FAKE_CURL = """#!/bin/bash
for url; do :; done
if [[ "$url" == */health ]]; then
  echo "$url" >> "$FAKE_LOG/curl"
fi
if [[ -n "${FAKE_UI_BUSY:-}" && "$url" == "http://localhost:$FAKE_UI_BUSY/" ]]; then
  echo '<html>another app</html>'
  exit 0
fi
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
            # macOS answers EPERM, not ESRCH, when only zombies are left in the group.
            with contextlib.suppress(ProcessLookupError, PermissionError):
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
        # I018: 127.0.0.1, where backend_ready looks. localhost is ::1 first,
        # where another server can start later and take every request.
        self.assertEqual((self.log / "npm").read_text().strip(), "http://127.0.0.1:8001")

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

    def test_taken_reader_port_stops_before_anything_starts(self) -> None:
        # H062: Vite used to slide to 5174 while run.sh still printed 5173.
        result = self.run_sh(8000, FAKE_UI_BUSY="5173")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Port 5173", result.stderr)
        self.assertIn("ALOUD_UI_PORT", result.stderr)
        self.assertNotIn("Aloud is ready", result.stdout)
        self.assertFalse((self.log / "npm").exists())
        self.assertFalse((self.log / "python").exists())

    def test_reader_keeps_to_the_port_it_prints(self) -> None:
        result = self.run_sh(8000, ALOUD_UI_PORT="5180")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            (self.log / "npm-args").read_text().split(),
            ["run", "dev", "--", "--port", "5180", "--strictPort"],
        )
        self.assertIn("Aloud is ready. Open  →  http://localhost:5180", result.stdout)
        self.assertNotIn("5173", result.stdout)

    def test_default_reader_port_is_strict(self) -> None:
        result = self.run_sh(8000)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--port 5173 --strictPort", (self.log / "npm-args").read_text())

    def test_reader_that_fails_to_start_is_reported(self) -> None:
        result = self.run_sh(8000, FAKE_NPM_STATUS="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("reader UI stopped", result.stderr)

    def test_vite_config_keeps_to_its_port(self) -> None:
        config = (BACKEND.parent / "frontend" / "vite.config.ts").read_text()
        self.assertIn("strictPort: true", config)


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


def accepting(*hosts: str):
    """A ``socket.create_connection`` stand-in that accepts only on ``hosts``."""

    def connect(address, timeout=None):
        if address[0] in hosts:
            return contextlib.nullcontext()
        raise ConnectionRefusedError(address)

    return connect


class NativeLoopbackTests(unittest.TestCase):
    """H026: a server on ::1 alone is the one clients dialing localhost reach."""

    def setUp(self) -> None:
        self.requests: list = []

    def health(self, by_host: dict[str, object]):
        def urlopen(request, timeout=None):
            self.requests.append(request)
            for prefix, payload in by_host.items():
                if request.full_url.startswith(prefix):
                    return FakeResponse(payload)
            raise urllib.error.URLError("connection refused")

        return urlopen

    def test_server_on_ipv6_loopback_alone_counts_as_busy(self) -> None:
        with mock.patch.object(native_app.socket, "create_connection", accepting("::1")):
            self.assertTrue(native_app.port_in_use(8000))
        with mock.patch.object(native_app.socket, "create_connection", accepting()):
            self.assertFalse(native_app.port_in_use(8000))

    def test_run_py_refuses_a_port_held_on_ipv6_alone(self) -> None:
        run = load_run()
        err = io.StringIO()
        with mock.patch.object(
            native_app.socket, "create_connection", accepting("::1")
        ), mock.patch.object(
            native_app.urllib.request, "urlopen", self.health({})
        ), redirect_stdout(io.StringIO()), redirect_stderr(err):
            self.assertEqual(run.preflight(8000), 1)
        self.assertIn("in use by another program", err.getvalue())

    def test_native_app_does_not_serve_next_to_it(self) -> None:
        # Every port answers on ::1 here, so it falls through to a free port.
        with mock.patch.object(
            native_app.socket, "create_connection", accepting("::1")
        ), mock.patch.dict(os.environ, {"ALOUD_PORT": ""}), mock.patch.object(
            native_app, "_find_free_port", return_value=54321
        ):
            self.assertEqual(native_app.choose_port(), 54321)

    def test_aloud_on_ipv4_with_another_server_on_ipv6_is_not_ours(self) -> None:
        with mock.patch.object(
            native_app.socket, "create_connection", accepting("127.0.0.1", "::1")
        ), mock.patch.object(
            native_app.urllib.request,
            "urlopen",
            self.health(
                {"http://127.0.0.1:": {"status": "ok", "engine": "kokoro"}, "http://[::1]:": {"ok": 1}}
            ),
        ):
            self.assertIsNone(native_app.probe_backend(8000))

    def test_dual_stack_aloud_is_ours_and_asked_as_localhost(self) -> None:
        payload = {"status": "ok", "engine": "kokoro"}
        with mock.patch.object(
            native_app.socket, "create_connection", accepting("127.0.0.1", "::1")
        ), mock.patch.object(
            native_app.urllib.request,
            "urlopen",
            self.health({"http://127.0.0.1:": payload, "http://[::1]:": payload}),
        ):
            self.assertEqual(native_app.probe_backend(8000), payload)
        ipv6 = [r for r in self.requests if r.full_url.startswith("http://[::1]:")]
        self.assertEqual([r.get_header("Host") for r in ipv6], ["localhost:8000"])


class NativePortTests(unittest.TestCase):
    def test_busy_default_port_falls_back_to_a_fixed_one(self) -> None:
        # H061: a random port is a new origin, and the reader's preferences
        # live with the origin.
        with mock.patch.dict(os.environ, {"ALOUD_PORT": ""}), mock.patch.object(
            native_app, "port_in_use", side_effect=lambda port: port == 8000
        ), mock.patch.object(native_app, "_find_free_port") as free:
            self.assertEqual(native_app.choose_port(), 8001)
        free.assert_not_called()

    def test_invalid_aloud_port_does_not_crash_choose_port(self) -> None:
        with mock.patch.dict(os.environ, {"ALOUD_PORT": "abc"}), mock.patch.object(
            native_app, "port_in_use", return_value=False
        ):
            self.assertIsNone(native_app.env_port())
            self.assertEqual(native_app.choose_port(), native_app.DEFAULT_PORT)

    def test_valid_aloud_port_is_used(self) -> None:
        with mock.patch.dict(os.environ, {"ALOUD_PORT": "8123"}):
            self.assertEqual(native_app.choose_port(), 8123)

    def test_aloud_on_a_fallback_port_is_attached_to(self) -> None:
        # I019: another program on 8000 and `ALOUD_PORT=8001 ./run.sh`, as
        # the README says; the window used to load a second model on 8002.
        def probe(*aloud: int):
            return mock.patch.object(
                native_app,
                "probe_backend",
                side_effect=lambda port: {"engine": "kokoro"} if port in aloud else None,
            )

        with mock.patch.dict(os.environ, {"ALOUD_PORT": ""}):
            with probe(8001):
                self.assertEqual(native_app.find_running_backend(), 8001)
            with probe(8000, 8003):
                self.assertEqual(native_app.find_running_backend(), 8000)
            with probe(8004, 8002):
                self.assertEqual(native_app.find_running_backend(), 8002)
            with probe(8011):
                self.assertIsNone(native_app.find_running_backend())
        with mock.patch.dict(os.environ, {"ALOUD_PORT": "8005"}), probe(8001) as probed:
            self.assertIsNone(native_app.find_running_backend())
        self.assertEqual([c.args for c in probed.call_args_list], [(8005,)])


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


class NativeWindowTests(unittest.TestCase):
    """H061 and H064: what main() does once the backend is healthy."""

    def run_main(self, *, attach: bool):
        webview = types.ModuleType("webview")
        webview.create_window = mock.Mock()
        webview.start = mock.Mock()
        watched = threading.Event()
        watcher = mock.Mock(side_effect=lambda *args: watched.set())
        server = mock.Mock()
        finished = threading.Thread(target=lambda: None)
        finished.start()
        finished.join()
        env = {k: v for k, v in os.environ.items() if not k.startswith("ALOUD_")}
        with mock.patch.dict(sys.modules, {"webview": webview}), mock.patch.dict(
            os.environ, env, clear=True
        ), mock.patch.object(
            native_app, "find_running_backend", return_value=8000 if attach else None
        ), mock.patch.object(native_app, "choose_port", return_value=8000), mock.patch.object(
            native_app, "_start_own_server", return_value=(server, finished)
        ) as start_own, mock.patch.object(
            native_app, "_wait_for_health", return_value=True
        ), mock.patch.object(native_app, "_take_over_when_gone", watcher):
            self.assertEqual(native_app.main(), 0)
            if attach:
                self.assertTrue(watched.wait(2), "the attached window never watched its backend")
        return webview, watcher, start_own

    def test_window_keeps_its_storage_between_launches(self) -> None:
        webview, _, _ = self.run_main(attach=False)
        self.assertEqual(webview.start.call_args.kwargs.get("private_mode"), False)

    def test_attached_window_watches_its_backend(self) -> None:
        webview, watcher, start_own = self.run_main(attach=True)
        start_own.assert_not_called()
        port, own, stop = watcher.call_args.args
        self.assertEqual((port, own), (8000, []))
        self.assertTrue(stop.is_set(), "closing the window stops the watch")
        self.assertEqual(webview.start.call_args.kwargs.get("private_mode"), False)

    def test_window_on_its_own_server_does_not_watch(self) -> None:
        _, watcher, start_own = self.run_main(attach=False)
        start_own.assert_called_once_with(8000)
        watcher.assert_not_called()


class AttachWatchTests(unittest.TestCase):
    """H064: the attached backend stopping no longer leaves the window mute."""

    def setUp(self) -> None:
        ended = threading.Thread(target=lambda: None)
        ended.start()
        ended.join()
        # uvicorn sets `started` once it has bound the port; a thread that ends
        # without it could not bind.
        self.serving = (types.SimpleNamespace(started=True), ended)
        self.lost_bind = (types.SimpleNamespace(started=False), ended)

    def watch(self, *, in_use: list, rounds: int, servers: list | None = None):
        stop = mock.Mock()
        stop.wait.side_effect = [False] * rounds + [True]
        stop.is_set.return_value = False
        own: list = []
        with mock.patch.object(native_app, "probe_backend", return_value=None), mock.patch.object(
            native_app, "port_in_use", side_effect=in_use
        ), mock.patch.object(
            native_app, "_start_own_server", side_effect=servers or [self.serving]
        ) as start_own:
            native_app._take_over_when_gone(8000, own, stop, interval=0)
        return own, start_own

    def test_backend_gone_and_port_free_starts_our_own_there(self) -> None:
        own, start_own = self.watch(in_use=[False], rounds=5)
        start_own.assert_called_once_with(8000)
        self.assertEqual(own, [self.serving])

    def test_live_backend_or_taken_port_is_left_alone(self) -> None:
        own, start_own = self.watch(in_use=[True, True], rounds=2)
        start_own.assert_not_called()
        self.assertEqual(own, [])

    def test_losing_the_port_to_another_backend_keeps_watching(self) -> None:
        # I017: run.sh restarted while ours loaded and bound the port first.
        # Ours stopped; when that one stops too, ours takes over after all.
        own, start_own = self.watch(
            in_use=[False, True, False],
            rounds=5,
            servers=[self.lost_bind, self.serving],
        )
        self.assertEqual(start_own.call_count, 2)
        self.assertEqual(own, [self.serving])

    def test_watching_sends_the_backend_no_requests(self) -> None:
        # I020: run.py logs every request, so a GET /health every two seconds
        # filled run.sh's terminal while a window was attached.
        stop = mock.Mock()
        stop.wait.side_effect = [False] * 5 + [True]
        stop.is_set.return_value = False
        with mock.patch.object(
            native_app.socket, "create_connection", accepting("127.0.0.1")
        ), mock.patch.object(native_app.urllib.request, "urlopen") as urlopen, mock.patch.object(
            native_app, "_start_own_server"
        ) as start_own:
            native_app._take_over_when_gone(8000, [], stop, interval=0)
        urlopen.assert_not_called()
        start_own.assert_not_called()


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class ModelDownloadTests(unittest.TestCase):
    """H063: a model file is trusted by its pinned SHA-256, not its size."""

    def setUp(self) -> None:
        self.dl = load_module("aloud_download_under_test", "download_models.py")
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        self.dest = self.dir / "model.bin"
        for name, value in (
            ("_MODELS_DIR", str(self.dir)),
            ("_ASSETS", [("model.bin", "https://example.invalid/model.bin", 3, sha256(b"abc"))]),
        ):
            patcher = mock.patch.object(self.dl, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def main(self, served: bytes):
        def download(url: str, dest: str) -> None:
            Path(dest).write_bytes(served)

        with mock.patch.object(self.dl, "_download", side_effect=download) as fetch, redirect_stdout(
            io.StringIO()
        ), redirect_stderr(io.StringIO()):
            code = self.dl.main()
        return code, fetch

    def test_right_sized_wrong_file_is_fetched_again(self) -> None:
        self.dest.write_bytes(b"xyz")
        code, fetch = self.main(b"abc")
        self.assertEqual(code, 0)
        fetch.assert_called_once()
        self.assertEqual(self.dest.read_bytes(), b"abc")

    def test_matching_file_is_skipped(self) -> None:
        self.dest.write_bytes(b"abc")
        code, fetch = self.main(b"abc")
        self.assertEqual(code, 0)
        fetch.assert_not_called()

    def test_download_that_does_not_match_is_deleted(self) -> None:
        code, _ = self.main(b"abd")
        self.assertEqual(code, 1)
        self.assertFalse(self.dest.exists())

    def test_real_assets_pin_a_sha256(self) -> None:
        dl = load_module("aloud_download_pins", "download_models.py")
        self.assertEqual(len(dl._ASSETS), 2)
        for name, _url, size, digest in dl._ASSETS:
            self.assertGreater(size, 0, name)
            self.assertRegex(digest, r"^[0-9a-f]{64}$", name)

    def test_backend_requirements_are_pinned(self) -> None:
        lines = [
            line.strip()
            for line in (BACKEND / "requirements.txt").read_text().splitlines()
            if line.strip() and not line.strip().startswith("#")
        ]
        self.assertTrue(lines)
        for line in lines:
            self.assertRegex(line, r"^[A-Za-z0-9_.\-\[\]]+==[0-9][0-9A-Za-z.]*$", line)


if __name__ == "__main__":
    unittest.main()
