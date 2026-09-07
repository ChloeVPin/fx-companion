# Launch copy

Use these snippets as factual starting points. Keep the benchmark boundary clear:
fx-companion dramatically accelerates workspace discovery, but it does not claim
the same multiplier for total interactive app startup.

## One line

Make fx dramatically faster on Apple Silicon. Same fx. Same results. No fork.

## Short description

fx-companion builds the real upstream Vercel Labs fx with a small Apple Silicon
workspace-discovery accelerator. Warm discovery measured 73.145x faster on a
51,200-file synthetic tree and 36.742x faster on a 161,771-path Homebrew tree on
Apple M2, with byte-identical stock results. If exactness cannot be proven, it
uses the stock path.

## Hacker News

Title:

```text
Show HN: fx-companion - faster workspace discovery for fx on Apple Silicon
```

Body:

```text
I wanted to speed up Vercel Labs fx without maintaining a behavior fork.

fx-companion builds the pinned upstream source and only accelerates workspace
discovery paths where it can prove stock-equivalent results. Tracked Git
workspaces cache raw git ls-files output before handing the exact bytes back to
upstream parsing. Sorted recursive discovery can reuse a validated filesystem
snapshot. Anything ambiguous falls back to stock.

On an Apple M2, a 51,200-file production discovery fixture measured 42.513 ms
stock, 19.059 ms cold, and 0.581 ms warm. A real /opt/homebrew tree with 161,771
paths measured 519.514 ms stock and 14.139 ms warm. The result metadata and
ordered path bytes matched stock in both cases.

There is a separate full-app startup benchmark in the repo because I do not want
to present the discovery multiplier as an end-to-end launch multiplier.

Install on Apple Silicon macOS:
npx github:ChloeVPin/fx-companion#v0.4.1

Stock mode is always:
FX_NO_COMPANION=1 fx
```

## Reddit or Discord

```text
I built fx-companion to make Vercel Labs fx faster on Apple Silicon without
forking its behavior. It builds the real pinned upstream source, accelerates only
workspace discovery, and falls back to stock when exactness cannot be proven.

Apple M2 production discovery results:
51,200 files: 42.513 ms stock, 0.581 ms warm, 73.145x
/opt/homebrew: 519.514 ms stock, 14.139 ms warm, 36.742x

Every compared result was byte-identical to stock. The repo also includes a real
terminal recording, machine-readable benchmark data, and a separate full-app
startup measurement so the performance claim stays scoped to the work actually
being accelerated.
```

## X

```text
fx-companion makes Vercel Labs fx workspace discovery faster on Apple Silicon.

Same upstream fx. Byte-identical results. Fail closed to stock.

Apple M2: 42.513 ms stock -> 0.581 ms warm on 51,200 files.

npx github:ChloeVPin/fx-companion#v0.4.1
```

## Technical explanation

fx-companion does not replace the fx command model or copy upstream application
policy. The injected surface is limited to low-level workspace discovery seams.
For normal tracked Git workspaces it snapshots raw `git ls-files` stdout against
repository identity, then sends those exact bytes through upstream parsing and
acceptance. For sorted recursive discovery it can reuse a persisted snapshot only
after validating the directory state captured by the accelerated traversal.

Persistent cache entries are versioned, checksum protected, tied to the pinned
upstream workspace-discovery source fingerprint, published atomically, and
pruned. Capped or source-order-sensitive cases, untracked Git modes, Git
environment overrides, cancellation-sensitive cases, unsupported layouts, and
anything else that cannot prove equivalence remain on stock behavior.

The release pipeline compiles the same workspace fingerprint probe against
pristine pinned upstream and the injected tree, compares Git and recursive cold
and warm results, runs adversarial mutation and cache-race tests, verifies the
release checksum, and publishes build provenance plus machine-readable benchmark
evidence.

## Assets

- Logo: [`../media/fxc.svg`](../media/fxc.svg)
- Terminal demo: [`../media/demo.gif`](../media/demo.gif)
- Raw terminal recording: [`../media/demo.cast`](../media/demo.cast)
- Benchmark card: [`../media/benchmark.png`](../media/benchmark.png)
- Social preview: [`../media/social-preview.png`](../media/social-preview.png)
- Machine-readable results: [`../benchmarks/results/latest.json`](../benchmarks/results/latest.json)
