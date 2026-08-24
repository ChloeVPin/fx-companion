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

FAST_PATH = '''    try checkCanceled(stop_requested);

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

'''

WELCOME_OLD = r'''    return std.fmt.allocPrint(
        alloc,
        "{s}𝒇x{s}{s} {s} · Run /help for commands" ++ reset_style ++ "\n\n",
        .{ subtitle_style, reset_style, dim_style, build_label },
    );'''

WELCOME_NEW = r'''    var badge_buf: [512]u8 = undefined;
    return std.fmt.allocPrint(
        alloc,
        "{s}𝒇x{s}{s} {s}{s} · Run /help for commands" ++ reset_style ++ "\n\n",
        .{ subtitle_style, reset_style, dim_style, build_label, fx_companion.boostedBadge(&badge_buf) },
    );'''


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: inject_hook.py <fx-src-dir>", file=sys.stderr)
        return 1
    src = Path(sys.argv[1])
    ws = src / "src" / "core" / "workspace" / "workspace_files.zig"
    render = src / "src" / "ui" / "render.zig"
    if not ws.exists() or not render.exists():
        print("inject: missing expected fx source files", file=sys.stderr)
        return 1
    text = ws.read_text()
    changed = False

    # --- workspace_files.zig: fast walk ---
    if "fx_companion.zig" not in text:
        # drop the module in next to workspace_files.zig
        shutil.copyfile(MODULE_SRC, ws.parent / "fx_companion.zig")

        m = re.search(r'(const std = @import\("std"\);\n)', text)
        if not m:
            print("inject: anchor not found (std import)", file=sys.stderr)
            return 1
        text = text.replace(m.group(1), m.group(1) + '\n'
                            '// fx-companion: parallel getdirentries traversal (Apple Silicon). Purely\n'
                            '// additive: unsupported platforms and FX_NO_COMPANION=1 take the stock\n'
                            '// path below, byte-identical output either way.\n'
                            'const fx_companion = @import("fx_companion.zig");\n', 1)

        m = re.search(r'\nfn walkWorkspacePaths\(', text)
        if not m:
            print("inject: anchor not found (walkWorkspacePaths)", file=sys.stderr)
            return 1
        switch_var = ('\n/// Global kill switch for the fx-companion accelerated walk. Set by the\n'
                      '/// CLI surface from --no-companion / FX_NO_COMPANION so users can always\n'
                      '/// force stock behavior.\n'
                      'pub var companion_enabled: bool = true;\n')
        text = text[: m.start()] + switch_var + text[m.start():]

        anchor = '    try checkCanceled(stop_requested);\n    var paths: std.ArrayList([]const u8) = .empty;\n'
        if anchor not in text:
            print("inject: anchor not found (fast-path site)", file=sys.stderr)
            return 1
        text = text.replace(anchor, FAST_PATH + anchor[len('    try checkCanceled(stop_requested);\n'):], 1)
        ws.write_text(text)
        print("inject: hook applied to", ws)
        changed = True
    else:
        print("inject: walk hook already present")

    # --- ui/render.zig: BOOSTED badge in the welcome header ---
    rtext = render.read_text()
    if "boostedBadge" in rtext:
        print("inject: badge already present")
        return 0
    if WELCOME_OLD not in rtext:
        print("inject: anchor not found (welcomeMessage)", file=sys.stderr)
        return 1
    rtext = rtext.replace(WELCOME_OLD, WELCOME_NEW, 1)
    m = re.search(r'(const main = @import\("\.\./main\.zig"\);\n)', rtext)
    if not m:
        print("inject: anchor not found (render import)", file=sys.stderr)
        return 1
    rtext = rtext.replace(m.group(1),
                          m.group(1) + 'const fx_companion = @import("../core/workspace/fx_companion.zig");\n', 1)
    render.write_text(rtext)
    print("inject: badge applied to", render)
    _ = changed
    return 0


if __name__ == "__main__":
    sys.exit(main())
