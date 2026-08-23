//! Faithful replica of fx's workspace traversal at pin 04e0ae0.
//!
//! Source of truth: src/core/workspace/workspace_files.zig :: walkWorkspacePaths
//! (vercel-labs/fx @ 04e0ae0). Reproduced syscall-for-syscall:
//!   - std.Io.Dir.openDirAbsolute(..., .{ .iterate = true })
//!   - explicit stack of {dir, prefix, iter} frames, DFS
//!   - std.Io.Dir.Iterator.next() (getdirentries under the hood, 2048-byte buffer)
//!   - same ignored_directory_names list from src/core/workspace/ignored_dirs.zig
//!   - hidden-name skip (leading '.') unless include_hidden
//!   - single-threaded, exactly like fx's fallback_threaded (.init_single_threaded)
//!
//! Two modes:
//!   collect : dupe every relative file path into an arena (what fx really does)
//!   count   : count files/dirs only (isolates syscall cost from allocation)
//!
//! Used by the Week 3 gate: compare against the fx-companion daemon walk on the
//! identical tree.

const std = @import("std");

const io_mod = struct {
    var threaded: std.Io.Threaded = .init_single_threaded;
    pub fn getIo() std.Io {
        return threaded.io();
    }
};

/// Verbatim from fx src/core/workspace/ignored_dirs.zig @ 04e0ae0.
const ignored_directory_names: []const []const u8 = &.{
    ".git",
    ".zig-cache",
    "zig-out",
    "node_modules",
    ".next",
    "dist",
    "build",
    "coverage",
};

pub const Mode = enum { collect, count };

pub const WalkOut = struct {
    files: u64,
    dirs: u64,
    /// Bytes of relative-path text accumulated (collect mode only).
    path_bytes: u64 = 0,
};

fn isIgnoredName(name: []const u8) bool {
    for (ignored_directory_names) |ignored| {
        if (std.mem.eql(u8, name, ignored)) return true;
    }
    return false;
}

fn isHiddenName(name: []const u8) bool {
    return name.len > 0 and name[0] == '.';
}

const FrameEntry = struct {
    dir: std.Io.Dir,
    prefix: []u8,
    iter: std.Io.Dir.Iterator,
};

pub fn walk(root: []const u8, mode: Mode) !WalkOut {
    const io = io_mod.getIo();
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa_state.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out = WalkOut{ .files = 0, .dirs = 0 };

    // fx opens the root with iterate=true via openDirAbsolute.
    var root_dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch |e| {
        return e;
    };
    // Root frame owns root_dir; subframes own their dirs. Mirrors fx's
    // retain_prefix=false handling where prefix "" is never freed individually.
    const initial_prefix = try arena.dupe(u8, "");
    var stack: std.ArrayList(FrameEntry) = .empty;
    defer stack.deinit(arena);
    try stack.append(arena, .{
        .dir = root_dir,
        .prefix = initial_prefix,
        .iter = root_dir.iterate(),
    });
    // After appending, root_dir is owned by the frame; do not double-close.
    // (fx keeps the same aliasing.)

    while (stack.items.len > 0) {
        var top = &stack.items[stack.items.len - 1];
        const maybe_entry = top.iter.next(io) catch {
            var popped = stack.pop().?;
            popped.dir.close(io);
            continue;
        };

        if (maybe_entry) |entry| {
            switch (entry.kind) {
                .file, .sym_link => {
                    out.files += 1;
                    if (mode == .collect) {
                        // fx: joinRelative(prefix, name) + arena.dupe semantics.
                        const rel = try std.mem.concat(arena, u8, &.{
                            top.prefix,
                            if (top.prefix.len > 0) "/" else "",
                            entry.name,
                        });
                        out.path_bytes += rel.len;
                    }
                },
                .directory => {
                    if (isHiddenName(entry.name)) continue;
                    if (isIgnoredName(entry.name)) continue;
                    const new_prefix = try std.mem.concat(arena, u8, &.{
                        top.prefix,
                        if (top.prefix.len > 0) "/" else "",
                        entry.name,
                    });
                    out.dirs += 1;
                    var sub = top.dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                    try stack.append(arena, .{
                        .dir = sub,
                        .prefix = new_prefix,
                        .iter = sub.iterate(),
                    });
                },
                else => {},
            }
        } else {
            var popped = stack.pop().?;
            popped.dir.close(io);
        }
    }
    return out;
}
