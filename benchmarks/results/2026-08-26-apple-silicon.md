# 2026-08-26 — Apple M2 / macOS 27

Environment: Apple M2 (8 cores), 8 GiB RAM, macOS 27.0, Darwin 27.0.0 arm64,
Zig 0.16.0. Pinned fx: `8d6152de17905429ad78decdb475df8cfd04f557`.

The large anchor has 4,096 directories and 409,600 empty files. The tiny
anchor has 8 files in one directory. Every comparison uses one untimed
stock/companion pair, seven timed pairs with alternating order and fresh
arenas, and byte-compares the sorted result after every pair. The table
reports medians; best times are in parentheses.

`FX_UPSTREAM_REPO=/tmp/fxc-latest-src` (read-only clone at the pin). The
runner archived that commit, injected the current product, and compiled
`benchmarks/discover_bench.zig`. The clone was not modified.

| Tree / cap | Stock | Companion cold | Companion warm | Warm speedup |
|---|---:|---:|---:|---:|
| 409,600 files / 100,000 | 83.584 ms (82.784) | 95.497 ms (94.623) | 1.199 ms (1.162) | 69.697× |
| 409,600 files / 600,000 | 366.373 ms (363.430) | 246.266 ms (240.558) | 4.602 ms (4.486) | 79.605× |
| 8 files / 100,000 | 0.022 ms (0.021) | 0.185 ms (0.170) | 0.017 ms (0.016) | 1.284× |

Every round was byte-identical (paths and result metadata).

Default-cap cold is stock's exact first-N plus snapshot construction, not a
discarded parallel walk. It still loses the cold column: 95.497 ms vs 83.584
ms stock (11.913 ms fill). The previous record's capped cold was 441.038 ms.
At these medians the extra fill is recovered on the first unchanged repeat
(warm 1.199 ms vs stock 83.584 ms).

Uncapped cold still beats stock (246.266 ms vs 366.373 ms). Warm is 4.602 ms
on the full 409,600-path result.

Tiny-tree warm now wins (0.017 ms vs 0.022 ms). Tiny cold still loses
(0.185 ms) because snapshot fill dominates an 8-file walk.

## Reproduce

```sh
zig run benchmarks/make_anchor.zig -lc -OReleaseFast -- /tmp/fxanchor-new 4096 100
mkdir -p /tmp/fxanchor-tiny
touch /tmp/fxanchor-tiny/f1 /tmp/fxanchor-tiny/f2 /tmp/fxanchor-tiny/f3 \
      /tmp/fxanchor-tiny/f4 /tmp/fxanchor-tiny/f5 /tmp/fxanchor-tiny/f6 \
      /tmp/fxanchor-tiny/f7 /tmp/fxanchor-tiny/f8
export FX_UPSTREAM_REPO=/path/to/vercel-labs/fx   # must contain PINNED_FX
benchmarks/run_discover_bench.sh /tmp/fxanchor-new 7 100000
benchmarks/run_discover_bench.sh /tmp/fxanchor-new 7 600000
benchmarks/run_discover_bench.sh /tmp/fxanchor-tiny 7 100000
```

## Raw capped rounds (409,600 files / 100,000)

```text
round=1 order=stock-first stock_ms=83.584 cold_ms=95.497 warm_ms=1.199
round=2 order=companion-first stock_ms=84.730 cold_ms=95.790 warm_ms=1.288
round=3 order=stock-first stock_ms=82.784 cold_ms=96.477 warm_ms=1.175
round=4 order=companion-first stock_ms=97.116 cold_ms=136.927 warm_ms=1.276
round=5 order=stock-first stock_ms=83.454 cold_ms=95.353 warm_ms=1.162
round=6 order=companion-first stock_ms=83.665 cold_ms=94.742 warm_ms=1.269
round=7 order=stock-first stock_ms=83.467 cold_ms=94.623 warm_ms=1.175
```

correctness=byte-identical paths=100000 path_bytes=1000000 cap=100000
stock median=83.584 ms best=82.784 ms
cold median=95.497 ms best=94.623 ms
warm median=1.199 ms best=1.162 ms validation_median=0.937 ms
speedup=69.697x

## Raw uncapped rounds (409,600 files / 600,000)

```text
round=1 order=stock-first stock_ms=367.170 cold_ms=245.237 warm_ms=4.760
round=2 order=companion-first stock_ms=365.009 cold_ms=247.500 warm_ms=4.654
round=3 order=stock-first stock_ms=366.745 cold_ms=246.212 warm_ms=4.552
round=4 order=companion-first stock_ms=363.828 cold_ms=246.266 warm_ms=4.602
round=5 order=stock-first stock_ms=366.373 cold_ms=246.360 warm_ms=4.600
round=6 order=companion-first stock_ms=363.430 cold_ms=252.239 warm_ms=4.486
round=7 order=stock-first stock_ms=367.169 cold_ms=240.558 warm_ms=4.832
```

correctness=byte-identical paths=409600 path_bytes=4096000 cap=600000
stock median=366.373 ms best=363.430 ms
cold median=246.266 ms best=240.558 ms
warm median=4.602 ms best=4.486 ms validation_median=3.652 ms
speedup=79.605x

## Raw tiny-tree rounds (8 files / 100,000)

```text
round=1 order=stock-first stock_ms=0.024 cold_ms=0.195 warm_ms=0.018
round=2 order=companion-first stock_ms=0.022 cold_ms=0.185 warm_ms=0.017
round=3 order=stock-first stock_ms=0.022 cold_ms=0.195 warm_ms=0.017
round=4 order=companion-first stock_ms=0.021 cold_ms=0.175 warm_ms=0.017
round=5 order=stock-first stock_ms=0.024 cold_ms=0.186 warm_ms=0.017
round=6 order=companion-first stock_ms=0.021 cold_ms=0.170 warm_ms=0.016
round=7 order=stock-first stock_ms=0.021 cold_ms=0.181 warm_ms=0.017
```

correctness=byte-identical paths=8 path_bytes=16 cap=100000
stock median=0.022 ms best=0.021 ms
cold median=0.185 ms best=0.170 ms
warm median=0.017 ms best=0.016 ms validation_median=0.011 ms
speedup=1.284x

## FSEvents

FSEvents-only invalidation remains rejected. The failed experiment was not
re-run on this date; see
[2026-08-24 record](2026-08-24-apple-silicon.md#rejected-fsevents-only-invalidation).
