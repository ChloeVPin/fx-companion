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
    if not ws.exists():
        print("inject: missing workspace_files.zig", file=sys.stderr)
        return 1
    problems = []
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
    if "badge_buf: [128]u8" in rtext and "boostedBadge" in rtext:
        # older injections used a 128-byte buffer; the badge outgrew it
        rtext = rtext.replace("var badge_buf: [128]u8 = undefined;",
                              "var badge_buf: [512]u8 = undefined;", 1)
        render.write_text(rtext)
        print("inject: upgraded badge buffer 128 -> 512")
    if "boostedBadge" in rtext:
        print("inject: badge already present")
    else:
        if WELCOME_OLD not in rtext:
            problems.append("badge: welcomeMessage anchor changed upstream")
        else:
            rtext = rtext.replace(WELCOME_OLD, WELCOME_NEW, 1)
            m = re.search(r'(const main = @import\("\.\./main\.zig"\);\n)', rtext)
            if not m:
                problems.append("badge: render import anchor changed")
            else:
                rtext = rtext.replace(m.group(1),
                                      m.group(1) + 'const fx_companion = @import("../core/workspace/fx_companion.zig");\n', 1)
                render.write_text(rtext)
                print("inject: badge applied to", render)

    # --- app_commands.zig: /benchmark slash command (ours, via unknown-cmd hook) ---
    appc = src / "src" / "core" / "app" / "app_commands.zig"
    if not appc.exists():
        problems.append("benchmark handler: app_commands.zig missing")
        atext = None
    atext = appc.read_text()
    if atext is None:
        pass
    elif "/benchmark" in atext:
        print("inject: benchmark handler already present")
        old_unknown = None
    else:
        old_unknown = '''        fn commandUnknown(ctx: *anyopaque, _: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            try app.writeDomainNotice(.{
                .topic = "command",
                .tone = .@"error",
                .body = "Unknown command. Try /help.",
            }, true);
        }'''
        new_unknown = '''        fn commandUnknown(ctx: *anyopaque, cmd_raw: []const u8) !void {
            const app: *App = @ptrCast(@alignCast(ctx));
            // fx-companion: /benchmark is ours — raw speed tests, no model call.
            if (std.mem.startsWith(u8, cmd_raw, "/benchmark")) {
                var body: std.ArrayListUnmanaged(u8) = .empty;
                fx_companion.runBenchmark(app.alloc, app.workspace_root, &body) catch |err| {
                    body.deinit(app.alloc);
                    try app.writeDomainNotice(.{
                        .topic = "benchmark",
                        .tone = .@"error",
                        .body = try std.fmt.allocPrint(app.alloc, "benchmark failed: {s}", .{@errorName(err)}),
                    }, true);
                    return;
                };
                try app.writeDomainNotice(.{ .topic = "benchmark", .tone = .neutral, .body = body.items }, true);
                return;
            }
            try app.writeDomainNotice(.{
                .topic = "command",
                .tone = .@"error",
                .body = "Unknown command. Try /help. (Tip: /benchmark runs fx-companion speed tests.)",
            }, true);
        }'''
    if old_unknown is not None:
        if old_unknown not in atext:
            print("inject: anchor not found (commandUnknown)", file=sys.stderr)
            return 1
        atext = atext.replace(old_unknown, new_unknown, 1)
        m3 = re.search(r'(const io_mod = @import\("[^"]*shared/io\.zig"\);\n)', atext)
    anchor_imp = None
    for pat in [r'(const command_router = @import\("[^"]*command_router\.zig"\);\n)', r'(const std = @import\("std"\);\n)']:
        m3 = re.search(pat, atext)
        if m3:
            anchor_imp = m3.group(1)
            break
    if "const fx_companion" not in atext:
        atext = atext.replace(anchor_imp, anchor_imp +
            'const fx_companion = @import("../workspace/fx_companion.zig");\n', 1)
    appc.write_text(atext)
    print("inject: /benchmark applied to", appc)

    # --- register /benchmark in the slash registry (drives autocomplete+help) ---
    specs = src / "src" / "builtins" / "commands.zig"
    stext = specs.read_text()
    if '"/benchmark"' in stext:
        print("inject: benchmark spec already present")
        return 0

    cs = src / "src" / "core" / "slash_commands" / "command_specs.zig"
    cstext = cs.read_text()
    if ".benchmark," not in cstext:
        k = re.search(r'(    version,\n\};)', cstext)
        if not k:
            print("inject: anchor not found (SlashKind)", file=sys.stderr)
            return 1
        cstext = cstext.replace(k.group(1), '    version,\n    benchmark,\n};', 1)
        router = src / "src" / "core" / "slash_commands" / "command_router.zig"
        rtext2 = router.read_text()
        pc = re.search(r'(        \.version => \.version,\n)', rtext2)
        if not pc:
            print("inject: anchor not found (parsedCommand switch)", file=sys.stderr)
            return 1
        rtext2 = rtext2.replace(pc.group(1),
            pc.group(1) + '        .benchmark => .unknown,\n', 1)
        cs.write_text(cstext)
        router.write_text(rtext2)
        print("inject: benchmark kind added")

    anchor_spec = '''    .{ .kind = .quit, .command = "/quit", .aliases = &.{"/exit"}, .help_entry = "/quit", .completion_description = "exit the interactive shell", .presentation_category = .general, .show_in_welcome = true },'''
    new_spec = '''    .{ .kind = .benchmark, .command = "/benchmark", .help_entry = "/benchmark", .completion_description = "fx-companion: run raw speed tests", .presentation_category = .general },'''
    if anchor_spec not in stext:
        print("inject: anchor not found (slash_specs)", file=sys.stderr)
        return 1
    stext = stext.replace(anchor_spec, anchor_spec + "\n" + new_spec, 1)
    specs.write_text(stext)
    print("inject: /benchmark registered for completion")
    _ = changed
    return 0


if __name__ == "__main__":
    sys.exit(main())
