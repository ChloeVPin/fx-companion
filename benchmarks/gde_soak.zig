// gde_soak: correctness soak for the getdirentries pool backend.
// Repeat runs must return identical entry counts with truncated=false,
// both backends must agree, and a worker sweep is printed. Run this
// against real trees (e.g. /opt/homebrew), not only synthetic ones:
// the anchor's flat shape hides prefix/path bugs that deep gem trees
// expose (this test caught a silent subtree-loss bug pre-commit).
const std = @import("std");
const bulk = @import("bulk_walk.zig");

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

    // Stability: 5 repeats at default workers; every count must agree.
    var ref: u64 = 0;
    for (0..5) |i| {
        const t0 = nowNs();
        const out = try bulk.walkNamesGde(root);
        const dt = nowNs() - t0;
        std.debug.print("run{d}: entries={d} us={d} truncated={}\n", .{ i, out.entries, dt / 1000, out.truncated });
        if (i == 0) ref = out.entries else if (out.entries != ref) return error.CountMismatch;
    }

    // Cross-backend agreement on a real tree.
    const b = try bulk.walkNames(root);
    std.debug.print("bulk : entries={d} truncated={}\n", .{ b.entries, b.truncated });
    if (b.entries != ref) return error.BackendMismatch;

    // Worker sweep for the gde backend.
    inline for (.{ 2, 4, 8, 12, 16 }) |W| {
        bulk.setWorkers(W);
        var times: [3]u64 = undefined;
        var ents: u64 = 0;
        for (0..3) |i| {
            const t0 = nowNs();
            const out = try bulk.walkNamesGde(root);
            times[i] = nowNs() - t0;
            ents = out.entries;
        }
        std.mem.sort(u64, &times, {}, std.sort.asc(u64));
        std.debug.print("workers={d}: median={d} us entries={d}\n", .{ W, times[1] / 1000, ents });
    }
}
