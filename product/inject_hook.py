#!/usr/bin/env python3
"""Inject the fx-companion accelerator hook into a vercel fx source tree.

Required seams: walkWorkspacePaths and gitRawList in workspace_files.zig.
No UI, command, branding, benchmark, or profile code is injected.
"""
import hashlib
import re
import sys
from pathlib import Path
from typing import List, Optional

MODULE_SRC = Path(__file__).parent / "fx_companion.zig"

FAST_PATH = '''    try checkCanceled(stop_requested);

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
        } else |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                paths_fast.deinit(arena);
                debug_trace.logf("core", "fx-companion unavailable ({s}); using stock walk", .{@errorName(err)});
            },
        }
    }

'''

def find_workspace_file(src: Path) -> Optional[Path]:
    direct = src / "src" / "core" / "workspace" / "workspace_files.zig"
    if direct.exists():
        return direct
    matches = list(src.rglob("workspace_files.zig"))
    return matches[0] if len(matches) == 1 else None


def apply_required_walk(ws: Path, problems: List[str]) -> bool:
    text = ws.read_text()
    fingerprint = hashlib.sha256(text.encode()).hexdigest()
    module_text = MODULE_SRC.read_text().replace("FXC_UPSTREAM_FINGERPRINT_UNSET", fingerprint)
    (ws.parent / "fx_companion.zig").write_text(module_text)

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
    if "fx-companion fast path" not in text:
        m = cancel_re.search(text)
        if not m:
            print("inject: required seam missing (fast-path site)", file=sys.stderr)
            return False
        text = text[: m.start()] + FAST_PATH + "    var paths: std.ArrayList([]const u8) = .empty;\n" + text[m.end() :]

    git_list_anchor = "        if (gitRawList(arena, workspace_root, options, stop_requested, executable)) |raw| {\n"
    git_take = '''        var companion_git_snapshot: ?*fx_companion.GitRawSnapshot = null;
        defer if (companion_git_snapshot) |snapshot| fx_companion.discardGitRawSnapshot(snapshot);
        if (companion_enabled) {
            companion_git_snapshot = fx_companion.beginGitRawSnapshot(
                workspace_root,
                executable,
                options.only_untracked,
                options.include_untracked,
                options.git_stdout_limit,
            ) catch null;
        }
        const companion_git_raw = if (companion_git_snapshot) |snapshot| cached: {
            if (fx_companion.takeGitRaw(snapshot, arena, stop_requested)) |raw| {
                break :cached raw;
            }
            break :cached gitRawList(arena, workspace_root, options, stop_requested, executable);
        } else gitRawList(arena, workspace_root, options, stop_requested, executable);
        if (companion_git_raw) |raw| {
            if (companion_git_snapshot) |snapshot| fx_companion.finishGitRawSnapshot(snapshot, raw);
'''
    if "beginGitRawSnapshot" not in text:
        if git_list_anchor not in text:
            print("inject: required seam missing (gitRawList)", file=sys.stderr)
            return False
        else:
            text = text.replace(git_list_anchor, git_take, 1)
            print("inject: raw git cache seam applied")

    ws.write_text(text)
    print("inject: walk seam applied to", ws)
    return True


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
    return 0


if __name__ == "__main__":
    sys.exit(main())
