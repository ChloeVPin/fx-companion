// fx_gate_bench: Week 3 gate. fx-replica walk vs fx-companion daemon walk
// on the same tree, both counting files (names mode), wall clock per run.
//
// Usage:
//   fx_gate_bench <tree-root> [runs]
//
// The daemon must be running (fx-companiond); the bench talks to it via
// walkrpc's client code path (MSG_WALK over the Mach service).

const std = @import("std");
const fx_replica = @import("fx_replica_walk.zig");
const fts = @import("fts_walk.zig");
const readdir = @import("readdir_walk.zig");
const bulk = @import("bulk_walk.zig");

extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;
const Timespec = extern struct { sec: isize, nsec: isize };

fn nowNs() u64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(4, &ts); // CLOCK_MONOTONIC_RAW
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn median(times: []u64) u64 {
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    return times[times.len / 2];
}

fn runNamed(
    label: []const u8,
    runs: u32,
    times: *[16]u64,
    entries_ref: *u64,
    ctx: *anyopaque,
    f: *const fn (*anyopaque) anyerror!u64,
) void {
    for (0..runs) |i| {
        const t0 = nowNs();
        entries_ref.* = f(ctx) catch |e| {
            std.debug.print("{s}: FAILED {s}\n", .{ label, @errorName(e) });
            return;
        };
        times[i] = nowNs() - t0;
    }
    std.debug.print("{s:<28} entries={d:<8} median={d} us\n", .{
        label, entries_ref.*, median(times[0..runs]) / 1000,
    });
}

const FtsCtx = struct { root: []const u8 };
fn ftsNames(ctx: *anyopaque) anyerror!u64 {
    const self: *FtsCtx = @ptrCast(@alignCast(ctx));
    const out = try fts.walkNames(self.root);
    return out.entries;
}
fn ftsAttrs(ctx: *anyopaque) anyerror!u64 {
    const self: *FtsCtx = @ptrCast(@alignCast(ctx));
    const out = try fts.walkAttrs(self.root);
    return out.entries;
}

const ReaddirCtx = struct { root: []const u8 };
fn readdirNames(ctx: *anyopaque) anyerror!u64 {
    const self: *ReaddirCtx = @ptrCast(@alignCast(ctx));
    const out = try readdir.walkNames(self.root);
    return out.entries;
}

const BulkCtx = struct { root: []const u8 };
fn bulkNames(ctx: *anyopaque) anyerror!u64 {
    const self: *BulkCtx = @ptrCast(@alignCast(ctx));
    const out = try bulk.walkNames(self.root);
    return out.entries;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    _ = &gpa_state;

    var args = std.process.Args.Iterator.init(init.args);
    defer args.deinit();
    _ = args.next(); // argv0
    const root = args.next() orelse {
        std.debug.print("usage: fx_gate_bench <tree-root> [runs]\n", .{});
        std.process.exit(2);
    };
    const runs: u32 = if (args.next()) |v| try std.fmt.parseInt(u32, v, 10) else 3;

    // --- fx replica (collect mode: fx really builds path strings) ---
    {
        var times: [16]u64 = undefined;
        var files_ref: u64 = 0;
        var path_bytes_ref: u64 = 0;
        for (0..runs) |i| {
            const t0 = nowNs();
            const out = try fx_replica.walk(root, .collect);
            times[i] = nowNs() - t0;
            files_ref = out.files;
            path_bytes_ref = out.path_bytes;
        }
        std.debug.print("fx-replica collect : files={d} path_bytes={d} median={d} us\n", .{
            files_ref, path_bytes_ref, median(times[0..runs]) / 1000,
        });
        for (times[0..runs], 0..) |t, i| {
            std.debug.print("  run{d}: {d} us\n", .{ i, t / 1000 });
        }
    }

    // --- fx replica count mode (pure syscall cost) ---
    {
        var times: [16]u64 = undefined;
        for (0..runs) |i| {
            const t0 = nowNs();
            const out = try fx_replica.walk(root, .count);
            times[i] = nowNs() - t0;
            if (i == 0) std.debug.print("fx-replica count   : files={d} dirs={d}\n", .{ out.files, out.dirs });
        }
        std.debug.print("fx-replica count   : median={d} us\n", .{median(times[0..runs]) / 1000});
    }

    // --- same-binary walkers: names mode, identical warm cache ---
    var times2: [16]u64 = undefined;
    var entries: u64 = 0;
    var fts_ctx = FtsCtx{ .root = root };
    runNamed("fts names", runs, &times2, &entries, @ptrCast(&fts_ctx), ftsNames);
    var rd_ctx = ReaddirCtx{ .root = root };
    runNamed("readdir names", runs, &times2, &entries, @ptrCast(&rd_ctx), readdirNames);
    var bulk_ctx = BulkCtx{ .root = root };
    runNamed("bulk(8w) names", runs, &times2, &entries, @ptrCast(&bulk_ctx), bulkNames);
}
