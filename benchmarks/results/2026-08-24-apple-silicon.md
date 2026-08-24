# 2026-08-24 — Apple M2 / macOS 27

Environment: Apple M2 (8 cores), 8 GiB RAM, macOS 27.0 (26A5416b), arm64,
Zig 0.16.0. Pinned fx: `669ef8a7f0bf6b13a1722bfd434fb9fc61d01511`.

The anchor has 4,096 directories and 409,600 empty files. Every comparison
uses one untimed stock/companion pair, seven timed pairs with alternating
order and fresh arenas, and byte-compares the sorted result after every pair.
The table reports medians; best times are in parentheses.

| Tree / cap | Stock | Companion cold | Companion warm | Warm speedup |
|---|---:|---:|---:|---:|
| 409,600 files / 100,000 | 80.251 ms (79.262) | 441.038 ms (432.007) | 5.100 ms (4.130) | 15.737× |
| 409,600 files / 600,000 | 497.828 ms (468.565) | 222.844 ms (213.955) | 5.511 ms (4.768) | 90.332× |
| 8 files / 100,000 | 0.158 ms (0.137) | 0.441 ms (0.323) | 0.221 ms (0.199) | 0.713× |

The default 100,000 cap must preserve stock's exact first-N source-order
selection. Its first call therefore runs the parallel probe, falls back to
stock, and builds a validated snapshot. That cold call loses. At these
medians, cumulative time breaks even on the sixth unchanged name-set walk.
Content-only file edits keep the snapshot; create, delete, rename, directory
metadata change, root replacement, and mount identity change invalidate it.

The uncapped stock timings were noisy on this 8 GiB machine (raw rounds below
include three 1.90–1.91 s outliers). The reported median and best are not
selected from different runs or hidden behind an average.

## Reproduce

```sh
zig run benchmarks/make_anchor.zig -lc -OReleaseFast -- /tmp/fxanchor-new 4096 100
benchmarks/run_discover_bench.sh /tmp/fxanchor-new 7 100000
benchmarks/run_discover_bench.sh /tmp/fxanchor-new 7 600000
```

`FX_UPSTREAM_REPO` may point to any read-only clone containing `PINNED_FX`.
The runner archives that exact commit into a temporary directory, injects the
current product, compiles the benchmark, and does not modify the clone.

## Raw capped rounds

```text
round=1 order=stock-first stock_ms=79.262 cold_ms=444.045 warm_ms=5.539
round=2 order=companion-first stock_ms=80.251 cold_ms=432.007 warm_ms=5.503
round=3 order=stock-first stock_ms=79.636 cold_ms=441.038 warm_ms=4.816
round=4 order=companion-first stock_ms=81.433 cold_ms=449.469 warm_ms=5.637
round=5 order=stock-first stock_ms=80.816 cold_ms=433.479 warm_ms=4.130
round=6 order=companion-first stock_ms=79.934 cold_ms=438.412 warm_ms=5.100
round=7 order=stock-first stock_ms=81.179 cold_ms=454.771 warm_ms=4.763
```

## Raw uncapped rounds

```text
round=1 order=stock-first stock_ms=468.565 cold_ms=213.955 warm_ms=5.533
round=2 order=companion-first stock_ms=497.828 cold_ms=364.297 warm_ms=6.033
round=3 order=stock-first stock_ms=1904.856 cold_ms=222.844 warm_ms=4.768
round=4 order=companion-first stock_ms=495.300 cold_ms=361.702 warm_ms=6.063
round=5 order=stock-first stock_ms=1912.506 cold_ms=216.018 warm_ms=5.511
round=6 order=companion-first stock_ms=491.570 cold_ms=368.332 warm_ms=5.495
round=7 order=stock-first stock_ms=1910.581 cold_ms=222.803 warm_ms=5.451
```

## Raw tiny-tree rounds

```text
round=1 order=stock-first stock_ms=0.196 cold_ms=0.323 warm_ms=0.226
round=2 order=companion-first stock_ms=0.202 cold_ms=0.497 warm_ms=0.385
round=3 order=stock-first stock_ms=0.144 cold_ms=0.451 warm_ms=0.219
round=4 order=companion-first stock_ms=0.150 cold_ms=0.373 warm_ms=0.275
round=5 order=stock-first stock_ms=0.137 cold_ms=0.406 warm_ms=0.199
round=6 order=companion-first stock_ms=0.185 cold_ms=0.455 warm_ms=0.203
round=7 order=stock-first stock_ms=0.158 cold_ms=0.441 warm_ms=0.221
```

## Correctness soaks

The final source also passed 80,000 mixed-key concurrent cache calls (eight
lanes × 10,000 iterations) and 1,000 mid-walk cancellations without a
mismatch or deadlock. The public release gate repeats smaller versions of both
soaks in addition to the public-API equivalence matrix.

## Rejected: FSEvents-only invalidation

`FSEventStreamFlushSync` itself measured 0.012 ms median, but the first flush
immediately after creating a file did not see the mutation. Detection took
11.741 ms and nine flush/poll attempts in the recorded run. A fast stale cache
is a correctness failure, so FSEvents-only invalidation does not ship.

```sh
zig build-exe benchmarks/fsevents_probe.zig -lc \
  -framework CoreServices -framework CoreFoundation \
  -OReleaseFast -femit-bin=/tmp/fsevents-probe
/tmp/fsevents-probe /tmp/fxanchor-new 11
```

The shipped validator instead checks device, inode, mode, mtime, and ctime for
every traversed directory on local APFS. On this anchor, 4,097 directory checks
measured 3.588 ms median and 3.469 ms best across 21 rounds; a mutation under
`d4004` was detected in 1.389 ms. The in-session profile measured 7.68 MiB of
retained snapshot data for the 409,600-path tree.
