# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Jason Cheng (Jason Tools)
"""Adaptive backpressure guard for exports (API *and* OpenSearch-direct).

A heavy export puts search/read load on the same OpenSearch cluster that Graylog
uses for indexing. On busy clusters — especially slow HDD-backed storage — that
starves ingestion: the disk journal and ring buffers back up and Graylog stops
collecting logs (in the worst case it wedges until restarted).

This guard samples Graylog's own health signals between chunks/batches and, the
moment ingestion starts falling behind, PAUSES the export until it drains — then
resumes. It watches every signal:

  * JVM heap                           (GC metrics: heap left after a
                                        collection, full GCs, GC time share;
                                        raw used % when those are missing)
  * disk journal uncommitted entries   (sustained rise)
  * input / process / output buffers   (sustained rise)

Design principles:
  * **Fail-safe** — if Graylog can't be read (health is None), that counts as
    pressure and we pause. An unreachable Graylog is when we must back off most.
  * **Trend based** — buffers/journal trip on a *sustained climb*, not an
    absolute number, so it works on any deployment/storage without tuning.
  * **Resume only once drained** — not merely "stopped rising", the signal must
    fall back toward its pre-spike level.
  * **Observable** — every pause is logged AND surfaced to the UI with the exact
    signal(s) that triggered it.
"""

from __future__ import annotations

import asyncio
import time
from collections import deque

from glogarch.utils.logging import get_logger

log = get_logger("export.health")

# (tracker key, health-dict key, human label)
_BUFFERS = (
    ("buffer_process", "buffer_process", "process buffer"),
    ("buffer_output", "buffer_output", "output buffer"),
    ("buffer_input", "buffer_input", "input buffer"),
)
_DRAIN_METRICS = ("journal_uncommitted", "buffer_process", "buffer_output", "buffer_input")


def _heap_bound(signals: list[str]) -> bool:
    """A pause caused by Graylog's heap (not the journal or buffers) — the only
    kind that releasing Graylog's cached search results can help."""
    return any("heap" in s or "garbage collection" in s for s in signals)


class RisingTracker:
    """Detects a metric that keeps climbing across consecutive samples."""

    def __init__(self, samples: int = 3, min_delta: int = 1):
        self.samples = max(1, samples)
        self.min_delta = max(1, min_delta)
        self._h: deque[float] = deque(maxlen=self.samples + 1)

    def add(self, v) -> None:
        self._h.append(v or 0)

    def rising(self) -> bool:
        if len(self._h) < self.samples + 1:
            return False
        xs = list(self._h)
        return all(xs[i + 1] - xs[i] >= self.min_delta for i in range(len(xs) - 1))

    def latest(self):
        return self._h[-1] if self._h else 0


class HealthGuard:
    """Pause/resume an export based on Graylog ingestion backpressure.

    Call ``await guard.checkpoint(progress)`` between chunks/batches. It returns
    immediately when healthy; otherwise it blocks (pausing the export) until the
    pressure clears, or raises RuntimeError if it stays high past the max wait.
    """

    def __init__(self, monitor, cfg, progress_callback=None, ctx=None,
                 cancel_check=None, pace_searches=False):
        self.monitor = monitor
        # True for the API export: its own searches are what fill Graylog's
        # heap (see ExportConfig.health_pace_start_pct), so slowing them down
        # is what lets it recover. OpenSearch-direct does not search Graylog.
        self.pace_searches = pace_searches
        self.pace_delay = 0.0
        self.cfg = cfg
        self.progress_callback = progress_callback
        # Read on every tick of a backpressure pause. "Paused — source under
        # load" is exactly when an operator presses Cancel, and the pause loop
        # used to ignore both the exporter's flag and the callback's exception
        # for up to health_max_pause_min (30 min by default).
        self.cancel_check = cancel_check
        self.ctx = dict(ctx or {})
        self.pause_count = 0
        self.total_paused_sec = 0
        self._heap_streak = 0
        self._gc_streak = 0
        self._gc_prev: tuple[float, int, int] | None = None
        self._heap_mode: str | None = None
        self._clock = time.monotonic
        self._last_sample = 0.0
        self._interval = max(1, getattr(cfg, "health_sample_interval_sec", 15))
        rs = getattr(cfg, "health_rise_samples", 3)
        jd = getattr(cfg, "health_journal_min_delta", 200)
        bd = getattr(cfg, "health_buffer_min_delta", 64)
        self.trackers = {
            "journal": RisingTracker(rs, jd),
            "buffer_process": RisingTracker(rs, bd),
            "buffer_output": RisingTracker(rs, bd),
            "buffer_input": RisingTracker(rs, bd),
        }

    @property
    def enabled(self) -> bool:
        return bool(getattr(self.cfg, "health_guard_enabled", True)) and self.monitor is not None

    async def _read(self):
        try:
            return await self.monitor.get_health()
        except Exception:
            return None

    def _tripped(self, health) -> list[str]:
        """Feed the trackers and return the list of tripped-signal descriptions
        (empty = healthy). health is None → fail-safe pressure."""
        if health is None:
            return ["Graylog not responding (pausing to be safe)"]
        out: list[str] = []
        # JVM heap: from the garbage collector's own metrics when Graylog
        # exposes them (_gc_pressure). Otherwise the two-tier used% check —
        # back off well before the ceiling without pausing on every GC peak:
        #   * hard tier  → pause immediately on one reading (acute spike)
        #   * soft tier  → pause only when SUSTAINED for N reads (steady climb)
        soft = getattr(self.cfg, "jvm_memory_threshold_pct", 75.0)
        hard = getattr(self.cfg, "jvm_memory_hard_pct", 90.0)
        need = max(1, getattr(self.cfg, "health_heap_sustained_samples", 2))
        hp = health.get("jvm_pct", 0)
        if self._judge_heap_by_gc(health):
            out.extend(self._gc_pressure(health, hard, need))
        elif hp >= hard:
            out.append(f"JVM heap {hp:.0f}% (over the hard limit {hard:.0f}%)")
            self._heap_streak = 0
        elif hp >= soft:
            self._heap_streak += 1
            if self._heap_streak >= need:
                out.append(f"JVM heap {hp:.0f}% (sustained above the soft limit {soft:.0f}%)")
        else:
            self._heap_streak = 0
        self.trackers["journal"].add(health.get("journal_uncommitted", 0))
        if self.trackers["journal"].rising():
            out.append(f"disk journal backlog rising ({int(self.trackers['journal'].latest()):,})")
        for tkey, hkey, name in _BUFFERS:
            self.trackers[tkey].add(health.get(hkey, 0))
            if self.trackers[tkey].rising():
                out.append(f"{name} rising steadily ({int(self.trackers[tkey].latest()):,})")
        return out

    def _judge_heap_by_gc(self, health: dict) -> bool:
        use_gc = (getattr(self.cfg, "health_heap_signal", "auto") != "used"
                  and health.get("gc_full_count") is not None
                  and health.get("gc_time_ms") is not None)
        mode = "gc" if use_gc else "used"
        if mode != self._heap_mode:
            self._heap_mode = mode
            log.info("Graylog heap pressure judged from "
                     + ("garbage-collector metrics" if use_gc else "heap used %"),
                     heap_signal=mode)
        return use_gc

    def _gc_pressure(self, health: dict, hard: float, need: int) -> list[str]:
        """Heap pressure from what the garbage collector is DOING, not used/max.

        used/max counts garbage the next young collection frees and old-
        generation garbage G1 has not marked yet: a healthy 3 GB Graylog swings
        between 75% and 95% with no export running, so readings near the top
        of that sawtooth kept tripping the used% check — a nightly 7.5M-record
        API export spent 54% of its 6 hours paused. A Graylog that really is
        running out of heap shows it in the collector (measured on a 3 GB
        Graylog 7.1: export-shaped load, 2.7% GC time and no full GC; a load
        that exhausted the heap, 30 full GCs in 3 minutes, then OOM):
          * heap still >= the hard limit right after a collection
          * any full GC since the previous reading
          * GC pauses >= health_gc_overhead_pct of wall time, sustained
        """
        out: list[str] = []
        now = self._clock()
        full, gc_ms = health["gc_full_count"], health["gc_time_ms"]
        prev, self._gc_prev = self._gc_prev, (now, full, gc_ms)
        after = health.get("heap_after_gc_pct")
        if after is not None and after >= hard:
            out.append(f"JVM heap {after:.0f}% still in use right after garbage "
                       f"collection (limit {hard:.0f}%)")
        if prev is None:
            return out
        elapsed = now - prev[0]
        d_full, d_gc = full - prev[1], gc_ms - prev[2]
        if elapsed <= 0 or d_full < 0 or d_gc < 0:
            # Graylog restarted between readings: its counters started over.
            self._gc_streak = 0
            return out
        if d_full > 0:
            out.append(f"{d_full} full garbage collection(s) in the last "
                       f"{elapsed:.0f}s (Graylog heap exhausted)")
        if elapsed < 1:
            return out
        share = d_gc / (elapsed * 1000.0) * 100.0
        limit = getattr(self.cfg, "health_gc_overhead_pct", 10.0)
        if share >= limit:
            self._gc_streak += 1
            if self._gc_streak >= need:
                out.append(f"JVM spent {share:.0f}% of the last {elapsed:.0f}s in "
                           f"garbage collection (limit {limit:.0f}%)")
        else:
            self._gc_streak = 0
        return out

    async def checkpoint(self, progress: dict | None = None) -> None:
        """Called FREQUENTLY by the export loop (per batch). It only actually
        reads Graylog every `health_sample_interval_sec` — so the sampling
        cadence is fixed wall-clock time, decoupled from how big/slow a chunk is
        (a chunk-only cadence could take many minutes between reads, making the
        trend thresholds meaningless). Between samples it returns instantly."""
        if not self.enabled:
            return
        now = time.monotonic()
        if now - self._last_sample < self._interval:
            return
        self._last_sample = now
        health = await self._read()
        tripped = self._tripped(health)
        self._update_pace(health)
        if tripped:
            await self._pause_until_clear(tripped, progress)

    async def pace(self) -> None:
        """Per-page delay for the API export (0 unless Graylog's heap after
        GC is above health_pace_start_pct). Call once per fetched page."""
        if self.pace_delay > 0:
            await asyncio.sleep(self.pace_delay)

    def _update_pace(self, health) -> None:
        """Delay per page grows linearly from 0 at health_pace_start_pct to
        health_pace_max_delay_sec at jvm_memory_hard_pct of heap after GC.

        Graylog's heap follows the export's rate over the last 5 minutes (it
        keeps every result that long), so a delay that rises with the heap
        settles at the rate this Graylog can hold instead of oscillating
        between full speed, full GCs and a stop. Only the GC-metric reading is
        steady enough to steer by; raw used % swings with every young GC."""
        if not self.pace_searches or not health:
            return
        after = health.get("heap_after_gc_pct")
        if after is None or not self._judge_heap_by_gc(health):
            new = 0.0
        else:
            start = getattr(self.cfg, "health_pace_start_pct", 70.0)
            hard = getattr(self.cfg, "jvm_memory_hard_pct", 90.0)
            most = max(0.0, getattr(self.cfg, "health_pace_max_delay_sec", 5.0))
            span = max(1.0, hard - start)
            new = 0.0 if after <= start else min(most, most * (after - start) / span)
        new = round(new, 2)
        if (new == 0) != (self.pace_delay == 0) or abs(new - self.pace_delay) >= 0.5:
            log.info("export pacing adjusted", delay_per_page_sec=new,
                     heap_after_gc_pct=None if after is None else round(after, 1))
        self.pace_delay = new

    async def _pause_until_clear(self, tripped: list[str], progress: dict | None) -> None:
        self.pause_count += 1
        log.warning("export paused — Graylog backpressure", signals=tripped)
        self._emit(progress, "Source Graylog under load, pausing: "
                   + "; ".join(tripped) + " — waiting for it to drain")
        interval = getattr(self.cfg, "health_pause_interval_sec", 15)
        max_wait = getattr(self.cfg, "health_max_pause_min", 30) * 60
        drain = getattr(self.cfg, "health_resume_drain_ratio", 0.7)
        flush_after = getattr(self.cfg, "health_search_cache_flush_sec", 310) or 0
        peak: dict[str, float] = {}
        waited = 0
        current = tripped
        last_flush = None
        while waited < max_wait:
            await asyncio.sleep(interval)
            waited += interval
            self.total_paused_sec += interval
            self._raise_if_cancelled(waited)
            if (flush_after and waited >= flush_after and _heap_bound(current)
                    and (last_flush is None or waited - last_flush >= 60)):
                last_flush = waited
                await self._release_expired_searches(waited)
            health = await self._read()
            if health is None:
                self._emit(progress, f"Graylog not responding; still waiting (paused {waited}s)")
                continue
            for mkey in _DRAIN_METRICS:
                peak[mkey] = max(peak.get(mkey, 0), health.get(mkey, 0))
            now_tripped = self._tripped(health)
            current = now_tripped or current
            drained = all(
                health.get(mkey, 0) <= max(1, peak.get(mkey, 0)) * drain
                for mkey in _DRAIN_METRICS
            )
            if not now_tripped and drained:
                log.info("export resumed — backpressure cleared", waited_sec=waited)
                self._emit(progress, f"Load has drained, resuming (paused {waited}s)")
                return
            self._emit(progress, "Still waiting to drain: "
                       + "; ".join(now_tripped or ["not yet down"])
                       + f" (paused {waited}s)")
        msg = (f"Source load did not drain for over {max_wait // 60} minutes "
               f"({'; '.join(tripped)}); export stopped. Consider OpenSearch-direct "
               f"mode, a larger Graylog heap, or a smaller export range.")
        log.error("export stopped — backpressure did not clear", signals=tripped, waited_sec=waited)
        try:
            from glogarch.notify.sender import notify_error
            await notify_error("Export", msg)
        except Exception as e:
            log.warning("Backpressure-stop notification failed - the stop was NOT reported to any channel", error=str(e))
        raise RuntimeError(msg)

    async def _release_expired_searches(self, waited: int) -> None:
        release = getattr(self.monitor, "release_expired_searches", None)
        if release is None:
            return
        try:
            n = await release()
        except Exception as e:
            log.warning("Could not ask Graylog to release expired search results",
                        error=str(e))
            return
        log.info("asked Graylog to release expired search results",
                 searches=n, waited_sec=waited)

    def _raise_if_cancelled(self, waited: int) -> None:
        if self.cancel_check and self.cancel_check():
            from glogarch.export.exporter import ExportCancelled
            log.info("export cancelled during backpressure pause", waited_sec=waited)
            raise ExportCancelled("Job cancelled by user")

    def _emit(self, progress: dict | None, detail: str) -> None:
        if not self.progress_callback:
            return
        payload = dict(self.ctx)
        if progress:
            payload.update(progress)
        payload.update({"phase": "backpressure_wait", "detail": detail})
        try:
            self.progress_callback(payload)
        except Exception as e:
            # The Web UI callback raises the cancel. Swallowing it here kept a
            # paused export paused for the full max wait after Cancel was pressed.
            from glogarch.export.exporter import _is_cancellation
            if _is_cancellation(e):
                raise
            log.debug("Backpressure progress callback failed", error=str(e))
