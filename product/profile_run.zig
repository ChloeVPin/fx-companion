//! /profile entry: production discover engagement, then recursive walk profile.
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

pub fn run(arena: std.mem.Allocator, workspace_root: []const u8, out: *std.ArrayListUnmanaged(u8)) !void {
    var aw: std.Io.Writer.Allocating = .fromArrayList(arena, out);
    const w = &aw.writer;
    try w.writeAll("fx-companion engagement (production discover)\n");
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

    try w.print("  source        {s}\n", .{@tagName(cold.source)});
    try w.print("  companion     cold={s} warm={s} ({s})\n", .{
        if (cold_hit) "hit" else "miss",
        if (warm_hit) "hit" else "miss",
        companion_label,
    });
    try w.print("  paths         cold={d} warm={d}\n", .{ cold.files.len, warm.files.len });
    try w.print("  git_list_ns   cold={d} warm={d} ({d:.3} ms / {d:.3} ms)\n", .{
        cold_ns,
        warm_ns,
        @as(f64, @floatFromInt(cold_ns)) / 1e6,
        @as(f64, @floatFromInt(warm_ns)) / 1e6,
    });
    try w.writeAll("  no_model_request true\n\n");
    out.* = aw.toArrayList();

    var rest: std.ArrayListUnmanaged(u8) = .empty;
    companion.runBenchmark(arena, workspace_root, &rest) catch |err| {
        rest.deinit(arena);
        var aw2: std.Io.Writer.Allocating = .fromArrayList(arena, out);
        try aw2.writer.print("recursive profile skipped: {s}\n", .{@errorName(err)});
        out.* = aw2.toArrayList();
        return;
    };
    try out.appendSlice(arena, rest.items);
    rest.deinit(arena);
}
