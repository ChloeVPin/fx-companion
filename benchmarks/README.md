# Benchmarks

This directory contains both current product validation and older research experiments. Use the current production-path results first.

## Current result

Start with [`results/2026-09-07-adaptive-traversal.md`](results/2026-09-07-adaptive-traversal.md)
for the production discovery result, then read
[`results/2026-09-07-launch-readiness.md`](results/2026-09-07-launch-readiness.md)
for the separate full interactive startup measurement.

That record uses the pinned upstream `fx` discovery API and reports stock, companion cold, and companion warm measurements with byte-identical correctness checks. The final clean-room Apple M2 measurements include:

| Workload | Stock median | Companion cold | Companion warm |
| --- | ---: | ---: | ---: |
| 51,200-file synthetic tree | 42.513 ms | 19.059 ms | 0.581 ms |
| `/opt/homebrew`, 161,771 paths | 519.514 ms | 305.942 ms | 14.139 ms |

## Reproduce the production discovery benchmark

[`discover_bench.zig`](discover_bench.zig) is the end-to-end benchmark for the real pinned `fx` workspace-discovery API. [`run_discover_bench.sh`](run_discover_bench.sh) archives the pinned upstream commit into a temporary directory, injects the current companion, builds the benchmark, and leaves the source clone unchanged.

```sh
FX_UPSTREAM_REPO=/path/to/vercel-labs/fx \
  benchmarks/run_discover_bench.sh /path/to/tree 7 600000
```

The release performance gate uses [`tooling/benchmark_runner.zig`](tooling/benchmark_runner.zig). It compares stock discovery against the validated warm repeat path and requires byte-identical results before reporting a speedup.

[`interactive_startup_bench.py`](interactive_startup_bench.py) measures a
different boundary: real `fx` process start to fx's own background file-index
ready event. It exists specifically so discovery-stage speedups are not confused
with whole-application startup speedups.

Machine-readable headline data is tracked in
[`results/latest.json`](results/latest.json). CI also publishes a fresh benchmark
JSON artifact from the current `main` commit.

## Research tooling

The remaining files under `benchmarks/` include traversal experiments, syscall probes, cancellation and cache stress tools, synthetic fixture generators, and historical measurements. They are useful for implementation research, but they are not all part of the shipped runtime path.

### Historical R&D: `comparison.html`

[`comparison.html`](comparison.html) is a historical research artifact from an earlier architecture and upstream pin. It includes daemon, Mach RPC, ZeroCopyState, fixed-worker, and fixed-buffer measurements that do not describe the current shipped product. Do not use it as the current performance claim.

For current public numbers, use [`results/2026-09-07-adaptive-traversal.md`](results/2026-09-07-adaptive-traversal.md).

## Result archive

- [`results/2026-09-07-adaptive-traversal.md`](results/2026-09-07-adaptive-traversal.md): current adaptive traversal policy and final production-path rerun.
- [`results/2026-09-07-launch-readiness.md`](results/2026-09-07-launch-readiness.md): fresh launch demo and real process-start-to-file-index-ready measurements.
- [`results/latest.json`](results/latest.json): machine-readable public benchmark evidence.
- [`results/2026-09-06-launch-readiness.md`](results/2026-09-06-launch-readiness.md): installer and cross-process cache launch checks.
- [`results/2026-08-26-engagement.md`](results/2026-08-26-engagement.md): production-path Git discovery engagement work.
- [`results/2026-08-26-apple-silicon.md`](results/2026-08-26-apple-silicon.md): earlier Apple M2 benchmark record.
- [`results/2026-08-24-apple-silicon.md`](results/2026-08-24-apple-silicon.md): historical baseline and rejected experiments.
