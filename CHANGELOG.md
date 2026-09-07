# Changelog

Notable user-facing changes to fx-companion are tracked here.

## 0.4.1

- Project maturity and contribution infrastructure improvements.
- Structured issue forms for bugs, performance reports, upstream compatibility, and feature requests.
- Richer package metadata for platform support, discovery, validation, and provenance-aware publishing.
- Rebuilt the README around install, proof, a real terminal benchmark capture, and current production measurements.
- Added a minimal Geist-based `fxc` mark, benchmark card, and social preview asset.
- Added machine-readable benchmark evidence plus a real full-app file-index-ready benchmark so discovery speedups are not confused with total startup speedups.
- Added a dedicated CI benchmark workflow and user-facing release notes.

## 0.4.0

- Hardened installer behavior so unrelated `fx` executables are never moved or replaced.
- Bound prebuilt installation to the release matching the package version and strengthened checksum and archive validation.
- Made source fallback use the immutable source bundle shipped with the package instead of executable source from a mutable branch.
- Added atomic publication of the managed binary and full manager bundle.
- Added pristine pinned-upstream vs injected differential CI for Git and recursive discovery, including warm-cache validation.
- Added release provenance and GitHub build attestation while preserving fail-closed equivalence gates.
