#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  echo "usage: benchmarks/run_discover_bench.sh TREE [ROUNDS=7] [CAP=600000]" >&2
  exit 2
fi

tree=$1
rounds=${2:-7}
cap=${3:-600000}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
upstream_repo=${FX_UPSTREAM_REPO:-"$HOME/Developer/fx-upstream"}
pin=$(tr -d '[:space:]' < "$repo_root/PINNED_FX")

if [ ! -d "$tree" ]; then
  echo "benchmark tree does not exist: $tree" >&2
  exit 2
fi
if ! git -C "$upstream_repo" cat-file -e "$pin^{commit}" 2>/dev/null; then
  echo "pinned fx commit $pin is unavailable in $upstream_repo" >&2
  echo "set FX_UPSTREAM_REPO to a read-only clone containing PINNED_FX" >&2
  exit 2
fi

bench_tmp=$(mktemp -d /tmp/fxc-discover-bench.XXXXXX)
cleanup() {
  case "$bench_tmp" in
    /tmp/fxc-discover-bench.*|/private/tmp/fxc-discover-bench.*)
      rm -rf -- "$bench_tmp"
      ;;
  esac
}
trap cleanup EXIT HUP INT TERM

git -C "$upstream_repo" archive "$pin" | tar -x -C "$bench_tmp"
python3 "$repo_root/product/inject_hook.py" "$bench_tmp"
cp "$script_dir/discover_bench.zig" "$bench_tmp/src/fx_companion_discover_bench.zig"

(
  cd "$bench_tmp"
  zig build-exe src/fx_companion_discover_bench.zig \
    -lc -OReleaseFast -femit-bin="$bench_tmp/discover-bench"
)

echo "pin=$pin"
echo "platform=$(uname -srm)"
echo "zig=$(zig version)"
"$bench_tmp/discover-bench" "$tree" "$rounds" "$cap"
