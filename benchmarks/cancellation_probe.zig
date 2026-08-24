//! Repeatedly cancels a cold traversal while workers are active.
const std = @import("std");
const companion = @import("core/workspace/fx_companion.zig");

extern "c" fn usleep(microseconds: c_uint) c_int;

const Context = struct {
    root: []const u8,
    stop: std.atomic.Value(bool) = .init(false),
    outcome: std.atomic.Value(u8) = .init(0),
};

fn runCanceled(context: *Context) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    var paths: std.ArrayList([]const u8) = .empty;
    var overlong: usize = 0;
    var exact = false;
    _ = companion.walkPaths(
        arena_state.allocator(),
        context.root,
        &.{ ".git", ".zig-cache", "zig-out", "node_modules", ".next", "dist", "build", "coverage" },
        null,
        true,
        false,
        std.math.maxInt(usize),
        4096,
        &context.stop,
        &paths,
        &overlong,
        &exact,
        true,
    ) catch |err| {
        context.outcome.store(if (err == error.Canceled) 1 else 2, .release);
        return;
    };
    context.outcome.store(3, .release);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const root = args.next() orelse return error.MissingRoot;
    const iterations = if (args.next()) |raw| try std.fmt.parseInt(usize, raw, 10) else 100;

    for (0..iterations) |_| {
        companion.clearSnapshotCache();
        var context = Context{ .root = root };
        const thread = try std.Thread.spawn(.{}, runCanceled, .{&context});
        _ = usleep(1000);
        context.stop.store(true, .seq_cst);
        thread.join();
        if (context.outcome.load(.acquire) != 1) return error.CancellationMismatch;
    }
    std.debug.print("CANCELLATION_OK iterations={d}\n", .{iterations});
}
