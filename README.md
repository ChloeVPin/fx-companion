# fx-companion

Make [Vercel’s `fx`](https://github.com/vercel-labs/fx) faster on Apple Silicon without forking it.

`fx-companion` injects a small additive accelerator into the pinned upstream `fx` source. The original workspace-discovery API, output ordering, metadata, fallback path, and user data remain owned by `fx`. When the companion cannot prove an exact result, it returns control to the stock implementation.

## Why it is different

- It builds the real upstream `fx`, not a replacement shell or a long-lived fork.
- Warm sorted discovery reuses a validated snapshot instead of walking the tree again.
- Normal Git workspaces reuse the tracked `git ls-files` result across separate `fx` processes when `.git`, `HEAD`, and `index` identity is unchanged.
- Source-order, untracked, unsupported-platform, and disabled-cache paths remain stock.
- `FX_NO_COMPANION=1 fx ...` is an immediate stock escape hatch.

The source boundary is pinned in [`PINNED_FX`](PINNED_FX), and the required injection seam is `walkWorkspacePaths` in Vercel `fx`.

## Install

On macOS Apple Silicon:

```sh
npx github:ChloeVPin/fx-companion
```

The installer prefers a checksum-verified `macos-arm64` GitHub Release. If no compatible release exists yet, it downloads the pinned source installer and builds the original Vercel `fx` locally. The source fallback requires Zig 0.16+, Git, Python 3, and Node.js 18+.

For the direct source path:

```sh
curl -fsSL -A "OpenAI File Downloader, XaiImageApiFetch/1.0" \
  https://raw.githubusercontent.com/ChloeVPin/fx-companion/main/bootstrap.sh | sh
```

Review either installer before running it. The installer does not read, move, or replace `~/.fx` sessions, chats, skills, or settings. A previous stock executable is backed up as `.stock.bak` only after the replacement passes its build and equivalence gate.

## Measured result

Recorded on Apple M2, 8 cores, 8 GiB RAM, macOS 27, Zig 0.16.0, using pinned `fx` commit `8d6152de17905429ad78decdb475df8cfd04f557`. Results are medians from seven alternating stock/companion pairs with fresh arenas and byte-identical output checks.

| Workload | Stock | Companion cold | Companion warm |
| --- | ---: | ---: | ---: |
| 409,600 files, cap 100,000 | 83.584 ms | 95.497 ms | 1.199 ms |
| 409,600 files, cap 600,000 | 366.373 ms | 246.266 ms | 4.602 ms |
| 8 files, cap 100,000 | 0.022 ms | 0.185 ms | 0.017 ms |

Cold fill is not universally faster. The repeat-discovery win is the product: the large capped workload reaches 69.697x warm speedup, and the uncapped workload reaches 79.605x. Tiny cold trees remain slower because cache construction dominates. Full records and reproduction commands are in [`benchmarks/results/2026-08-26-apple-silicon.md`](benchmarks/results/2026-08-26-apple-silicon.md).

## Compatibility and safety

- Supported product target: macOS on Apple Silicon (`arm64`). Other platforms use stock `fx` or are rejected by the installer.
- The upstream commit is explicit and reproducible. Release builds clone Vercel `fx`, check out [`PINNED_FX`](PINNED_FX), inject the companion, run equivalence probes, then package the binary.
- The release gate compares paths, ordering, source metadata, caps, hidden paths, Git ignores, symlinks, special files, cache invalidation, cancellation, and cross-process Git caching.
- The companion cache is opt-out with `FX_COMPANION_NO_CACHE=1`. The full accelerator is opt-out with `FX_NO_COMPANION=1`.
- A failed source build keeps the previously installed binary. A failed release validation does not retire the existing stock executable.

Rollback:

```sh
FX_NO_COMPANION=1 fx
rm -f "$HOME/.fx-companion/bin/fx"
mv "$HOME/.local/bin/fx.stock.bak" "$HOME/.local/bin/fx"  # if that backup exists
```

Check the installation with:

```sh
npx github:ChloeVPin/fx-companion status
```

## Development

The shipped accelerator is in [`product/`](product/). The standalone daemon, Mach clients, ZeroCopyState experiment, and traversal shootouts in [`src/`](src/) and [`benchmarks/`](benchmarks/) are retained research and measurement tooling, not required runtime dependencies for the installer.

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
