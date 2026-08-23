# fx-companion

**Boosted [fx](https://github.com/vercel-labs/fx) for Apple Silicon — stock output, faster traversal.**

## Quick start

```sh
curl -fsSL https://raw.githubusercontent.com/ChloeVPin/fx-companion/main/bootstrap.sh | sh
```

Requires macOS on arm64 and Zig (`brew install zig`). The installer builds fx,
self-tests boosted-vs-stock output equivalence, and refuses to install anything
that isn't byte-identical. Then:

```sh
export PATH="$HOME/.fx-companion/bin:$PATH"   # add to ~/.zshrc
fx                                            # looks like fx, runs boosted
FX_NO_COMPANION=1 fx ...                      # pure stock, anytime
~/.fx-companion/fxc sync                      # re-boost after any `fx upgrade`
```

---

A native acceleration layer for fx on Apple silicon.
User-space companion daemon plus benchmark suite. Experimental research prototype.

Read [PLAN.md](PLAN.md) for goals, corrected claims, and the phased roadmap.
Every performance number published here comes from `benchmarks/` runs recorded with
the pinned fx commit hash and machine details.

## Status

Weeks 1-2 skeleton:

- `fx-companiond`: Zig Mach-service daemon with per-message audit-token
  validation (kernel-stamped `MACH_RCV_TRAILER_AUDIT` trailer; euid policy;
  pid/pidversion logged), ping and stat RPCs. The stat reply includes
  `init_us`, the daemon's self-timed entry-to-check-in window.
- `com.chloevpin.fx-companiond.plist`: on-demand LaunchAgent registration.
  Edit the absolute path inside before installing elsewhere. Verified:
  launchd owns `dev.fx.companion`, spawns the daemon at first Mach lookup,
  and nothing runs until then.
- `latency`: client measuring round-trip latency against the running daemon.
- `walkrpc`: asks the daemon to walk a directory tree (MSG_WALK RPC) and
  cross-checks the reply against an in-process run of the same walker.
- `benchmarks/traversal_bench`: fts vs readdir vs getattrlistbulk shootout
  over a synthetic tree (name-only and attribute-heavy modes).

Walk RPC notes: walks execute on a worker pool (8 threads, pthread
mutex/condvar - Zig 0.16 removed std.Thread sync primitives), so a blocked
`open()` (macOS TCC consent on Downloads/Documents/Desktop can stall
indefinitely for launchd-spawned processes) never wedges the service;
concurrent requests get an immediate busy status. There is no fixed
directory cap; the walk covers the whole tree and reports a truncated flag
only if an allocation fails.

## Product: boosted fx (in-process hook)

The daemon path was dropped from the product: the in-process hook is strictly
faster (no IPC hop, no launchd cold-start penalty). `product/` contains the
shippable booster:

- `fx_companion.zig` — the accelerator module (8-worker getdirentries pool,
  128 KB buffers, pthread sync). Byte-identical output to stock fx, verified
  by `tests_fxcompanion.zig` on three trees (tiny known tree with symlinks,
  hidden files and node_modules; the 409,600-file anchor; `/opt/homebrew`),
  both targets, repeated runs.
- `inject_hook.py` — idempotently injects the hook into an fx source tree;
  fails loudly if upstream anchors changed.
- `install.sh` — one command: payload to `~/.fx-companion`, clone fx, inject,
  build ReleaseFast, run the equivalence self-test (refuses to install on any
  mismatch), install to `~/.fx-companion/bin/fx`.
- `fxc` — `fxc sync` re-applies the booster after any `fx upgrade`
  (fetch latest stock source, inject, rebuild); `fxc status` reports whether
  the fx on PATH carries the booster.

Stock behavior anytime: `FX_NO_COMPANION=1 fx ...`.

### Measured (Apple Silicon macOS, ReleaseFast, medians)

| Surface | stock fx | boosted | speedup |
|---|---|---|---|
| `discover()` end-to-end, 409,600 files | 1,589-1,685 ms | 347-533 ms | 3.2-4.6x |
| Equivalence probe walker, anchor | 1,761-2,767 ms | 156-297 ms | 5.9-17.7x |
| Raw walker (gate bench) | 213 ms | 104 ms | 2.05x |

Output byte-identical in every case (`IDENTICAL` on files and dirs targets).

## Build

Requires Zig 0.16+ and macOS on arm64.

```sh
git clone https://github.com/ChloeVPin/fx-companion.git
cd fx-companion
zig build -Doptimize=ReleaseFast
```

## Run

Daemon (foreground):

```sh
./zig-out/bin/fx-companiond
```

Latency check (daemon must be running):

```sh
./zig-out/bin/latency
```

Traversal shootout (creates a temp tree, cleans up after):

```sh
./zig-out/bin/traversal_bench --dirs 128 --files 256 --runs 5
```

Install as an on-demand LaunchAgent:

```sh
cp com.chloevpin.fx-companiond.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.chloevpin.fx-companiond.plist
```

The agent starts on first Mach lookup of `dev.fx.companion` and exits after idle timeout.

## First measurements

Machine: Apple silicon Mac, macOS 27.0, ReleaseFast build, warm cache.

IPC round trip through the audited Mach path (n=101):
p50 13-19 us, p99 25-76 us; bootstrap lookup 130-350 us.

Launchd on-demand activation (verified end to end): the agent registers
`dev.fx.companion` with no process running; the first Mach lookup spawns the
daemon. Daemon self-timed init (entry to bootstrap_check_in complete):
412 us, well inside the <5 ms cold-start budget. Daemon RSS at idle:
1.8 MB, inside the <15 MB budget. End-to-end cold first round trip,
which additionally includes launchd fork/exec and dyld: 19-115 ms across
runs; that span is launchd's spawn chain, not daemon initialization.

Traversal, synthetic tree of 128 dirs x 256 files (32,896 entries,
93.8 MB data), median of 5 runs:

| method          | names    | attrs    |
|-----------------|----------|----------|
| fts             | 29.5 ms  | 31.4 ms  |
| readdir+lstat   | 13.0 ms  | 68.8 ms  |
| getattrlistbulk | 26.0 ms  | 26.1 ms  |

Walk RPC over the daemon (repo tree, 461 entries / 350 MB): 14.6 ms walk,
15.0 ms round trip - the Mach hop adds under 1% on real workloads.
The walker is a work-stealing worker pool (8 threads, pthread sync): each
worker claims queued directories and walks its own subtree. On /opt/homebrew
(15k dirs, 158k entries, 4.3 GB) it completes in ~830-940 ms with full
counts - the previous single-threaded version took 3.1 s and silently
truncated past an 8192-directory cap. Daemon RSS under this load: 26 MB
(the pool's per-worker buffers; idle RSS stays at 1.8 MB).

Early signals consistent with tempel.org's finding that no single syscall
wins everywhere: readdir is fastest name-only here, while bulk wins once
attributes ride along and stays flat regardless of mode. Concurrency
(dumac-style worker pool) is the next lever, not yet wired.
These are single-machine observations, not claims; the >=4x target gate
still requires instrumenting fx's own walk paths at the pinned commit.

## Week 3 gate: fx-replica vs fx-companion (measured)

fx pinned at 04e0ae0. Its recursive-walk fallback is `walkWorkspacePaths`
in `src/core/workspace/workspace_files.zig`: single-threaded DFS with
`std.Io.Dir.Iterator` (2048-byte readdir buffer), skipping `.git` and other
ignored names plus hidden dirs. `benchmarks/fx_replica_walk.zig` reproduces
that walker syscall-for-syscall (same iterator, same stack discipline, same
ignored list). In git repos fx prefers `git ls-files` and only falls back to
this walker; the POSIX path also backs grep/completion/file-index flows on
non-git trees.

Anchor workload: /tmp/fxanchor - 4,096 dirs, 409,600 files (the plan's
>=400k-file anchor), APFS, warm cache, ReleaseFast, medians of 3 runs,
names mode (count entries only) unless stated:

| walker                          | median   |
|---------------------------------|----------|
| **companion getdirentries pool x8** | **104 ms** |
| plain readdir DFS (single-threaded) | 187-200 ms |
| fx-replica collect (fx's real behavior: build path strings) | 213 ms |
| fx-replica count                | 206-214 ms   |
| companion daemon RPC, warm      | 125 ms direct-spawn / 220-300 ms launchd-spawn |
| fts (single-threaded)           | 6,300 ms |
| getattrlistbulk worker pool x8  | 734-1,072 ms |

Honest verdict for this tree and workload, revised 2026-08-23: the
companion's getdirentries worker pool is ~2x faster than fx's fallback in
names mode (104 ms vs 213 ms), byte-exact on the full 413,696-entry count,
verified by `gde_soak` across repeated runs and real trees (/opt/homebrew:
158,229 entries stable). The earlier "refuted" verdict applied to the
getattrlistbulk backend only; bulk pays per-entry attribute decode that
names mode never needed. The daemon RPC path beats fx end to end when the
daemon is spawned directly (~125 ms); under launchd it currently runs at
~220-300 ms - still no slower than fx - and the cause is isolated to the
launchd-managed context, not QoS tier (a utility-tier taskpolicy spawn
matches the fast path). Traversal is a measured win in both configurations.

The getdirentries backend uses the same directory-read syscall as fx
(std.Io.Dir.Iterator drives readdir/getdirentries underneath) with three
differences: 128 KB buffers instead of the iterator's 2 KB, an 8-thread
work-stealing queue, and deferred openat-through-the-root-fd so open fds
stay bounded at workers+1 regardless of tree shape. Job path strings are
NUL-terminated by construction; the soak test exists because a previous
non-terminated version silently dropped subtrees depending on malloc
layout - flat synthetic trees masked it completely.

Reproduce:

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/fx_gate_bench /path/to/large/tree 3
./zig-out/bin/fx-companiond &        # then:
./zig-out/bin/walkrpc --names /path/to/large/tree
```

## Week 4: ZeroCopyState (implemented, measured)

`src/zcs.zig` implements the shared-memory state region: POSIX shm object
per key (`/fxcomp-<key>`), 256-byte header (magic FXZS, version, epoch,
capacity, length, CRC-32), a process-shared pthread mutex, and one slab.
Writers memcpy payload once into the mapping and publish via a release
store of the epoch; readers either take the mutex or run lock-free
(epoch check + CRC verify). Attach/detach are mmap/munmap; unlink is
explicit creator cleanup.

Daemon RPCs `MSG_STATE_PUT` / `MSG_STATE_GET`: the client names the key,
the daemon attaches to the same shm object, and only the key plus control
metadata travel through Mach - the payload itself never crosses the RPC
for readers. Verified end to end: process A puts, daemon attaches
independently, separate process B reads byte-exact data with no daemon
involvement on the read path.

Hand-off benchmark (`statetool bench <key> <bytes>`), median of 5 runs,
warm cache, ReleaseFast. Baseline B is the classic tool-process pattern:
fork/exec of `/bin/cat` echoing the blob back through two pipes (parent
side non-blocking + poll so it cannot deadlock). A-fast is the shipped
no-CRC fast path (writer put + lock-free reader get, torn-write detection
by epoch alone); A-crc pays CRC-32 twice per blob (write + read verify):

| payload | A no-CRC | A CRC | B fork/exec+pipe | no-CRC win | CRC win |
|---------|----------|-------|------------------|------------|---------|
| 4 KB    | 1 us     | 109 us    | 4,332 us | 3,716x | 40x   |
| 64 KB   | 16 us    | 1,525 us  | 2,250 us | 137x   | 1.5x  |
| 256 KB  | 44 us    | 4,489 us  | 1,950 us | 44x    | 0.4x  |
| 1 MB    | 150 us   | 15,380 us | 1,971 us | 13x    | 0.1x  |
| 4 MB    | 613 us   | 61,892 us | 3,213 us | 5.2x   | 0.1x  |

All runs byte-verified 5/5 at every size. Honest verdict, revised:
with the no-CRC fast path ZeroCopyState wins at every measured size,
from 1 us control-plane hand-offs to 613 us at 4 MB - bulk transfer
included (the earlier "pipes win for megabytes" verdict applied only
to the CRC-checked path, which loses above ~64 KB because CRC-32 over
the blob costs more than the entire pipe round trip). The no-CRC path
detects torn writes via the epoch counter but not content corruption;
use it when the writer is trusted or integrity is checked elsewhere,
and the CRC path when it is not.

Engineering note (2026-08-23): the bench previously hung at >=256 KB.
Root cause: `fcntl(2)` is variadic; a hand-written fixed-arity
`extern "c" fn fcntl(fd, cmd, arg) c_int` declaration compiles and
returns 0 but silently never applies `F_SETFL` flags on arm64 macOS /
Zig 0.16, so the parent's "non-blocking" pipe writes were blocking.
64 KB payloads fit in the pipe buffer and masked the bug. Fix routes
fcntl through the true C prototype (`@cImport("fcntl.h")`). Verified
by A/B probe: same call site, flags stick only through the variadic
prototype.

Reproduce:

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/statetool bench zcsbench 4096
./zig-out/bin/statetool put demo "payload" && ./zig-out/bin/statetool get demo
```

## License

Apache-2.0.
