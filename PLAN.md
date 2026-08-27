# fx-companion Plan

**Status:** Shipping product plus retained research archive (Revised 2026-08-24)
**License:** Apache-2.0
**Primary Platform:** macOS on Apple Silicon (M-series)
**Language:** Zig 0.16+ for new code; C only for syscalls Apple does not expose to Zig cleanly.
**Compatibility pin:** fx `8d6152de17905429ad78decdb475df8cfd04f557`. `PINNED_FX` is authoritative.

## 1. Vision

fx-companion is a source-injected additive acceleration module compiled with pinned fx.
It preserves fx's observable workspace-discovery contract and falls back to stock whenever
the accelerated path cannot prove an exact result.

Primary focus is deterministic acceleration. Speculative features are strictly opt-in.

### Shipped path (2026-08-24)

- Cold sorted traversal: eight getdirentries workers, 128 KiB buffers.
- Warm sorted traversal: packed path snapshot, validated on local APFS by parallel
  device/inode/mode/mtime/ctime checks for every traversed directory.
- Exact cap handling: stock computes the first capped result; later calls reuse only a
  validated byte-identical snapshot. Source-order calls always stay stock.
- Public-API equivalence gate covers ordering, cap metadata, hidden paths, Git ignores,
  symlinks, special files, cache hits, create/delete invalidation, and content-only hits.
- `/benchmark` guards the interactive thread with a 10,000-path / 100 ms preflight;
  large trees return a bounded no-claim profile instead of blocking on an uncacheable walk.
- FSEvents-only invalidation rejected: the immediate post-create synchronous flush missed
  the event; reproducible result is recorded under `benchmarks/results/`.

The older daemon, XPC, ZeroCopyState, AMX, and predictor sections below are retained as
research history. They are not the installed product path.

## 2. Goals

### Primary (Deterministic)

1. Fast directory traversal via a measured shootout, not a single-syscall assumption.
2. Persistent launchd/XPC daemon eliminating repeated fork/exec.
3. ZeroCopyState: shared-memory agent state removing serialization on hand-off.
4. Audited XPC interface validating callers with the audit token.

### Secondary / Experimental

5. Optional CPU-based speculative tool execution (PASTE-style Pattern Tuples).
   AMX and ANE are research spikes only, behind explicit kill switches.

### Non-Goals

- Never grow the main fx binary or change its cold-start characteristics.
- No classic kexts. DriverKit only if proven necessary later.
- Do not claim AMX accelerates string search or that ANE is the right speculative scorer.

## 3. Core Components

### 3.1 Traversal Service

Two distinct workloads:

- **Name-only walks**: live shootout on current macOS between fts, readdir, and getattrlistbulk.
  Choose per filesystem. 2019 data (tempel.org) showed readdir/fts faster name-only on APFS;
  re-measure before trusting it.
- **Attribute-heavy scans** (size, dates, type): getattrlistbulk plus a worker pool and ~128 KB buffers.
  Only this workload may carry the >=5x claim, and only against a concurrent baseline.

Concurrency is a larger lever than the syscall itself (dumac results).

### 3.2 ZeroCopyState

shm_open/mmap with lock-free rings (pattern proven in pjsny/macos-zero-copy-ipc).
Cost moves to synchronization design; stress tests are mandatory.

### 3.3 Persistent Daemon

launchd + XPC is the Apple-recommended pattern. Every connection validates the peer audit
token (uid, pid, pidversion) before any message is processed.

### 3.4 AMXSearch (optional spike)

Behind `FX_COMPANION_SPECULATIVE=1`. Kill rule: must beat a hand-written NEON SIMD baseline
by more than 20 percent on the anchor workload, else deleted. Matmul-shaped work already
reaches AMX through public Accelerate APIs.

### 3.5 Speculative Layer (CPU Pattern Predictor)

Drop ANE as scorer. Port PASTE's mechanism:

- Pattern Tuple (tool-type sequence context, predicted tool, symbolic parameter derivation, probability)
- Side-effect policy classes: speculatable / dry-run only / prohibited
- Speculation runs only on slack resources with instant preemption

ANE remains a research appendix citing maderix/ANE and Orion, listing known walls:
~0.095 ms dispatch overhead, ~119-compiles-per-process leak, baked weights.

### 3.6 Sandboxing

sandbox-exec is deprecated by Apple. Centralized Seatbelt profiles still function but carry
maintenance risk. For the eval/gym workload prefer per-user isolation or VM snapshots
(alcless / GhostVM patterns).

## 4. Success Metrics

| Metric | Target | Gate |
|---|---|---|
| Attribute-heavy FS + search loops | >=4x wall clock | after instrumenting real fx paths at pinned commit |
| Name-only walks | parity or better vs best of shootout | measured per filesystem |
| Subagent hand-off | no claim yet | baseline first; >=3x was unproven and retracted |
| Daemon cold start | <5 ms | on-demand LaunchAgent |
| Daemon RSS | <15 MB normal load | Week 2 measurement |

## 5. Phases

- **Weeks 1-2 Foundation** (current): Zig XPC service as on-demand LaunchAgent,
  audit-token validation, health endpoint, round-trip latency client, cold start + RSS measured.
- **Week 3 Traversal**: live shootout harness, winners implemented, fx paths instrumented first.
- **Week 4 ZeroCopyState**: layout, atomics, ownership regions, one migrated object, zero-copy proof (done: shm region + daemon RPCs in `src/zcs.zig`, cross-process hand-off verified; verdict in README - 31x at 4 KB control-plane state, loses to pipes at >=256 KB bulk transfer because of double CRC+memcpy).
- **Week 5 AMX spike**: flag-gated, NEON kill rule enforced.
- **Week 6+ Speculative predictor**: Pattern Tuples + policies; ANE appendix only.

## 6. Integration Order

1. MCP server / skill touching zero fx core code
2. ACP extension
3. Optional thin library
4. Last resort: tiny isolated patches inside fx

## 7. Agent Coding Rules

- Pin the exact fx commit hash in every benchmark record.
- Every public surface ships with a benchmark under `benchmarks/`.
- Speculative/private-API code sits behind compile-time AND runtime flags.
- Validate every XPC caller through the audit token.
- Document ownership and lifetime rules for every shared-memory region.

## 8. Risk Register

| Risk | Severity | Mitigation |
|---|---|---|
| Outdated FS performance data | High | live shootout on current macOS before committing |
| AMX does not help string search | High | optional spike + hard kill rule vs NEON |
| ANE wrong tool for scoring | High | replaced by CPU Pattern Tuples |
| Races in ZeroCopyState | High | strict ownership + atomics + stress tests |
| sandbox-exec deprecated | Medium | prefer VM/per-user isolation for evals |
| fx upstream churn | High | pin commit hash; re-baseline often |
| XPC accepts everyone by default | High | mandatory audit-token check |

## 9. First Milestone

1. Repository created (done).
2. Weeks 1-2 XPC skeleton: LaunchAgent plist, daemon, audit-token validation, latency client (done).
3. Week 3 benchmark harness instrumenting real fx walk/search paths plus the traversal shootout (done: fx pinned at 04e0ae0, `walkWorkspacePaths` replicated syscall-for-syscall in `benchmarks/fx_replica_walk.zig`, gated in `benchmarks/fx_gate_bench.zig`; verdict in README: >=5x name-only traversal target refuted on APFS - fx's readdir iterator is already near the floor; bulk wins only attribute-heavy scans).
4. First measured numbers on modern Apple silicon.
