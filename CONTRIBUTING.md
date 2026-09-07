# Contributing to fx-companion

Thanks for helping make fx-companion faster, safer, and easier to trust.

## Before opening a pull request

fx-companion has one non-negotiable rule: accelerated behavior must match stock `fx` behavior. Performance wins are not accepted when output, ordering, metadata, fallback behavior, cancellation, or user data semantics change.

Before changing production behavior:

1. Read `README.md` and `PINNED_FX`.
2. Keep the patch surface against upstream `fx` as small as practical.
3. Preserve `FX_NO_COMPANION=1` as a stock escape hatch.
4. Fail closed when exact equivalence cannot be proven.
5. Add or update a differential test for every semantic change.

## Development setup

The supported product target is macOS on Apple Silicon. Development requires Zig 0.16+, Git, Python 3, and Node.js 18+.

Run the local checks that apply to your change:

```sh
npm run check
npm test
zig build test
```

Pull requests and `main` builds also compile discovery probes against pristine pinned upstream `fx` and the injected tree, then require identical fingerprints for Git and recursive discovery, including warm-cache reruns.

## Performance changes

For performance work, include:

- Apple chip and core count
- macOS and Zig versions
- workspace type and approximate file count
- candidate cap and discovery mode
- cold and warm measurements
- correctness output from the same run
- any thermal, power, or background-load caveats that materially affect the result

Prefer medians over single-run best cases. Do not hide regressions or exclude losing samples without explaining why.

## Upstream compatibility changes

`PINNED_FX` is intentional. If upstream changes an injection seam, open an upstream compatibility issue or pull request that shows:

- the current pin
- the upstream commit being tested
- injector output
- the failing or changed seam
- the differential result

Do not advance the pin merely because upstream is newer. Advance it only after the compatibility and equivalence gates pass.

## Pull request scope

Keep pull requests focused. Separate product behavior, benchmark tooling, documentation, and distribution changes when doing so makes review easier.

By contributing, you agree that your contribution is provided under the Apache-2.0 license used by this repository.
