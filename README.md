# fx-companion

A native acceleration layer for [fx](https://github.com/vercel-labs/fx) on Apple silicon.
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
| fx-replica collect (fx's real behavior: build path strings) | 227 ms |
| fx-replica count                | 219 ms   |
| plain readdir DFS (single-threaded) | 199 ms |
| fts (single-threaded)           | 3,774 ms |
| getattrlistbulk worker pool x8 (companion walker) | 887 ms |
| companion daemon RPC (walk time) | 1,019-1,067 ms |

Honest verdict for this tree and workload: the companion's bulk+pool walker
is ~4x faster than fx's fallback **only against fts-shaped baselines**; it
is ~4x SLOWER than fx's actual readdir-iterator fallback in names mode
(227 ms fx-replica vs ~890 ms bulk pool vs ~1,020 ms over RPC). The Mach hop
itself adds under 15% (RPC minus local bulk). The >=5x Week 3 traversal
target is NOT met and should be treated as refuted for name-only walks on
this machine: Zig's std.Io.Dir.Iterator readdir loop is already near the
APFS floor (~0.5 us/entry), so there is little deterministic headroom left
in names-mode traversal itself.

Where a deterministic win remains plausible: attribute-heavy walks
(lstat-per-file workloads like du/grep-size paths) where the plan's
getattrlistbulk advantage is 3x+ even single-threaded (68.8 ms vs 26.1 ms
on the synthetic tree above); and IPC/state work (Weeks 4-5), which this
gate does not measure.

Reproduce:

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/fx_gate_bench /path/to/large/tree 3
./zig-out/bin/fx-companiond &        # then:
./zig-out/bin/walkrpc --names /path/to/large/tree
```

## License

Apache-2.0.
