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
GIT_HTTP_USER_AGENT="OpenAI File Downloader, XaiImageApiFetch/1.0"

command -v zig >/dev/null || { echo "sync: zig is required" >&2; exit 1; }
command -v git >/dev/null || { echo "sync: git is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "sync: python3 is required" >&2; exit 1; }

FXC_HOME_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$FXC_HOME")"
UPSTREAM_REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$UPSTREAM")"
case "$UPSTREAM_REAL" in
  "$FXC_HOME_REAL"/*) ;;
  *)
    echo "sync: refusing destructive checkout outside FX_COMPANION_HOME: $UPSTREAM" >&2
    exit 1
    ;;
esac

if [ ! -f "$PIN_FILE" ]; then
  echo "sync: missing PINNED_FX at $PIN_FILE" >&2
  exit 1
fi

PIN="$(tr -d '[:space:]' < "$PIN_FILE")"
if ! printf '%s' "$PIN" | grep -Eq '^[0-9a-fA-F]{40}$'; then
  echo "sync: PINNED_FX must contain one exact 40-hex commit" >&2
  exit 1
fi
mkdir -p "$FXC_HOME/bin"

atomic_copy() {
  local src="$1" dest="$2" mode="${3:-}"
  local tmp="${dest}.tmp.$$"
  rm -f -- "$tmp"
  cp -- "$src" "$tmp"
  if [ -n "$mode" ]; then chmod "$mode" "$tmp"; fi
  mv -f -- "$tmp" "$dest"
}

SYNC_LOCK="$FXC_HOME/.sync.lock"
if ! mkdir "$SYNC_LOCK" 2>/dev/null; then
  LOCK_PID="$(cat "$SYNC_LOCK/pid" 2>/dev/null || true)"
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    echo "sync: another fx-companion sync is already running (pid $LOCK_PID)" >&2
    exit 1
  fi
  rm -rf -- "$SYNC_LOCK"
  mkdir "$SYNC_LOCK" || { echo "sync: could not acquire sync lock" >&2; exit 1; }
fi
printf '%s\n' "$$" > "$SYNC_LOCK/pid"

cleanup() {
  if [ -n "${TINY:-}" ]; then rm -rf -- "$TINY"; fi
  rm -f "$UPSTREAM/src/tests_fxcompanion.zig" /tmp/fxc_equiv_selftest \
    "${NEW_STAGE:-}" "${PREV_STAGE:-}" "${PIN_STAGE:-}"
  rm -rf -- "$SYNC_LOCK"
}
trap cleanup EXIT

if [ ! -d "$UPSTREAM/.git" ]; then
  echo "sync: cloning vercel-labs/fx (read-only)"
  git -c http.userAgent="$GIT_HTTP_USER_AGENT" clone https://github.com/vercel-labs/fx "$UPSTREAM"
else
  ORIGIN_URL="$(git -C "$UPSTREAM" remote get-url origin 2>/dev/null || true)"
  case "$ORIGIN_URL" in
    https://github.com/vercel-labs/fx|https://github.com/vercel-labs/fx.git) ;;
    *)
      echo "sync: refusing unexpected upstream origin: ${ORIGIN_URL:-missing}" >&2
      exit 1
      ;;
  esac
fi

git -c http.userAgent="$GIT_HTTP_USER_AGENT" -C "$UPSTREAM" fetch --tags --force origin
TARGET="$PIN"
if [ "$TRY_LATEST" = "--latest" ]; then
  git -c http.userAgent="$GIT_HTTP_USER_AGENT" -C "$UPSTREAM" fetch origin main
  TARGET="$(git -C "$UPSTREAM" rev-parse origin/main)"
  echo "sync: probing latest origin/main $TARGET (pin is $PIN)"
fi
if ! git -C "$UPSTREAM" cat-file -e "$TARGET^{commit}" 2>/dev/null; then
  echo "sync: target is not an available upstream commit: $TARGET" >&2
  exit 1
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

# Publish the complete manager bundle before replacing the live binary. Each
# file is staged beside its destination and renamed into place, so an
# interrupted copy cannot leave a truncated manager script/source file.
echo "sync: publishing manager bundle"
atomic_copy "$HERE/fx_companion.zig" "$FXC_HOME/fx_companion.zig"
atomic_copy "$HERE/inject_hook.py" "$FXC_HOME/inject_hook.py"
atomic_copy "$HERE/tests_fxcompanion.zig" "$FXC_HOME/tests_fxcompanion.zig"
atomic_copy "$HERE/install.sh" "$FXC_HOME/install.sh" 755
atomic_copy "$HERE/sync.sh" "$FXC_HOME/sync.sh" 755
atomic_copy "$HERE/fxc" "$FXC_HOME/fxc" 755
if [ "$PIN_FILE" != "$FXC_HOME/PINNED_FX" ]; then
  atomic_copy "$PIN_FILE" "$FXC_HOME/PINNED_FX"
fi

# Publish the executable with a same-directory atomic rename. Preserve the
# previous known-good binary first, but never move or modify any fx executable
# outside FXC_HOME.
NEW_STAGE="$(mktemp "$FXC_HOME/bin/.fx.new.XXXXXX")"
cp -- "$NEW_BIN" "$NEW_STAGE"
chmod 755 "$NEW_STAGE"
if [ -x "$FXC_HOME/bin/fx" ]; then
  PREV_STAGE="$(mktemp "$FXC_HOME/bin/.fx.prev.XXXXXX")"
  cp -- "$FXC_HOME/bin/fx" "$PREV_STAGE"
  chmod 755 "$PREV_STAGE"
  mv -f -- "$PREV_STAGE" "$FXC_HOME/bin/fx.prev"
  PREV_STAGE=""
fi
mv -f -- "$NEW_STAGE" "$FXC_HOME/bin/fx"
NEW_STAGE=""

if [ "$TRY_LATEST" = "--latest" ] && [ "$TARGET" != "$PIN" ]; then
  PIN_STAGE="${PIN_FILE}.tmp.$$"
  printf '%s\n' "$TARGET" > "$PIN_STAGE"
  mv -f -- "$PIN_STAGE" "$PIN_FILE"
  PIN_STAGE=""
  if [ "$PIN_FILE" != "$FXC_HOME/PINNED_FX" ]; then
    atomic_copy "$PIN_FILE" "$FXC_HOME/PINNED_FX"
  fi
  echo "sync: advanced PINNED_FX to $TARGET"
fi

echo "sync: installed $FXC_HOME/bin/fx"
echo "After stock \`fx upgrade\`, re-run this sync to reattach the booster."
echo "Stock anytime: FX_NO_COMPANION=1 fx ..."
