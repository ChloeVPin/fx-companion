//! Stable-tree stress owner for the process-global snapshot cache.
const std = @import("std");
const companion = @import("core/workspace/fx_companion.zig");

const lanes = 8;

const Expected = struct {
    count: usize,
    hash: u64,
};

fn pathHash(paths: []const []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (paths) |path| {
        hasher.update(std.mem.asBytes(&path.len));
        hasher.update(path);
    }
    return hasher.final();
}

fn runOne(root: []const u8, target_files: bool, include_hidden: bool) !Expected {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    var overlong: usize = 0;
    var exact = false;
    const incomplete = try companion.walkPaths(
        arena_state.allocator(),
        root,
        &.{ ".git", ".zig-cache", "zig-out", "node_modules", ".next", "dist", "build", "coverage" },
        null,
        target_files,
        include_hidden,
        std.math.maxInt(usize),
        4096,
        null,
        &paths,
        &overlong,
        &exact,
        true,
    );
    if (incomplete or !exact or overlong != 0) return error.UnexpectedWalkMetadata;
    return .{ .count = paths.items.len, .hash = pathHash(paths.items) };
}

const Context = struct {
    root: []const u8,
    iterations: usize,
    expected: [3]Expected,
    failed: std.atomic.Value(bool) = .init(false),
};

fn worker(context: *Context, lane: usize) void {
    for (0..context.iterations) |iteration| {
        if (context.failed.load(.acquire)) return;
        const mode = (lane + iteration) % context.expected.len;
        const actual = runOne(
            context.root,
            mode != 1,
            mode == 2,
        ) catch {
            context.failed.store(true, .release);
            return;
        };
        if (actual.count != context.expected[mode].count or actual.hash != context.expected[mode].hash) {
            context.failed.store(true, .release);
            return;
        }
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const root = args.next() orelse return error.MissingRoot;
    const iterations = if (args.next()) |raw| try std.fmt.parseInt(usize, raw, 10) else 100;

    companion.clearSnapshotCache();
    var context = Context{
        .root = root,
        .iterations = iterations,
        .expected = .{
            try runOne(root, true, false),
            try runOne(root, false, false),
            try runOne(root, true, true),
        },
    };
    var threads: [lanes - 1]std.Thread = undefined;
    for (&threads, 1..) |*thread, lane| {
        thread.* = try std.Thread.spawn(.{}, worker, .{ &context, lane });
    }
    worker(&context, 0);
    for (threads) |thread| thread.join();
    if (context.failed.load(.acquire)) return error.ConcurrentCacheMismatch;
    std.debug.print("CONCURRENT_CACHE_OK lanes={d} iterations={d} calls={d}\n", .{
        lanes,
        iterations,
        lanes * iterations,
    });
}
