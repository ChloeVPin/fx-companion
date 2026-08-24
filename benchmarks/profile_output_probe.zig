//! Standalone owner for the in-session `/benchmark` profile renderer.
const std = @import("std");
const companion = @import("core/workspace/fx_companion.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const root = args.next() orelse return error.MissingRoot;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    var output: std.ArrayListUnmanaged(u8) = .empty;
    try companion.runBenchmark(arena_state.allocator(), root, &output);
    std.debug.print("{s}", .{output.items});
}
