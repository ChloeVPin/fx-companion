//! End-to-end benchmark for the real pinned fx workspace discovery API.
//!
//! Copy this file to `src/fx_companion_discover_bench.zig` in an injected fx
//! tree, then build it with libc. The runner script does that without
//! modifying the user's upstream checkout.
const std = @import("std");
const companion = @import("core/workspace/fx_companion.zig");
const workspace_files = @import("core/workspace/workspace_files.zig");

extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;

const Timespec = extern struct { sec: isize, nsec: isize };
const max_rounds = 31;

fn nowNs() u64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(4, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

const TimedResult = struct {
    result: workspace_files.Result,
    elapsed_ns: u64,
};

fn discoverTimed(
    arena: std.mem.Allocator,
    root: []const u8,
    options: workspace_files.Options,
    enabled: bool,
) !TimedResult {
    workspace_files.companion_enabled = enabled;
    const started = nowNs();
    const result = try workspace_files.discover(arena, root, options);
    return .{ .result = result, .elapsed_ns = nowNs() - started };
}

fn assertEquivalent(stock: workspace_files.Result, boosted: workspace_files.Result) !void {
    if (stock.source != boosted.source or
        stock.candidate_cap != boosted.candidate_cap or
        stock.incomplete != boosted.incomplete or
        stock.cap_reason != boosted.cap_reason or
        stock.skipped_overlong != boosted.skipped_overlong or
        stock.files.len != boosted.files.len)
    {
        return error.MetadataMismatch;
    }
    for (stock.files, boosted.files) |stock_path, boosted_path| {
        if (!std.mem.eql(u8, stock_path, boosted_path)) return error.ContentMismatch;
    }
}

const Pair = struct {
    stock_ns: u64,
    cold_ns: u64,
    warm_ns: u64,
    validation_ns: u64,
    paths: usize,
    path_bytes: usize,
};

fn runPair(root: []const u8, options: workspace_files.Options, stock_first: bool) !Pair {
    var stock_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer stock_arena.deinit();
    var boosted_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer boosted_arena.deinit();
    var warm_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer warm_arena.deinit();

    var stock: TimedResult = undefined;
    var cold: TimedResult = undefined;
    var warm: TimedResult = undefined;
    companion.clearSnapshotCache();
    if (stock_first) {
        stock = try discoverTimed(stock_arena.allocator(), root, options, false);
        cold = try discoverTimed(boosted_arena.allocator(), root, options, true);
        if (companion.lastCacheObservation().hit) return error.UnexpectedColdHit;
        warm = try discoverTimed(warm_arena.allocator(), root, options, true);
    } else {
        cold = try discoverTimed(boosted_arena.allocator(), root, options, true);
        if (companion.lastCacheObservation().hit) return error.UnexpectedColdHit;
        warm = try discoverTimed(warm_arena.allocator(), root, options, true);
        stock = try discoverTimed(stock_arena.allocator(), root, options, false);
    }
    const observation = companion.lastCacheObservation();
    if (!observation.hit) return error.ExpectedWarmHit;
    try assertEquivalent(stock.result, cold.result);
    try assertEquivalent(stock.result, warm.result);

    var path_bytes: usize = 0;
    for (stock.result.files) |path| path_bytes += path.len;
    return .{
        .stock_ns = stock.elapsed_ns,
        .cold_ns = cold.elapsed_ns,
        .warm_ns = warm.elapsed_ns,
        .validation_ns = observation.validation_ns,
        .paths = stock.result.files.len,
        .path_bytes = path_bytes,
    };
}

fn median(times: []const u64) u64 {
    var copy: [max_rounds]u64 = undefined;
    @memcpy(copy[0..times.len], times);
    std.mem.sort(u64, copy[0..times.len], {}, std.sort.asc(u64));
    return copy[times.len / 2];
}

fn best(times: []const u64) u64 {
    var value: u64 = std.math.maxInt(u64);
    for (times) |elapsed| value = @min(value, elapsed);
    return value;
}

fn printDuration(ns: u64) void {
    std.debug.print("{d:.3} ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0});
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const root = args.next() orelse return error.MissingRoot;
    const rounds = if (args.next()) |raw|
        try std.fmt.parseInt(usize, raw, 10)
    else
        7;
    const cap = if (args.next()) |raw|
        try std.fmt.parseInt(usize, raw, 10)
    else
        600_000;
    if (rounds == 0 or rounds > max_rounds) return error.InvalidRounds;
    if (!companion.active()) return error.CompanionInactive;
    defer workspace_files.companion_enabled = true;

    const options: workspace_files.Options = .{
        .candidate_cap = cap,
        .force_fallback = true,
        .sort_paths = true,
    };

    // Untimed warmup for both implementations. Timed order then alternates
    // each round so neither implementation always receives the warmer cache.
    _ = try runPair(root, options, true);

    var stock_times: [max_rounds]u64 = undefined;
    var cold_times: [max_rounds]u64 = undefined;
    var warm_times: [max_rounds]u64 = undefined;
    var validation_times: [max_rounds]u64 = undefined;
    var paths: usize = 0;
    var path_bytes: usize = 0;
    for (0..rounds) |round| {
        const pair = try runPair(root, options, round % 2 == 0);
        stock_times[round] = pair.stock_ns;
        cold_times[round] = pair.cold_ns;
        warm_times[round] = pair.warm_ns;
        validation_times[round] = pair.validation_ns;
        paths = pair.paths;
        path_bytes = pair.path_bytes;
        std.debug.print("round={d} order={s} stock_ms={d:.3} cold_ms={d:.3} warm_ms={d:.3}\n", .{
            round + 1,
            if (round % 2 == 0) "stock-first" else "companion-first",
            @as(f64, @floatFromInt(pair.stock_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(pair.cold_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(pair.warm_ns)) / 1_000_000.0,
        });
    }

    const stock_median = median(stock_times[0..rounds]);
    const cold_median = median(cold_times[0..rounds]);
    const warm_median = median(warm_times[0..rounds]);
    const speedup = @as(f64, @floatFromInt(stock_median)) /
        @as(f64, @floatFromInt(warm_median));

    std.debug.print("tree={s}\n", .{root});
    std.debug.print("methodology=1 warmup pair, {d} timed pairs, alternating order, fresh arenas\n", .{rounds});
    std.debug.print("correctness=byte-identical paths={d} path_bytes={d} cap={d}\n", .{ paths, path_bytes, cap });
    std.debug.print("stock      median=", .{});
    printDuration(stock_median);
    std.debug.print(" best=", .{});
    printDuration(best(stock_times[0..rounds]));
    std.debug.print("\n", .{});
    std.debug.print("cold       median=", .{});
    printDuration(cold_median);
    std.debug.print(" best=", .{});
    printDuration(best(cold_times[0..rounds]));
    std.debug.print("\n", .{});
    std.debug.print("warm       median=", .{});
    printDuration(warm_median);
    std.debug.print(" best=", .{});
    printDuration(best(warm_times[0..rounds]));
    std.debug.print(" validation_median=", .{});
    printDuration(median(validation_times[0..rounds]));
    std.debug.print("\n", .{});
    std.debug.print("speedup={d:.3}x\n", .{speedup});
}
