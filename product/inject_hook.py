#!/usr/bin/env python3
"""Inject the fx-companion accelerator hook into a vercel fx source tree.

Required seam: walkWorkspacePaths in workspace_files.zig.
Optional UI/benchmark hooks warn and skip. They never fail inject.
"""
import re
import shutil
import sys
from pathlib import Path
from typing import List, Optional

MODULE_SRC = Path(__file__).parent / "fx_companion.zig"
BENCHMARK_SRC = Path(__file__).parent / "benchmark_runner.zig"
PROFILE_SRC = Path(__file__).parent / "profile_run.zig"

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

STOCK_CACHE_HOOK = '''    if (options.sort_paths) sortPathList(paths.items);

    if (companion_stock_snapshot) |snapshot| {
        fx_companion.finishStockSnapshot(
            snapshot,
            workspace_root,
            paths.items,
            skipped_overlong,
            incomplete,
        );
        fx_companion.discardStockSnapshot(snapshot);
        companion_stock_snapshot = null;
    }

    return .{'''

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


def find_workspace_file(src: Path) -> Optional[Path]:
    direct = src / "src" / "core" / "workspace" / "workspace_files.zig"
    if direct.exists():
        return direct
    matches = list(src.rglob("workspace_files.zig"))
    return matches[0] if len(matches) == 1 else None


def apply_required_walk(ws: Path, problems: List[str]) -> bool:
    text = ws.read_text()
    shutil.copyfile(MODULE_SRC, ws.parent / "fx_companion.zig")

    if 'const fx_companion = @import("fx_companion.zig");' not in text:
        m = re.search(r'(const std = @import\("std"\);\n)', text)
        if not m:
            print("inject: required seam missing (std import)", file=sys.stderr)
            return False
        text = text.replace(
            m.group(1),
            m.group(1)
            + "\n"
            + "// fx-companion: parallel getdirentries traversal (Apple Silicon). Purely\n"
            + "// additive: unsupported platforms and FX_NO_COMPANION=1 take the stock\n"
            + "// path below, byte-identical output either way.\n"
            + 'const fx_companion = @import("fx_companion.zig");\n',
            1,
        )

    walk_fn = re.search(r"\nfn walkWorkspacePaths\s*\(", text)
    if not walk_fn:
        print("inject: required seam missing (walkWorkspacePaths)", file=sys.stderr)
        return False
    if "pub var companion_enabled: bool = true;" not in text:
        switch_var = (
            "\n/// Global kill switch for the fx-companion accelerated walk. Set by the\n"
            "/// CLI surface from --no-companion / FX_NO_COMPANION so users can always\n"
            "/// force stock behavior.\n"
            "pub var companion_enabled: bool = true;\n"
        )
        text = text[: walk_fn.start()] + switch_var + text[walk_fn.start() :]

    cancel_re = re.compile(
        r"    try checkCanceled\(stop_requested\);\n+"
        r"    var paths: std\.ArrayList\(\[\]const u8\) = \.empty;\n"
    )
    if "var companion_stock_snapshot:" not in text:
        m = cancel_re.search(text)
        if not m:
            print("inject: required seam missing (fast-path site)", file=sys.stderr)
            return False
        text = text[: m.start()] + FAST_PATH + "    var paths: std.ArrayList([]const u8) = .empty;\n" + text[m.end() :]
    else:
        hook_start = -1
        for marker in (
            "    try checkCanceled(stop_requested);\n\n    var companion_stock_snapshot:",
            "    try checkCanceled(stop_requested);\n\n    // fx-companion fast path",
        ):
            hook_start = text.find(marker)
            if hook_start >= 0:
                break
        stock_start = text.find("    var paths: std.ArrayList([]const u8) = .empty;\n", max(hook_start, 0) + 1)
        if hook_start >= 0 and stock_start >= 0:
            installed = text[hook_start:stock_start]
            if "options.sort_paths" not in installed or "beginStockSnapshot" not in installed:
                text = text[:hook_start] + FAST_PATH + text[stock_start:]

    if "finishStockSnapshot(" in text and "incomplete," not in text.split("finishStockSnapshot(")[1][:400]:
        text = re.sub(
            r"fx_companion\.finishStockSnapshot\(\s*snapshot,\s*workspace_root,\s*paths\.items,\s*skipped_overlong,?\s*\)",
            "fx_companion.finishStockSnapshot(\n            snapshot,\n            workspace_root,\n            paths.items,\n            skipped_overlong,\n            incomplete,\n        )",
            text,
            count=1,
        )
    if "finishStockSnapshot" not in text:
        sort_re = re.compile(
            r"    if \(options\.sort_paths\) sortPathList\(paths\.items\);\n\n    return \.\{"
        )
        if not sort_re.search(text):
            print("inject: required seam missing (stock snapshot cache)", file=sys.stderr)
            return False
        text = sort_re.sub(STOCK_CACHE_HOOK, text, count=1)
    elif "if (incomplete)" in text and "finishStockSnapshot" in text:
        text = re.sub(
            r"    if \(companion_stock_snapshot\) \|snapshot\| \{\n"
            r"        if \(incomplete\) \{\n"
            r"            fx_companion\.finishStockSnapshot\(\n"
            r"                snapshot,\n"
            r"                workspace_root,\n"
            r"                paths\.items,\n"
            r"                skipped_overlong,\n"
            r"            \);\n"
            r"        \}\n"
            r"        fx_companion\.discardStockSnapshot\(snapshot\);\n"
            r"        companion_stock_snapshot = null;\n"
            r"    \}",
            """    if (companion_stock_snapshot) |snapshot| {
        fx_companion.finishStockSnapshot(
            snapshot,
            workspace_root,
            paths.items,
            skipped_overlong,
            incomplete,
        );
        fx_companion.discardStockSnapshot(snapshot);
        companion_stock_snapshot = null;
    }""",
            text,
            count=1,
        )

    git_list_anchor = "        if (gitRawList(arena, workspace_root, options, stop_requested, executable)) |raw| {\n"
    git_take = '''        if (companion_enabled and !options.force_fallback and !options.only_untracked and !options.include_untracked) {
            var git_paths: std.ArrayList([]const u8) = .empty;
            var git_overlong: usize = 0;
            var git_incomplete = false;
            if (fx_companion.takeGitFiles(
                arena,
                workspace_root,
                options.ignored_names,
                options.include_hidden,
                options.candidate_cap,
                options.sort_paths,
                &git_paths,
                &git_overlong,
                &git_incomplete,
            )) {
                return .{
                    .files = try git_paths.toOwnedSlice(arena),
                    .source = .git,
                    .candidate_cap = options.candidate_cap,
                    .incomplete = git_incomplete,
                    .cap_reason = if (git_incomplete) .candidate_cap else null,
                    .skipped_overlong = git_overlong,
                };
            }
        }
        if (gitRawList(arena, workspace_root, options, stop_requested, executable)) |raw| {
'''
    if "takeGitFiles" not in text:
        if git_list_anchor not in text:
            print("inject: WARNING: gitRawList anchor changed; git-list cache skipped", file=sys.stderr)
        else:
            text = text.replace(git_list_anchor, git_take, 1)
            print("inject: git-list cache take applied")

    git_store_anchor = "            const parsed = try parseRawList(arena, raw, .git, options);\n"
    git_store = '''            const parsed = try parseRawList(arena, raw, .git, options);
            if (companion_enabled and !options.only_untracked and !options.include_untracked) {
                fx_companion.storeGitFiles(
                    workspace_root,
                    options.ignored_names,
                    options.include_hidden,
                    options.candidate_cap,
                    options.sort_paths,
                    parsed.files,
                    parsed.incomplete,
                    parsed.skipped_overlong,
                );
            }
'''
    if "storeGitFiles" not in text:
        if git_store_anchor not in text:
            print("inject: WARNING: parseRawList git anchor changed; git-list store skipped", file=sys.stderr)
        else:
            text = text.replace(git_store_anchor, git_store, 1)
            print("inject: git-list cache store applied")

    ws.write_text(text)
    print("inject: walk seam applied to", ws)
    return True


def apply_optional_benchmark(src: Path, problems: List[str]) -> None:
    benchmark_dst = src / "src" / "fx_companion_benchmark.zig"
    try:
        if not benchmark_dst.exists() or benchmark_dst.read_bytes() != BENCHMARK_SRC.read_bytes():
            shutil.copyfile(BENCHMARK_SRC, benchmark_dst)
            print("inject: benchmark runner refreshed")
    except OSError as err:
        problems.append(f"benchmark runner: {err}")
        return

    main_zig = src / "src" / "main.zig"
    if not main_zig.exists():
        problems.append("benchmark child: main.zig missing")
        return
    main_text = main_zig.read_text()
    benchmark_import = 'const fx_companion_benchmark = @import("fx_companion_benchmark.zig");\n'
    if benchmark_import not in main_text:
        if 'const io_mod = @import("core/shared/io.zig");\n' not in main_text:
            problems.append("benchmark child: io_mod import anchor changed")
            return
        main_text = main_text.replace(
            'const io_mod = @import("core/shared/io.zig");\n',
            'const io_mod = @import("core/shared/io.zig");\n' + benchmark_import,
            1,
        )
    if "--fx-companion-benchmark" not in main_text:
        anchor = "    const raw_env: RawEnviron = @ptrCast(c_envp);\n\n"
        hook = (
            "    const raw_env: RawEnviron = @ptrCast(c_envp);\n\n"
            "    // fx-companion: isolated, visible stock-vs-boosted benchmark child.\n"
            '    if (raw_args.len == 3 and std.mem.eql(u8, std.mem.sliceTo(raw_args[1], 0), "--fx-companion-benchmark")) {\n'
            "        io_mod.setRawEnviron(raw_env);\n"
            "        const process_args = argsFromRaw(raw_args);\n"
            "        var threaded = std.Io.Threaded.init(processAllocator(), .{\n"
            "            .argv0 = .init(process_args),\n"
            "            .environ = .{ .block = environBlockFromRaw(raw_env) },\n"
            "        });\n"
            "        defer threaded.deinit();\n"
            "        io_mod.setIo(threaded.io());\n"
            "        try fx_companion_benchmark.run(std.mem.sliceTo(raw_args[2], 0));\n"
            "        return;\n"
            "    }\n\n"
        )
        if anchor not in main_text:
            problems.append("benchmark child: main.zig entry anchor changed")
            return
        main_text = main_text.replace(anchor, hook, 1)
    main_zig.write_text(main_text)


def apply_optional_badge(src: Path, problems: List[str]) -> None:
    render = src / "src" / "ui" / "render.zig"
    if not render.exists():
        problems.append("badge: render.zig missing")
        return
    rtext = render.read_text()
    if "badge_buf: [128]u8" in rtext and "boostedBadge" in rtext:
        rtext = rtext.replace("var badge_buf: [128]u8 = undefined;", "var badge_buf: [512]u8 = undefined;", 1)
        render.write_text(rtext)
        print("inject: upgraded badge buffer 128 -> 512")
        rtext = render.read_text()
    if "boostedBadge" in rtext:
        print("inject: badge already present")
        return
    if WELCOME_OLD not in rtext:
        problems.append("badge: welcomeMessage anchor changed upstream")
        return
    candidate = rtext.replace(WELCOME_OLD, WELCOME_NEW, 1)
    m = re.search(r'(const main = @import\("\.\./main\.zig"\);\n)', candidate)
    if not m:
        problems.append("badge: render import anchor changed")
        return
    candidate = candidate.replace(
        m.group(1),
        m.group(1) + 'const fx_companion = @import("../core/workspace/fx_companion.zig");\n',
        1,
    )
    render.write_text(candidate)
    print("inject: badge applied to", render)


def apply_optional_slash(src: Path, problems: List[str]) -> None:
    profile_dst = src / "src" / "fx_companion_profile.zig"
    try:
        if PROFILE_SRC.exists():
            if not profile_dst.exists() or profile_dst.read_bytes() != PROFILE_SRC.read_bytes():
                shutil.copyfile(PROFILE_SRC, profile_dst)
                print("inject: profile engagement runner refreshed")
    except OSError as err:
        problems.append(f"profile runner: {err}")

    appc = src / "src" / "core" / "app" / "app_commands.zig"
    if not appc.exists():
        problems.append("benchmark handler: app_commands.zig missing")
        return
    atext = appc.read_text()
    if "fx_companion_profile" not in atext and 'const fx_companion = @import("../workspace/fx_companion.zig");' in atext:
        atext = atext.replace(
            'const fx_companion = @import("../workspace/fx_companion.zig");\n',
            'const fx_companion = @import("../workspace/fx_companion.zig");\n'
            'const fx_companion_profile = @import("../../fx_companion_profile.zig");\n',
            1,
        )
        appc.write_text(atext)
        atext = appc.read_text()
        print("inject: profile import added")
    if "fx_companion.runBenchmark(app.alloc, app.workspace_root, &body)" in atext:
        atext = atext.replace(
            "fx_companion.runBenchmark(app.alloc, app.workspace_root, &body)",
            "fx_companion_profile.run(app.alloc, app.workspace_root, &body)",
            1,
        )
        appc.write_text(atext)
        atext = appc.read_text()
        print("inject: /profile upgraded to production engagement")
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
            // fx-companion: /benchmark runs in an isolated fx child with the
            // terminal attached, so each round is visible as it completes.
            if (std.mem.startsWith(u8, cmd_raw, "/benchmark")) {
                const executable = try fx_companion.executablePathAlloc(app.alloc);
                defer app.alloc.free(executable);
                try app.runExternalInteractive(&.{ executable, "--fx-companion-benchmark", app.workspace_root });
                return;
            }
            if (std.mem.startsWith(u8, cmd_raw, "/profile")) {
                var body: std.ArrayListUnmanaged(u8) = .empty;
                fx_companion_profile.run(app.alloc, app.workspace_root, &body) catch |err| {
                    body.deinit(app.alloc);
                    try app.writeDomainNotice(.{ .topic = "profile", .tone = .@"error", .body = try std.fmt.allocPrint(app.alloc, "profile failed: {s}", .{@errorName(err)}) }, true);
                    return;
                };
                try app.writeDomainNotice(.{ .topic = "profile", .tone = .neutral, .body = body.items }, true);
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
                        anchor_imp + 'const fx_companion = @import("../workspace/fx_companion.zig");\n'
                        'const fx_companion_profile = @import("../../fx_companion_profile.zig");\n',
                        1,
                    )
                elif "fx_companion_profile" not in candidate:
                    candidate = candidate.replace(
                        'const fx_companion = @import("../workspace/fx_companion.zig");\n',
                        'const fx_companion = @import("../workspace/fx_companion.zig");\n'
                        'const fx_companion_profile = @import("../../fx_companion_profile.zig");\n',
                        1,
                    )
                appc.write_text(candidate)
                print("inject: /benchmark applied to", appc)

    specs = src / "src" / "builtins" / "commands.zig"
    cs = src / "src" / "core" / "slash_commands" / "command_specs.zig"
    anchor_spec = '''    .{ .kind = .quit, .command = "/quit", .aliases = &.{"/exit"}, .help_entry = "/quit", .completion_description = "exit the interactive shell", .presentation_category = .general, .show_in_welcome = true },'''
    new_spec = '''    .{ .kind = .benchmark, .command = "/benchmark", .help_entry = "/benchmark", .completion_description = "fx-companion: compare boosted vs stock", .presentation_category = .general },'''
    if not specs.exists():
        problems.append("benchmark registry: builtins/commands.zig missing")
        return
    if not cs.exists():
        problems.append("benchmark registry: command_specs.zig missing")
        return
    stext = specs.read_text()
    if '"/benchmark"' in stext:
        print("inject: benchmark spec already present")
        return
    cstext = cs.read_text()
    router = src / "src" / "core" / "slash_commands" / "command_router.zig"
    router_text = None
    if ".benchmark," not in cstext:
        kind_anchor = re.search(r"(    version,\n\};)", cstext)
        if not kind_anchor:
            problems.append("benchmark registry: SlashKind anchor changed")
            return
        if not router.exists():
            problems.append("benchmark registry: command_router.zig missing")
            return
        router_text = router.read_text()
        parsed_anchor = re.search(r"(        \.version => \.version,\n)", router_text)
        if not parsed_anchor:
            problems.append("benchmark registry: parsedCommand anchor changed")
            return
        cstext = cstext.replace(kind_anchor.group(1), "    version,\n    benchmark,\n};", 1)
        router_text = router_text.replace(
            parsed_anchor.group(1),
            parsed_anchor.group(1) + "        .benchmark => .unknown,\n",
            1,
        )
    if anchor_spec not in stext:
        problems.append("benchmark registry: slash_specs anchor changed")
        return
    if router_text is not None:
        cs.write_text(cstext)
        router.write_text(router_text)
        print("inject: benchmark kind added")
    specs.write_text(stext.replace(anchor_spec, anchor_spec + "\n" + new_spec, 1))
    print("inject: /benchmark registered for completion")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: inject_hook.py <fx-src-dir>", file=sys.stderr)
        return 1
    src = Path(sys.argv[1])
    ws = find_workspace_file(src)
    if ws is None:
        print("inject: missing workspace_files.zig", file=sys.stderr)
        return 1
    problems: List[str] = []
    if not apply_required_walk(ws, problems):
        return 1
    apply_optional_benchmark(src, problems)
    apply_optional_badge(src, problems)
    apply_optional_slash(src, problems)
    for problem in problems:
        print(f"inject: WARNING: {problem}; optional feature skipped", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
