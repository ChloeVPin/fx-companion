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
  pid/pidversion logged), ping and stat RPCs.
- `com.chloevpin.fx-companiond.plist`: on-demand LaunchAgent registration.
  Edit the absolute path inside before installing elsewhere.
- `latency`: client measuring round-trip latency against the running daemon.
- `benchmarks/traversal_bench`: fts vs readdir vs getattrlistbulk shootout
  over a synthetic tree (name-only and attribute-heavy modes).

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

Traversal, synthetic tree of 128 dirs x 256 files (32,896 entries,
93.8 MB data), median of 5 runs:

| method          | names    | attrs    |
|-----------------|----------|----------|
| fts             | 29.5 ms  | 31.4 ms  |
| readdir+lstat   | 13.0 ms  | 68.8 ms  |
| getattrlistbulk | 26.0 ms  | 26.1 ms  |

Early signals consistent with tempel.org's finding that no single syscall
wins everywhere: readdir is fastest name-only here, while bulk wins once
attributes ride along and stays flat regardless of mode. Concurrency
(dumac-style worker pool) is the next lever, not yet wired.
These are single-machine observations, not claims; the >=4x target gate
still requires instrumenting fx's own walk paths at the pinned commit.

## License

Apache-2.0.
