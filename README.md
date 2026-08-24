<div align="center">

# ⚡ fx-companion

### Boosted [fx](https://github.com/vercel-labs/fx) for Apple Silicon

**Stock output. Faster traversal. Zero config.**

[![Install](https://img.shields.io/badge/install-npx-9cf)](#install)
[![Platform](https://img.shields.io/badge/platform-macOS%20Apple%20Silicon-black)](https://github.com/ChloeVPin/fx-companion)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
[![Tests](https://img.shields.io/badge/equivalence-byte--identical-success)](#how-it-works)

</div>

---

## Install

<div align="center">

```sh
npx github:ChloeVPin/fx-companion
```

**That's it.** Downloads the prebuilt binary (checksum-verified), retires any
stock fx you had — sessions, skills, and settings stay untouched — and you're
done.

</div>

> [!NOTE]
> Requires macOS on Apple Silicon and Node 18+.
>
> **Every release is built in public CI** from vercel-labs/fx at a pinned
> commit, and the installer refuses to install anything that doesn't pass a
> byte-identical output self-test. No trust required — reproduce it yourself.

<details>
<summary><b>Commands</b></summary>

```sh
npx github:ChloeVPin/fx-companion install   # default: download + replace + activate
npx github:ChloeVPin/fx-companion status    # what's installed, which fx wins on PATH
```

</details>

---

## Why

fx walks your workspace on every turn of its agent loop. On Apple Silicon
that walk was leaving big wins on the table: a single thread with a 2 KB
buffer, one directory at a time.

fx-companion swaps that inner loop for an **8-worker pool over the same
syscalls**, with 128 KB buffers — and nothing else changes:

- **Byte-identical output.** Same paths, same order after sort, same hidden /
  ignore-list / cap rules. Verified by an equivalence probe on every install.
- **Purely additive.** Unsupported platform or any hard failure → stock fx,
  automatically. Kill switch anytime with `FX_NO_COMPANION=1`.
- **No daemon, no background processes.** The speedup lives inside the binary.
- **Survives updates? No — it *is* fx.** The formula builds vercel's own
  source with one additive hook file. New upstream version = new formula bump.

## Performance

Measured on macOS arm64 (ReleaseFast, medians). Full methodology in
[`benchmarks/`](benchmarks).

| Surface | Stock fx | Boosted | Speedup |
|---|---:|---:|---:|
| Workspace walk, end-to-end (409,600 files) | 1,589–1,685 ms | 347–533 ms | **3.2–4.6×** |
| Raw traversal | 213 ms | 104 ms | **2.05×** |
| State hand-off (vs fork/exec + pipe) | ~2–4 ms | 44 µs | **44–3,716×** |

Every number is reproducible from the bench sources in this repo.

## How it works

```text
stock fx   ──► single-threaded readdir, 2 KB buffer        ──► 213 ms
boosted fx ──► 8 workers · getdirentries · 128 KB buffers  ──► 104 ms
               └─ any failure or non-arm64 ──► stock path, byte-for-byte
```

The booster is a single module ([`product/fx_companion.zig`](product/fx_companion.zig))
plus ~40 injected lines in fx's walker. The installer runs an equivalence
probe against a known tree before installing anything — if boosted output
differs from stock by even one byte, it refuses to install.

## Repository layout

```text
product/     the shippable booster: module, injector, installer, probes
benchmarks/  every walker, bench harness, and the comparison chart
src/         daemon research prototype (Mach service, shm state, ZCS format)
PLAN.md      goals, corrected claims, phased roadmap
```

## FAQ

<details>
<summary><b>Is this a fork of fx?</b></summary>

No. It builds vercel-labs/fx unmodified plus one additive module with a
graceful fallback. Remove the module and you have exactly stock fx.
</details>

<details>
<summary><b>How do I go back to stock?</b></summary>

Delete `~/.fx-companion/bin/fx` (or restore your `.stock.bak` backup) — or run `FX_NO_COMPANION=1 fx …` to skip the
booster per-invocation without uninstalling.
</details>

<details>
<summary><b>Does it work on Intel Macs or Linux?</b></summary>

Not yet — the fast path targets macOS arm64 syscalls. Everything falls back
to stock behavior there.
</details>

## Credits & license

<div align="center">

**Apache-2.0** · © 2026 **ChloeVPin** — the fx-companion accelerator

Built on [**fx**](https://github.com/vercel-labs/fx) by **Vercel Labs** · © Vercel Labs, Inc. · Apache-2.0

Unofficial project — not affiliated with or endorsed by Vercel. See [NOTICE](NOTICE).

</div>
