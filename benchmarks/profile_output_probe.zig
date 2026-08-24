//! Standalone owner for the in-session `/benchmark` profile renderer.
const std = @import("std");
const companion = @import("core/workspace/fx_companion.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const root = args.next() orelse return error.MissingRoot;
    const expectation = args.next();
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    var output: std.ArrayListUnmanaged(u8) = .empty;
    try companion.runBenchmark(arena_state.allocator(), root, &output);
    if (std.mem.find(u8, output.items, "profile unavailable") != null) {
        return error.LegacyUnavailableResult;
    }
    if (expectation) |expected| {
        if (std.mem.eql(u8, expected, "--require-responsive") and
            std.mem.find(u8, output.items, "responsive bounded probe") == null)
        {
            return error.MissingResponsiveGuard;
        }
        if (std.mem.eql(u8, expected, "--require-full") and
            std.mem.find(u8, output.items, "1 warmup + 7 rounds") == null)
        {
            return error.MissingFullProfile;
        }
    }
    std.debug.print("{s}", .{output.items});
}
