//! Isolated stock-vs-boosted workspace benchmark used by `/benchmark`.
const std = @import("std");
const companion = @import("core/workspace/fx_companion.zig");
const workspace_files = @import("core/workspace/workspace_files.zig");

extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;
const Timespec = extern struct { sec: isize, nsec: isize };
const rounds = 7;
const cap = 100_000;
fn nowNs() u64 { var ts: Timespec = undefined; _ = clock_gettime(4, &ts); return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec)); }
const Timed = struct { result: workspace_files.Result, ns: u64 };
fn discover(arena: std.mem.Allocator, root: []const u8, enabled: bool) !Timed {
    workspace_files.companion_enabled = enabled;
    const started = nowNs();
    const result = try workspace_files.discover(arena, root, .{ .candidate_cap = cap, .force_fallback = true, .sort_paths = true });
    return .{ .result = result, .ns = nowNs() - started };
}
fn equivalent(a: workspace_files.Result, b: workspace_files.Result) bool {
    if (a.source != b.source or a.candidate_cap != b.candidate_cap or a.incomplete != b.incomplete or a.cap_reason != b.cap_reason or a.skipped_overlong != b.skipped_overlong or a.files.len != b.files.len) return false;
    for (a.files, b.files) |left, right| if (!std.mem.eql(u8, left, right)) return false;
    return true;
}
const Pair = struct { stock: u64, boosted: u64, paths: usize, bytes: usize };
fn runPair(root: []const u8, stock_first: bool) !Pair {
    var stock_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator); defer stock_arena.deinit();
    var cold_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator); defer cold_arena.deinit();
    var warm_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator); defer warm_arena.deinit();
    companion.clearSnapshotCache();
    var stock: Timed = undefined; var cold: Timed = undefined; var boosted: Timed = undefined;
    if (stock_first) { stock = try discover(stock_arena.allocator(), root, false); cold = try discover(cold_arena.allocator(), root, true); boosted = try discover(warm_arena.allocator(), root, true); }
    else { cold = try discover(cold_arena.allocator(), root, true); boosted = try discover(warm_arena.allocator(), root, true); stock = try discover(stock_arena.allocator(), root, false); }
    if (!companion.lastCacheObservation().hit) return error.BoostedCacheMiss;
    if (!equivalent(stock.result, cold.result) or !equivalent(stock.result, boosted.result)) return error.EquivalenceFailure;
    var bytes: usize = 0; for (stock.result.files) |path| bytes += path.len;
    return .{ .stock = stock.ns, .boosted = boosted.ns, .paths = stock.result.files.len, .bytes = bytes };
}
fn median(values: []const u64) u64 { var copy: [rounds]u64 = undefined; @memcpy(copy[0..values.len], values); std.mem.sort(u64, copy[0..values.len], {}, std.sort.asc(u64)); return copy[values.len / 2]; }
fn best(values: []const u64) u64 { var result: u64 = std.math.maxInt(u64); for (values) |value| result = @min(result, value); return result; }
fn ms(ns: u64) f64 { return @as(f64, @floatFromInt(ns)) / 1_000_000.0; }

pub fn run(root: []const u8) !void {
    if (!companion.active()) return error.CompanionInactive;
    defer workspace_files.companion_enabled = true;
    std.debug.print("\nfx-companion benchmark\ntree: {s}\n", .{root});
    std.debug.print("method: isolated fx child; original stock code path vs boosted repeat path; 1 warmup + {d} rounds; alternating order\n", .{rounds});
    std.debug.print("scope: forced recursive discovery, sorted output, cap={d}; traversal only (process startup and boosted cold fill excluded)\n\n", .{cap});
    std.debug.print("             NON-BOOSTED (stock)       BOOSTED (fx-companion)\nround  first           time                     time        winner\n", .{});
    _ = try runPair(root, true);
    var stock_times: [rounds]u64 = undefined; var boosted_times: [rounds]u64 = undefined; var paths: usize = 0; var path_bytes: usize = 0;
    for (0..rounds) |i| {
        const stock_first = i % 2 == 0; const sample = try runPair(root, stock_first);
        stock_times[i] = sample.stock; boosted_times[i] = sample.boosted; paths = sample.paths; path_bytes = sample.bytes;
        std.debug.print(" {d}     {s: <5}    {d: >10.3} ms          {d: >10.3} ms     {s}\n", .{ i + 1, if (stock_first) "stock" else "boost", ms(sample.stock), ms(sample.boosted), if (sample.boosted < sample.stock) "BOOSTED" else "STOCK" });
    }
    const stock_med = median(&stock_times); const boosted_med = median(&boosted_times); const speedup = @as(f64, @floatFromInt(stock_med)) / @as(f64, @floatFromInt(boosted_med));
    std.debug.print("\nmedian          {d: >10.3} ms          {d: >10.3} ms     {d:.2}x\nbest            {d: >10.3} ms          {d: >10.3} ms\n", .{ ms(stock_med), ms(boosted_med), speedup, ms(best(&stock_times)), ms(best(&boosted_times)) });
    std.debug.print("correctness: PASS — every stock/cold/warm result byte-identical; paths={d}, path_bytes={d}, metadata matched\n", .{ paths, path_bytes });
    if (speedup < 1.0) std.debug.print("result: boosted LOST ({d:.2}x). This is reported as measured, not hidden.\n", .{speedup});
    std.debug.print("\n", .{});
}
