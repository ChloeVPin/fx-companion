#!/usr/bin/env python3
"""Inject the fx-companion accelerator hook into a vercel fx source tree.

Idempotent: exits 0 without changes if the hook is already present.
Exits 1 if the expected anchor points are missing (upstream changed).
"""
import re
import shutil
import sys
from pathlib import Path

MODULE_SRC = Path(__file__).parent / "fx_companion.zig"


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: inject_hook.py <fx-src-dir>", file=sys.stderr)
        return 1
    src = Path(sys.argv[1])
    ws = src / "src" / "core" / "workspace" / "workspace_files.zig"
    if not ws.exists():
        print(f"inject: missing {ws}", file=sys.stderr)
        return 1
    text = ws.read_text()
    if "fx_companion.zig" in text:
        print("inject: hook already present")
        return 0

    # 1) drop the module in next to workspace_files.zig
    dst = ws.parent / "fx_companion.zig"
    shutil.copyfile(MODULE_SRC, dst)

    # 2) import + global kill switch after the first import block
    m = re.search(r'(const std = @import\("std"\);\n)', text)
    if not m:
        print("inject: anchor not found (std import)", file=sys.stderr)
        return 1
    text = text.replace(
        m.group(1),
        m.group(1)
        + '\n// fx-companion: parallel getdirentries traversal (Apple Silicon). Purely\n'
          '// additive: unsupported platforms and FX_NO_COMPANION=1 take the stock\n'
          '// path below, byte-identical output either way.\n'
          'const fx_companion = @import("fx_companion.zig");\n',
        1,
    )

    # 3) kill switch var right before walkWorkspacePaths
    m = re.search(r'\nfn walkWorkspacePaths\(', text)
    if not m:
        print("inject: anchor not found (walkWorkspacePaths)", file=sys.stderr)
        return 1
    switch_var = (
        "\n/// Global kill switch for the fx-companion accelerated walk. Set by the\n"
        "/// CLI surface from --no-companion / FX_NO_COMPANION so users can always\n"
        "/// force stock behavior.\n"
        "pub var companion_enabled: bool = true;\n"
    )
    text = text[: m.start()] + switch_var + text[m.start():]

    # 4) fast path at the top of walkWorkspacePaths, right after the cancel
    #    check that opens the function body (unique: followed by paths decl)
    anchor = '''    try checkCanceled(stop_requested);
    var paths: std.ArrayList([]const u8) = .empty;
'''
    fast_path = '''    try checkCanceled(stop_requested);

    // fx-companion fast path (macOS/arm64 only; silently skipped elsewhere).
    // Produces exactly the same relative path list as the stock walk below.
    if (companion_enabled) {
        var paths_fast: std.ArrayList([]const u8) = .empty;
        var skipped_overlong_c: usize = 0;
        if (fx_companion.walkPaths(
            arena,
            workspace_root,
            options.ignored_names,
            ignored_paths,
            target == .files,
            options.include_hidden,
            options.candidate_cap,
            max_relative_path_bytes,
            stop_requested,
            &paths_fast,
            &skipped_overlong_c,
        )) |incomplete_c| {
            return .{
                .paths = try paths_fast.toOwnedSlice(arena),
                .incomplete = incomplete_c,
                .skipped_overlong = skipped_overlong_c,
            };
        } else |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                paths_fast.deinit(arena);
                debug_trace.logf("core", "fx-companion unavailable ({s}); using stock walk", .{@errorName(err)});
            },
        }
    }

    var paths: std.ArrayList([]const u8) = .empty;
'''
    if anchor not in text:
        print("inject: anchor not found (fast-path site)", file=sys.stderr)
        return 1
    text = text.replace(anchor, fast_path, 1)

    ws.write_text(text)
    print("inject: hook applied to", ws)
    return 0


if __name__ == "__main__":
    sys.exit(main())
