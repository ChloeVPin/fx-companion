#!/usr/bin/env bash
# fx-companion installer: one command, then `fx` just works — stock output,
# boosted speed. Stock behavior anytime with FX_NO_COMPANION=1.
#
#   1. installs the booster payload into ~/.fx-companion (self-contained;
#      `fx upgrade` never touches it)
#   2. clones (or reuses) the vercel fx source, injects the hook, builds
#      ReleaseFast, runs an equivalence self-test, installs to ~/.fx-companion/bin
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FXC_HOME="${FX_COMPANION_HOME:-$HOME/.fx-companion}"
UPSTREAM="$FXC_HOME/upstream"

command -v zig >/dev/null || { echo "install: zig is required"; exit 1; }
command -v git >/dev/null || { echo "install: git is required"; exit 1; }

echo "install: booster payload -> $FXC_HOME"
mkdir -p "$FXC_HOME/bin"
cp "$HERE/fx_companion.zig"   "$FXC_HOME/fx_companion.zig"
cp "$HERE/inject_hook.py"     "$FXC_HOME/inject_hook.py"
cp "$HERE/fxc"                "$FXC_HOME/fxc"
cp "$HERE/tests_fxcompanion.zig" "$FXC_HOME/tests_fxcompanion.zig"
chmod +x "$FXC_HOME/fxc"

if [ ! -f "$UPSTREAM/build.zig" ]; then
  echo "install: cloning vercel-labs/fx"
  git clone --depth 1 https://github.com/vercel-labs/fx "$UPSTREAM"
fi

# Retire any previously installed stock fx (user data in ~/.fx untouched).
for old in "$HOME/.local/bin/fx" "$HOME/.fx-companion/bin/fx" "/usr/local/bin/fx"; do
  if [ -f "$old" ]; then
    mv "$old" "$old.stock.bak" && echo "install: retired previous $old (backup at $old.stock.bak)"
  fi
done

python3 "$HERE/inject_hook.py" "$UPSTREAM"

echo "install: building fx (ReleaseFast) — a few minutes"
(cd "$UPSTREAM" && zig build -Doptimize=ReleaseFast)

echo "install: equivalence self-test (tiny known tree, files+dirs)"
cp "$FXC_HOME/tests_fxcompanion.zig" "$UPSTREAM/src/tests_fxcompanion.zig"
rm -rf /tmp/fxtiny_install
mkdir -p /tmp/fxtiny_install/src/deep /tmp/fxtiny_install/node_modules/pkg /tmp/fxtiny_install/.git
touch /tmp/fxtiny_install/a.txt /tmp/fxtiny_install/b.log /tmp/fxtiny_install/.dotfile \
      /tmp/fxtiny_install/src/main.zig /tmp/fxtiny_install/src/deep/x.zig \
      /tmp/fxtiny_install/node_modules/pkg/index.js
ln -sf a.txt /tmp/fxtiny_install/link_to_a
ln -sfn src /tmp/fxtiny_install/dirlink
(cd "$UPSTREAM" && zig build-exe src/tests_fxcompanion.zig -lc -OReleaseFast -femit-bin=/tmp/fxc_equiv_selftest)
OUT="$(/tmp/fxc_equiv_selftest /tmp/fxtiny_install 2>&1 || true)"
rm -f "$UPSTREAM/src/tests_fxcompanion.zig" /tmp/fxc_equiv_selftest
if [ "$(echo "$OUT" | grep -c IDENTICAL)" -ne 2 ]; then
  echo "install: SELF-TEST FAILED — not installing boosted binary" >&2
  echo "$OUT" >&2
  exit 1
fi
echo "install: self-test passed"

cp "$UPSTREAM/zig-out/bin/fx" "$FXC_HOME/bin/fx"

echo "install: done."
echo
echo "Activate (one time):"
echo "  export PATH=\"$FXC_HOME/bin:\$PATH\"   # add to your shell profile"
echo
echo "After any \`fx upgrade\`, re-attach the booster:"
echo "  $FXC_HOME/fxc sync"
echo "Stock fx anytime: FX_NO_COMPANION=1 fx ..."
