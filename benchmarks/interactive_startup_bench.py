#!/usr/bin/env python3
"""Measure real fx process start to the background file index becoming ready.

This is intentionally separate from discover_bench.zig. discover_bench.zig
isolates the workspace discovery stage that fx-companion accelerates. This
script measures a user-facing milestone in the full interactive application.

Usage:
  python3 benchmarks/interactive_startup_bench.py FX_BINARY ROOT [ROUNDS]

The same fx binary is used for all measurements. Stock mode is selected with
FX_NO_COMPANION=1. Companion cold and warm runs use an isolated cache directory.
The script watches fx's own FX_TRACE_LOG for "file index generation ready" and
terminates the process immediately after that milestone.
"""

from __future__ import annotations

import fcntl
import os
import pty
import re
import shutil
import signal
import statistics
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path


READY_TEXT = "file index generation ready"
READY_RE = re.compile(r"file index generation ready generation=\d+ count=(\d+)")


def die(message: str) -> None:
    print(f"startup-bench: {message}", file=sys.stderr)
    raise SystemExit(2)


def run_once(fx_binary: str, root: str, cache_home: str, extra_env: dict[str, str]) -> tuple[float, int]:
    trace_path = tempfile.mktemp(prefix="fxc-startup-", suffix=".log")
    master_fd, slave_fd = pty.openpty()
    fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))

    env = os.environ.copy()
    env.update(
        {
            "TERM": "xterm-256color",
            "FX_TRACE": "1",
            "FX_TRACE_LOG": trace_path,
            "FX_COMPANION_HOME": cache_home,
        }
    )
    env.update(extra_env)

    started_ns = time.perf_counter_ns()
    process = subprocess.Popen(
        [fx_binary],
        cwd=root,
        env=env,
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        close_fds=True,
    )
    os.close(slave_fd)

    elapsed_ms: float | None = None
    indexed_files: int | None = None
    deadline = time.monotonic() + 10.0
    trace = ""

    try:
        while time.monotonic() < deadline:
            time.sleep(0.005)
            try:
                trace = Path(trace_path).read_text(errors="replace")
            except FileNotFoundError:
                trace = ""

            if READY_TEXT in trace:
                elapsed_ms = (time.perf_counter_ns() - started_ns) / 1_000_000.0
                matches = READY_RE.findall(trace)
                if matches:
                    indexed_files = int(matches[-1])
                break

            if process.poll() is not None:
                break
    finally:
        try:
            process.terminate()
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=0.5)
        except subprocess.TimeoutExpired:
            try:
                process.kill()
            except ProcessLookupError:
                pass
            process.wait()
        os.close(master_fd)
        try:
            os.unlink(trace_path)
        except FileNotFoundError:
            pass

    if elapsed_ms is None or indexed_files is None:
        raise RuntimeError("fx did not report a ready file index within 10 seconds")
    return elapsed_ms, indexed_files


def median(values: list[float]) -> float:
    return float(statistics.median(values))


def main() -> None:
    if sys.platform != "darwin":
        die("this benchmark currently supports macOS only")
    if len(sys.argv) not in (3, 4):
        die("usage: interactive_startup_bench.py FX_BINARY ROOT [ROUNDS]")

    fx_binary = os.path.realpath(sys.argv[1])
    root = os.path.realpath(sys.argv[2])
    rounds = int(sys.argv[3]) if len(sys.argv) == 4 else 7
    if rounds < 1 or rounds > 31:
        die("ROUNDS must be between 1 and 31")
    if not os.path.isfile(fx_binary) or not os.access(fx_binary, os.X_OK):
        die(f"fx binary is not executable: {fx_binary}")
    if not os.path.isdir(root):
        die(f"workspace root does not exist: {root}")

    cache_root = tempfile.mkdtemp(prefix="fxc-startup-cache-")
    stock_times: list[float] = []
    cold_times: list[float] = []
    warm_times: list[float] = []
    indexed_count: int | None = None

    try:
        # Untimed process warmups keep dylib/page-cache startup effects from
        # dominating the first measured round.
        run_once(fx_binary, root, os.path.join(cache_root, "warmup-stock"), {"FX_NO_COMPANION": "1"})
        run_once(fx_binary, root, os.path.join(cache_root, "warmup-companion"), {})

        for index in range(rounds):
            cache_home = os.path.join(cache_root, f"round-{index}")
            os.makedirs(cache_home, exist_ok=True)

            if index % 2 == 0:
                stock_ms, stock_count = run_once(fx_binary, root, cache_home, {"FX_NO_COMPANION": "1"})
                cold_ms, cold_count = run_once(fx_binary, root, cache_home, {})
                warm_ms, warm_count = run_once(fx_binary, root, cache_home, {})
            else:
                cold_ms, cold_count = run_once(fx_binary, root, cache_home, {})
                warm_ms, warm_count = run_once(fx_binary, root, cache_home, {})
                stock_ms, stock_count = run_once(fx_binary, root, cache_home, {"FX_NO_COMPANION": "1"})

            if not (stock_count == cold_count == warm_count):
                raise RuntimeError(
                    f"indexed candidate counts diverged: stock={stock_count} cold={cold_count} warm={warm_count}"
                )

            indexed_count = stock_count
            stock_times.append(stock_ms)
            cold_times.append(cold_ms)
            warm_times.append(warm_ms)
            print(
                f"round={index + 1} stock_ms={stock_ms:.3f} cold_ms={cold_ms:.3f} "
                f"warm_ms={warm_ms:.3f} indexed={stock_count}"
            )

        stock_median = median(stock_times)
        cold_median = median(cold_times)
        warm_median = median(warm_times)
        print(f"root={root}")
        print(f"indexed={indexed_count}")
        print(f"stock_median_ms={stock_median:.3f}")
        print(f"cold_median_ms={cold_median:.3f}")
        print(f"warm_median_ms={warm_median:.3f}")
        print(f"warm_speedup={stock_median / warm_median:.3f}x")
    finally:
        shutil.rmtree(cache_root, ignore_errors=True)


if __name__ == "__main__":
    main()
