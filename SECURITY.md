# Security Policy

## Supported versions

Security fixes are provided for the latest published fx-companion release. Older releases may be asked to upgrade before a fix is evaluated.

## Reporting a vulnerability

Do not include exploit details, secrets, private repository data, or other sensitive information in a public issue.

Use GitHub's private vulnerability reporting flow when it is available for this repository:

https://github.com/ChloeVPin/fx-companion/security/advisories/new

If that private form is unavailable, open a public issue with only a short request for a private security contact. Do not include vulnerability details in that issue.

Useful reports include the affected fx-companion version, macOS version, Apple Silicon model, installation method, whether the issue reproduces with `FX_NO_COMPANION=1`, and the smallest safe reproduction you can provide.

## Security model

fx-companion installs its managed binary and support files under `~/.fx-companion`. It must not move or overwrite unrelated `fx` executables. Release installation verifies the matching release archive against `SHA256SUMS`, validates archive shape, and checks the fx-companion marker before publishing the binary locally.

Release CI builds against the explicit `PINNED_FX` commit, verifies the Zig toolchain archive checksum, runs stock-vs-injected differential gates, generates build provenance, and creates a GitHub artifact attestation for the release tarball.
