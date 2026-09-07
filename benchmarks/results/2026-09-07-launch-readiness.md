# 2026-09-07 - Launch-readiness measurements

Hardware: Apple M2, 8 logical CPUs, 4 performance cores, 8 GiB RAM, macOS 27.
Pinned fx: `8d6152de17905429ad78decdb475df8cfd04f557`.
Zig: `0.16.0`.

This record separates the stage fx-companion actually accelerates from the
full interactive application. The distinction matters because authentication,
model catalog loading, terminal setup, rendering, and other startup work can
dominate total launch time even when workspace discovery itself is much faster.

## Production workspace discovery

The clean-room production benchmark remains the primary performance proof:

| Workload | Stock median | Companion cold | Companion warm | Warm speedup |
| --- | ---: | ---: | ---: | ---: |
| 51,200-file synthetic tree | 42.513 ms | 19.059 ms | 0.581 ms | 73.145x |
| `/opt/homebrew`, 161,771 paths | 519.514 ms | 305.942 ms | 14.139 ms | 36.742x |

Every path and result-metadata field matched stock byte-for-byte.

## Fresh launch-asset rerun

A new 7-round clean-room rerun on the same 51,200-file fixture measured:

- Stock median: 37.948 ms
- Companion cold median: 19.549 ms
- Companion warm median: 0.717 ms
- Warm speedup: 52.956x
- Correctness: byte-identical

The checked-in terminal recording in `media/demo.cast` is a separate real
7-round capture made from the same pinned production benchmark binary. That
recorded run measured 39.101 ms stock, 18.710 ms cold, and 0.676 ms warm for a
57.824x warm speedup with byte-identical results. `media/demo.gif` is rendered
directly from that asciinema recording.

## Full interactive startup to file index ready

`benchmarks/interactive_startup_bench.py` launches the actual release `fx`
binary in a PTY and watches `FX_TRACE_LOG` for fx's own
`file index generation ready` milestone. Stock mode uses
`FX_NO_COMPANION=1`; cold and warm companion runs use the same binary and an
isolated cache. Timed order alternates between rounds.

| Workspace | Indexed candidates | Stock median | Companion cold | Companion warm | Warm speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| 51,200-file synthetic tree | 51,712 | 624.530 ms | 624.927 ms | 617.566 ms | 1.011x |
| 409,600-file synthetic tree | 100,000 cap | 951.448 ms | 998.054 ms | 907.892 ms | 1.048x |

These end-to-end numbers are deliberately not marketed as large speedups. They
show that current full-app startup has substantial work outside workspace
discovery. The large discovery-stage win is real, but it should not be presented
as a 53x to 73x reduction in total interactive startup time.

The machine-readable form of all headline numbers is
[`latest.json`](latest.json).
