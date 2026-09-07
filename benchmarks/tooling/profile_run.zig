//! Standalone production discovery profiler. This is deliberately not wired
//! into fx's command/UI surface; copy it beside the pinned upstream sources
//! when profiling is needed.
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

pub fn run(workspace_root: []const u8) !void {
    std.debug.print("fx-companion engagement (production discover)\n", .{});
    companion.clearSnapshotCache();
    workspace_files.companion_enabled = true;

    var cold_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer cold_arena.deinit();
    const cold_started = nowNs();
    const cold = try workspace_files.discover(cold_arena.allocator(), workspace_root, .{});
    const cold_ns = nowNs() - cold_started;
    const cold_hit = companion.lastCacheObservation().hit;

    var warm_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer warm_arena.deinit();
    const warm_started = nowNs();
    const warm = try workspace_files.discover(warm_arena.allocator(), workspace_root, .{});
    const warm_ns = nowNs() - warm_started;
    const warm_hit = companion.lastCacheObservation().hit;

    const companion_label: []const u8 = if (cold.source == .git)
        (if (warm_hit) "hit" else "miss")
    else if (warm_hit)
        "hit"
    else
        "skipped:unsorted-or-recursive";

    std.debug.print("  source        {s}\n", .{@tagName(cold.source)});
    std.debug.print("  companion     cold={s} warm={s} ({s})\n", .{
        if (cold_hit) "hit" else "miss",
        if (warm_hit) "hit" else "miss",
        companion_label,
    });
    std.debug.print("  paths         cold={d} warm={d}\n", .{ cold.files.len, warm.files.len });
    std.debug.print("  discover_ns   cold={d} warm={d} ({d:.3} ms / {d:.3} ms)\n", .{
        cold_ns,
        warm_ns,
        @as(f64, @floatFromInt(cold_ns)) / 1e6,
        @as(f64, @floatFromInt(warm_ns)) / 1e6,
    });
    std.debug.print("  no_model_request true\n", .{});
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const root = args.next() orelse return error.MissingRoot;
    try run(root);
}
