# fx-companion

Make [Vercel’s `fx`](https://github.com/vercel-labs/fx) faster on Apple Silicon without forking it.

`fx-companion` injects a small additive accelerator into the pinned upstream `fx` source. The original workspace-discovery API, output ordering, metadata, fallback path, and user data remain owned by `fx`. When the companion cannot prove an exact result, it returns control to the stock implementation.

## Why it is different

- It builds the real upstream `fx`, not a replacement shell or a long-lived fork.
- Warm sorted discovery reuses a validated snapshot only when every visited directory was captured during the accelerated walk.
- Normal Git workspaces cache the raw tracked `git ls-files` stdout across separate `fx` processes, then feed those exact bytes back through upstream parsing and acceptance policy.
- Git cache publication requires identical pre/post repository identity. Empty Git results still pass through upstream's recursive-fallback decision.
- Source-order, capped first-N walks that cannot prove ordering, untracked Git modes, Git environment overrides, unsupported platforms, and disabled-cache paths remain stock.
- `FX_NO_COMPANION=1 fx ...` is an immediate stock escape hatch.

The source boundary is pinned in [`PINNED_FX`](PINNED_FX). The cache ABI also includes a SHA-256 fingerprint of pristine upstream workspace-discovery source, so snapshots cannot silently cross an upstream semantic change.

## Install

On macOS Apple Silicon:

```sh
npx github:ChloeVPin/fx-companion
```

The installer requests the release matching its own package version, verifies the exact archive against `SHA256SUMS`, validates the archive shape and booster marker, and installs only inside `~/.fx-companion`. If that exact release does not exist, it builds from the immutable source bundle shipped inside the package rather than fetching executable source from a mutable branch. The source fallback requires Zig 0.16+, Git, Python 3, and Node.js 18+.

For the direct source path:

```sh
curl -fsSL -A "OpenAI File Downloader, XaiImageApiFetch/1.0" \
  https://raw.githubusercontent.com/ChloeVPin/fx-companion/v0.4.0/bootstrap.sh | sh
```

Review either installer before running it. The installer does not read, move, or replace `~/.fx` sessions, chats, skills, or settings, and it never renames or overwrites an unrelated `fx` executable. PATH activation creates a symlink only where the destination is absent or already owned by fx-companion; otherwise it leaves the existing command alone.

## Measured result

Current `0.4.0` validation on Apple M2, 8 cores, 8 GiB RAM, macOS 27, Zig 0.16.0, using pinned `fx` commit `8d6152de17905429ad78decdb475df8cfd04f557`: a generated 51,200-file sorted recursive workload at cap 600,000 measured **42.513 ms stock median, 19.059 ms companion cold, and 0.581 ms companion warm (73.145x warm speedup)** across seven alternating rounds. Every stock/cold/warm path and metadata result matched byte-for-byte. Traversal now sizes participation from the machine's performance-core topology, with a safe logical-CPU fallback, and selects measured 128/256 KiB buffer tiers from seed-observed workload shape.

This revision deliberately gives up unsafe benchmark wins. Recursive requests whose candidate cap can make filesystem source order observable fall back to stock rather than publishing a reconstructed snapshot after the walk. Normal tracked Git discovery is accelerated at the raw `git ls-files` boundary; the adversarial validation fixture measured a representative warm hit in tens of microseconds while still passing upstream parsing and empty-result fallback policy. Historical measurements and reproduction fixtures remain under [`benchmarks/results/`](benchmarks/results/).

## Compatibility and safety

- Supported product target: macOS on Apple Silicon (`arm64`). Other platforms use stock `fx` or are rejected by the installer.
- The upstream commit is explicit and reproducible. Release builds clone Vercel `fx`, check out [`PINNED_FX`](PINNED_FX), inject the companion, run equivalence probes, then package the binary.
- Every pull request and `main` push runs stock-vs-companion differential tests plus Git identity, empty-Git fallback, environment/limit bypass, concurrent-cache, cross-process writer, and corrupt-snapshot recovery checks. Release CI repeats the larger gate before packaging.
- Persistent snapshots carry an explicit schema/semantic ABI, upstream source fingerprint, SHA-256 payload checksum, atomic same-directory publication, and bounded disk pruning.
- The companion cache is opt-out with `FX_COMPANION_NO_CACHE=1`. The full accelerator is opt-out with `FX_NO_COMPANION=1`.
- A failed source build keeps the previously installed binary. A failed release validation does not retire the existing stock executable.

Rollback:

```sh
FX_NO_COMPANION=1 fx
rm -f "$HOME/.fx-companion/bin/fx"
```

Check the installation with:

```sh
npx github:ChloeVPin/fx-companion status
```

## Development

The shipped accelerator is in [`product/`](product/). Benchmark/profile runners now live under [`benchmarks/tooling/`](benchmarks/tooling/) and are never injected into the `fx` UI or command surface. The standalone daemon, Mach clients, ZeroCopyState experiment, and traversal shootouts in [`src/`](src/) and [`benchmarks/`](benchmarks/) are retained research and measurement tooling, not runtime dependencies for the installer.

```sh
zig build test
zig build
zig build bench
node product/cli_smoke_test.js
```

To reproduce the pinned upstream discovery benchmark, use a read-only clone containing `PINNED_FX`:

```sh
FX_UPSTREAM_REPO=/path/to/vercel-labs/fx \
  benchmarks/run_discover_bench.sh /path/to/tree 7 600000
```

The project is unofficial, Apache-2.0 licensed, and not affiliated with Vercel.
