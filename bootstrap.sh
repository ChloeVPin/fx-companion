#!/usr/bin/env bash
# One-command installer for fx-companion:
#
#   curl -fsSL https://raw.githubusercontent.com/ChloeVPin/fx-companion/main/bootstrap.sh | sh
#
# Fetches the booster payload and hands off to the real installer.
set -euo pipefail

REPO="ChloeVPin/fx-companion"
BRANCH="main"
BASE="https://raw.githubusercontent.com/$REPO/$BRANCH/product"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v curl >/dev/null || { echo "bootstrap: curl is required"; exit 1; }
command -v zig >/dev/null || {
  echo "bootstrap: zig is required — install it first:  brew install zig"
  exit 1
}

for f in fx_companion.zig inject_hook.py fxc tests_fxcompanion.zig install.sh sync.sh benchmark_runner.zig profile_run.zig; do
  echo "bootstrap: fetching $f"
  curl -fsSL "$BASE/$f" -o "$TMP/$f"
done
chmod +x "$TMP/fxc"

exec bash "$TMP/install.sh"
