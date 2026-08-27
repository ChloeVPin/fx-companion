#!/usr/bin/env bash
# fx-companion installer: one command, then `fx` just works — stock output,
# boosted speed. Stock behavior anytime with FX_NO_COMPANION=1.
#
# Builds pinned vercel-labs/fx with the additive booster. Never reads or
# moves ~/.fx (sessions, chats, skills, settings).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FXC_HOME="${FX_COMPANION_HOME:-$HOME/.fx-companion}"

command -v zig >/dev/null || { echo "install: zig is required"; exit 1; }
command -v git >/dev/null || { echo "install: git is required"; exit 1; }

# Retire any previously installed stock fx (user data in ~/.fx untouched).
for old in "$HOME/.local/bin/fx" "/usr/local/bin/fx"; do
  if [ -f "$old" ] && [ ! -L "$old" ]; then
    mv "$old" "$old.stock.bak" && echo "install: retired previous $old (backup at $old.stock.bak)"
  fi
done

bash "$HERE/sync.sh"

echo
echo "Activate (one time):"
echo "  export PATH=\"$FXC_HOME/bin:\$PATH\"   # add to your shell profile"
echo
echo "After any \`fx upgrade\`, re-attach the booster:"
echo "  $FXC_HOME/fxc sync"
echo "Stock fx anytime: FX_NO_COMPANION=1 fx ..."
