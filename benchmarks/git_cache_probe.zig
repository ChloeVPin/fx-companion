//! Cross-process probe for the production git ls-files snapshot cache.
//!
//! The first invocation clears prior snapshots and must take the stock git
//! path. A second invocation must reuse the same pinned fx result from disk.
//! The upstream workspace discovery API and result contract are unchanged.

const std = @import("std");
const companion = @import("core/workspace/fx_companion.zig");
const workspace_files = @import("core/workspace/workspace_files.zig");

extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;

const Timespec = extern struct { sec: isize, nsec: isize };

fn nowNs() u64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(4, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const root = args.next() orelse return error.MissingRoot;
    const clear = if (args.next()) |flag| std.mem.eql(u8, flag, "--clear") else false;
    if (!companion.active()) return error.CompanionInactive;

    if (clear) companion.clearSnapshotCache();

    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    workspace_files.companion_enabled = true;
    const started = nowNs();
    const result = try workspace_files.discover(arena.allocator(), root, .{
        .candidate_cap = 100_000,
        .sort_paths = true,
    });
    const elapsed_ns = nowNs() - started;
    if (result.source != .git) return error.ExpectedGitSource;

    const hit = companion.lastCacheObservation().hit;
    if (clear and hit) return error.UnexpectedColdHit;
    if (!clear and !hit) return error.MissingDiskHit;
    std.debug.print("git-cache {s} hit={} paths={d} elapsed_ms={d:.3}\n", .{
        if (clear) "cold" else "disk",
        hit,
        result.files.len,
        @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0,
    });
}
