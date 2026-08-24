//! Prototype for cache validation by directory identity and metadata.
//!
//! A cached file-name snapshot is still current when every directory that
//! contributed to it has the same device, inode, mtime, and ctime. Entry
//! creation, removal, or rename changes its parent directory metadata; file
//! content writes do not invalidate a name-only snapshot.
const std = @import("std");
const companion = @import("core/workspace/fx_companion.zig");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;

const Timespec = extern struct { sec: isize, nsec: isize };
const workers = 8;

fn nowNs() u64 {
    var ts: Timespec = undefined;
    _ = clock_gettime(4, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

const Record = struct {
    path: [:0]const u8,
    expected: c.struct_stat,
    root: bool = false,
};

fn sameStamp(left: c.struct_stat, right: c.struct_stat) bool {
    return left.st_dev == right.st_dev and
        left.st_ino == right.st_ino and
        left.st_mode == right.st_mode and
        left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec and
        left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec and
        left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec and
        left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec;
}

const ValidateContext = struct {
    root_fd: c_int,
    records: []const Record,
    changed: std.atomic.Value(bool) = .init(false),
};

fn validateLane(context: *ValidateContext, lane: usize) void {
    var index = lane;
    while (index < context.records.len) : (index += workers) {
        if (context.changed.load(.acquire)) return;
        const record = context.records[index];
        var current: c.struct_stat = undefined;
        const rc = if (record.root)
            c.fstat(context.root_fd, &current)
        else
            c.fstatat(context.root_fd, record.path.ptr, &current, c.AT_SYMLINK_NOFOLLOW);
        if (rc != 0 or !sameStamp(record.expected, current)) {
            context.changed.store(true, .release);
            return;
        }
    }
}

fn validate(root_fd: c_int, records: []const Record) !bool {
    var context = ValidateContext{ .root_fd = root_fd, .records = records };
    var threads: [workers - 1]std.Thread = undefined;
    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    for (&threads, 1..) |*thread, lane| {
        thread.* = try std.Thread.spawn(.{}, validateLane, .{ &context, lane });
        started += 1;
    }
    validateLane(&context, 0);
    for (threads[0..started]) |thread| thread.join();
    return !context.changed.load(.acquire);
}

fn median(times: []const u64) u64 {
    var copy: [31]u64 = undefined;
    @memcpy(copy[0..times.len], times);
    std.mem.sort(u64, copy[0..times.len], {}, std.sort.asc(u64));
    return copy[times.len / 2];
}

fn best(times: []const u64) u64 {
    var value: u64 = std.math.maxInt(u64);
    for (times) |elapsed| value = @min(value, elapsed);
    return value;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const root = args.next() orelse return error.MissingRoot;
    const rounds = if (args.next()) |raw| try std.fmt.parseInt(usize, raw, 10) else 11;
    if (rounds == 0 or rounds > 31) return error.InvalidRounds;

    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var directories: std.ArrayList([]const u8) = .empty;
    var skipped_overlong: usize = 0;
    var exact = false;
    const incomplete = try companion.walkPaths(
        arena,
        root,
        &.{ ".git", ".zig-cache", "zig-out", "node_modules", ".next", "dist", "build", "coverage" },
        null,
        false,
        false,
        std.math.maxInt(usize),
        4096,
        null,
        &directories,
        &skipped_overlong,
        &exact,
        false,
    );
    if (incomplete or skipped_overlong != 0) return error.IncompleteBaseline;

    const root_z = try arena.dupeZ(u8, root);
    const root_fd = c.open(root_z.ptr, c.O_RDONLY);
    if (root_fd < 0) return error.OpenRootFailed;
    defer _ = c.close(root_fd);

    var records: std.ArrayList(Record) = .empty;
    var root_stat: c.struct_stat = undefined;
    if (c.fstat(root_fd, &root_stat) != 0) return error.StatRootFailed;
    try records.append(arena, .{ .path = try arena.dupeZ(u8, ""), .expected = root_stat, .root = true });
    for (directories.items) |path| {
        const path_z = try arena.dupeZ(u8, path);
        var expected: c.struct_stat = undefined;
        if (c.fstatat(root_fd, path_z.ptr, &expected, c.AT_SYMLINK_NOFOLLOW) != 0) {
            return error.StatDirectoryFailed;
        }
        try records.append(arena, .{ .path = path_z, .expected = expected });
    }

    if (!try validate(root_fd, records.items)) return error.WarmupMismatch;
    var times: [31]u64 = undefined;
    for (0..rounds) |round| {
        const started = nowNs();
        const unchanged = try validate(root_fd, records.items);
        times[round] = nowNs() - started;
        if (!unchanged) return error.UnexpectedMutation;
    }

    const mutation_parent = if (directories.items.len > 0) directories.items[directories.items.len / 2] else "";
    const mutation_path = if (mutation_parent.len == 0)
        try std.fmt.allocPrintSentinel(arena, ".fxc-stat-probe", .{}, 0)
    else
        try std.fmt.allocPrintSentinel(arena, "{s}/.fxc-stat-probe", .{mutation_parent}, 0);
    const fd = c.openat(root_fd, mutation_path.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL, @as(c_uint, 0o600));
    if (fd < 0) return error.CreateMutationFailed;
    _ = c.close(fd);
    defer _ = c.unlinkat(root_fd, mutation_path.ptr, 0);

    const mutation_started = nowNs();
    const unchanged_after_mutation = try validate(root_fd, records.items);
    const mutation_ns = nowNs() - mutation_started;
    if (unchanged_after_mutation) return error.MissedMutation;

    std.debug.print("directories={d} workers={d}\n", .{ records.items.len, workers });
    std.debug.print("clean_validation median={d:.3}ms best={d:.3}ms rounds={d}\n", .{
        @as(f64, @floatFromInt(median(times[0..rounds]))) / 1_000_000.0,
        @as(f64, @floatFromInt(best(times[0..rounds]))) / 1_000_000.0,
        rounds,
    });
    std.debug.print("mutation_validation={d:.3}ms detected=true parent={s}\n", .{
        @as(f64, @floatFromInt(mutation_ns)) / 1_000_000.0,
        mutation_parent,
    });
}
