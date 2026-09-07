#!/usr/bin/env bash
# fx-companion installer: one command, then `fx` just works with stock output
# and accelerated discovery. Stock behavior anytime with FX_NO_COMPANION=1.
#
# Builds pinned vercel-labs/fx with the additive accelerator. Never reads or
# moves ~/.fx (sessions, chats, skills, settings).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FXC_HOME="${FX_COMPANION_HOME:-$HOME/.fx-companion}"

command -v zig >/dev/null || { echo "install: zig is required"; exit 1; }
command -v git >/dev/null || { echo "install: git is required"; exit 1; }

bash "$HERE/sync.sh"

echo
echo "Activate (one time):"
echo "  export PATH=\"$FXC_HOME/bin:\$PATH\"   # add to your shell profile"
echo "Existing fx executables are never moved or replaced by this installer."
echo
echo "After any \`fx upgrade\`, re-attach fx-companion:"
echo "  $FXC_HOME/fxc sync"
echo "Stock fx anytime: FX_NO_COMPANION=1 fx ..."
