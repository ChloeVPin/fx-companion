// Worker-count sweep for the bulk walker, driven in-process.
const std = @import("std");
const bulk = @import("bulk_walk");

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

    // Warm.
    _ = try bulk.walkNames(root);

    inline for (.{ 1, 2, 4, 6, 8 }) |W| {
        bulk.setWorkers(W);
        var times: [3]u64 = undefined;
        for (0..3) |i| {
            const t0 = nowNs();
            const out = try bulk.walkNames(root);
            times[i] = nowNs() - t0;
            if (i == 0) std.debug.print("  entries={d}\n", .{out.entries});
        }
        std.mem.sort(u64, &times, {}, std.sort.asc(u64));
        std.debug.print("workers={d}: median={d} us\n", .{ W, times[1] / 1000 });
    }
}
