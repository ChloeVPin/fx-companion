# 2026-09-07 — Adaptive traversal policy

Hardware: Apple M2, 8 logical CPUs (4 performance + 4 efficiency), macOS arm64.
Pinned fx: `8d6152de17905429ad78decdb475df8cfd04f557`.

The production walker previously used a fixed 128 KiB buffer and all available
logical CPUs (bounded by root breadth). Research first swept `getdirentries`
buffers of 32/64/128/256 KiB and 1/2/4/6/8 participants. Final selection was
then made from the real pinned-fx production path, not the count-only probe.

## Research sweep

Representative medians from `zig-out/bin/wprobe`:

| Tree | Best measured pair | Median |
|---|---:|---:|
| 512 dirs × 128 files (65,536 files) | 32 KiB / 2 workers | 20.691 ms |
| `/opt/homebrew` (181,778 entries in count-only probe) | 64 KiB / 2 workers | 439.940 ms |
| 128-level deep chain (2,176 entries) | 128 KiB / 1 worker | 4.514 ms |

The count-only research walker is useful for buffer/syscall behavior but does
not model production path materialization and locking. It suggested smaller
buffers on some trees, which the production-path sweep correctly overruled.

## Production buffer sweep

With four participants fixed on this M2, the injected pinned-fx discovery path
measured these cold medians; every candidate was byte-identical to stock:

| Tree | 32 KiB | 128 KiB | 256 KiB |
|---|---:|---:|---:|
| 512 × 100 wide synthetic (51,200 paths) | 28.755 ms | **21.799 ms** | 34.723 ms |
| `/opt/homebrew` (161,771 paths) | 286.407 ms | 303.656 ms | **262.814 ms** |

Final M2 policy: a single queued root child stays at 1 participant/128 KiB;
branchy roots use 4 participants; complex moderate fan-out (8–63 queued root
children, including Homebrew) uses 256 KiB, while very-wide roots use 128 KiB.
Higher-core Apple Silicon reads `hw.perflevel0.physicalcpu` and uses that
performance-core count, capped at 8 and bounded by exposed work. If the sysctl
is unavailable, it fails safely to roughly half logical CPU count. The buffer
tiers depend on measured workload topology rather than marketing chip names.

One additional production point, 2,048 dirs × 64 files (131,072 paths), favored
256 KiB at 72.7 ms over 32 KiB at 79.0 ms and 128 KiB at 91.6 ms with four
participants. Because that conflicts with the 512-dir wide result, the shipping
policy does **not** add an overfit 2,048-dir threshold; 128 KiB remains the safe
wide default until a stable topology predictor is measured across more machines.

Directory validation was measured separately on a 15,929-directory Homebrew
snapshot. Median clean validation was 25.840 ms (1 lane), 16.822 ms (2),
18.589 ms (4), and 14.369 ms (8), so validation retains up to 8 hardware-bounded
lanes while tiny snapshots stay sequential.

## Pinned-fx equivalence and end-to-end benchmark

Injected equivalence passed on the Git fixture (`EQUIVALENCE_OK cases=26`), the
wide tree (`cases=23`), and the deep tree (`cases=9`). The end-to-end sorted
recursive benchmark remained byte-identical:

| Tree | Stock median | Companion cold | Companion warm |
|---|---:|---:|---:|
| wide / cap 100001 | 51.191 ms | 23.379 ms | 0.859 ms |
| deep / cap 100001 | 6.731 ms | 6.806 ms | 0.252 ms |
| `/opt/homebrew` / cap 600000 | 493.723 ms | 289.639 ms | 14.607 ms |

The deep-tree cold path is deliberately not claimed as a speedup; the adaptive
policy prefers exactness and low thread overhead, while unchanged repeats still
benefit from validated snapshots.

Final clean-room rerun after the performance-core sysctl implementation, using
the same pinned upstream source and production `discover` path:

| Tree | Stock median | Companion cold | Companion warm | Warm speedup |
|---|---:|---:|---:|---:|
| 512 × 100 synthetic / cap 600000 | 42.513 ms | 19.059 ms | 0.581 ms | 73.145× |
| `/opt/homebrew` / cap 600000 | 519.514 ms | 305.942 ms | 14.139 ms | 36.742× |

Every result in that rerun remained byte-identical to stock, including source,
cap, incomplete/cap-reason metadata, overlong counts, ordered paths, and path
bytes.
