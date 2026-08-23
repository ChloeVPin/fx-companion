// traversal_bench: shootout between fts, readdir, and getattrlistbulk.
//
// Builds a synthetic tree (libc), walks it three ways in both modes:
//   names : count entries only
//   attrs : also sum file data sizes
// Reports wall clock per method per run plus medians.
//
// Usage:
//   traversal_bench [--root DIR] [--dirs 256] [--files 128] [--runs 3] [--keep]

const std = @import("std");
const fts = @import("fts_walk.zig");
const bulk = @import("bulk_walk.zig");
const readdir = @import("readdir_walk.zig");

extern "c" fn getpid() c_int;

const Options = struct {
    root: []const u8 = "",
    dirs: u32 = 256,
    files_per_dir: u32 = 128,
    runs: u32 = 3,
    keep_tree: bool = false,
};

fn parseArgs(argv: std.process.Args, alloc: std.mem.Allocator) !Options {
    var opts = Options{};
    var args = std.process.Args.Iterator.init(argv);
    defer args.deinit();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--root")) {
            const v = args.next() orelse "";
            opts.root = try alloc.dupe(u8, v);
        } else if (std.mem.eql(u8, a, "--dirs")) {
            opts.dirs = try std.fmt.parseInt(u32, args.next() orelse "256", 10);
        } else if (std.mem.eql(u8, a, "--files")) {
            opts.files_per_dir = try std.fmt.parseInt(u32, args.next() orelse "128", 10);
        } else if (std.mem.eql(u8, a, "--runs")) {
            opts.runs = try std.fmt.parseInt(u32, args.next() orelse "3", 10);
        } else if (std.mem.eql(u8, a, "--keep")) {
            opts.keep_tree = true;
        }
    }
    if (opts.root.len == 0) {
        opts.root = try std.fmt.allocPrint(alloc, "/tmp/fxc-bench-{d}", .{getpid()});
    }
    return opts;
}

fn nowNs() u64 {
    const cmod = struct {
        extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;
        const Timespec = extern struct { sec: isize, nsec: isize };
    };
    var ts: cmod.Timespec = undefined;
    // Darwin CLOCK_MONOTONIC_RAW == 4
    _ = cmod.clock_gettime(4, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

const Result = struct {
    method: []const u8,
    mode: []const u8,
    run: u32,
    entries: u64,
    bytes_sum: u64,
    wall_us: u64,
};

fn medianUs(results: []const Result, method: []const u8, mode: []const u8) ?u64 {
    var times: [64]u64 = undefined;
    var n: usize = 0;
    for (results) |r| {
        if (n >= times.len) break;
        if (std.mem.eql(u8, r.method, method) and std.mem.eql(u8, r.mode, mode)) {
            times[n] = r.wall_us;
            n += 1;
        }
    }
    if (n == 0) return null;
    std.mem.sort(u64, times[0..n], {}, std.sort.asc(u64));
    return times[n / 2];
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    const alloc = gpa_state.allocator();
    const opts = try parseArgs(init.args, alloc);

    try buildTree(opts.root, opts.dirs, opts.files_per_dir);
    defer if (!opts.keep_tree) deleteTree(opts.root);

    var results: [512]Result = undefined;
    var nres: usize = 0;

    std.debug.print("tree: {s}  dirs={d} files/dir={d} runs={d}\n", .{
        opts.root, opts.dirs, opts.files_per_dir, opts.runs,
    });

    var run: u32 = 0;
    while (run < opts.runs) : (run += 1) {
        const specs = [_]struct { m: []const u8, mode: []const u8, f: *const fn ([]const u8) anyerror!readdir.WalkOut }{
            .{ .m = "fts", .mode = "names", .f = fts.walkNames },
            .{ .m = "fts", .mode = "attrs", .f = fts.walkAttrs },
            .{ .m = "readdir", .mode = "names", .f = readdir.walkNames },
            .{ .m = "readdir", .mode = "attrs", .f = readdir.walkAttrs },
            .{ .m = "getattrlistbulk", .mode = "names", .f = bulk.walkNames },
            .{ .m = "getattrlistbulk", .mode = "attrs", .f = bulk.walkAttrs },
        };
        for (specs) |s| {
            const t0 = nowNs();
            const out = s.f(opts.root) catch |e| {
                std.debug.print("{s}/{s}: FAILED {s}\n", .{ s.m, s.mode, @errorName(e) });
                continue;
            };
            const us = (nowNs() - t0) / 1000;
            if (nres < results.len) {
                results[nres] = .{
                    .method = s.m,
                    .mode = s.mode,
                    .run = run,
                    .entries = out.entries,
                    .bytes_sum = out.bytes_sum,
                    .wall_us = us,
                };
                nres += 1;
            }
        }
    }

    std.debug.print("\nper-run wall_us:\n", .{});
    for (results[0..nres]) |r| {
        std.debug.print("  run{d}  {s:<16} {s:<6} entries={d:>7}  bytes={d:>10}  {d:>8} us\n", .{
            r.run, r.method, r.mode, r.entries, r.bytes_sum, r.wall_us,
        });
    }

    std.debug.print("\nmedians:\n", .{});
    const methods = [_][]const u8{ "fts", "readdir", "getattrlistbulk" };
    const modes = [_][]const u8{ "names", "attrs" };
    for (modes) |m| {
        for (methods) |meth| {
            if (medianUs(results[0..nres], meth, m)) |med| {
                std.debug.print("  {s:<16} {s:<6} {d:>8} us\n", .{ meth, m, med });
            }
        }
    }
}

extern "c" fn mkdir(path: [*:0]const u8, mode: c_int) c_int;

fn buildTree(root: []const u8, dirs: u32, files: u32) !void {
    var buf: [1024]u8 = undefined;
    if (root.len + 24 >= buf.len) return error.PathTooLong;
    _ = mkdir(@ptrCast(try std.fmt.bufPrintZ(&buf, "{s}", .{root})), 0o755);
    var d: u32 = 0;
    while (d < dirs) : (d += 1) {
        const sub = try std.fmt.bufPrintZ(&buf, "{s}/d{d}", .{ root, d });
        _ = mkdir(sub.ptr, 0o755);
        var f: u32 = 0;
        while (f < files) : (f += 1) {
            const fp = try std.fmt.bufPrintZ(&buf, "{s}/d{d}/f{d}.txt", .{ root, d, f });
            const fd = open(fp.ptr, 0x601, 0o644); // O_WRONLY|O_CREAT|O_TRUNC
            if (fd < 0) continue;
            var size: usize = (@as(usize, d) * 31 + f * 7) % 8192 + 1;
            var tmp: [256]u8 = undefined;
            while (size > 0) {
                const chunk = @min(size, tmp.len);
                if (write(fd, &tmp, chunk) < 0) break;
                size -= chunk;
            }
            _ = close(fd);
        }
    }
}

fn deleteTree(root: []const u8) void {
    // rm -rf via system(); one-shot cleanup, not on the measured path.
    var cmd: [1100]u8 = undefined;
    const z = std.fmt.bufPrintZ(&cmd, "rm -rf '{s}'", .{root}) catch return;
    _ = system(z.ptr);
}

extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn system(cmd: [*:0]const u8) c_int;
