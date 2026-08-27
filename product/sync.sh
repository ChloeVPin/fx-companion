#!/usr/bin/env bash
# Rebuild boosted fx from a pinned vercel-labs/fx commit.
# Does not replace the installed binary until inject + equivalence pass.
# If the required seam is gone, keep the last known-good binary.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FXC_HOME="${FX_COMPANION_HOME:-$HOME/.fx-companion}"
UPSTREAM="${FX_UPSTREAM_DIR:-$FXC_HOME/upstream}"
if [ -f "$HERE/../PINNED_FX" ]; then
  PIN_FILE="${FX_PIN_FILE:-$HERE/../PINNED_FX}"
else
  PIN_FILE="${FX_PIN_FILE:-$FXC_HOME/PINNED_FX}"
fi
TRY_LATEST="${1:-}"

command -v zig >/dev/null || { echo "sync: zig is required" >&2; exit 1; }
command -v git >/dev/null || { echo "sync: git is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "sync: python3 is required" >&2; exit 1; }

if [ ! -f "$PIN_FILE" ]; then
  echo "sync: missing PINNED_FX at $PIN_FILE" >&2
  exit 1
fi

PIN="$(tr -d '[:space:]' < "$PIN_FILE")"
mkdir -p "$FXC_HOME/bin"
cp "$HERE/fx_companion.zig" "$FXC_HOME/fx_companion.zig"
cp "$HERE/inject_hook.py" "$FXC_HOME/inject_hook.py"
cp "$HERE/fxc" "$FXC_HOME/fxc"
cp "$HERE/tests_fxcompanion.zig" "$FXC_HOME/tests_fxcompanion.zig"
cp "$HERE/benchmark_runner.zig" "$FXC_HOME/benchmark_runner.zig"
cp "$HERE/profile_run.zig" "$FXC_HOME/profile_run.zig"
cp "$PIN_FILE" "$FXC_HOME/PINNED_FX"
chmod +x "$FXC_HOME/fxc"

if [ ! -d "$UPSTREAM/.git" ]; then
  echo "sync: cloning vercel-labs/fx (read-only)"
  git clone https://github.com/vercel-labs/fx "$UPSTREAM"
fi

git -C "$UPSTREAM" fetch --tags --force origin
TARGET="$PIN"
if [ "$TRY_LATEST" = "--latest" ]; then
  git -C "$UPSTREAM" fetch origin main
  TARGET="$(git -C "$UPSTREAM" rev-parse origin/main)"
  echo "sync: probing latest origin/main $TARGET (pin is $PIN)"
fi

git -C "$UPSTREAM" checkout --force "$TARGET" >/dev/null
git -C "$UPSTREAM" reset --hard "$TARGET" >/dev/null
git -C "$UPSTREAM" clean -fdx >/dev/null

echo "sync: injecting booster into $TARGET"
if ! python3 "$HERE/inject_hook.py" "$UPSTREAM"; then
  echo "sync: required seam missing on $TARGET — keeping last known-good binary" >&2
  if [ -x "$FXC_HOME/bin/fx" ]; then
    echo "sync: still installed $FXC_HOME/bin/fx"
    exit 1
  fi
  echo "sync: no previous boosted binary to keep" >&2
  exit 1
fi

echo "sync: building fx (ReleaseFast)"
(cd "$UPSTREAM" && zig build -Doptimize=ReleaseFast)

NEW_BIN="$UPSTREAM/zig-out/bin/fx"
if [ ! -x "$NEW_BIN" ]; then
  echo "sync: build produced no fx binary" >&2
  exit 1
fi
if ! grep -q FX_NO_COMPANION "$NEW_BIN"; then
  echo "sync: booster marker missing; refusing to install" >&2
  exit 1
fi

echo "sync: equivalence self-test"
cp "$HERE/tests_fxcompanion.zig" "$UPSTREAM/src/tests_fxcompanion.zig"
TINY="$(mktemp -d /tmp/fxc-sync-tiny.XXXXXX)"
trap 'rm -rf -- "$TINY"; rm -f "$UPSTREAM/src/tests_fxcompanion.zig" /tmp/fxc_equiv_selftest' EXIT
mkdir -p "$TINY/src/deep" "$TINY/node_modules/pkg" "$TINY/.git"
touch "$TINY/a.txt" "$TINY/b.log" "$TINY/.dotfile" \
      "$TINY/src/main.zig" "$TINY/src/deep/x.zig" \
      "$TINY/node_modules/pkg/index.js"
ln -sf a.txt "$TINY/link_to_a"
ln -sfn src "$TINY/dirlink"
(cd "$UPSTREAM" && zig build-exe src/tests_fxcompanion.zig -lc -OReleaseFast -femit-bin=/tmp/fxc_equiv_selftest)
OUT="$(/tmp/fxc_equiv_selftest "$TINY" 2>&1 || true)"
if [ "$(echo "$OUT" | grep -c IDENTICAL)" -lt 2 ]; then
  echo "sync: SELF-TEST FAILED — keeping last known-good binary" >&2
  echo "$OUT" >&2
  exit 1
fi
echo "sync: self-test passed"

if [ -x "$FXC_HOME/bin/fx" ]; then
  cp "$FXC_HOME/bin/fx" "$FXC_HOME/bin/fx.prev"
fi
cp "$NEW_BIN" "$FXC_HOME/bin/fx"
chmod +x "$FXC_HOME/bin/fx"

if [ "$TRY_LATEST" = "--latest" ] && [ "$TARGET" != "$PIN" ]; then
  printf '%s\n' "$TARGET" > "$PIN_FILE"
  cp "$PIN_FILE" "$FXC_HOME/PINNED_FX"
  echo "sync: advanced PINNED_FX to $TARGET"
fi

echo "sync: installed $FXC_HOME/bin/fx"
echo "After stock \`fx upgrade\`, re-run this sync to reattach the booster."
echo "Stock anytime: FX_NO_COMPANION=1 fx ..."
