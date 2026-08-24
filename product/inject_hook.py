#!/usr/bin/env python3
"""Inject the fx-companion accelerator hook into a vercel fx source tree.

Idempotent: exits 0 without changes if the hook is already present.
Core-walk anchor failures exit 1; optional UI/benchmark hooks warn and skip.
"""
import re
import shutil
import sys
from pathlib import Path

MODULE_SRC = Path(__file__).parent / "fx_companion.zig"

FAST_PATH = '''    try checkCanceled(stop_requested);

    var companion_stock_snapshot: ?*fx_companion.StockSnapshot = null;
    defer {
        if (companion_stock_snapshot) |snapshot| fx_companion.discardStockSnapshot(snapshot);
    }

    // fx-companion fast path (macOS/arm64 only; silently skipped elsewhere).
    // Produces exactly the same relative path list as the stock walk below.
    // The stock walker exposes source order when sort_paths is false. A
    // parallel traversal cannot preserve that order, so accelerate only the
    // sorted contract. If the cap truncates a walk, retry stock as well: the
    // exact first N source-order entries are part of fx's observable result.
    if (companion_enabled and options.sort_paths and options.candidate_cap > 0) {
        var paths_fast: std.ArrayList([]const u8) = .empty;
        var skipped_overlong_c: usize = 0;
        var exact_c = false;
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
            &exact_c,
            true,
        )) |incomplete_c| {
            if (exact_c) {
                return .{
                    .paths = try paths_fast.toOwnedSlice(arena),
                    .incomplete = incomplete_c,
                    .skipped_overlong = skipped_overlong_c,
                };
            }
            paths_fast.deinit(arena);
            debug_trace.logf("core", "fx-companion cap reached; using stock walk for exact source-order truncation", .{});
            companion_stock_snapshot = fx_companion.beginStockSnapshot(
                workspace_root,
                options.ignored_names,
                ignored_paths,
                target == .files,
                options.include_hidden,
                options.candidate_cap,
                max_relative_path_bytes,
                stop_requested,
            ) catch null;
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

STOCK_CACHE_ANCHOR = '''    if (options.sort_paths) sortPathList(paths.items);

    return .{'''

STOCK_CACHE_HOOK = '''    if (options.sort_paths) sortPathList(paths.items);

    if (companion_stock_snapshot) |snapshot| {
        if (incomplete) {
            fx_companion.finishStockSnapshot(
                snapshot,
                workspace_root,
                paths.items,
                skipped_overlong,
            );
        }
        fx_companion.discardStockSnapshot(snapshot);
        companion_stock_snapshot = null;
    }

    return .{'''

STOCK_CACHE_HOOK_V1 = '''    if (options.sort_paths) sortPathList(paths.items);

    if (companion_stock_snapshot) |snapshot| {
        fx_companion.finishStockSnapshot(
            snapshot,
            workspace_root,
            paths.items,
            skipped_overlong,
        );
        fx_companion.discardStockSnapshot(snapshot);
        companion_stock_snapshot = null;
    }

    return .{'''


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
        # Keep repeated injections useful: refresh the additive module and
        # migrate the original order-unsafe fast path in place.
        module_dst = ws.parent / "fx_companion.zig"
        if not module_dst.exists() or module_dst.read_bytes() != MODULE_SRC.read_bytes():
            shutil.copyfile(MODULE_SRC, module_dst)
            print("inject: accelerator module refreshed")

        hook_start = -1
        for hook_marker in [
            "    try checkCanceled(stop_requested);\n\n    var companion_stock_snapshot:",
            "    try checkCanceled(stop_requested);\n\n    // fx-companion fast path",
        ]:
            hook_start = text.find(hook_marker)
            if hook_start >= 0:
                break
        stock_start = text.find(
            "    var paths: std.ArrayList([]const u8) = .empty;\n",
            hook_start + 1,
        )
        if hook_start >= 0 and stock_start >= 0:
            installed_hook = text[hook_start:stock_start]
            if ("options.sort_paths" not in installed_hook or
                    "beginStockSnapshot" not in installed_hook or
                    "options.candidate_cap > 0" not in installed_hook):
                text = text[:hook_start] + FAST_PATH + text[stock_start:]
                ws.write_text(text)
                print("inject: walk hook upgraded for exact ordering and cap fallback")
                changed = True

    text = ws.read_text()
    if STOCK_CACHE_HOOK_V1 in text:
        text = text.replace(STOCK_CACHE_HOOK_V1, STOCK_CACHE_HOOK, 1)
        ws.write_text(text)
        print("inject: exact capped-result cache upgraded")
        changed = True
    elif "finishStockSnapshot" not in text:
        if STOCK_CACHE_ANCHOR not in text:
            print("inject: anchor not found (stock snapshot cache)", file=sys.stderr)
            return 1
        text = text.replace(STOCK_CACHE_ANCHOR, STOCK_CACHE_HOOK, 1)
        ws.write_text(text)
        print("inject: exact capped-result cache applied")
        changed = True

    # --- ui/render.zig: BOOSTED badge in the welcome header ---
    if not render.exists():
        problems.append("badge: render.zig missing")
    else:
        rtext = render.read_text()
        if "badge_buf: [128]u8" in rtext and "boostedBadge" in rtext:
            rtext = rtext.replace("var badge_buf: [128]u8 = undefined;",
                                  "var badge_buf: [512]u8 = undefined;", 1)
            render.write_text(rtext)
            print("inject: upgraded badge buffer 128 -> 512")
        if "boostedBadge" in rtext:
            print("inject: badge already present")
        elif WELCOME_OLD not in rtext:
            problems.append("badge: welcomeMessage anchor changed upstream")
        else:
            candidate = rtext.replace(WELCOME_OLD, WELCOME_NEW, 1)
            m = re.search(r'(const main = @import\("\.\./main\.zig"\);\n)', candidate)
            if not m:
                problems.append("badge: render import anchor changed")
            else:
                candidate = candidate.replace(
                    m.group(1),
                    m.group(1) + 'const fx_companion = @import("../core/workspace/fx_companion.zig");\n',
                    1,
                )
                render.write_text(candidate)
                print("inject: badge applied to", render)

    # --- app_commands.zig: /benchmark slash command (ours, via unknown-cmd hook) ---
    appc = src / "src" / "core" / "app" / "app_commands.zig"
    if not appc.exists():
        problems.append("benchmark handler: app_commands.zig missing")
    else:
        atext = appc.read_text()
        if "/benchmark" in atext:
            print("inject: benchmark handler already present")
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
            if old_unknown not in atext:
                problems.append("benchmark handler: commandUnknown anchor changed")
            else:
                candidate = atext.replace(old_unknown, new_unknown, 1)
                anchor_imp = None
                for pat in [
                    r'(const command_router = @import\("[^"]*command_router\.zig"\);\n)',
                    r'(const std = @import\("std"\);\n)',
                ]:
                    match = re.search(pat, candidate)
                    if match:
                        anchor_imp = match.group(1)
                        break
                if anchor_imp is None:
                    problems.append("benchmark handler: import anchor changed")
                else:
                    if "const fx_companion" not in candidate:
                        candidate = candidate.replace(
                            anchor_imp,
                            anchor_imp + 'const fx_companion = @import("../workspace/fx_companion.zig");\n',
                            1,
                        )
                    appc.write_text(candidate)
                    print("inject: /benchmark applied to", appc)

    # --- register /benchmark in the slash registry (drives autocomplete+help) ---
    specs = src / "src" / "builtins" / "commands.zig"
    cs = src / "src" / "core" / "slash_commands" / "command_specs.zig"
    anchor_spec = '''    .{ .kind = .quit, .command = "/quit", .aliases = &.{"/exit"}, .help_entry = "/quit", .completion_description = "exit the interactive shell", .presentation_category = .general, .show_in_welcome = true },'''
    new_spec = '''    .{ .kind = .benchmark, .command = "/benchmark", .help_entry = "/benchmark", .completion_description = "fx-companion: run raw speed tests", .presentation_category = .general },'''
    if not specs.exists():
        problems.append("benchmark registry: builtins/commands.zig missing")
    elif not cs.exists():
        problems.append("benchmark registry: command_specs.zig missing")
    else:
        stext = specs.read_text()
        if '"/benchmark"' in stext:
            print("inject: benchmark spec already present")
        else:
            cstext = cs.read_text()
            router = src / "src" / "core" / "slash_commands" / "command_router.zig"
            router_text = None
            registry_ok = True
            if ".benchmark," not in cstext:
                kind_anchor = re.search(r'(    version,\n\};)', cstext)
                if not kind_anchor:
                    problems.append("benchmark registry: SlashKind anchor changed")
                    registry_ok = False
                elif not router.exists():
                    problems.append("benchmark registry: command_router.zig missing")
                    registry_ok = False
                else:
                    router_text = router.read_text()
                    parsed_anchor = re.search(r'(        \.version => \.version,\n)', router_text)
                    if not parsed_anchor:
                        problems.append("benchmark registry: parsedCommand anchor changed")
                        registry_ok = False
                    else:
                        cstext = cstext.replace(
                            kind_anchor.group(1),
                            '    version,\n    benchmark,\n};',
                            1,
                        )
                        router_text = router_text.replace(
                            parsed_anchor.group(1),
                            parsed_anchor.group(1) + '        .benchmark => .unknown,\n',
                            1,
                        )
            if anchor_spec not in stext:
                problems.append("benchmark registry: slash_specs anchor changed")
                registry_ok = False
            if registry_ok:
                if router_text is not None:
                    cs.write_text(cstext)
                    router.write_text(router_text)
                    print("inject: benchmark kind added")
                specs.write_text(stext.replace(anchor_spec, anchor_spec + "\n" + new_spec, 1))
                print("inject: /benchmark registered for completion")

    for problem in problems:
        print(f"inject: WARNING: {problem}; optional feature skipped", file=sys.stderr)
    _ = changed
    return 0


if __name__ == "__main__":
    sys.exit(main())
