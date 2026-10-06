"""Serialized, priority-ordered synthesis queue.

Kokoro reaches espeak-ng for phonemization inside ``kokoro.create()``. espeak-ng
keeps process-global state and is not thread-safe, and FastAPI runs sync
endpoints in a threadpool — so the player's concurrent /synthesize calls used to
land inside ``create()`` at the same instant and corrupt one another:

    "number of lines in input and output must be equal, we have: input=3, output=2"

Measured on this machine, 12 sentences, model pre-warmed: 0/12 failures at one
in flight, 1/12 at three (the player's default), 2/12 at six (scrubbing).

The fix is structural rather than defensive: every synthesis runs on ONE
dedicated worker thread, so exactly one ``create()`` call exists process-wide at
any instant. HTTP handlers submit a job and block on it; the threadpool thread
parks, the model never overlaps with itself.

Waiting jobs are ordered by priority, not arrival. A ``now`` job is the sentence
a listener is currently waiting on; a ``prefetch`` job is speculative lookahead
they may never reach. Serving arrival-order would make a seek wait behind two
sentences that are about to be thrown away, so ``now`` jumps the whole prefetch
backlog; within a class the order is FIFO.

Only prefetch jobs count against the queue bound. Rejecting a ``now`` job for
depth would reintroduce the exact stall this module exists to remove.

A job the client has given up on is dropped, not run. The web player aborts
every request it no longer needs (a seek, a voice change, its own 30 s
timeout); the HTTP layer notices the hang-up and calls :meth:`SynthQueue.cancel`,
so the sentence the listener is waiting on never queues behind abandoned ones.

If throughput ever has to exceed one stream, it must come from separate
PROCESSES — each with its own espeak-ng state — never from more threads here.
"""

from __future__ import annotations

import logging
import threading
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Any, Callable

logger = logging.getLogger("aloud.queue")

PRIORITY_NOW = "now"
PRIORITY_PREFETCH = "prefetch"

# Warm-up text: short enough to cost almost nothing beyond the one-time ONNX
# graph build, long enough to walk the same phonemize -> infer path a real
# sentence takes. First inference is ~4.1s here, subsequent ones ~0.87s.
_WARMUP_TEXT = "Aloud is ready."

# How much of the offending text a log line carries. Enough to identify the
# sentence in the source document without turning the log into a transcript.
_LOG_TEXT_CHARS = 120


class JobCancelledError(RuntimeError):
    """Raised by :meth:`SynthQueue.result` for a job cancelled before it ran."""


class QueueFullError(RuntimeError):
    """Raised by :meth:`SynthQueue.submit` when the prefetch backlog is full.

    The HTTP layer turns this into a 429 with ``Retry-After`` — a bounded queue
    that answers honestly is strictly better than an unbounded one that answers
    late, and it must never look like a 500 to the client's retry logic.
    """

    def __init__(self, depth: int, limit: int) -> None:
        super().__init__(f"prefetch queue is full ({depth} of {limit} waiting)")
        self.depth = depth
        self.limit = limit


@dataclass(eq=False)
class _Job:
    """One queued synthesis. ``done`` hands the result back to the HTTP thread.

    Compared by identity, so :meth:`SynthQueue.cancel` removes this job and never
    an identical-looking one queued by another request.
    """

    text: str
    voice: str
    speed: float
    priority: str
    queued_at: float = field(default_factory=time.perf_counter)
    done: threading.Event = field(default_factory=threading.Event)
    result: Any = None
    error: BaseException | None = None
    cancelled: bool = False


def truncate_for_log(text: str, limit: int = _LOG_TEXT_CHARS) -> str:
    """Collapse whitespace and clip ``text`` so a log line stays one line."""
    flat = " ".join((text or "").split())
    return flat if len(flat) <= limit else flat[:limit] + "…"


class SynthQueue:
    """Single-worker synthesis queue with ``now`` / ``prefetch`` priorities.

    ``synth_fn`` is called as ``synth_fn(text, voice, speed)`` on the worker
    thread and nowhere else.
    """

    def __init__(
        self,
        synth_fn: Callable[[str, str, float], Any],
        *,
        max_prefetch: int = 8,
        warmup_voice: str = "af_heart",
        warmup_text: str = _WARMUP_TEXT,
    ) -> None:
        self._synth_fn = synth_fn
        self._max_prefetch = max(0, int(max_prefetch))
        self._warmup_voice = warmup_voice
        self._warmup_text = warmup_text

        # One condition guards both deques, the warm flag and the shutdown flag,
        # so depth checks and enqueues are atomic with respect to the worker.
        self._cv = threading.Condition()
        self._now: deque[_Job] = deque()
        self._prefetch: deque[_Job] = deque()
        self._warm = False
        self._stopping = False

        self._thread = threading.Thread(target=self._run, name="synth-worker", daemon=True)

    # -- lifecycle --------------------------------------------------------

    def start(self) -> None:
        """Start the worker. Its first job is always the warm-up (A1.4)."""
        self._thread.start()

    def stop(self) -> None:
        """Ask the worker to drain and exit; fails anything still waiting."""
        with self._cv:
            self._stopping = True
            self._cv.notify_all()

    # -- introspection ----------------------------------------------------

    @property
    def warm(self) -> bool:
        """True once the warm-up inference has finished (success or failure).

        Failure still flips this: a broken warm-up must not pin /health at
        "warming" forever when real requests are being served fine.
        """
        with self._cv:
            return self._warm

    @property
    def max_prefetch(self) -> int:
        return self._max_prefetch

    @property
    def queue_depth(self) -> int:
        """Jobs WAITING, both classes, excluding the one in flight (§1.2)."""
        with self._cv:
            return len(self._now) + len(self._prefetch)

    # -- submission -------------------------------------------------------

    def submit(self, text: str, voice: str, speed: float, priority: str = PRIORITY_NOW) -> Any:
        """Queue a synthesis and block until the worker finishes it.

        Returns whatever ``synth_fn`` returned; re-raises whatever it raised, in
        the calling thread, so the HTTP layer's error mapping is unchanged from
        when it called the engine directly.

        Raises :class:`QueueFullError` — before doing any work — when a prefetch
        arrives with the backlog already at ``ALOUD_QUEUE_MAX``.
        """
        return self.result(self.enqueue(text, voice, speed, priority))

    def enqueue(self, text: str, voice: str, speed: float, priority: str = PRIORITY_NOW) -> _Job:
        """Queue a synthesis without waiting for it.

        The caller then waits with :meth:`result`, or gives the job up with
        :meth:`cancel` when its client goes away. Raises :class:`QueueFullError`
        exactly as :meth:`submit` does.
        """
        job = _Job(text=text, voice=voice, speed=speed, priority=priority)

        with self._cv:
            if self._stopping:
                raise RuntimeError("synthesis queue is shutting down")
            if priority == PRIORITY_PREFETCH:
                depth = len(self._prefetch)
                if depth >= self._max_prefetch:
                    raise QueueFullError(depth, self._max_prefetch)
                self._prefetch.append(job)
            else:
                self._now.append(job)
            self._cv.notify()

        return job

    def result(self, job: _Job) -> Any:
        """Block until ``job`` is finished; return its result or raise its error."""
        job.done.wait()

        if job.error is not None:
            raise job.error
        return job.result

    def cancel(self, job: _Job) -> bool:
        """Give up on ``job`` because nobody is waiting for it any more.

        A job still waiting is taken out of its lane, so the worker never spends
        a second on it, and returns True. A job already in flight cannot be
        interrupted; it finishes, its result is thrown away, and this returns
        False.
        """
        with self._cv:
            job.cancelled = True
            removed = False
            for lane in (self._now, self._prefetch):
                try:
                    lane.remove(job)
                except ValueError:
                    continue
                removed = True
                break
        if removed:
            job.error = JobCancelledError("the client stopped waiting for this sentence")
            job.done.set()
            logger.debug("dropped abandoned %s job voice=%s", job.priority, job.voice)
        return removed

    # -- worker -----------------------------------------------------------

    def _run(self) -> None:
        """Worker loop: warm up once, then serve jobs strictly one at a time."""
        try:
            self._warm_up()
            while True:
                job = self._next_job()
                if job is None:
                    return
                self._execute(job)
        finally:
            # If the loop ever exits unexpectedly, release every blocked HTTP
            # thread with an error rather than leaving them parked forever.
            self._fail_pending(RuntimeError("synthesis worker stopped"))

    def _warm_up(self) -> None:
        """Pay the one-time ONNX graph-build cost before any user request.

        Requests that arrive during warm-up simply queue behind it — which is
        the point: the listener's first sentence is never the ~4.1s cold one.
        """
        started = time.perf_counter()
        try:
            self._synth_fn(self._warmup_text, self._warmup_voice, 1.0)
        except Exception:  # noqa: BLE001 — a cold engine still beats no engine
            logger.exception("Warm-up synthesis failed; serving requests cold")
        else:
            logger.info("Warm-up synthesis finished in %.2fs", time.perf_counter() - started)
        finally:
            with self._cv:
                self._warm = True

    def _next_job(self) -> _Job | None:
        """Block until a job is available; ``now`` first, FIFO within a class."""
        with self._cv:
            while not self._now and not self._prefetch and not self._stopping:
                self._cv.wait()
            if self._now:
                return self._now.popleft()
            if self._prefetch:
                return self._prefetch.popleft()
            return None  # stopping and drained

    def _execute(self, job: _Job) -> None:
        started = time.perf_counter()
        try:
            job.result = self._synth_fn(job.text, job.voice, job.speed)
        except Exception as exc:  # noqa: BLE001 — reported to the submitter
            job.error = exc
        finally:
            job.done.set()

        logger.debug(
            "synth %s waited=%.0fms ran=%.0fms voice=%s%s",
            job.priority,
            (started - job.queued_at) * 1000,
            (time.perf_counter() - started) * 1000,
            job.voice,
            "" if job.error is None else f" error={job.error}",
        )

    def _fail_pending(self, error: BaseException) -> None:
        with self._cv:
            pending = list(self._now) + list(self._prefetch)
            self._now.clear()
            self._prefetch.clear()
        for job in pending:
            job.error = error
            job.done.set()
