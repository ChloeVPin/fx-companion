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

Walk RPC notes: walks execute on a worker thread, so a blocked `open()`
(macOS TCC consent on Downloads/Documents/Desktop can stall indefinitely for
launchd-spawned processes) never wedges the service; concurrent requests get
an immediate busy status. The walker's fixed 8192-directory table reports a
truncated status instead of silently dropping directories.

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

Walk RPC over the daemon (repo tree, 408 entries / 321 MB): 12.7 ms walk,
12.8 ms round trip - the Mach hop adds under 1% on real workloads.
`/opt/homebrew` (15k dirs) completes in 3.1 s with a truncated status;
counts are lower bounds past the walker's directory-table cap.

Early signals consistent with tempel.org's finding that no single syscall
wins everywhere: readdir is fastest name-only here, while bulk wins once
attributes ride along and stays flat regardless of mode. Concurrency
(dumac-style worker pool) is the next lever, not yet wired.
These are single-machine observations, not claims; the >=4x target gate
still requires instrumenting fx's own walk paths at the pinned commit.

## License

Apache-2.0.
