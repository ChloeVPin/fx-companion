#!/usr/bin/env bash
# One-command installer for fx-companion:
#
#   curl -fsSL https://raw.githubusercontent.com/ChloeVPin/fx-companion/v0.4.1/bootstrap.sh | sh
#
# Fetches the fx-companion payload and hands off to the real installer.
set -euo pipefail

REPO="ChloeVPin/fx-companion"
VERSION="0.4.1"
REF="v$VERSION"
BASE="https://raw.githubusercontent.com/$REPO/$REF/product"
ROOT_BASE="https://raw.githubusercontent.com/$REPO/$REF"
USER_AGENT="fx-companion-bootstrap/$VERSION"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v curl >/dev/null || { echo "bootstrap: curl is required"; exit 1; }
command -v zig >/dev/null || {
  echo "bootstrap: zig is required - install it first:  brew install zig"
  exit 1
}

for f in fx_companion.zig inject_hook.py fxc tests_fxcompanion.zig install.sh sync.sh; do
  echo "bootstrap: fetching $f"
  curl -fsSL -A "$USER_AGENT" "$BASE/$f" -o "$TMP/$f"
done
echo "bootstrap: fetching PINNED_FX"
curl -fsSL -A "$USER_AGENT" "$ROOT_BASE/PINNED_FX" -o "$TMP/PINNED_FX"
chmod +x "$TMP/fxc"

export FX_PIN_FILE="$TMP/PINNED_FX"
exec bash "$TMP/install.sh"
