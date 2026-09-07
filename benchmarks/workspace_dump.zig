//! External differential fingerprint for pristine-vs-injected upstream fx.
//! Compile this once before injection and once after injection. The output is
//! deterministic over workspace discovery metadata, ordered path bytes, and
//! path boundaries, so byte-equal output proves the public result matched.
const std = @import("std");
const workspace_files = @import("core/workspace/workspace_files.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const root = args.next() orelse return error.MissingRoot;
    const mode = args.next() orelse "git";
    const cap = if (args.next()) |raw| try std.fmt.parseInt(usize, raw, 10) else 600_000;

    if (comptime @hasDecl(workspace_files, "companion_enabled")) {
        workspace_files.companion_enabled = true;
    }

    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const result = try workspace_files.discover(arena_state.allocator(), root, .{
        .candidate_cap = cap,
        .sort_paths = true,
        .force_fallback = std.mem.eql(u8, mode, "recursive"),
    });

    var hasher = std.hash.Wyhash.init(0);
    for (result.files) |path| {
        hasher.update(std.mem.asBytes(&path.len));
        hasher.update(path);
    }
    const cap_reason = if (result.cap_reason) |reason| @tagName(reason) else "none";
    std.debug.print(
        "source={s} cap={d} incomplete={} cap_reason={s} overlong={d} paths={d} hash={x}\n",
        .{
            @tagName(result.source),
            result.candidate_cap,
            result.incomplete,
            cap_reason,
            result.skipped_overlong,
            result.files.len,
            hasher.final(),
        },
    );
}
